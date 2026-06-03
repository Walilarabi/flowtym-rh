-- =====================================================================
-- Flowtym RH · 06 — Module Pointage : table staff_clockings + RLS + index
-- Un pointage = une session de travail (arrivée + départ + pause).
-- Plusieurs pointages possibles par (employé, jour) → vacations multiples.
-- =====================================================================

create table if not exists public.staff_clockings (
  id              uuid primary key default gen_random_uuid(),
  hotel_id        uuid not null references public.hotels(id) on delete cascade,
  employee_id     uuid not null references public.employees(id) on delete cascade,
  day             date not null,
  clock_in_ts     timestamptz not null,
  clock_out_ts    timestamptz,
  break_minutes   int not null default 0 check (break_minutes >= 0 and break_minutes <= 480),
  notes           text,
  source          text not null default 'manual' check (source in ('manual','qr','self')),
  created_by      uuid references public.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint clock_out_after_in check (clock_out_ts is null or clock_out_ts > clock_in_ts)
);

create index if not exists ix_staff_clockings_hotel_day on public.staff_clockings (hotel_id, day);
create index if not exists ix_staff_clockings_employee  on public.staff_clockings (employee_id, day desc);

alter table public.staff_clockings enable row level security;
drop policy if exists staff_clockings_hotel_isolation on public.staff_clockings;
create policy staff_clockings_hotel_isolation on public.staff_clockings
  for all
  using      (hotel_id in (select public.pl_my_hotels()))
  with check (hotel_id in (select public.pl_my_hotels()));

grant select, insert, update, delete on public.staff_clockings to authenticated;

drop trigger if exists staff_clockings_touch on public.staff_clockings;
create trigger staff_clockings_touch
  before update on public.staff_clockings
  for each row execute function public.pl_touch_updated_at();

comment on table public.staff_clockings is 'Pointages des collaborateurs : une ligne par session de travail. Plusieurs par jour pour les vacations multiples.';
