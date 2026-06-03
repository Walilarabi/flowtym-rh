-- Flowtym RH · 11 — Journal d'audit pour les documents RH
create table if not exists public.hr_document_audit_logs (
  id uuid primary key default gen_random_uuid(),
  hotel_id uuid not null references public.hotels(id) on delete cascade,
  actor_user_id uuid references public.users(id),
  actor_email text,
  action text not null check (action in (
    'template_upload','template_update','template_archive',
    'document_upload','document_view','document_download','document_delete',
    'contract_generate','contract_send','contract_sign')),
  entity_type text not null check (entity_type in ('contract_template','employee_document','employee_contract')),
  entity_id uuid,
  employee_id uuid references public.employees(id) on delete set null,
  details jsonb, ip_address text, user_agent text,
  created_at timestamptz not null default now()
);
create index if not exists ix_audit_hotel_date on public.hr_document_audit_logs (hotel_id, created_at desc);
alter table public.hr_document_audit_logs enable row level security;
drop policy if exists hr_audit_read on public.hr_document_audit_logs;
create policy hr_audit_read on public.hr_document_audit_logs for select using (
  hotel_id in (select public.pl_my_hotels())
  and exists (
    select 1 from public.user_hotels uh join public.users u on u.id = uh.user_id
    where u.auth_id = auth.uid() and uh.hotel_id = hr_document_audit_logs.hotel_id
      and uh.role::text in ('direction','admin_hotel','comptabilite')
  )
);
drop policy if exists hr_audit_insert on public.hr_document_audit_logs;
create policy hr_audit_insert on public.hr_document_audit_logs for insert
  with check (hotel_id in (select public.pl_my_hotels()));
grant select, insert on public.hr_document_audit_logs to authenticated;
