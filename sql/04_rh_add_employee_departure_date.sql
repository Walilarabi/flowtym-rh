-- =====================================================================
-- Flowtym · 04 — Date de départ des collaborateurs
-- Ajoute employees.departure_date utilisée pour masquer un collaborateur
-- dans le planning à partir du mois suivant son départ. Rejouable.
-- =====================================================================
alter table public.employees add column if not exists departure_date date;
