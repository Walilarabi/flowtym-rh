-- Migration 30 : Rythmes de travail + historique de génération automatique du planning

-- 1. Modèles de travail par salarié
create table if not exists employee_work_patterns (
  id                uuid primary key default gen_random_uuid(),
  hotel_id          uuid not null references hotels(id) on delete cascade,
  employee_id       uuid not null references employees(id) on delete cascade,
  pattern_type      text not null default 'manual'
                    check (pattern_type in ('fixed_days_off','rotating_cycle','manual')),
  fixed_days_off    jsonb,           -- ex: [0,6] (0=dim, 6=sam)
  cycle_start_date  date,            -- date réelle du jour 1 du cycle
  cycle_length_days int,             -- longueur du cycle en jours
  cycle_days        jsonb,           -- [{day:1,status:"work"},{day:2,status:"off"},...}]
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (hotel_id, employee_id)
);

alter table employee_work_patterns enable row level security;
drop policy if exists ewp_hotel_isolation on employee_work_patterns;
create policy ewp_hotel_isolation on employee_work_patterns for all
  using  (hotel_id in (select pl_my_hotels()))
  with check (hotel_id in (select pl_my_hotels()));
grant select, insert, update, delete on employee_work_patterns to authenticated;

drop trigger if exists ewp_touch on employee_work_patterns;
create trigger ewp_touch before update on employee_work_patterns
  for each row execute function pl_touch_updated_at();

-- 2. Historique des générations automatiques
create table if not exists planning_generation_runs (
  id             uuid primary key default gen_random_uuid(),
  hotel_id       uuid not null references hotels(id) on delete cascade,
  generated_by   uuid references auth.users(id),
  scope_type     text not null check (scope_type in ('employee','service','establishment')),
  scope_id       text,              -- employee_id ou service name
  period_start   date not null,
  period_end     date not null,
  mode           text not null,    -- 'safe' | 'force'
  status         text not null default 'done' check (status in ('done','partial','error')),
  summary_json   jsonb,
  created_at     timestamptz not null default now()
);

alter table planning_generation_runs enable row level security;
drop policy if exists pgr_hotel_isolation on planning_generation_runs;
create policy pgr_hotel_isolation on planning_generation_runs for all
  using  (hotel_id in (select pl_my_hotels()))
  with check (hotel_id in (select pl_my_hotels()));
grant select, insert on planning_generation_runs to authenticated;

-- 3. Détail ligne par ligne (audit trail)
create table if not exists planning_generation_items (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references planning_generation_runs(id) on delete cascade,
  employee_id  uuid not null references employees(id) on delete cascade,
  date         date not null,
  old_value    text,
  new_value    text,
  action       text not null check (action in ('created','skipped','protected','conflict')),
  reason       text,
  created_at   timestamptz not null default now()
);

alter table planning_generation_items enable row level security;
drop policy if exists pgi_via_run on planning_generation_items;
create policy pgi_via_run on planning_generation_items for all
  using  (run_id in (select id from planning_generation_runs where hotel_id in (select pl_my_hotels())))
  with check (run_id in (select id from planning_generation_runs where hotel_id in (select pl_my_hotels())));
grant select, insert on planning_generation_items to authenticated;

create index if not exists idx_ewp_emp on employee_work_patterns(hotel_id, employee_id);
create index if not exists idx_pgr_hotel on planning_generation_runs(hotel_id, created_at desc);
create index if not exists idx_pgi_run on planning_generation_items(run_id);
