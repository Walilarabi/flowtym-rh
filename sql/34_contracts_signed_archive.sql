-- Migration 34: archivage contrats signés, audit, coffre-fort

ALTER TABLE generated_contracts
  ADD COLUMN IF NOT EXISTS sent_at                  timestamptz,
  ADD COLUMN IF NOT EXISTS department               text,
  ADD COLUMN IF NOT EXISTS job_title                text,
  ADD COLUMN IF NOT EXISTS signer_name              text,
  ADD COLUMN IF NOT EXISTS signer_email             text,
  ADD COLUMN IF NOT EXISTS signature_provider       text DEFAULT 'yousign',
  ADD COLUMN IF NOT EXISTS refused_reason           text,
  ADD COLUMN IF NOT EXISTS refused_at               timestamptz,
  ADD COLUMN IF NOT EXISTS signed_pdf_storage_path  text;

CREATE TABLE IF NOT EXISTS contract_audit_logs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id    uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  contract_id uuid REFERENCES generated_contracts(id) ON DELETE SET NULL,
  employee_id uuid REFERENCES employees(id) ON DELETE SET NULL,
  action      text NOT NULL,
  actor_email text,
  details     jsonb DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS contract_audit_hotel_idx    ON contract_audit_logs(hotel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS contract_audit_contract_idx ON contract_audit_logs(contract_id);

ALTER TABLE contract_audit_logs ENABLE ROW LEVEL SECURITY;
