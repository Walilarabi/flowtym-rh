-- Migration 27 : YouSign electronic signature integration
-- Requires migration 26 (portal_employee)

-- Table de suivi des demandes de signature
create table if not exists portal_signature_requests (
  id                          uuid primary key default gen_random_uuid(),
  hotel_id                    uuid references hotels(id) on delete cascade not null,
  employee_id                 uuid references employees(id) on delete cascade not null,
  document_id                 uuid references employee_documents(id) on delete set null,
  yousign_sr_id               text unique not null,
  yousign_signer_id           text,
  yousign_document_id         text,
  status                      text not null default 'ongoing'
                              check (status in ('draft','ongoing','done','refused','expired','canceled')),
  signed_document_path        text,
  audit_trail_path            text,
  initiated_by                uuid references auth.users(id),
  created_at                  timestamptz not null default now(),
  done_at                     timestamptz
);

alter table portal_signature_requests enable row level security;

create policy "psr_manager" on portal_signature_requests for all
  using (hotel_id IN (SELECT pl_my_hotels() AS h));

create policy "psr_employee_read" on portal_signature_requests for select
  using (employee_id = pl_portal_employee_id());

-- Colonnes signature sur employee_documents
alter table employee_documents
  add column if not exists signature_status text
    check (signature_status in ('none','pending','signed','refused','expired'))
    default 'none',
  add column if not exists signature_request_id uuid
    references portal_signature_requests(id) on delete set null;

create index if not exists idx_psr_hotel     on portal_signature_requests(hotel_id);
create index if not exists idx_psr_employee  on portal_signature_requests(employee_id);
create index if not exists idx_psr_yousign   on portal_signature_requests(yousign_sr_id);

-- Edge Functions à déployer :
--   supabase/functions/yousign-create   → crée la demande + upload doc + signer + activate
--   supabase/functions/yousign-webhook  → reçoit signature_request.done → télécharge PDF signé
--
-- Secrets Supabase à configurer (Dashboard > Edge Functions > Secrets) :
--   YOUSIGN_API_KEY      = clé API YouSign (sandbox: u0qeb7TfiROHkMcu9IzeksSaRWDF8p4z)
--   YOUSIGN_WEBHOOK_SECRET = secret HMAC du webhook YouSign (à copier depuis YouSign Dashboard)
--   SUPABASE_SERVICE_ROLE_KEY = clé service role Supabase
--
-- URL du webhook à configurer dans YouSign Dashboard (sandbox) :
--   https://hzrzkvdebaadditvbqis.supabase.co/functions/v1/yousign-webhook
--   Événements : signature_request.done, signature_request.refused, signature_request.expired
