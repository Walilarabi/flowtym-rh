-- ============================================================================
-- Suite de tests reproductible — P0 Prévisualisation des essais expirés
--
-- Portée réduite suite à la décision CTO du plan de dépréciation de
-- hotel_app_subscriptions (ADR-011) : cette suite ne couvre plus que
-- admin_preview_expired_trials_processing(), strictement indépendante de
-- hotel_app_subscriptions. admin_extend_trial() n'est plus modifiée par ce lot (elle reste
-- celle de sql/70, non retestée ici) et admin_sync_app_trial_dates() n'existe plus.
--
-- À exécuter APRÈS avoir appliqué sql/79_super_admin_p0_trial_app_access_coherence.sql
-- (en développement, ou en production dans une transaction non commitée pour vérification
-- pré-déploiement). Convention identique aux suites soeurs : chaque scénario crée ses propres
-- fixtures, suffixées par un uuid aléatoire.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE zz_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 400))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz_results TO authenticated;

-- ----------------------------------------------------------------------------
-- Helpers de fixtures
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.zz_mk_hotel(p_status text DEFAULT 'active') RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST-' || gen_random_uuid()::text, p_status) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins(auth_id, email, role, is_active)
    VALUES (v_auth, 'zztest-admin-' || v_auth::text || '@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_plan(p_trial_days int DEFAULT 14) RETURNS uuid AS $$
DECLARE v_id uuid; v_slug text := 'zztest-plan-' || gen_random_uuid()::text;
BEGIN
  INSERT INTO public.subscription_plans(
    name, slug, price_monthly, price_annual, modules, features, support_level,
    is_active, sort_order, trial_days, plan_scope, is_commercializable
  ) VALUES (
    'ZZTEST Plan', v_slug, 100, 1000, '[]'::jsonb, '[]'::jsonb, 'none', true, 999, p_trial_days, 'public', true
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_sub(
  p_hotel uuid, p_plan uuid, p_status text DEFAULT 'trial', p_trial_ends_at timestamptz DEFAULT NULL
) RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotel_subscriptions(hotel_id, plan_id, status, billing_cycle, trial_ends_at)
  VALUES (p_hotel, p_plan, p_status, 'monthly', p_trial_ends_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 1. Prévisualisation avec zéro ligne (rien n'a dépassé son échéance)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '30 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro ligne', 'PASS', 'aucune ligne pour cet hôtel');
  ELSE
    PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro ligne', 'FAIL', format('%s ligne(s) inattendue(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro ligne', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Prévisualisation avec un abonnement principal expiré — contenu correct
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '3 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_row.subscription_id = v_sub AND v_row.days_since_expiry > 0 AND v_row.theoretical_effect LIKE '%expired%' THEN
    PERFORM pg_temp.zz_log(2, 'Prévisualisation avec abonnement principal expiré', 'PASS', format('days_since_expiry=%s effet=%s', v_row.days_since_expiry, v_row.theoretical_effect));
  ELSE
    PERFORM pg_temp.zz_log(2, 'Prévisualisation avec abonnement principal expiré', 'FAIL', coalesce(v_row::text, 'aucune ligne'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(2, 'Prévisualisation avec abonnement principal expiré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Essai avec trial_ends_at IS NULL — ignoré, jamais traité comme expiré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', NULL);
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(3, 'Essai avec trial_ends_at IS NULL ignoré', 'PASS', 'aucune ligne — jamais traité comme expiré');
  ELSE
    PERFORM pg_temp.zz_log(3, 'Essai avec trial_ends_at IS NULL ignoré', 'FAIL', format('%s ligne(s) inattendue(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Essai avec trial_ends_at IS NULL ignoré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Abonnement non-trial ou déjà expiré — jamais reproposé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'expired', now() - interval '10 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(4, 'Abonnement déjà expired non reproposé', 'PASS', 'aucune ligne — seul status=trial est éligible');
  ELSE
    PERFORM pg_temp.zz_log(4, 'Abonnement déjà expired non reproposé', 'FAIL', format('%s ligne(s) inattendue(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Abonnement déjà expired non reproposé', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Appel non-admin rejeté (42501)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_nonadmin uuid; v_failed boolean := false;
BEGIN
  v_nonadmin := pg_temp.zz_mk_nonadmin(); PERFORM pg_temp.zz_as(v_nonadmin);
  BEGIN
    PERFORM * FROM public.admin_preview_expired_trials_processing();
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN v_failed := true; END IF;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz_log(5, 'Appel non-admin rejeté', 'PASS', 'exception 42501 levée');
  ELSE
    PERFORM pg_temp.zz_log(5, 'Appel non-admin rejeté', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(5, 'Appel non-admin rejeté', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Prévisualisation sans écriture — deux appels successifs, aucun effet
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid;
        v_evt_before int; v_evt_after int; v_log_before int; v_log_after int; v_status text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_evt_before FROM public.hotel_subscription_events WHERE subscription_id = v_sub;
  SELECT count(*) INTO v_log_before FROM public.platform_logs WHERE entity_id = v_sub::text;
  PERFORM * FROM public.admin_preview_expired_trials_processing();
  PERFORM * FROM public.admin_preview_expired_trials_processing();
  SELECT count(*) INTO v_evt_after FROM public.hotel_subscription_events WHERE subscription_id = v_sub;
  SELECT count(*) INTO v_log_after FROM public.platform_logs WHERE entity_id = v_sub::text;
  SELECT status INTO v_status FROM public.hotel_subscriptions WHERE id = v_sub;
  IF v_evt_before = v_evt_after AND v_log_before = v_log_after AND v_status = 'trial' THEN
    PERFORM pg_temp.zz_log(6, 'Prévisualisation sans écriture', 'PASS', 'aucun événement, aucun log, statut inchangé après 2 appels');
  ELSE
    PERFORM pg_temp.zz_log(6, 'Prévisualisation sans écriture', 'FAIL', format('evt %s->%s log %s->%s statut=%s', v_evt_before, v_evt_after, v_log_before, v_log_after, v_status));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(6, 'Prévisualisation sans écriture', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. ACL — REVOKE FROM anon/service_role, GRANT à authenticated seulement
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_anon boolean; v_svc boolean; v_auth boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.admin_preview_expired_trials_processing()', 'EXECUTE') INTO v_anon;
  SELECT has_function_privilege('service_role', 'public.admin_preview_expired_trials_processing()', 'EXECUTE') INTO v_svc;
  SELECT has_function_privilege('authenticated', 'public.admin_preview_expired_trials_processing()', 'EXECUTE') INTO v_auth;
  IF NOT v_anon AND NOT v_svc AND v_auth THEN
    PERFORM pg_temp.zz_log(7, 'ACL admin_preview_expired_trials_processing', 'PASS', 'anon=false, service_role=false, authenticated=true');
  ELSE
    PERFORM pg_temp.zz_log(7, 'ACL admin_preview_expired_trials_processing', 'FAIL', format('anon=%s service_role=%s authenticated=%s', v_anon, v_svc, v_auth));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(7, 'ACL admin_preview_expired_trials_processing', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Non-régression — admin_extend_trial reste inchangée (signature de retour d'origine),
--    admin_sync_app_trial_dates n'existe pas, hotel_app_subscriptions n'est touchée nulle part
--    par cette migration
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_ret text; v_sync_exists boolean; v_src text;
BEGIN
  SELECT format_type(p.prorettype, NULL) INTO v_ret
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'admin_extend_trial';
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'admin_sync_app_trial_dates'
  ) INTO v_sync_exists;
  SELECT pg_get_functiondef('public.admin_preview_expired_trials_processing()'::regprocedure) INTO v_src;
  IF v_ret = 'hotel_subscriptions' AND NOT v_sync_exists AND v_src !~* 'hotel_app_subscriptions' THEN
    PERFORM pg_temp.zz_log(8, 'Aucune dépendance métier nouvelle vers hotel_app_subscriptions', 'PASS', format('admin_extend_trial retourne %s (type d''origine), admin_sync_app_trial_dates absente, preview sans référence à hotel_app_subscriptions', v_ret));
  ELSE
    PERFORM pg_temp.zz_log(8, 'Aucune dépendance métier nouvelle vers hotel_app_subscriptions', 'FAIL', format('admin_extend_trial retourne %s, admin_sync_app_trial_dates existe=%s', v_ret, v_sync_exists));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(8, 'Aucune dépendance métier nouvelle vers hotel_app_subscriptions', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Non-régression sur les autres hôtels réels (hors ZZTEST)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_bad_hs int;
BEGIN
  SELECT count(*) INTO v_bad_hs FROM public.hotel_subscriptions hs
   JOIN public.hotels h ON h.id = hs.hotel_id
   WHERE h.name NOT LIKE 'ZZTEST-%' AND hs.updated_at >= now() - interval '5 minutes';
  IF v_bad_hs = 0 THEN
    PERFORM pg_temp.zz_log(9, 'Non-régression sur les autres hôtels', 'PASS', 'aucune ligne réelle modifiée pendant la suite (prévisualisation strictement lecture seule)');
  ELSE
    PERFORM pg_temp.zz_log(9, 'Non-régression sur les autres hôtels', 'FAIL', format('%s ligne(s) modifiée(s)', v_bad_hs));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(9, 'Non-régression sur les autres hôtels', 'FAIL', SQLERRM);
END $$;

-- ============================================================================
-- Rapport final : détail + échec si au moins un test a échoué
-- ============================================================================
DO $$
DECLARE v_total int; v_failed int; v_row record;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status = 'FAIL') INTO v_total, v_failed FROM zz_results;
  FOR v_row IN SELECT * FROM zz_results ORDER BY test_no LOOP
    RAISE NOTICE '[%] % — %: %', v_row.test_no, v_row.status, v_row.name, v_row.detail;
  END LOOP;
  RAISE NOTICE '========================================';
  RAISE NOTICE 'Résultat : % / % PASS', v_total - v_failed, v_total;
  RAISE NOTICE '========================================';
  IF v_failed > 0 THEN
    RAISE EXCEPTION '% test(s) en échec sur %', v_failed, v_total;
  END IF;
  RAISE NOTICE 'OK : suite P0 prévisualisation des essais expirés complète, % scénarios, 0 échec.', v_total;
END $$;

-- Rollback du BEGIN externe : détruit toutes les fixtures ZZTEST, aucune trace persistante.
ROLLBACK;
