-- Flowtym RH · 10 — Enrichissement de employee_documents (fichier réel + alertes)
alter table public.employee_documents
  add column if not exists doc_type_code text references public.document_types(code),
  add column if not exists file_path text,
  add column if not exists file_size int,
  add column if not exists file_mime text,
  add column if not exists issued_at date,
  add column if not exists notes text,
  add column if not exists uploaded_by uuid references public.users(id);

create or replace view public.v_employee_documents_alerts as
select ed.hotel_id, ed.employee_id, e.first_name, e.last_name,
  ed.doc_type_code, coalesce(dt.label, ed.doc_type) as doc_label,
  ed.expires_at, ed.status, dt.alert_days_before,
  case
    when ed.expires_at is null and ed.status = 'missing' then 'missing'
    when ed.expires_at is null then null
    when ed.expires_at < current_date then 'expired'
    when ed.expires_at < current_date + (coalesce(dt.alert_days_before,30) || ' days')::interval then 'expiring_soon'
    else null
  end as alert_kind,
  case when ed.expires_at is not null then (ed.expires_at - current_date) end as days_until_expiry
from public.employee_documents ed
join public.employees e on e.id = ed.employee_id
left join public.document_types dt on dt.code = ed.doc_type_code
where e.active = true;
grant select on public.v_employee_documents_alerts to authenticated;
