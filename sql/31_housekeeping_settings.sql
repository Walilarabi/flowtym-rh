-- Migration 31 : Paramétrage service étages (housekeeping)

create table if not exists housekeeping_settings (
  id                    uuid primary key default gen_random_uuid(),
  hotel_id              uuid not null references hotels(id) on delete cascade unique,
  -- Minimum par jour de semaine (0=dim, 1=lun, ..., 6=sam)
  min_staff             jsonb not null default '{"0":3,"1":3,"2":3,"3":3,"4":3,"5":4,"6":4}',
  -- Nom du service étages dans la DB (flexible par hôtel)
  dept_name             text not null default 'Étage',
  -- Nom du rôle(s) à compter (jsonb array, flexible)
  roles_counted         jsonb not null default '["Femme de chambre","Gouvernante"]',
  -- Architecture PMS (valeurs nulles jusqu''à la connexion)
  pms_productivity      int default 14,   -- chambres nettoyées par personne par jour
  pms_enabled           boolean not null default false,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

alter table housekeeping_settings enable row level security;
drop policy if exists hks_hotel_isolation on housekeeping_settings;
create policy hks_hotel_isolation on housekeeping_settings for all
  using  (hotel_id in (select pl_my_hotels()))
  with check (hotel_id in (select pl_my_hotels()));
grant select, insert, update, delete on housekeeping_settings to authenticated;

drop trigger if exists hks_touch on housekeeping_settings;
create trigger hks_touch before update on housekeeping_settings
  for each row execute function pl_touch_updated_at();

-- Table PMS future (architecture prête, données nulles pour l'instant)
create table if not exists pms_daily_data (
  id             uuid primary key default gen_random_uuid(),
  hotel_id       uuid not null references hotels(id) on delete cascade,
  date           date not null,
  rooms_sold     int,
  rooms_occupied int,
  departures     int,
  arrivals       int,
  stay_overs     int,
  occupancy_rate numeric(5,2),
  source         text default 'manual',
  created_at     timestamptz not null default now(),
  unique (hotel_id, date)
);

alter table pms_daily_data enable row level security;
drop policy if exists pms_hotel_isolation on pms_daily_data;
create policy pms_hotel_isolation on pms_daily_data for all
  using  (hotel_id in (select pl_my_hotels()))
  with check (hotel_id in (select pl_my_hotels()));
grant select, insert, update, delete on pms_daily_data to authenticated;

create index if not exists idx_pms_hotel_date on pms_daily_data(hotel_id, date);
