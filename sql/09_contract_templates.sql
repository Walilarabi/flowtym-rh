-- Flowtym RH · 09 — Modèles de contrats versionnables (HTML avec variables)
create table if not exists public.contract_templates (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  parent_id uuid references public.contract_templates(id),
  version int not null default 1,
  name text not null,
  contract_type text not null check (contract_type in ('CDI','CDD','Extra','Saisonnier','Stage','Apprentissage','Interim')),
  department_id uuid references public.staff_departments(id),
  role_id uuid references public.staff_roles(id),
  body_html text not null,
  status text not null default 'active' check (status in ('active','archived')),
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_contract_templates_hotel on public.contract_templates (hotel_id, status, contract_type);
alter table public.contract_templates enable row level security;
drop policy if exists contract_templates_hotel_isolation on public.contract_templates;
create policy contract_templates_hotel_isolation on public.contract_templates for all
  using (hotel_id in (select public.pl_my_hotels()))
  with check (hotel_id in (select public.pl_my_hotels()));
grant select, insert, update, delete on public.contract_templates to authenticated;
drop trigger if exists contract_templates_touch on public.contract_templates;
create trigger contract_templates_touch before update on public.contract_templates
  for each row execute function public.pl_touch_updated_at();
