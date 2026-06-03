-- =====================================================================
-- Flowtym · Module RH/Staff — schéma multi-tenant (hotel_id) + RLS
-- Migration : rh_staff_module_schema
-- Tenant = hotels(id) ; sécurité via public.pl_my_hotels()
-- Additive et REJOUABLE (if not exists / on conflict / drop policy if exists)
-- =====================================================================

create or replace function public.pl_touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------------------- Référentiels ----------------------
create table if not exists public.staff_departments (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (hotel_id, name)
);

create table if not exists public.staff_roles (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  name text not null,
  department_id uuid references public.staff_departments(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (hotel_id, name)
);

-- ---------------------- Fiche collaborateur ----------------------
create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  first_name text not null,
  last_name  text not null,
  role text,
  role_id uuid references public.staff_roles(id) on delete set null,
  department text,
  department_id uuid references public.staff_departments(id) on delete set null,
  contract_type text not null default 'CDI'
    check (contract_type in ('CDI','CDD','Extra','Stage','Interim','Apprentissage')),
  hire_date date,
  rest_days int[] not null default '{}',          -- 0=dimanche … 6=samedi
  phone text, email text, address text,
  emergency_contact text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_employees_hotel on public.employees(hotel_id);
create index if not exists idx_employees_hotel_active on public.employees(hotel_id, active);

create table if not exists public.employee_contracts (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  type text not null default 'CDI'
    check (type in ('CDI','CDD','Extra','Stage','Interim','Apprentissage')),
  start_date date, end_date date,
  weekly_hours numeric(5,1),
  gross_monthly_salary numeric(10,2),
  signed boolean not null default false,
  document_url text,
  created_at timestamptz not null default now()
);
create index if not exists idx_contracts_employee on public.employee_contracts(employee_id);

create table if not exists public.employee_documents (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  doc_type text not null
    check (doc_type in ('cni','passport','sejour','rib','domicile','hebergement','contrat','autre')),
  status text not null default 'missing'
    check (status in ('provided','missing','expired','pending')),
  file_url text,
  expires_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (hotel_id, employee_id, doc_type)
);

-- ---------------------- Planning & absences ----------------------
create table if not exists public.staff_planning (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  day date not null,
  status text not null check (status in ('P','CP','RTT','MAL','MAT','CSS','AE','F')),
  duration numeric(3,1) not null default 1.0 check (duration in (0.5,1.0)),
  note text,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (hotel_id, employee_id, day)
);
create index if not exists idx_planning_hotel_day on public.staff_planning(hotel_id, day);
create index if not exists idx_planning_emp_day on public.staff_planning(employee_id, day);

create table if not exists public.staff_absences (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  type text not null check (type in ('CP','RTT','MAL','MAT','CSS','AE','F')),
  start_date date not null,
  end_date date not null,
  days numeric(5,1),
  status text not null default 'approved'
    check (status in ('pending','approved','rejected','cancelled')),
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists idx_absences_hotel_emp on public.staff_absences(hotel_id, employee_id);

-- ---------------------- Triggers updated_at ----------------------
drop trigger if exists trg_employees_touch on public.employees;
create trigger trg_employees_touch before update on public.employees
  for each row execute function public.pl_touch_updated_at();
drop trigger if exists trg_emp_docs_touch on public.employee_documents;
create trigger trg_emp_docs_touch before update on public.employee_documents
  for each row execute function public.pl_touch_updated_at();
drop trigger if exists trg_planning_touch on public.staff_planning;
create trigger trg_planning_touch before update on public.staff_planning
  for each row execute function public.pl_touch_updated_at();
drop trigger if exists trg_absences_touch on public.staff_absences;
create trigger trg_absences_touch before update on public.staff_absences
  for each row execute function public.pl_touch_updated_at();

-- ---------------------- RLS : isolation stricte par hotel_id ----------------------
do $$
declare t text;
begin
  foreach t in array array['staff_departments','staff_roles','employees','employee_contracts',
                           'employee_documents','staff_planning','staff_absences']
  loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists %I on public.%I;', t||'_rls', t);
    execute format($f$create policy %I on public.%I for all
      using (hotel_id in (select public.pl_my_hotels()))
      with check (hotel_id in (select public.pl_my_hotels()));$f$, t||'_rls', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated;', t);
  end loop;
end $$;

-- ---------------------- Vue de synthèse (security_invoker) ----------------------
create or replace view public.v_staff_month_summary as
select
  p.hotel_id, p.employee_id,
  (date_trunc('month', p.day))::date as month,
  sum(case when p.status='P'  then p.duration else 0 end) as worked_days,
  sum(case when p.status='CP' then p.duration else 0 end) as cp_days,
  sum(case when p.status in ('RTT','MAL','MAT','CSS','AE') then p.duration else 0 end) as other_absences,
  count(*) as entries
from public.staff_planning p
group by p.hotel_id, p.employee_id, (date_trunc('month', p.day))::date;
alter view public.v_staff_month_summary set (security_invoker = on);
grant select on public.v_staff_month_summary to authenticated;

-- ---------------------- Seed des référentiels (par hôtel) ----------------------
insert into public.staff_departments (hotel_id, name, sort_order)
select h.id, d.name, d.so from public.hotels h
cross join (values ('Réception',1),('Étage',2),('Technique',3),('Restauration',4),('Direction',5),('Administration',6))
  as d(name, so)
on conflict (hotel_id, name) do nothing;

insert into public.staff_roles (hotel_id, name, department_id)
select h.id, r.name, dep.id
from public.hotels h
cross join (values
  ('Réceptionniste','Réception'),('Chef de réception','Réception'),('Veilleur de nuit','Réception'),
  ('Gouvernante','Étage'),('Femme de chambre','Étage'),('Valet de chambre','Étage'),
  ('Technicien','Technique'),('Serveur','Restauration'),('Plongeur','Restauration'),
  ('Cuisinier','Restauration'),('Directeur','Direction'),('Comptable','Administration')
) as r(name, dept)
left join public.staff_departments dep on dep.hotel_id=h.id and dep.name=r.dept
on conflict (hotel_id, name) do nothing;
