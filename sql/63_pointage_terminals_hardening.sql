-- =============================================================================
-- 63_pointage_terminals_hardening.sql
-- Durcissement du module Pointage v2 après audit critique.
--
-- Ce fichier ajoute :
--   1. Autorisation multi-hôtel stricte (fonction employee_can_clock_at, sans
--      recours à l'historique de pointage) — critères actuels uniquement.
--   2. Archivage (soft-delete) des terminaux ; blocage du DELETE physique dès
--      qu'un staff_clockings.terminal_id référence le terminal.
--   3. Régénération de token atomique + journal (pointage_terminal_events),
--      via RPC SECURITY DEFINER filtrée par pl_my_hotels().
--   4. Protection SQL contre le double clock-in :
--        · unique partiel (employee_id) WHERE clock_out_ts IS NULL
--        · idempotency_key unique
--        · advisory lock par employé dans la RPC record_clocking
--   5. Heure serveur systématique (clock_in_ts/clock_out_ts = now()) + day
--      calculé dans le fuseau de l'hôtel — poste de nuit / passage minuit OK.
--   6. Extensibilité sécurité QR : geofence_radius_override_meters +
--      active_from_minute / active_to_minute par terminal.
--   7. TODO daté pour le retrait complet de hotel_qr_tokens (fenêtre 90 j).
--
-- Rejouable (IF NOT EXISTS / CREATE OR REPLACE / DO $$ ... $$).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 0. Colonnes d'audit sur staff_clockings (défensif : peuvent avoir été
--      ajoutées hors migration versionnée en production). ────────────────────
ALTER TABLE public.staff_clockings
  ADD COLUMN IF NOT EXISTS gps_lat          double precision,
  ADD COLUMN IF NOT EXISTS gps_lng          double precision,
  ADD COLUMN IF NOT EXISTS gps_accuracy     double precision,
  ADD COLUMN IF NOT EXISTS distance_meters  integer,
  ADD COLUMN IF NOT EXISTS device_info      text,
  ADD COLUMN IF NOT EXISTS ip_address       inet,
  ADD COLUMN IF NOT EXISTS clock_status     text,
  ADD COLUMN IF NOT EXISTS anomaly_flags    text[],
  ADD COLUMN IF NOT EXISTS qr_token_id      uuid;

-- ── 1. Colonnes d'archivage et d'extensibilité sécurité ─────────────────────
ALTER TABLE public.pointage_terminals
  ADD COLUMN IF NOT EXISTS archived_at                  timestamptz,
  ADD COLUMN IF NOT EXISTS archived_by                  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS archived_by_email            text,
  ADD COLUMN IF NOT EXISTS geofence_radius_override_meters int
    CHECK (geofence_radius_override_meters IS NULL OR (geofence_radius_override_meters BETWEEN 20 AND 5000)),
  ADD COLUMN IF NOT EXISTS active_from_minute           int
    CHECK (active_from_minute IS NULL OR (active_from_minute BETWEEN 0 AND 1439)),
  ADD COLUMN IF NOT EXISTS active_to_minute             int
    CHECK (active_to_minute IS NULL OR (active_to_minute BETWEEN 0 AND 1439));

COMMENT ON COLUMN public.pointage_terminals.archived_at IS
  'Soft-delete : timestamp d''archivage. Un terminal archivé n''est plus scannable mais reste visible dans l''historique.';
COMMENT ON COLUMN public.pointage_terminals.geofence_radius_override_meters IS
  'Facultatif : rayon (m) spécifique à ce terminal, remplace hotels.geofence_radius_meters.';
COMMENT ON COLUMN public.pointage_terminals.active_from_minute IS
  'Facultatif : minute (0-1439, fuseau hôtel) à partir de laquelle le terminal accepte les scans.';
COMMENT ON COLUMN public.pointage_terminals.active_to_minute IS
  'Facultatif : minute (0-1439, fuseau hôtel) après laquelle le terminal refuse les scans. Peut être < active_from_minute (plage sur minuit).';

-- Invariant : un terminal archivé n''est jamais actif
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='pointage_terminals_archived_not_active') THEN
    ALTER TABLE public.pointage_terminals
      ADD CONSTRAINT pointage_terminals_archived_not_active
      CHECK (archived_at IS NULL OR is_active = false);
  END IF;
