-- =====================================================================
-- Flowtym · 02 — Migration de données du prototype pl_* vers le nouveau modèle
-- Préserve les données existantes :
--   staff_members  ->  employees    (par nom + hotel_id, idempotent)
--   pl_entries     ->  staff_planning (par employee_id + day, on conflict do nothing)
-- À exécuter UNE FOIS, après la création du schéma RH (migration 01).
-- =====================================================================

insert into public.employees(hotel_id, first_name, last_name, role, department, contract_type, active)
select sm.hotel_id, sm.first_name, sm.last_name,
       case sm.role::text
         when 'reception'        then 'Réceptionniste'
         when 'gouvernante'      then 'Gouvernante'
         when 'femme_de_chambre' then 'Femme de chambre'
         when 'maintenance'      then 'Technicien'
         when 'breakfast'        then 'Petit-déjeuner'
         when 'direction'        then 'Directeur'
         when 'admin_hotel'      then 'Direction'
         when 'comptabilite'     then 'Comptable'
         when 'revenue_manager'  then 'Revenue manager'
         else sm.role::text
       end,
       sm.department, 'CDI'::text, coalesce(sm.active, true)
from public.staff_members sm
where not exists (
  select 1 from public.employees e
  where e.hotel_id = sm.hotel_id
    and lower(e.first_name) = lower(sm.first_name)
    and lower(e.last_name)  = lower(sm.last_name)
);

insert into public.staff_planning(hotel_id, employee_id, day, status, duration)
select p.hotel_id, e.id, p.entry_date, t.code, p.duration
from public.pl_entries p
join public.staff_members sm   on sm.id = p.staff_id
join public.employees e        on e.hotel_id = sm.hotel_id
                              and lower(e.first_name) = lower(sm.first_name)
                              and lower(e.last_name)  = lower(sm.last_name)
join public.pl_absence_types t on t.id = p.type_id
where t.code in ('P','CP','RTT','MAL','MAT','CSS','AE','F')
on conflict (hotel_id, employee_id, day) do nothing;
