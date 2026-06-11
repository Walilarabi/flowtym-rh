-- 40_signature_engine.sql
-- Moteur de signature électronique natif Flowtym — eIDAS simple.
--
-- Remplace progressivement Yousign. Aucune donnée Yousign supprimée.
-- Entièrement additif — idempotent — rejouable.
--
-- Tables créées : signature_requests, signature_events
-- Colonnes additives sur generated_contracts (compat préservée)
-- RLS : managers via pl_my_hotels() ; portail via pl_portal_employee_id()
-- signature_events : append-only (UPDATE/DELETE révoqués sur roles clients)

-- ─── signature_requests ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.signature_requests (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id                    uuid        NOT NULL REFERENCES public.hotels(id),
  employee_id                 uuid        NOT NULL REFERENCES public.employees(id),
  -- Liens documentaires (l'un ou l'autre, pas les deux obligatoires)
  contract_id                 uuid        REFERENCES public.generated_contracts(id),
  document_id                 uuid        REFERENCES public.employee_documents(id),
  -- Identité du signataire (dénormalisée pour le PDF)
  signer_name                 text        NOT NULL,
  signer_email                text        NOT NULL,
  -- Workflow
  status                      text        NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','otp_sent','otp_verified','signed','refused','expired')),
  -- OTP email (jamais stocké en clair)
  otp_hash                    text,          -- SHA-256 hex de l'OTP à 6 chiffres
  otp_expires_at              timestamptz,
  otp_attempts                int         NOT NULL DEFAULT 0,
  -- Consentement eIDAS
  accepted_terms_at           timestamptz,
  -- Empreintes documentaires
  document_hash_sha256        text,          -- SHA-256 du PDF source avant signature
  signed_document_hash_sha256 text,          -- SHA-256 du PDF après embed signature
  -- Archivage
  signed_pdf_storage_path     text,          -- chemin dans bucket hr-documents
  -- Traçabilité signataire (enregistrées au moment de la signature)
  signer_ip                   text,
  signer_ua                   text,
  signed_at                   timestamptz,
  refused_reason              text,
  refused_at                  timestamptz,
  -- Audit
  initiated_by                uuid        REFERENCES auth.users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sigreq_hotel     ON public.signature_requests(hotel_id);
CREATE INDEX IF NOT EXISTS idx_sigreq_employee  ON public.signature_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_sigreq_contract  ON public.signature_requests(contract_id);
CREATE INDEX IF NOT EXISTS idx_sigreq_status    ON public.signature_requests(status);

COMMENT ON TABLE public.signature_requests IS
  'Demandes de signature électronique natives Flowtym (eIDAS simple). Une ligne par demande. Statuts : pending → otp_sent → otp_verified → signed | refused | expired.';

COMMENT ON COLUMN public.signature_requests.otp_hash IS
  'SHA-256 hex de l OTP 6 chiffres. Jamais stocké en clair.';

COMMENT ON COLUMN public.signature_requests.document_hash_sha256 IS
  'SHA-256 hex du PDF source (avant embed signature). Calculé par la Edge Function sig-send au moment de l envoi.';

COMMENT ON COLUMN public.signature_requests.signed_document_hash_sha256 IS
  'SHA-256 hex du PDF signé archivé. Calculé par sig-sign après embed. Permet de vérifier l intégrité du document archivé.';

COMMENT ON COLUMN public.signature_requests.accepted_terms_at IS
  'Horodatage UTC d acceptation des conditions de signature électronique par le salarié (étape obligatoire avant signature canvas).';

-- ─── signature_events — journal d'audit append-only ─────────────────────────

CREATE TABLE IF NOT EXISTS public.signature_events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id  uuid        NOT NULL REFERENCES public.signature_requests(id),
  hotel_id    uuid        NOT NULL REFERENCES public.hotels(id),
  type        text        NOT NULL CHECK (type IN (
                'created',
                'portal_authenticated',
                'otp_sent',
                'otp_verified',
                'otp_failed',
                'terms_accepted',
                'signed',
                'pdf_archived',
                'refused',
                'expired'
              )),
  actor_ip    text,
  actor_ua    text,
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sigevt_request ON public.signature_events(request_id);
CREATE INDEX IF NOT EXISTS idx_sigevt_hotel   ON public.signature_events(hotel_id);
CREATE INDEX IF NOT EXISTS idx_sigevt_type    ON public.signature_events(type);

COMMENT ON TABLE public.signature_events IS
  'Journal d audit append-only des événements de signature. Aucun UPDATE ni DELETE autorisé (révoqué sur les rôles clients). Seul le service_role (Edge Functions) insère.';

-- ─── Colonnes additives sur generated_contracts ──────────────────────────────
-- Les colonnes yousign_* sont intentionnellement préservées (compatibilité historique).

ALTER TABLE public.generated_contracts
  ADD COLUMN IF NOT EXISTS signature_request_id        uuid        REFERENCES public.signature_requests(id),
  ADD COLUMN IF NOT EXISTS document_hash_sha256        text,
  ADD COLUMN IF NOT EXISTS signed_document_hash_sha256 text,
  ADD COLUMN IF NOT EXISTS accepted_terms_at           timestamptz;

COMMENT ON COLUMN public.generated_contracts.signature_request_id IS
  'Référence vers la demande de signature native Flowtym. NULL pour les contrats Yousign historiques (utiliser yousign_sr_id).';

COMMENT ON COLUMN public.generated_contracts.document_hash_sha256 IS
  'SHA-256 du PDF contractuel source, calculé à l envoi. Tracabilité eIDAS.';

-- ─── RLS — signature_requests ────────────────────────────────────────────────

ALTER TABLE public.signature_requests ENABLE ROW LEVEL SECURITY;

-- Managers : accès complet à leurs hôtels
CREATE POLICY sigreq_mgr_select ON public.signature_requests
  FOR SELECT USING (hotel_id IN (SELECT pl_my_hotels()));

CREATE POLICY sigreq_mgr_insert ON public.signature_requests
  FOR INSERT WITH CHECK (hotel_id IN (SELECT pl_my_hotels()));

CREATE POLICY sigreq_mgr_update ON public.signature_requests
  FOR UPDATE USING (hotel_id IN (SELECT pl_my_hotels()));

-- Portail salarié : lecture de ses propres demandes uniquement
-- (les écritures portail passent exclusivement par Edge Functions service_role)
CREATE POLICY sigreq_portal_select ON public.signature_requests
  FOR SELECT USING (employee_id = pl_portal_employee_id());

-- ─── RLS — signature_events ──────────────────────────────────────────────────

ALTER TABLE public.signature_events ENABLE ROW LEVEL SECURITY;

-- Lecture : managers pour leurs hôtels, portail pour ses demandes
CREATE POLICY sigevt_select ON public.signature_events
  FOR SELECT USING (
    hotel_id IN (SELECT pl_my_hotels())
    OR request_id IN (
      SELECT id FROM public.signature_requests
      WHERE employee_id = pl_portal_employee_id()
    )
  );

-- Append-only : interdire UPDATE et DELETE aux rôles clients
REVOKE UPDATE, DELETE ON public.signature_events FROM authenticated;
REVOKE UPDATE, DELETE ON public.signature_events FROM anon;

-- ─── Trigger updated_at sur signature_requests ───────────────────────────────

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_sigreq_updated_at ON public.signature_requests;
CREATE TRIGGER trg_sigreq_updated_at
  BEFORE UPDATE ON public.signature_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