END $$;

-- Une seule ligne active par (hotel_id, name) pour éviter les doublons visuels
CREATE UNIQUE INDEX IF NOT EXISTS idx_pointage_terminals_hotel_name_active
  ON public.pointage_terminals(hotel_id, lower(name))
  WHERE is_active AND archived_at IS NULL;

-- ── 2. Blocage du DELETE si le terminal a servi ──────────────────────────────
CREATE OR REPLACE FUNCTION public.pointage_terminals_prevent_delete_if_used()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.staff_clockings WHERE terminal_id = OLD.id LIMIT 1) THEN
    RAISE EXCEPTION 'Terminal déjà utilisé : archivez-le au lieu de le supprimer.'
      USING ERRCODE = 'foreign_key_violation', HINT = 'Utilisez archive_pointage_terminal(uuid).';
  END IF;
  RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS trg_pointage_terminals_no_delete_if_used ON public.pointage_terminals;
CREATE TRIGGER trg_pointage_terminals_no_delete_if_used
  BEFORE DELETE ON public.pointage_terminals
  FOR EACH ROW EXECUTE FUNCTION public.pointage_terminals_prevent_delete_if_used();

-- ── 3. Journal d'événements terminaux ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pointage_terminal_events (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  terminal_id    uuid        REFERENCES public.pointage_terminals(id) ON DELETE SET NULL,
  hotel_id       uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  action         text        NOT NULL
    CHECK (action IN ('create','rename','regenerate','disable','enable','archive','delete',
                      'geofence_override','time_window','update')),
  actor_user_id  uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  actor_auth_id  uuid,
  actor_email    text,
  details        jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pointage_terminal_events_hotel_time
  ON public.pointage_terminal_events(hotel_id, created_at DESC);

ALTER TABLE public.pointage_terminal_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pointage_terminal_events_isolation ON public.pointage_terminal_events;
CREATE POLICY pointage_terminal_events_isolation ON public.pointage_terminal_events
  FOR SELECT
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT ON public.pointage_terminal_events TO authenticated;

COMMENT ON TABLE public.pointage_terminal_events IS
  'Journal d''audit des opérations sur les terminaux de pointage : création, renommage, régénération de token, activation, archivage. Aucun droit INSERT/UPDATE aux clients — alimenté uniquement par les RPC SECURITY DEFINER de ce module.';

-- ── 4. Générateur de token cryptographique ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_terminal_token()
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
  SELECT 'ftt_' || encode(public.gen_random_bytes(24), 'hex')
$$;

-- gen_random_bytes vient de pgcrypto (déjà activé). 24 octets = 192 bits
-- d''entropie, encodés hex → 48 caractères. La probabilité de collision
-- est négligeable ; l''unicité est en plus garantie par l''index UNIQUE
-- pointage_terminals(token).

-- ── 5. RPC : création d'un terminal (SECURITY DEFINER + audit) ──────────────
CREATE OR REPLACE FUNCTION public.create_pointage_terminal(
  p_hotel_id uuid,
  p_name text,
  p_location text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_token text;
  v_user_id uuid;
  v_user_email text;
BEGIN
  IF p_hotel_id IS NULL OR btrim(coalesce(p_name,'')) = '' THEN
    RAISE EXCEPTION 'BAD_INPUT' USING ERRCODE='22023';
  END IF;
  IF p_hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN
    RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501';
  END IF;

  -- Génère un token unique (retry en cas de collision extrêmement improbable)
  LOOP
    v_token := public.generate_terminal_token();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.pointage_terminals WHERE token = v_token);
  END LOOP;

  SELECT id, email INTO v_user_id, v_user_email
    FROM public.users WHERE auth_id = auth.uid() LIMIT 1;

  INSERT INTO public.pointage_terminals(hotel_id, name, location, token, is_active, created_by, created_by_email)
  VALUES (p_hotel_id, btrim(p_name), NULLIF(btrim(coalesce(p_location,'')),''), v_token, true, v_user_id, v_user_email)
  RETURNING id INTO v_id;

  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (v_id, p_hotel_id, 'create', v_user_id, auth.uid(), v_user_email,
          jsonb_build_object('name', p_name, 'location', p_location));

  RETURN jsonb_build_object('id', v_id, 'token', v_token);
