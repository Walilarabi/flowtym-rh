-- =============================================================================
-- 65_pointage_record_clocking_column_alignment.sql
-- Migration additive : corrige record_clocking pour tolérer les types réels
-- de staff_clockings en production (colonnes ajoutées hors migration
-- versionnée avant le module Pointage v2) et sécurise anomaly_flags.
--
-- Deux bugs corrigés :
--
--   1. anomaly_flags recevait un jsonb null (« "anomaly_flags": null »).
--      Le test `p_audit ? 'anomaly_flags'` matchait la clé même quand la
--      valeur est null. Résultat : `jsonb_array_elements_text(null::jsonb)`
--      → 22023 "cannot extract elements from a scalar". Chaque scan sans
--      anomalie explosait avec message « Erreur enregistrement: cannot
--      extract elements from a scalar ». Fix : basculer sur
--      `jsonb_typeof(...) = 'array'`.
--
--   2. staff_clockings.ip_address est `text` (pas `inet`) et
--      distance_meters est `double precision` (pas `int`) en production
--      — les ADD COLUMN IF NOT EXISTS de la migration 63 étaient des
--      no-ops sur ces colonnes préexistantes. Les casts `::inet` et
--      `::int` dans record_clocking levaient 42804 côté clock_out.
--      Fix : pas de cast pour ip_address (texte direct), cast ::float8
--      pour distance_meters.
--
-- Migration ADDITIVE : appliquée après 63 en production, safe à rejouer.
-- Le fichier 63 initial reste dans son état déployé côté prod (les 5
-- entrées dans supabase_migrations.schema_migrations demeurent la
-- trace historique). Une reconstruction from scratch depuis le dépôt
-- exécute 62 → 63 (fichier corrigé côté fichier source) → 64 → 65.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_clocking(
  p_employee_id uuid, p_hotel_id uuid, p_terminal_id uuid,
  p_source text, p_idempotency_key text DEFAULT NULL, p_audit jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE v_open public.staff_clockings; v_existing public.staff_clockings; v_day date; v_now timestamptz := now(); v_id uuid; v_action text;
BEGIN
  IF p_employee_id IS NULL OR p_hotel_id IS NULL THEN RAISE EXCEPTION 'BAD_INPUT' USING ERRCODE='22023'; END IF;
  IF coalesce(p_source,'') NOT IN ('manual','qr','self','system') THEN RAISE EXCEPTION 'BAD_SOURCE' USING ERRCODE='22023'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_employee_id::text, 62));

  IF p_idempotency_key IS NOT NULL THEN
    SELECT c.* INTO v_existing FROM public.staff_clocking_idempotency k
     JOIN public.staff_clockings c ON c.id = k.clocking_id
     WHERE k.key = p_idempotency_key LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'id', v_existing.id,
        'action', (SELECT action FROM public.staff_clocking_idempotency WHERE key = p_idempotency_key),
        'day', v_existing.day, 'clock_in_ts', v_existing.clock_in_ts, 'clock_out_ts', v_existing.clock_out_ts,
        'idempotent', true);
    END IF;
  END IF;

  SELECT * INTO v_open FROM public.staff_clockings
   WHERE employee_id = p_employee_id AND clock_out_ts IS NULL LIMIT 1;

  IF v_open.id IS NOT NULL THEN
    -- CLOCK-OUT : anomaly_flags via jsonb_typeof (null/scalar-safe).
    -- ip_address text (pas inet), distance_meters double precision (pas int).
    UPDATE public.staff_clockings
       SET clock_out_ts = v_now, updated_at = v_now,
           gps_lat = COALESCE((p_audit->>'gps_lat')::float8, gps_lat),
           gps_lng = COALESCE((p_audit->>'gps_lng')::float8, gps_lng),
           gps_accuracy = COALESCE((p_audit->>'gps_accuracy')::float8, gps_accuracy),
           distance_meters = COALESCE((p_audit->>'distance_meters')::float8, distance_meters),
           device_info = COALESCE(p_audit->>'device_info', device_info),
           ip_address  = COALESCE(p_audit->>'ip_address',  ip_address),
           clock_status = COALESCE(p_audit->>'clock_status', clock_status),
           anomaly_flags = CASE jsonb_typeof(p_audit->'anomaly_flags')
                             WHEN 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p_audit->'anomaly_flags'))
                             ELSE anomaly_flags
                           END,
           idempotency_key = COALESCE(idempotency_key, p_idempotency_key)
     WHERE id = v_open.id AND clock_out_ts IS NULL
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      SELECT id INTO v_id FROM public.staff_clockings WHERE id = v_open.id;
    END IF;
    v_action := 'clock_out';
    IF p_idempotency_key IS NOT NULL THEN
      INSERT INTO public.staff_clocking_idempotency(key, clocking_id, action) VALUES (p_idempotency_key, v_id, 'clock_out')
      ON CONFLICT (key) DO NOTHING;
    END IF;
  ELSE
    -- CLOCK-IN : idem — jsonb_typeof + types réels.
    v_day := public.pl_hotel_local_day(p_hotel_id, v_now);
    BEGIN
      INSERT INTO public.staff_clockings(
        hotel_id, employee_id, day, clock_in_ts, source, terminal_id, idempotency_key,
        gps_lat, gps_lng, gps_accuracy, distance_meters, device_info, ip_address, clock_status, anomaly_flags
      ) VALUES (
        p_hotel_id, p_employee_id, v_day, v_now, p_source, p_terminal_id, p_idempotency_key,
        NULLIF(p_audit->>'gps_lat','')::float8, NULLIF(p_audit->>'gps_lng','')::float8,
        NULLIF(p_audit->>'gps_accuracy','')::float8, NULLIF(p_audit->>'distance_meters','')::float8,
        p_audit->>'device_info', p_audit->>'ip_address',
        COALESCE(p_audit->>'clock_status','valid'),
        CASE jsonb_typeof(p_audit->'anomaly_flags')
          WHEN 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p_audit->'anomaly_flags'))
          ELSE NULL
        END
      ) RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT id INTO v_id FROM public.staff_clockings WHERE employee_id = p_employee_id AND clock_out_ts IS NULL LIMIT 1;
    END;
    v_action := 'clock_in';
    IF p_idempotency_key IS NOT NULL AND v_id IS NOT NULL THEN
      INSERT INTO public.staff_clocking_idempotency(key, clocking_id, action) VALUES (p_idempotency_key, v_id, 'clock_in')
      ON CONFLICT (key) DO NOTHING;
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id, 'action', v_action, 'day', COALESCE(v_day, v_open.day), 'idempotent', false);
END $$;

REVOKE ALL ON FUNCTION public.record_clocking(uuid,uuid,uuid,text,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_clocking(uuid,uuid,uuid,text,text,jsonb) TO service_role;
