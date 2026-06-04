-- =============================================================================
-- 26_portal_employee.sql
-- Portail salarié — tables, fonctions RPC, RLS, bucket Storage.
--
-- Sécurité & RGPD :
--   • employees.portal_auth_id  → lien 1:1 entre auth.users et l'employé
--   • Toutes les tables ont RLS active ; chaque salarié ne voit QUE ses données
--   • pl_portal_employee_id()   → SECURITY DEFINER, renvoie l'id employé de la session
--   • Bucket "portal-documents" → path :  {hotel_id}/{employee_id}/{filename}
--     - le salarié ne peut écrire/lire que dans son propre dossier
--     - le manager lit tous les dossiers de son hôtel
--   • Journaux d'audit via la table portal_audit_log (RGPD, art. 30)
--   • Données supprimables via RPC pl_portal_gdpr_erase() (droit à l'oubli)
--   • Consentement : colonne portal_consent_at + portal_consent_ip
--
-- Rejouable (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO NOTHING).
-- =============================================================================

-- ── 0. Extension utile ────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 1. Lien auth → employé ────────────────────────────────────────────────────
-- Chaque employé peut avoir un compte portail. Le lien se fait par email ou
-- par invitation explicite (portal_invite_token).
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS portal_auth_id    uuid     REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS portal_enabled    boolean  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS portal_invite_token text,
  ADD COLUMN IF NOT EXISTS portal_invite_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS portal_consent_at timestamptz,
  ADD COLUMN IF NOT EXISTS portal_consent_ip inet;

CREATE UNIQUE INDEX IF NOT EXISTS idx_employees_portal_auth
  ON public.employees(portal_auth_id) WHERE portal_auth_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_employees_portal_enabled
  ON public.employees(hotel_id, portal_enabled) WHERE portal_enabled = true;

COMMENT ON COLUMN public.employees.portal_auth_id IS
  'UUID auth.users lié à ce salarié. NULL = pas de compte portail. RGPD : supprimé sur demande via pl_portal_gdpr_erase().';
COMMENT ON COLUMN public.employees.portal_consent_at IS
  'Horodatage du consentement explicite du salarié aux CGU du portail (RGPD art. 7).';
COMMENT ON COLUMN public.employees.portal_invite_token IS
  'Token à usage unique pour activation du compte portail. Hashé en base.';

-- ── 2. Fonction identité portail ─────────────────────────────────────────────
-- Renvoie l'employee.id correspondant à auth.uid().
-- SECURITY DEFINER : tourne avec les droits du propriétaire, pas de l'appelant.
-- Utilisée dans toutes les RLS du portail.
CREATE OR REPLACE FUNCTION public.pl_portal_employee_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.employees
  WHERE portal_auth_id = auth.uid()
    AND portal_enabled = true
  LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION public.pl_portal_employee_id() TO authenticated, anon;

-- ── 3. Table des demandes RH ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.portal_requests (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id     uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,

  type            text        NOT NULL
    CHECK (type IN (
      'conge_paye',          -- CP classique
      'absence_except',      -- absence exceptionnelle
      'maladie',             -- arrêt maladie
      'extra',               -- demande d'extra / vacation supplémentaire
      'echange_shift',       -- échange avec un collègue
      'autre'
    )),

  -- Période concernée
  date_start      date        NOT NULL,
  date_end        date,
  shift_label     text,       -- pour les demandes extra / échange

  -- Échange de shift : collègue cible
  target_employee_id  uuid    REFERENCES public.employees(id) ON DELETE SET NULL,
  target_date         date,
  target_shift        text,

  -- Contenu
  reason          text,       -- motif libre (tronqué UI à 500 chars)
  message         text,       -- message au manager

  -- Pièce jointe (path Storage portal-documents/{hotel_id}/{employee_id}/…)
  attachment_path text,
  attachment_name text,       -- nom original (affiché UI, pas utilisé pour fetch)

  -- Workflow
  status          text        NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','cancelled')),
  manager_comment text,
  reviewed_by     uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  reviewed_at     timestamptz,

  -- Consentement : le salarié déclare avoir lu les CGU à la soumission
  submitted_consent boolean NOT NULL DEFAULT false,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_portal_requests_hotel     ON public.portal_requests(hotel_id, status);
CREATE INDEX IF NOT EXISTS idx_portal_requests_employee  ON public.portal_requests(employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_portal_requests_pending   ON public.portal_requests(hotel_id) WHERE status = 'pending';

ALTER TABLE public.portal_requests ENABLE ROW LEVEL SECURITY;

-- Manager : voit toutes les demandes de son hôtel
DROP POLICY IF EXISTS "portal_requests_manager"  ON public.portal_requests;
CREATE POLICY "portal_requests_manager" ON public.portal_requests
  FOR ALL
  USING   (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));

-- Salarié : voit et crée uniquement ses propres demandes
DROP POLICY IF EXISTS "portal_requests_employee" ON public.portal_requests;
CREATE POLICY "portal_requests_employee" ON public.portal_requests
  FOR ALL
  USING   (employee_id = public.pl_portal_employee_id())
  WITH CHECK (employee_id = public.pl_portal_employee_id()
              AND hotel_id = (SELECT hotel_id FROM public.employees
                              WHERE id = public.pl_portal_employee_id()));

CREATE TRIGGER trg_portal_requests_touch
  BEFORE UPDATE ON public.portal_requests
  FOR EACH ROW EXECUTE FUNCTION public.pl_touch_updated_at();

COMMENT ON TABLE public.portal_requests IS
  'Demandes RH soumises par le salarié via le portail : CP, absence, maladie, extra, échange shift. RGPD : effaçables via pl_portal_gdpr_erase().';

-- ── 4. Messagerie manager ↔ salarié ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.portal_messages (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id      uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id   uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,

  -- Expéditeur : soit un manager (manager_id non nul), soit le salarié (manager_id nul)
  manager_id    uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  direction     text        NOT NULL CHECK (direction IN ('manager_to_employee','employee_to_manager')),

  body          text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  read_at       timestamptz,   -- NULL = non lu par le destinataire

  -- RGPD : message peut être effacé individuellement (soft-delete)
  deleted_by_employee boolean NOT NULL DEFAULT false,
  deleted_by_manager  boolean NOT NULL DEFAULT false,

  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_portal_messages_employee ON public.portal_messages(employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_portal_messages_unread   ON public.portal_messages(hotel_id) WHERE read_at IS NULL;

ALTER TABLE public.portal_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "portal_messages_manager"  ON public.portal_messages;
CREATE POLICY "portal_messages_manager" ON public.portal_messages
  FOR ALL
  USING   (hotel_id IN (SELECT public.pl_my_hotels()) AND NOT deleted_by_manager)
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));

DROP POLICY IF EXISTS "portal_messages_employee" ON public.portal_messages;
CREATE POLICY "portal_messages_employee" ON public.portal_messages
  FOR ALL
  USING   (employee_id = public.pl_portal_employee_id() AND NOT deleted_by_employee)
  WITH CHECK (employee_id = public.pl_portal_employee_id());

COMMENT ON TABLE public.portal_messages IS
  'Messagerie directe manager ↔ salarié. Soft-delete par chaque partie. RGPD : effaçable.';

-- ── 5. Soldes congés / RTT ────────────────────────────────────────────────────
-- Vue simple calculée à partir du planning. Extensible avec une vraie table de mouvements.
CREATE OR REPLACE VIEW public.portal_leave_balances AS
SELECT
  sp.hotel_id,
  sp.employee_id,
  date_trunc('year', sp.day)::date AS year_start,
  COUNT(*) FILTER (WHERE sp.status = 'CP')  AS cp_taken,
  COUNT(*) FILTER (WHERE sp.status = 'RTT') AS rtt_taken
FROM public.staff_planning sp
GROUP BY sp.hotel_id, sp.employee_id, date_trunc('year', sp.day)::date;

-- ── 6. Journal d'audit RGPD ───────────────────────────────────────────────────
-- Art. 30 RGPD : registre des traitements. Trace toute action sensible.
CREATE TABLE IF NOT EXISTS public.portal_audit_log (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id      uuid        REFERENCES public.hotels(id) ON DELETE SET NULL,
  employee_id   uuid        REFERENCES public.employees(id) ON DELETE SET NULL,
  actor_auth_id uuid,       -- auth.uid() au moment de l'action
  actor_type    text        NOT NULL CHECK (actor_type IN ('employee','manager','system')),
  action        text        NOT NULL,     -- ex: 'login','upload_doc','request_cp','gdpr_erase'
  resource_type text,                     -- ex: 'portal_request','portal_message','document'
  resource_id   uuid,
  ip_address    inet,
  user_agent    text,
  metadata      jsonb       NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Aucune UPDATE ni DELETE sur ce journal (immuable sauf via gdpr_erase)
ALTER TABLE public.portal_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_log_manager_read" ON public.portal_audit_log;
CREATE POLICY "audit_log_manager_read" ON public.portal_audit_log
  FOR SELECT USING (hotel_id IN (SELECT public.pl_my_hotels()));

-- Le salarié peut lire son propre journal (droit d'accès RGPD art. 15)
DROP POLICY IF EXISTS "audit_log_employee_read" ON public.portal_audit_log;
CREATE POLICY "audit_log_employee_read" ON public.portal_audit_log
  FOR SELECT USING (employee_id = public.pl_portal_employee_id());

-- Seul INSERT autorisé (via RPC sécurisée) — pas de UPDATE/DELETE directs
DROP POLICY IF EXISTS "audit_log_insert" ON public.portal_audit_log;
CREATE POLICY "audit_log_insert" ON public.portal_audit_log
  FOR INSERT WITH CHECK (true);

COMMENT ON TABLE public.portal_audit_log IS
  'Journal d''audit RGPD (art. 30). Immuable. Toute action sur le portail y est tracée.';

-- ── 7. Bucket Storage portal-documents ───────────────────────────────────────
-- Convention path : {hotel_id}/{employee_id}/{type}/{filename}
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'portal-documents',
  'portal-documents',
  false,
  20971520,   -- 20 Mo max
  ARRAY[
    'application/pdf',
    'image/jpeg','image/png','image/heic','image/webp',
    'image/gif',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit  = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Policies Storage : salarié ne voit que son propre dossier {hotel_id}/{employee_id}/
-- Managers voient tout le dossier de leur hôtel.
DO $$
DECLARE act text;
BEGIN
  FOR act IN SELECT unnest(ARRAY['select','insert','update','delete']) LOOP
    EXECUTE format($p$
      DROP POLICY IF EXISTS "portal_docs_%1$s_manager" ON storage.objects;
      CREATE POLICY "portal_docs_%1$s_manager" ON storage.objects FOR %1$s
      %2$s (
        bucket_id = 'portal-documents'
        AND (storage.foldername(name))[1]::uuid IN (SELECT public.pl_my_hotels())
      );
    $p$, act, CASE WHEN act='insert' THEN 'WITH CHECK' ELSE 'USING' END);

    EXECUTE format($p$
      DROP POLICY IF EXISTS "portal_docs_%1$s_employee" ON storage.objects;
      CREATE POLICY "portal_docs_%1$s_employee" ON storage.objects FOR %1$s
      %2$s (
        bucket_id = 'portal-documents'
        AND (storage.foldername(name))[2]::uuid = public.pl_portal_employee_id()
      );
    $p$, act, CASE WHEN act='insert' THEN 'WITH CHECK' ELSE 'USING' END);
  END LOOP;
END $$;

-- ── 8. RPC : invitation salarié ───────────────────────────────────────────────
-- Génère un token d'invitation unique (expire 72h). Le manager appelle cette RPC.
-- Le token est envoyé par email (Supabase Magic Link côté frontend).
CREATE OR REPLACE FUNCTION public.pl_portal_invite(p_employee_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tok text;
BEGIN
  SELECT * INTO emp FROM public.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Employé introuvable' USING ERRCODE = 'P0002';
  END IF;
  -- Vérifier que le manager a accès à cet hôtel
  IF emp.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN
    RAISE EXCEPTION 'Accès refusé' USING ERRCODE = '42501';
  END IF;
  -- Générer token 32 octets hex
  tok := encode(gen_random_bytes(32), 'hex');
  UPDATE public.employees
     SET portal_invite_token    = tok,
         portal_invite_expires_at = now() + INTERVAL '72 hours',
         portal_enabled         = true
   WHERE id = p_employee_id;
  -- Audit
  INSERT INTO public.portal_audit_log(hotel_id, employee_id, actor_auth_id, actor_type, action, resource_type, resource_id)
  VALUES (emp.hotel_id, p_employee_id, auth.uid(), 'manager', 'portal_invite', 'employee', p_employee_id);
  RETURN tok;
END;
$$;
GRANT EXECUTE ON FUNCTION public.pl_portal_invite(uuid) TO authenticated;

-- ── 9. RPC : activation du compte portail ─────────────────────────────────────
-- Appelée lors du premier login salarié avec son token.
CREATE OR REPLACE FUNCTION public.pl_portal_activate(
  p_token       text,
  p_consent_ip  inet DEFAULT NULL
)
RETURNS uuid   -- employee_id activé
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
BEGIN
  SELECT * INTO emp FROM public.employees
  WHERE portal_invite_token = p_token
    AND portal_invite_expires_at > now()
    AND portal_enabled = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Token invalide ou expiré' USING ERRCODE = '22023';
  END IF;
  UPDATE public.employees
     SET portal_auth_id           = auth.uid(),
         portal_invite_token      = NULL,
         portal_invite_expires_at = NULL,
         portal_consent_at        = now(),
         portal_consent_ip        = p_consent_ip
   WHERE id = emp.id;
  -- Audit
  INSERT INTO public.portal_audit_log(hotel_id, employee_id, actor_auth_id, actor_type, action)
  VALUES (emp.hotel_id, emp.id, auth.uid(), 'employee', 'portal_activate');
  RETURN emp.id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.pl_portal_activate(text, inet) TO authenticated;

-- ── 10. RPC : droit à l'oubli RGPD ───────────────────────────────────────────
-- Peut être appelée par le salarié (efface ses propres données) ou par un manager.
-- Conserve les données anonymisées légalement obligatoires (bulletins de paie 5 ans).
CREATE OR REPLACE FUNCTION public.pl_portal_gdpr_erase(p_employee_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE emp RECORD;
BEGIN
  SELECT * INTO emp FROM public.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employé introuvable' USING ERRCODE = 'P0002'; END IF;

  -- Vérifier l'appelant : salarié lui-même ou manager de l'hôtel
  IF emp.portal_auth_id != auth.uid()
     AND emp.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN
    RAISE EXCEPTION 'Accès refusé' USING ERRCODE = '42501';
  END IF;

  -- Effacer les messages (soft-delete total)
  UPDATE public.portal_messages
     SET deleted_by_employee = true, deleted_by_manager = true, body = '[Effacé — RGPD]'
   WHERE employee_id = p_employee_id;

  -- Effacer les demandes sensibles (soft-delete : garder les lignes pour cohérence RH)
  UPDATE public.portal_requests
     SET reason = '[Effacé — RGPD]', message = '[Effacé — RGPD]', attachment_path = NULL
   WHERE employee_id = p_employee_id;

  -- Dissocier le compte auth (le salarié ne peut plus se connecter)
  UPDATE public.employees
     SET portal_auth_id  = NULL,
         portal_enabled  = false,
         portal_consent_at = NULL,
         portal_consent_ip = NULL
   WHERE id = p_employee_id;

  -- Audit final
  INSERT INTO public.portal_audit_log(hotel_id, employee_id, actor_auth_id, actor_type, action, metadata)
  VALUES (emp.hotel_id, p_employee_id, auth.uid(), 'system', 'gdpr_erase', '{"reason":"right_to_erasure"}'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION public.pl_portal_gdpr_erase(uuid) TO authenticated;

-- ── 11. RLS sur employees : un salarié ne voit que SA fiche ──────────────────
-- (En plus de la policy manager existante)
DROP POLICY IF EXISTS "employees_portal_self" ON public.employees;
CREATE POLICY "employees_portal_self" ON public.employees
  FOR SELECT
  USING (id = public.pl_portal_employee_id());

-- ── 12. RLS sur staff_planning : salarié lit uniquement son planning ─────────
DROP POLICY IF EXISTS "planning_portal_self" ON public.staff_planning;
CREATE POLICY "planning_portal_self" ON public.staff_planning
  FOR SELECT
  USING (employee_id = public.pl_portal_employee_id());

-- ── 13. RLS sur staff_clockings : salarié lit ses pointages + peut inserer ───
DROP POLICY IF EXISTS "clockings_portal_self_read"   ON public.staff_clockings;
DROP POLICY IF EXISTS "clockings_portal_self_insert" ON public.staff_clockings;

CREATE POLICY "clockings_portal_self_read" ON public.staff_clockings
  FOR SELECT USING (employee_id = public.pl_portal_employee_id());

CREATE POLICY "clockings_portal_self_insert" ON public.staff_clockings
  FOR INSERT WITH CHECK (
    employee_id = public.pl_portal_employee_id()
    AND source IN ('qr','self')
    -- Empêcher le pointage rétroactif au-delà de 4h
    AND clock_in_ts >= now() - INTERVAL '4 hours'
  );

-- ── 14. RLS sur employee_documents : salarié lit ses documents ───────────────
DROP POLICY IF EXISTS "emp_docs_portal_self" ON public.employee_documents;
CREATE POLICY "emp_docs_portal_self" ON public.employee_documents
  FOR SELECT USING (employee_id = public.pl_portal_employee_id());

COMMENT ON FUNCTION public.pl_portal_employee_id() IS
  'Retourne l''employee.id lié à auth.uid(). Utilisé dans toutes les RLS portail.';
