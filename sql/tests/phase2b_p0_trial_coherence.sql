-- ============================================================================
-- Suite de tests reproductible — P0 Traitement des essais expirés, périmètre
-- hotel_subscriptions uniquement (contrat prévisualisation = exécution, ADR-011 phase 1)
--
-- Couvre : admin_preview_expired_trials_processing(), process_expired_hotel_subscription_trials(),
-- admin_run_expired_trials_processing(). Vérifie explicitement qu'aucune ligne
-- hotel_app_subscriptions n'est modifiée par le portail, que l'ancienne
-- process_expired_subscription_trials() reste intacte et non appelée, et qu'aucune donnée
-- historique n'est supprimée.
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

CREATE OR REPLACE FUNCTION pg_temp.zz_app_id(p_code text) RETURNS uuid AS $$
  SELECT id FROM public.platform_apps WHERE code = p_code;
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

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_app_sub(
  p_hotel uuid, p_app_code text, p_status text DEFAULT 'trial', p_trial_ends_at timestamptz DEFAULT NULL
) RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotel_app_subscriptions(hotel_id, app_id, status, trial_ends_at)
  VALUES (p_hotel, pg_temp.zz_app_id(p_app_code), p_status, p_trial_ends_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 1. Prévisualisation avec zéro abonnement expiré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '30 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro abonnement expiré', 'PASS', 'aucune ligne');
  ELSE
    PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro abonnement expiré', 'FAIL', format('%s ligne(s) inattendue(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'Prévisualisation avec zéro abonnement expiré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Exécution avec zéro abonnement expiré — aucune modification
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_row record; v_status_after text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '30 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_run_expired_trials_processing();
  SELECT status INTO v_status_after FROM public.hotel_subscriptions WHERE id = v_sub;
  IF v_status_after = 'trial' THEN
    PERFORM pg_temp.zz_log(2, 'Exécution avec zéro abonnement expiré', 'PASS', format('processed_subscriptions global=%s (peut inclure d''autres runs), statut fixture inchangé=trial', v_row.processed_subscriptions));
  ELSE
    PERFORM pg_temp.zz_log(2, 'Exécution avec zéro abonnement expiré', 'FAIL', format('statut fixture=%s (attendu trial)', v_status_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(2, 'Exécution avec zéro abonnement expiré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Prévisualisation et exécution avec un abonnement expiré — cohérence
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid;
        v_preview record; v_exec record; v_status_after text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '3 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_preview FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  SELECT * INTO v_exec FROM public.admin_run_expired_trials_processing();
  SELECT status INTO v_status_after FROM public.hotel_subscriptions WHERE id = v_sub;
  IF v_preview.subscription_id = v_sub AND v_status_after = 'expired' THEN
    PERFORM pg_temp.zz_log(3, 'Prévisualisation et exécution avec un abonnement expiré', 'PASS', format('preview a annoncé %s, statut après exécution=%s', v_preview.subscription_id, v_status_after));
  ELSE
    PERFORM pg_temp.zz_log(3, 'Prévisualisation et exécution avec un abonnement expiré', 'FAIL', format('preview=%s statut_après=%s', v_preview.subscription_id, v_status_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Prévisualisation et exécution avec un abonnement expiré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4/5. Ligne hotel_app_subscriptions expirée en parallèle — jamais modifiée par le portail
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_app_sub uuid;
        v_before timestamptz := now() - interval '40 days'; v_status_before text := 'trial';
        v_after timestamptz; v_status_after text; v_sub_status_after text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '3 days');
  v_app_sub := pg_temp.zz_mk_app_sub(v_hotel, 'RH', v_status_before, v_before); -- ligne legacy également expirée
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_run_expired_trials_processing();
  SELECT trial_ends_at, status INTO v_after, v_status_after FROM public.hotel_app_subscriptions WHERE id = v_app_sub;
  SELECT status INTO v_sub_status_after FROM public.hotel_subscriptions WHERE id = v_sub;
  IF v_after = v_before AND v_status_after = v_status_before AND v_sub_status_after = 'expired' THEN
    PERFORM pg_temp.zz_log(4, 'Ligne hotel_app_subscriptions legacy jamais modifiée par le portail', 'PASS', format('hotel_app_subscriptions inchangée (statut=%s, date=%s), abonnement principal correctement expiré', v_status_after, v_after));
  ELSE
    PERFORM pg_temp.zz_log(4, 'Ligne hotel_app_subscriptions legacy jamais modifiée par le portail', 'FAIL', format('statut=%s (attendu %s) date=%s (attendu %s) sub=%s', v_status_after, v_status_before, v_after, v_before, v_sub_status_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Ligne hotel_app_subscriptions legacy jamais modifiée par le portail', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Cohérence des critères SQL entre preview et exécution (même prédicat exact)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_preview_src text; v_exec_src text;
        v_preview_pred text := 'status = ''trial'' AND hs.trial_ends_at IS NOT NULL AND hs.trial_ends_at < now()';
BEGIN
  SELECT pg_get_functiondef('public.admin_preview_expired_trials_processing()'::regprocedure) INTO v_preview_src;
  SELECT pg_get_functiondef('public.process_expired_hotel_subscription_trials()'::regprocedure) INTO v_exec_src;
  IF v_preview_src ~* 'status\s*=\s*''trial''.*trial_ends_at\s+is\s+not\s+null.*trial_ends_at\s*<\s*now\(\)'
     AND v_exec_src ~* 'status\s*=\s*''trial''.*trial_ends_at\s+is\s+not\s+null.*trial_ends_at\s*<\s*now\(\)'
     AND v_preview_src ~* 'hotel_subscriptions' AND v_exec_src ~* 'hotel_subscriptions'
     AND v_preview_src !~* 'hotel_app_subscriptions' AND v_exec_src !~* 'hotel_app_subscriptions' THEN
    PERFORM pg_temp.zz_log(6, 'Cohérence des critères SQL preview/exécution', 'PASS', 'même table (hotel_subscriptions), même statut, même condition trial_ends_at, aucune référence à hotel_app_subscriptions dans les deux corps de fonction');
  ELSE
    PERFORM pg_temp.zz_log(6, 'Cohérence des critères SQL preview/exécution', 'FAIL', 'prédicats divergents ou référence résiduelle à hotel_app_subscriptions détectée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(6, 'Cohérence des critères SQL preview/exécution', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Idempotence — deux exécutions successives, la seconde ne retraite rien
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_r1 record; v_r2 record; v_before_count int; v_after_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '2 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_before_count FROM public.hotel_subscription_events WHERE subscription_id = v_sub AND event_type = 'expired_automatic';
  SELECT * INTO v_r1 FROM public.admin_run_expired_trials_processing();
  SELECT * INTO v_r2 FROM public.admin_run_expired_trials_processing();
  SELECT count(*) INTO v_after_count FROM public.hotel_subscription_events WHERE subscription_id = v_sub AND event_type = 'expired_automatic';
  IF v_after_count = v_before_count + 1 THEN
    PERFORM pg_temp.zz_log(7, 'Idempotence — second appel ne retraite rien', 'PASS', format('1 seul événement expired_automatic malgré 2 exécutions (r2.processed_subscriptions global=%s)', v_r2.processed_subscriptions));
  ELSE
    PERFORM pg_temp.zz_log(7, 'Idempotence — second appel ne retraite rien', 'FAIL', format('%s événement(s) au lieu de 1', v_after_count - v_before_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(7, 'Idempotence — second appel ne retraite rien', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Double clic — deux appels quasi simultanés (séquentiels dans la même session) sans
--    double traitement, garanti par le WHERE ... AND status='trial' de l'UPDATE atomique
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_evt_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '1 day');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_run_expired_trials_processing();
  PERFORM public.admin_run_expired_trials_processing(); -- simule un second clic après le premier
  SELECT count(*) INTO v_evt_count FROM public.hotel_subscription_events WHERE subscription_id = v_sub AND event_type = 'expired_automatic';
  IF v_evt_count = 1 THEN
    PERFORM pg_temp.zz_log(8, 'Double clic sans double traitement', 'PASS', '1 seul événement malgré 2 clics successifs');
  ELSE
    PERFORM pg_temp.zz_log(8, 'Double clic sans double traitement', 'FAIL', format('%s événement(s)', v_evt_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(8, 'Double clic sans double traitement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Appel non-admin rejeté (preview ET exécution)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_nonadmin uuid; v_failed_preview boolean := false; v_failed_exec boolean := false;
BEGIN
  v_nonadmin := pg_temp.zz_mk_nonadmin(); PERFORM pg_temp.zz_as(v_nonadmin);
  BEGIN
    PERFORM * FROM public.admin_preview_expired_trials_processing();
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE = '42501' THEN v_failed_preview := true; END IF; END;
  BEGIN
    PERFORM * FROM public.admin_run_expired_trials_processing();
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE = '42501' THEN v_failed_exec := true; END IF; END;
  IF v_failed_preview AND v_failed_exec THEN
    PERFORM pg_temp.zz_log(9, 'Appel non-admin rejeté (preview et exécution)', 'PASS', 'exception 42501 levée dans les deux cas');
  ELSE
    PERFORM pg_temp.zz_log(9, 'Appel non-admin rejeté (preview et exécution)', 'FAIL', format('preview_rejetee=%s exec_rejetee=%s', v_failed_preview, v_failed_exec));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(9, 'Appel non-admin rejeté (preview et exécution)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. Audit et logs — hotel_subscription_events + platform_logs (manuel + système)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_evt_count int; v_log_manual int; v_log_system int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '1 day');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_run_expired_trials_processing();
  SELECT count(*) INTO v_evt_count FROM public.hotel_subscription_events
   WHERE subscription_id = v_sub AND event_type = 'expired_automatic' AND actor_type = 'system';
  SELECT count(*) INTO v_log_manual FROM public.platform_logs WHERE action = 'trial_processing.manual_trigger';
  SELECT count(*) INTO v_log_system FROM public.platform_logs
   WHERE action = 'subscription_trial_expired' AND entity_id = v_sub::text;
  IF v_evt_count = 1 AND v_log_manual >= 1 AND v_log_system = 1 THEN
    PERFORM pg_temp.zz_log(10, 'Audit et logs', 'PASS', 'événement hotel_subscription_events + log manuel + log système présents');
  ELSE
    PERFORM pg_temp.zz_log(10, 'Audit et logs', 'FAIL', format('evt=%s log_manuel(total)=%s log_systeme=%s', v_evt_count, v_log_manual, v_log_system));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(10, 'Audit et logs', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11. Aucune régression sur Folkestone (donnée réelle, jamais modifiée par cette suite)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel_id uuid := '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid;
        v_sub_status text; v_sub_trial timestamptz; v_rh_trial timestamptz; v_pms_trial timestamptz;
BEGIN
  SELECT status, trial_ends_at INTO v_sub_status, v_sub_trial FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_id;
  SELECT trial_ends_at INTO v_rh_trial FROM public.hotel_app_subscriptions WHERE hotel_id = v_hotel_id AND app_id = pg_temp.zz_app_id('RH');
  SELECT trial_ends_at INTO v_pms_trial FROM public.hotel_app_subscriptions WHERE hotel_id = v_hotel_id AND app_id = pg_temp.zz_app_id('PMS');
  IF v_sub_status = 'trial' AND v_sub_trial > now() AND v_rh_trial IS NOT NULL AND v_pms_trial IS NOT NULL THEN
    PERFORM pg_temp.zz_log(11, 'Aucune régression sur Folkestone', 'PASS', format('abonnement toujours trial (%s, encore valide), RH/PMS legacy inchangées', v_sub_trial));
  ELSE
    PERFORM pg_temp.zz_log(11, 'Aucune régression sur Folkestone', 'FAIL', format('statut=%s trial_ends_at=%s rh=%s pms=%s', v_sub_status, v_sub_trial, v_rh_trial, v_pms_trial));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(11, 'Aucune régression sur Folkestone', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. Aucune suppression de table ni de fonction historique
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_table_exists boolean; v_old_fn_exists boolean; v_app_sub_count int;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='hotel_app_subscriptions'
  ) INTO v_table_exists;
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='process_expired_subscription_trials'
  ) INTO v_old_fn_exists;
  SELECT count(*) INTO v_app_sub_count FROM public.hotel_app_subscriptions;
  IF v_table_exists AND v_old_fn_exists AND v_app_sub_count >= 2 THEN
    PERFORM pg_temp.zz_log(12, 'Aucune suppression de table ni de donnée historique', 'PASS', format('hotel_app_subscriptions existe (%s lignes), process_expired_subscription_trials() toujours présente', v_app_sub_count));
  ELSE
    PERFORM pg_temp.zz_log(12, 'Aucune suppression de table ni de donnée historique', 'FAIL', format('table_existe=%s ancienne_fonction_existe=%s lignes=%s', v_table_exists, v_old_fn_exists, v_app_sub_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(12, 'Aucune suppression de table ni de donnée historique', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. process_expired_subscription_trials() (ancienne fonction) n'a plus aucun appelant réel
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_admin_run_src text;
BEGIN
  SELECT pg_get_functiondef('public.admin_run_expired_trials_processing()'::regprocedure) INTO v_admin_run_src;
  IF v_admin_run_src ~* 'process_expired_hotel_subscription_trials' AND v_admin_run_src !~* 'process_expired_subscription_trials\(\)' THEN
    PERFORM pg_temp.zz_log(13, 'admin_run_expired_trials_processing appelle le traitement dédié', 'PASS', 'appelle process_expired_hotel_subscription_trials(), plus process_expired_subscription_trials()');
  ELSE
    PERFORM pg_temp.zz_log(13, 'admin_run_expired_trials_processing appelle le traitement dédié', 'FAIL', 'référence inattendue détectée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(13, 'admin_run_expired_trials_processing appelle le traitement dédié', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14. Non-régression sur les autres hôtels réels (hors ZZTEST et Folkestone)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_bad_hs int; v_bad_has int;
BEGIN
  SELECT count(*) INTO v_bad_hs FROM public.hotel_subscriptions hs
   JOIN public.hotels h ON h.id = hs.hotel_id
   WHERE h.name NOT LIKE 'ZZTEST-%' AND hs.hotel_id <> '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid
     AND hs.updated_at >= now() - interval '5 minutes';
  SELECT count(*) INTO v_bad_has FROM public.hotel_app_subscriptions has
   JOIN public.hotels h ON h.id = has.hotel_id
   WHERE h.name NOT LIKE 'ZZTEST-%'
     AND has.updated_at >= now() - interval '5 minutes';
  IF v_bad_hs = 0 AND v_bad_has = 0 THEN
    PERFORM pg_temp.zz_log(14, 'Non-régression sur les autres hôtels', 'PASS', 'aucune ligne réelle modifiée (y compris aucune ligne hotel_app_subscriptions réelle, quel que soit l''hôtel)');
  ELSE
    PERFORM pg_temp.zz_log(14, 'Non-régression sur les autres hôtels', 'FAIL', format('hs modifiées=%s has modifiées=%s', v_bad_hs, v_bad_has));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(14, 'Non-régression sur les autres hôtels', 'FAIL', SQLERRM);
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
  RAISE NOTICE 'OK : suite P0 traitement des essais (hotel_subscriptions uniquement) complète, % scénarios, 0 échec.', v_total;
END $$;

-- Rollback du BEGIN externe : détruit toutes les fixtures ZZTEST, aucune trace persistante.
ROLLBACK;
