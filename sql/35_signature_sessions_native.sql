-- Migration 35 : Signature électronique native (remplacement YouSign)
-- Appliquée via Supabase MCP

CREATE TABLE IF NOT EXISTS signature_sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  contract_id     uuid NOT NULL REFERENCES generated_contracts(id) ON DELETE CASCADE,
  employee_id     uuid REFERENCES staff(id) ON DELETE SET NULL,
  signer_email    text NOT NULL,
  signer_name     text,
  token           text UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32),'hex'),
  otp_code        char(6),
  otp_sent_at     timestamptz,
  otp_attempts    int NOT NULL DEFAULT 0,
  otp_verified_at timestamptz,
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '7 days',
  signed_at       timestamptz,
  ip_address      text,
  user_agent      text,
  pdf_hash        text,
  signed_pdf_url  text,
  signed_pdf_path text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE generated_contracts
  ADD COLUMN IF NOT EXISTS signature_token text,
  ADD COLUMN IF NOT EXISTS signature_link  text;

-- RLS
ALTER TABLE signature_sessions ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='signature_sessions' AND policyname='signature_sessions_hotel') THEN
    CREATE POLICY signature_sessions_hotel ON signature_sessions
      USING (hotel_id IN (SELECT hotel_id FROM user_hotels WHERE user_id = auth.uid()));
  END IF;
END $$;