END $$;
GRANT EXECUTE ON FUNCTION public.create_pointage_terminal(uuid, text, text) TO authenticated;

-- ── 6. RPC : renommer ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rename_pointage_terminal(
  p_terminal_id uuid, p_name text, p_location text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_t public.pointage_terminals; v_uid uuid; v_email text;
BEGIN
  SELECT * INTO v_t FROM public.pointage_terminals WHERE id = p_terminal_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'TERMINAL_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF v_t.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501'; END IF;
  IF v_t.archived_at IS NOT NULL THEN RAISE EXCEPTION 'ARCHIVED' USING ERRCODE='P0001'; END IF;
  IF btrim(coalesce(p_name,'')) = '' THEN RAISE EXCEPTION 'BAD_INPUT' USING ERRCODE='22023'; END IF;

  UPDATE public.pointage_terminals
     SET name = btrim(p_name),
         location = NULLIF(btrim(coalesce(p_location,'')),'')
   WHERE id = p_terminal_id;

  SELECT id, email INTO v_uid, v_email FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (p_terminal_id, v_t.hotel_id, 'rename', v_uid, auth.uid(), v_email,
          jsonb_build_object('old_name', v_t.name, 'new_name', p_name, 'location', p_location));
END $$;
GRANT EXECUTE ON FUNCTION public.rename_pointage_terminal(uuid, text, text) TO authenticated;

-- ── 7. RPC : régénération de token (atomique, audité) ───────────────────────
CREATE OR REPLACE FUNCTION public.regenerate_pointage_terminal_token(
  p_terminal_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_t public.pointage_terminals;
  v_new_token text;
  v_uid uuid;
  v_email text;
BEGIN
  -- Verrou pessimiste sur la ligne : sérialisation stricte des régénérations
  SELECT * INTO v_t FROM public.pointage_terminals WHERE id = p_terminal_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'TERMINAL_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF v_t.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501'; END IF;
  IF v_t.archived_at IS NOT NULL THEN RAISE EXCEPTION 'ARCHIVED' USING ERRCODE='P0001'; END IF;

  LOOP
    v_new_token := public.generate_terminal_token();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.pointage_terminals WHERE token = v_new_token);
  END LOOP;

  UPDATE public.pointage_terminals
     SET token = v_new_token, updated_at = now()
   WHERE id = p_terminal_id;

  SELECT id, email INTO v_uid, v_email FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (p_terminal_id, v_t.hotel_id, 'regenerate', v_uid, auth.uid(), v_email,
          jsonb_build_object('old_token_tail', right(v_t.token, 6),
                             'new_token_tail', right(v_new_token, 6)));

  RETURN jsonb_build_object('id', p_terminal_id, 'token', v_new_token);
END $$;
GRANT EXECUTE ON FUNCTION public.regenerate_pointage_terminal_token(uuid) TO authenticated;

-- ── 8. RPC : activer / désactiver / archiver ────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_pointage_terminal_active(
  p_terminal_id uuid, p_active boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_t public.pointage_terminals; v_uid uuid; v_email text;
BEGIN
  SELECT * INTO v_t FROM public.pointage_terminals WHERE id = p_terminal_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'TERMINAL_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF v_t.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501'; END IF;
  IF v_t.archived_at IS NOT NULL AND p_active THEN
    RAISE EXCEPTION 'ARCHIVED_CANNOT_ACTIVATE' USING ERRCODE='P0001';
  END IF;

  UPDATE public.pointage_terminals
     SET is_active = p_active, updated_at = now()
   WHERE id = p_terminal_id;

  SELECT id, email INTO v_uid, v_email FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (p_terminal_id, v_t.hotel_id, CASE WHEN p_active THEN 'enable' ELSE 'disable' END,
          v_uid, auth.uid(), v_email, jsonb_build_object('previous', v_t.is_active));
END $$;
GRANT EXECUTE ON FUNCTION public.set_pointage_terminal_active(uuid, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.archive_pointage_terminal(p_terminal_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_t public.pointage_terminals; v_uid uuid; v_email text;
BEGIN
  SELECT * INTO v_t FROM public.pointage_terminals WHERE id = p_terminal_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'TERMINAL_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF v_t.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501'; END IF;
  IF v_t.archived_at IS NOT NULL THEN RETURN; END IF;

  SELECT id, email INTO v_uid, v_email FROM public.users WHERE auth_id = auth.uid() LIMIT 1;

  UPDATE public.pointage_terminals
     SET is_active     = false,
         archived_at   = now(),
         archived_by   = v_uid,
         archived_by_email = v_email,
         updated_at    = now()
   WHERE id = p_terminal_id;

  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (p_terminal_id, v_t.hotel_id, 'archive', v_uid, auth.uid(), v_email,
          jsonb_build_object('previous_active', v_t.is_active));
END $$;
GRANT EXECUTE ON FUNCTION public.archive_pointage_terminal(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_pointage_terminal_security(
  p_terminal_id uuid,
  p_geofence_override_meters int,
  p_active_from_minute int,
  p_active_to_minute int
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_t public.pointage_terminals; v_uid uuid; v_email text;
BEGIN
  SELECT * INTO v_t FROM public.pointage_terminals WHERE id = p_terminal_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'TERMINAL_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF v_t.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE='42501'; END IF;
  IF v_t.archived_at IS NOT NULL THEN RAISE EXCEPTION 'ARCHIVED' USING ERRCODE='P0001'; END IF;

  UPDATE public.pointage_terminals
     SET geofence_radius_override_meters = p_geofence_override_meters,
         active_from_minute = p_active_from_minute,
         active_to_minute   = p_active_to_minute,
         updated_at         = now()
   WHERE id = p_terminal_id;

  SELECT id, email INTO v_uid, v_email FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  INSERT INTO public.pointage_terminal_events(terminal_id, hotel_id, action, actor_user_id, actor_auth_id, actor_email, details)
  VALUES (p_terminal_id, v_t.hotel_id, 'geofence_override', v_uid, auth.uid(), v_email,
          jsonb_build_object('geofence_override_meters', p_geofence_override_meters,
                             'active_from_minute', p_active_from_minute,
                             'active_to_minute', p_active_to_minute));
END $$;
GRANT EXECUTE ON FUNCTION public.set_pointage_terminal_security(uuid, int, int, int) TO authenticated;

-- ── 9. Autorisation multi-hôtel STRICTE — sans historique ───────────────────
-- Règle (chaque OU indépendant, un seul suffit) :
--   (a) l'employé est actif ET l'hôtel du terminal est son hôtel principal
--   (b) l'employé possède une affectation permanente (employee_hotel_assignments)
--       active pour cet hôtel
--   (c) l'employé possède une activation Extra (employee_extra_activations) active
--       couvrant le mois du pointage dans cet hôtel
--   (d) l'employé possède un shift planifié (staff_planning) à la date du
--       pointage dans cet hôtel avec status='P' (présent)
--
-- Refuse notamment :
--   • un ancien employé désactivé (active=false)
--   • un employé qui a POINTÉ dans un hôtel mais n'y a plus aucun droit actuel
--   • un extra dont l'activation est expirée (active=false ou hors mois)
--   • un shift planifié dans un AUTRE hôtel que le terminal
CREATE OR REPLACE FUNCTION public.employee_can_clock_at(
  p_employee uuid, p_hotel uuid, p_day date
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    -- (a) hôtel principal + employé actif
    EXISTS (
      SELECT 1 FROM public.employees e
       WHERE e.id = p_employee
         AND e.hotel_id = p_hotel
         AND e.active = true
    )
    OR
    -- (b) affectation permanente active
    EXISTS (
      SELECT 1
        FROM public.employees e
        JOIN public.employee_hotel_assignments a
          ON a.employee_id = e.id
         AND a.target_hotel_id = p_hotel
         AND a.active = true
       WHERE e.id = p_employee AND e.active = true
    )
    OR
    -- (c) activation Extra pour le mois concerné
    EXISTS (
      SELECT 1
        FROM public.employees e
        JOIN public.employee_extra_activations ea
          ON ea.employee_id = e.id
         AND ea.hotel_id = p_hotel
         AND ea.active = true
         AND ea.year  = extract(year  FROM p_day)::int
         AND ea.month = extract(month FROM p_day)::int
       WHERE e.id = p_employee AND e.active = true
    )
    OR
    -- (d) shift planifié P pour la date concernée
    EXISTS (
      SELECT 1
        FROM public.employees e
        JOIN public.staff_planning p
          ON p.employee_id = e.id
         AND p.hotel_id = p_hotel
         AND p.day = p_day
         AND p.status = 'P'
       WHERE e.id = p_employee AND e.active = true
    ),
    false
  )
$$;
GRANT EXECUTE ON FUNCTION public.employee_can_clock_at(uuid, uuid, date) TO authenticated, service_role;

COMMENT ON FUNCTION public.employee_can_clock_at(uuid, uuid, date) IS
  'Renvoie true si le salarié est actuellement autorisé à pointer dans l''hôtel du terminal à la date donnée. Ne prend PAS en compte l''historique de pointage : seuls comptent l''hôtel principal actif, une affectation ou activation Extra active, ou un shift planifié. Utilisé par la RPC record_clocking et par clock-portal.';

-- ── 10. Idempotence + protection SQL contre double pointage ──────────────────
-- On maintient une table dédiée (clé, clocking_id, action) plutôt qu'une
-- colonne unique sur staff_clockings : une même session peut recevoir des
-- clés distinctes sur clock_in puis clock_out ; chaque retry doit pouvoir
-- retomber sur sa propre écriture.
CREATE TABLE IF NOT EXISTS public.staff_clocking_idempotency (
  key          text        PRIMARY KEY,
  clocking_id  uuid        NOT NULL REFERENCES public.staff_clockings(id) ON DELETE CASCADE,
  action       text        NOT NULL CHECK (action IN ('clock_in','clock_out')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staff_clocking_idempotency_clocking
  ON public.staff_clocking_idempotency(clocking_id);

COMMENT ON TABLE public.staff_clocking_idempotency IS
  'Registre des clés d''idempotence par pointage. Un retry réseau avec la même clé retourne la même écriture. Purge conseillée après 24 h.';

-- Colonne informative sur staff_clockings pour retrouver la clé la plus
-- récente sans jointure (utile pour l''export/audit).
ALTER TABLE public.staff_clockings
  ADD COLUMN IF NOT EXISTS idempotency_key text;

-- Invariant fort : au plus UN pointage ouvert par employé, tous hôtels confondus.
-- Empêche à la source les doubles clock-in issus de deux onglets, deux
-- terminaux, un double-clic ou une course d'insertions concurrentes.
CREATE UNIQUE INDEX IF NOT EXISTS staff_clockings_one_open_per_employee
  ON public.staff_clockings(employee_id)
  WHERE clock_out_ts IS NULL;

COMMENT ON INDEX public.staff_clockings_one_open_per_employee IS
  'Un salarié ne peut avoir qu''un seul pointage ouvert à la fois (tous hôtels confondus). Empêche les doubles clock-in issus de courses HTTP concurrentes. Le fermer avant un nouveau clock-in est de la responsabilité de la RPC record_clocking (advisory lock + logique action).';

-- ── 11. Utilitaire : date civile dans le fuseau de l'hôtel ──────────────────
CREATE OR REPLACE FUNCTION public.pl_hotel_local_day(
  p_hotel uuid, p_ts timestamptz DEFAULT now()
) RETURNS date
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT (p_ts AT TIME ZONE COALESCE(
            (SELECT timezone FROM public.hotels WHERE id = p_hotel),
            'Europe/Paris'
          ))::date
$$;
GRANT EXECUTE ON FUNCTION public.pl_hotel_local_day(uuid, timestamptz) TO authenticated, service_role;

COMMENT ON FUNCTION public.pl_hotel_local_day(uuid, timestamptz) IS
  'Date civile locale de l''hôtel pour un timestamp donné. Fallback Europe/Paris si hotels.timezone non défini. Utilisée pour calculer staff_clockings.day sans dérive due au décalage UTC/local (poste de nuit, DST).';

-- ── 12. RPC de pointage atomique (source de vérité pour l'edge function) ────
-- Encapsule :
--   · advisory lock par employé (empêche deux pointages concurrents du même
--     salarié de s'entrelacer, même sans idempotency_key)
--   · lookup d'idempotency_key : si la même clé revient, on renvoie la ligne
--     déjà écrite (retry réseau safe)
--   · lookup de l'unique pointage ouvert de l'employé (indépendant du jour)
--   · si ouvert : UPDATE ... WHERE id = X AND clock_out_ts IS NULL
--     → toute course perd et la 2e requête est traitée comme succès idempotent
--   · si fermé : INSERT ; l'index unique partiel empêche le doublon
--
-- Cette RPC est appelée par l'edge function clock-portal (service_role) après
-- authentification et vérification employee_can_clock_at().
CREATE OR REPLACE FUNCTION public.record_clocking(
  p_employee_id     uuid,
  p_hotel_id        uuid,
  p_terminal_id     uuid,
  p_source          text,
  p_idempotency_key text DEFAULT NULL,
  p_audit           jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_open   public.staff_clockings;
  v_existing public.staff_clockings;
  v_day    date;
  v_now    timestamptz := now();
  v_id     uuid;
  v_action text;
BEGIN
  IF p_employee_id IS NULL OR p_hotel_id IS NULL THEN
    RAISE EXCEPTION 'BAD_INPUT' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_source,'') NOT IN ('manual','qr','self','system') THEN
    RAISE EXCEPTION 'BAD_SOURCE' USING ERRCODE = '22023';
  END IF;

  -- 1. Sérialisation stricte par employé (verrou transactionnel advisory).
  --    hashtextextended est stable → même bucket à chaque appel.
  --    Placé AVANT la lecture d'idempotence pour que deux requêtes émises
  --    quasi-simultanément avec la même clé soient sérialisées : la seconde
  --    trouvera la clé fraîchement inscrite par la première et retournera
  --    immédiatement sans re-jouer l'action.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_employee_id::text, 62));

  -- 2. Idempotency : si la clé est déjà connue, retourner la ligne
  --    correspondante en marquant idempotent=true. Le verrou détenu à
  --    l'étape 1 garantit que la course "insert idempotency vs read
  --    idempotency" ne peut plus se produire pour ce même employé.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT c.* INTO v_existing
      FROM public.staff_clocking_idempotency k
      JOIN public.staff_clockings c ON c.id = k.clocking_id
     WHERE k.key = p_idempotency_key
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'id',        v_existing.id,
        'action',    (SELECT action FROM public.staff_clocking_idempotency
                       WHERE key = p_idempotency_key),
        'day',       v_existing.day,
        'clock_in_ts',  v_existing.clock_in_ts,
        'clock_out_ts', v_existing.clock_out_ts,
        'idempotent', true
      );
    END IF;
  END IF;

  -- 3. Chercher l'unique pointage ouvert de l'employé, tous hôtels confondus.
  --    (garanti unique par staff_clockings_one_open_per_employee)
  SELECT * INTO v_open FROM public.staff_clockings
   WHERE employee_id = p_employee_id AND clock_out_ts IS NULL
   LIMIT 1;

  IF v_open.id IS NOT NULL THEN
    -- 4a. CLOCK-OUT. Deux requêtes concurrentes : celle qui perd n'affecte
    --     aucune ligne (clock_out_ts est déjà non NULL) → succès idempotent.
    UPDATE public.staff_clockings
       SET clock_out_ts = v_now,
           updated_at   = v_now,
           gps_lat        = COALESCE((p_audit->>'gps_lat')::float8,    gps_lat),
           gps_lng        = COALESCE((p_audit->>'gps_lng')::float8,    gps_lng),
           gps_accuracy   = COALESCE((p_audit->>'gps_accuracy')::float8, gps_accuracy),
           distance_meters= COALESCE((p_audit->>'distance_meters')::int, distance_meters),
           device_info    = COALESCE(p_audit->>'device_info',    device_info),
           ip_address     = COALESCE((p_audit->>'ip_address')::inet, ip_address),
           clock_status   = COALESCE(p_audit->>'clock_status',   clock_status),
           anomaly_flags  = CASE WHEN p_audit ? 'anomaly_flags'
                                 THEN ARRAY(SELECT jsonb_array_elements_text(p_audit->'anomaly_flags'))
                                 ELSE anomaly_flags END,
           idempotency_key = COALESCE(idempotency_key, p_idempotency_key)
     WHERE id = v_open.id AND clock_out_ts IS NULL
     RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      -- La course a été perdue : renvoyer la version fermée.
      SELECT id INTO v_id FROM public.staff_clockings WHERE id = v_open.id;
    END IF;
    v_action := 'clock_out';

    IF p_idempotency_key IS NOT NULL THEN
      INSERT INTO public.staff_clocking_idempotency(key, clocking_id, action)
      VALUES (p_idempotency_key, v_id, 'clock_out')
      ON CONFLICT (key) DO NOTHING;
    END IF;
  ELSE
    -- 4b. CLOCK-IN. day dérive du fuseau de l'hôtel du terminal.
    v_day := public.pl_hotel_local_day(p_hotel_id, v_now);

    BEGIN
      INSERT INTO public.staff_clockings(
        hotel_id, employee_id, day, clock_in_ts, source,
        terminal_id, idempotency_key,
        gps_lat, gps_lng, gps_accuracy, distance_meters,
        device_info, ip_address, clock_status, anomaly_flags
      ) VALUES (
        p_hotel_id, p_employee_id, v_day, v_now, p_source,
        p_terminal_id, p_idempotency_key,
        NULLIF(p_audit->>'gps_lat','')::float8,
        NULLIF(p_audit->>'gps_lng','')::float8,
        NULLIF(p_audit->>'gps_accuracy','')::float8,
        NULLIF(p_audit->>'distance_meters','')::int,
        p_audit->>'device_info',
        NULLIF(p_audit->>'ip_address','')::inet,
        COALESCE(p_audit->>'clock_status','valid'),
        CASE WHEN p_audit ? 'anomaly_flags'
             THEN ARRAY(SELECT jsonb_array_elements_text(p_audit->'anomaly_flags'))
             ELSE NULL END
      )
      RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
      -- Course perdue sur staff_clockings_one_open_per_employee : renvoyer
      -- la ligne ouverte existante (créée par l'autre requête concurrente).
      SELECT id INTO v_id FROM public.staff_clockings
       WHERE employee_id = p_employee_id AND clock_out_ts IS NULL LIMIT 1;
    END;
    v_action := 'clock_in';

    IF p_idempotency_key IS NOT NULL AND v_id IS NOT NULL THEN
      INSERT INTO public.staff_clocking_idempotency(key, clocking_id, action)
      VALUES (p_idempotency_key, v_id, 'clock_in')
      ON CONFLICT (key) DO NOTHING;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'id',       v_id,
    'action',   v_action,
    'day',      COALESCE(v_day, v_open.day),
    'idempotent', false
  );
END $$;

-- record_clocking n'est jamais appelée par un client anonyme : elle est
-- invoquée par l'edge function clock-portal (rôle service_role) une fois
-- l'employé authentifié et l'autorisation employee_can_clock_at() validée.
REVOKE ALL ON FUNCTION public.record_clocking(uuid,uuid,uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_clocking(uuid,uuid,uuid,text,text,jsonb) TO service_role;

-- ── 13. TODO daté : retrait complet du fallback hotel_qr_tokens ─────────────
-- Créé : 2026-07-27
-- Fenêtre de compatibilité : 90 jours (jusqu'au 2026-10-25).
-- Étapes prévues :
--   1. À J+30 : ajouter is_deprecated=true sur les anciens hotel_qr_tokens
--      pour émettre un warning dans clock-portal (télémétrie).
--   2. À J+60 : désactiver (is_active=false) tous les hotel_qr_tokens actifs
--      et communiquer aux hôtels concernés — chaque hôtel doit désormais
--      utiliser un terminal explicitement créé.
--   3. À J+90 : supprimer le chemin legacy dans clock-portal/index.ts,
--      supprimer la table hotel_qr_tokens (après export des tokens en audit).
-- IMPORTANT : un ancien hotel_qr_tokens ne DOIT jamais être promu en terminal
-- automatiquement — le backfill de la migration 62 crée un terminal
-- « Réception » dédié et l'edge function trace legacy=true sur chaque usage.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='hotel_qr_tokens') THEN
    -- Comment sur la table pour rappeler la deadline (visible dans le studio Supabase).
    EXECUTE 'COMMENT ON TABLE public.hotel_qr_tokens IS '
         || quote_literal('OBSOLÈTE — fallback maintenu jusqu''au 2026-10-25 (90 jours après la migration 63). '
                       || 'Ne PAS créer de nouveaux tokens ici. Utilisez create_pointage_terminal(). '
                       || 'La suppression sera effectuée par une migration 65_hotel_qr_tokens_drop.sql.');
  END IF;
END $$;
