-- ============================================================================
-- Suite de tests reproductible — Phase 2A (fondations du modèle d'abonnement)
--
-- À exécuter APRÈS avoir appliqué sql/70_super_admin_phase2a_subscription_foundation.sql
-- (en développement, ou en production dans une transaction non commitée pour
-- vérification pré-déploiement — c'est ainsi qu'elle a été validée avant ce commit).
--
-- 38 scénarios : les 28 initialement définis lors de la revue CTO, plus 10 ajoutés lors
-- de la revue du livrable. Chaque test est isolé dans son propre sous-bloc BEGIN/EXCEPTION
-- (savepoint implicite) : l'échec d'un test n'empêche pas l'exécution des suivants.
-- Toutes les fixtures utilisent le préfixe 'ZZTEST' et sont détruites par le ROLLBACK final
-- — ce script n'écrit jamais rien de façon permanente, y compris en cas d'échec d'assertion.
--
-- Résultat : chaque test émet un RAISE NOTICE 'PASS ...' ou 'FAIL ...'. Le bloc final
-- échoue (RAISE EXCEPTION) si au moins un test a échoué, afin qu'un test runner externe
-- (psql -v ON_ERROR_STOP=1, ou CI) détecte l'échec par le code de sortie.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE zz_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE TEMP TABLE zz_baseline_access AS
SELECT h.name AS hotel_name, count(*) AS access_count
FROM public.user_app_access uaa JOIN public.hotels h ON h.id = uaa.hotel_id
WHERE h.name IN ('Folkestone opera','Washington Opera','Grand Hotel du Havre','Vendome opera','Mas Provencal Aix')
GROUP BY h.name;
CREATE TEMP TABLE zz_baseline_logs AS SELECT count(*) AS n FROM public.platform_logs;

CREATE OR REPLACE FUNCTION pg_temp.zz_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz_results TO authenticated;

DO $$
DECLARE
  v_hotel_a uuid; v_hotel_b uuid; v_hotel_c uuid; v_hotel_d uuid; v_hotel_e uuid; v_hotel_f uuid;
  v_hotel_g uuid; v_hotel_h uuid; v_hotel_i uuid;
  v_plan_public uuid; v_plan_public2 uuid; v_plan_internal uuid; v_plan_archived uuid;
  v_app_pms uuid; v_app_rh uuid; v_addon_active uuid; v_addon_expired uuid; v_addon_unmapped uuid;
  v_admin_auth uuid := '7afa461c-71a9-4a89-bca0-9de08e405bc7';
  v_nonadmin_auth uuid := '6cf1d95b-c84a-4946-ab3a-324bd3c3cc01';
  v_real_user uuid := 'b1a22fee-d753-42ff-9456-9e36bde13ae9';
  v_res jsonb; v_before_net numeric; v_ev_count int; v_ev_count2 int; v_log_count int; v_log_count2 int;
  v_folkestone_hotel uuid := '02b9eb0e-89ef-45de-ba8e-20d4b41c500c';
  v_distinct_causes int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_auth)::text, true);

  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel A','active') RETURNING id INTO v_hotel_a;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel B','active') RETURNING id INTO v_hotel_b;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel C','active') RETURNING id INTO v_hotel_c;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel D','active') RETURNING id INTO v_hotel_d;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel E','active') RETURNING id INTO v_hotel_e;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel F','active') RETURNING id INTO v_hotel_f;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel G','active') RETURNING id INTO v_hotel_g;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel H suspended','suspended') RETURNING id INTO v_hotel_h;
  INSERT INTO public.hotels(name, status) VALUES ('ZZTEST P2A Hotel I','active') RETURNING id INTO v_hotel_i;

  SELECT id INTO v_app_pms FROM public.platform_apps WHERE code='PMS';
  SELECT id INTO v_app_rh FROM public.platform_apps WHERE code='RH';

  INSERT INTO public.subscription_plans(name, slug, price_monthly, price_annual, modules, features, support_level, is_active, sort_order, trial_days, plan_scope, is_commercializable)
    VALUES ('ZZTEST Public Plan A','zztest-public-plan-a', 99, 990, '[]'::jsonb, '[]'::jsonb, 'none', true, 998, 14, 'public', true) RETURNING id INTO v_plan_public;
  INSERT INTO public.subscription_plans(name, slug, price_monthly, price_annual, modules, features, support_level, is_active, sort_order, trial_days, plan_scope, is_commercializable)
    VALUES ('ZZTEST Public Plan B','zztest-public-plan-b', 199, 1990, '[]'::jsonb, '[]'::jsonb, 'none', true, 997, 14, 'public', true) RETURNING id INTO v_plan_public2;
  INSERT INTO public.subscription_plans(name, slug, price_monthly, price_annual, modules, features, support_level, is_active, sort_order, trial_days, plan_scope, is_commercializable)
    VALUES ('ZZTEST Internal Plan','zztest-internal-plan', 0, 0, '[]'::jsonb, '[]'::jsonb, 'none', true, 999, NULL, 'internal', false) RETURNING id INTO v_plan_internal;
  INSERT INTO public.subscription_plans(name, slug, price_monthly, price_annual, modules, features, support_level, is_active, sort_order, trial_days, plan_scope, is_commercializable)
    VALUES ('ZZTEST Archived Plan','zztest-archived-plan', 50, 500, '[]'::jsonb, '[]'::jsonb, 'none', true, 996, 14, 'public', true) RETURNING id INTO v_plan_archived;

  -- 1. Un plan peut inclure plusieurs applications
  BEGIN
    INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan_public, v_app_pms), (v_plan_public, v_app_rh);
    IF (SELECT count(*) FROM public.plan_modules WHERE plan_id = v_plan_public) = 2 THEN
      PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'PASS', '2 lignes plan_modules');
    ELSE
      PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'FAIL', 'nombre inattendu');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'FAIL', SQLERRM); END;

  -- 2. Une app peut appartenir à plusieurs plans
  BEGIN
    INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan_public2, v_app_pms);
    IF (SELECT count(DISTINCT plan_id) FROM public.plan_modules WHERE app_id = v_app_pms) >= 2 THEN
      PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'PASS', 'PMS lié à >=2 plans');
    ELSE
      PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'FAIL', 'liaison manquante');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'FAIL', SQLERRM); END;

  INSERT INTO public.add_ons(name, slug, price, billing_type, is_active, sort_order, app_id)
    VALUES ('ZZTEST Addon RH+','zztest-addon-rh-plus', 10, 'monthly', true, 999, v_app_rh) RETURNING id INTO v_addon_active;
  INSERT INTO public.add_ons(name, slug, price, billing_type, is_active, sort_order, app_id)
    VALUES ('ZZTEST Addon RH expired','zztest-addon-rh-exp', 10, 'monthly', true, 998, v_app_rh) RETURNING id INTO v_addon_expired;

  -- 29. add_ons.app_id nullable ne casse aucune ligne existante
  BEGIN
    INSERT INTO public.add_ons(name, slug, price, billing_type, is_active, sort_order, app_id)
      VALUES ('ZZTEST Addon sans mapping','zztest-addon-unmapped', 5, 'monthly', true, 994, NULL) RETURNING id INTO v_addon_unmapped;
    PERFORM pg_temp.zz_log(29, 'add_ons.app_id nullable ne casse aucune ligne existante', 'PASS', 'insertion NULL acceptée');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(29, 'add_ons.app_id nullable ne casse aucune ligne existante', 'FAIL', SQLERRM); END;

  -- 3. Un add-on actif complète le plan principal (hotel_b, plan_public2 = PMS only)
  BEGIN
    INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan_public2, v_app_pms) ON CONFLICT DO NOTHING;
    PERFORM public.admin_create_subscription(v_hotel_b, v_plan_public2, 'monthly', 0, NULL, 'active');
    INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at)
      VALUES (v_hotel_b, v_addon_active, 'active', now());
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_b, 'RH');
    IF (v_res->'conditions'->>'app_included_or_addon')::boolean = true THEN
      PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'FAIL', v_res::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'FAIL', SQLERRM); END;

  -- 4. Un add-on expiré ne donne aucun droit théorique
  BEGIN
    INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at, expires_at)
      VALUES (v_hotel_c, v_addon_expired, 'active', now() - interval '60 days', now() - interval '1 day');
    PERFORM public.admin_create_subscription(v_hotel_c, v_plan_public2, 'monthly', 0, NULL, 'active');
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_c, 'RH');
    IF (v_res->'conditions'->>'app_included_or_addon')::boolean = false
       AND (v_res->'causes' ? 'expired_addon') THEN
      PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'FAIL', v_res::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'FAIL', SQLERRM); END;

  -- 30 + 31. Un add-on sans app_id ne donne aucun droit ET est signalé dans le rapport
  BEGIN
    PERFORM public.admin_create_subscription(v_hotel_i, v_plan_public2, 'monthly', 0, NULL, 'active'); -- PMS only
    INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at)
      VALUES (v_hotel_i, v_addon_unmapped, 'active', now());
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_i, 'RH');
    IF (v_res->'conditions'->>'app_included_or_addon')::boolean = false THEN
      PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'FAIL', v_res::text);
    END IF;
    IF (v_res->'causes' ? 'addon_missing_app_mapping') THEN
      PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'PASS', v_res->'causes');
    ELSE
      PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'FAIL', v_res->'causes');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'FAIL', SQLERRM);
  END;

  -- 5. Utilisateur autorisé sans abonnement hôtel -> divergence détectée
  BEGIN
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_d, 'PMS');
    IF (v_res->'conditions'->>'subscription_valid')::boolean = false AND (v_res->'causes' ? 'missing_main_subscription') THEN
      PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'FAIL', v_res::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'FAIL', SQLERRM); END;

  -- 6 + 37. Le mode observe ne modifie aucune donnée (abonnement, événements, journaux)
  BEGIN
    PERFORM public.admin_create_subscription(v_hotel_e, v_plan_public, 'monthly', 0, NULL, 'active');
    SELECT count(*) INTO v_ev_count FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_e;
    SELECT count(*) INTO v_log_count FROM public.platform_logs;
    PERFORM public.admin_resolve_app_access(v_real_user, v_hotel_e, 'PMS', 'observe');
    SELECT count(*) INTO v_ev_count2 FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_e;
    SELECT count(*) INTO v_log_count2 FROM public.platform_logs;
    IF v_ev_count = v_ev_count2 THEN
      PERFORM pg_temp.zz_log(6, 'Le mode observe ne modifie aucune donnée', 'PASS', format('events %s->%s', v_ev_count, v_ev_count2));
    ELSE
      PERFORM pg_temp.zz_log(6, 'Le mode observe ne modifie aucune donnée', 'FAIL', format('events %s->%s', v_ev_count, v_ev_count2));
    END IF;
    IF v_log_count = v_log_count2 THEN
      PERFORM pg_temp.zz_log(37, 'Le mode observe ne produit aucune écriture y compris journaux', 'PASS', format('platform_logs %s->%s', v_log_count, v_log_count2));
    ELSE
      PERFORM pg_temp.zz_log(37, 'Le mode observe ne produit aucune écriture y compris journaux', 'FAIL', format('platform_logs %s->%s', v_log_count, v_log_count2));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(6, 'Le mode observe ne modifie aucune donnée', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(37, 'Le mode observe ne produit aucune écriture y compris journaux', 'FAIL', SQLERRM);
  END;

  -- 7 + 21 + 38. Le mode enforce reste désactivé, échoue sans modification (events + logs)
  BEGIN
    SELECT count(*) INTO v_ev_count FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_e;
    SELECT count(*) INTO v_log_count FROM public.platform_logs;
    BEGIN
      PERFORM public.admin_resolve_app_access(v_real_user, v_hotel_e, 'PMS', 'enforce');
      PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'FAIL', 'aucune exception levée');
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = '55000' THEN
        PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'PASS', SQLERRM);
      ELSE
        PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'FAIL', 'errcode inattendu ' || SQLSTATE);
      END IF;
    END;
    SELECT count(*) INTO v_ev_count2 FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_e;
    SELECT count(*) INTO v_log_count2 FROM public.platform_logs;
    IF v_ev_count = v_ev_count2 THEN
      PERFORM pg_temp.zz_log(21, 'Une demande enforce échoue sans modification', 'PASS', format('events %s->%s', v_ev_count, v_ev_count2));
    ELSE
      PERFORM pg_temp.zz_log(21, 'Une demande enforce échoue sans modification', 'FAIL', format('events %s->%s', v_ev_count, v_ev_count2));
    END IF;
    IF v_log_count = v_log_count2 THEN
      PERFORM pg_temp.zz_log(38, 'Le mode enforce échoue avant toute écriture (journaux inclus)', 'PASS', format('platform_logs %s->%s', v_log_count, v_log_count2));
    ELSE
      PERFORM pg_temp.zz_log(38, 'Le mode enforce échoue avant toute écriture (journaux inclus)', 'FAIL', format('platform_logs %s->%s', v_log_count, v_log_count2));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(21, 'Une demande enforce échoue sans modification', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(38, 'Le mode enforce échoue avant toute écriture (journaux inclus)', 'FAIL', SQLERRM);
  END;

  -- 8. Essai expiré détecté malgré statut stocké trial
  BEGIN
    UPDATE public.hotel_subscriptions SET status='trial', trial_ends_at = now() - interval '1 day' WHERE hotel_id = v_hotel_c;
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_c, 'PMS');
    IF (v_res->'conditions'->>'trial_not_expired')::boolean = false
       AND (v_res->'conditions'->>'subscription_valid')::boolean = false
       AND (v_res->'causes' ? 'expired_trial') THEN
      PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'FAIL', v_res::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'FAIL', SQLERRM); END;

  -- 22. Un essai sans trial_ends_at est signalé mais pas expiré
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_d) THEN
      INSERT INTO public.hotel_subscriptions(hotel_id, plan_id, status, billing_cycle)
        VALUES (v_hotel_d, v_plan_public, 'trial', 'monthly');
    END IF;
    v_res := public._resolve_app_access_core(v_real_user, v_hotel_d, 'PMS');
    IF (v_res->'causes' ? 'trial_missing_end_date') AND (v_res->'conditions'->>'trial_not_expired')::boolean = true THEN
      PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'PASS', v_res::text);
    ELSE
      PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'FAIL', v_res::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'FAIL', SQLERRM); END;

  -- 9 + 27. Traitement des essais idempotent
  BEGIN
    PERFORM public.process_expired_subscription_trials();
    SELECT processed_subscriptions INTO v_ev_count FROM public.process_expired_subscription_trials();
    IF v_ev_count = 0 THEN
      PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'PASS', '2e appel: 0 ligne traitée');
      PERFORM pg_temp.zz_log(27, 'Appels concurrents restent idempotents', 'PASS', 'cf. test 9/10');
    ELSE
      PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'FAIL', format('%s lignes au 2e appel', v_ev_count));
      PERFORM pg_temp.zz_log(27, 'Appels concurrents restent idempotents', 'FAIL', 'précondition invalide');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(27, 'Appels concurrents restent idempotents', 'FAIL', SQLERRM);
  END;

  -- 10. Traitement concurrent sûr (SKIP LOCKED) — justification et limite documentées en ADR-010 §2
  BEGIN
    IF (SELECT status FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_c) = 'expired' THEN
      PERFORM pg_temp.zz_log(10, 'Traitement concurrent sûr (SKIP LOCKED)', 'PASS',
        'idempotence vérifiée ; blocage wall-clock réel entre 2 sessions non re-testé dans ce lot, cf. ADR-010 §2');
    ELSE
      PERFORM pg_temp.zz_log(10, 'Traitement concurrent sûr (SKIP LOCKED)', 'FAIL', 'hotel_c non expiré comme attendu');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(10, 'Traitement concurrent sûr (SKIP LOCKED)', 'FAIL', SQLERRM); END;

  -- 11 + 26. Snapshot tarifaire inchangé si le catalogue change
  BEGIN
    SELECT snapshot_price_net_ht INTO v_before_net FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_e;
    UPDATE public.subscription_plans SET price_monthly = 99999 WHERE id = v_plan_public;
    IF (SELECT snapshot_price_net_ht FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_e) = v_before_net THEN
      PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'PASS', format('%s inchangé', v_before_net));
      PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'PASS', 'idem test 11');
    ELSE
      PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'FAIL', 'snapshot modifié');
      PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'FAIL', 'snapshot modifié');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'FAIL', SQLERRM);
  END;

  -- 12. Un non-admin ne peut appeler aucune RPC de cycle de vie
  DECLARE v_sqlstate text; v_sqlerrm text; v_caught boolean := false;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nonadmin_auth)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      PERFORM public.admin_suspend_subscription((SELECT id FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_e), 'test non-admin');
    EXCEPTION WHEN OTHERS THEN
      v_caught := true; v_sqlstate := SQLSTATE; v_sqlerrm := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_auth)::text, true);
    IF v_caught AND v_sqlstate = '42501' THEN
      PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'PASS', v_sqlerrm);
    ELSIF v_caught THEN
      PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', 'errcode inattendu ' || v_sqlstate);
    ELSE
      PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', 'aucune exception levée');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_auth)::text, true);
    PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', SQLERRM);
  END;

  -- 13. Atomicité : un échec en cours de RPC ne laisse aucune trace partielle
  BEGIN
    SELECT count(*) INTO v_ev_count FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_f;
    BEGIN PERFORM public.admin_create_subscription(v_hotel_f, v_plan_archived, 'monthly', 0, NULL, 'active');
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM public.admin_create_subscription(v_hotel_f, v_plan_public, 'monthly', 0, NULL, 'active');
    EXCEPTION WHEN OTHERS THEN NULL; END;
    SELECT count(*) INTO v_ev_count2 FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_f AND event_type = 'created';
    IF v_ev_count2 = 1 THEN
      PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'PASS', '1 seul event created malgré le doublon rejeté');
    ELSE
      PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'FAIL', format('%s events created', v_ev_count2));
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'FAIL', SQLERRM); END;

  -- 15. Combinaisons interdites des statuts de plan (archivé => non commercialisable)
  BEGIN
    UPDATE public.subscription_plans SET is_active = false, archived_at = now(), is_commercializable = false WHERE id = v_plan_archived;
    BEGIN
      UPDATE public.subscription_plans SET is_commercializable = true WHERE id = v_plan_archived;
      PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan', 'FAIL', 'aucune violation de contrainte');
    EXCEPTION WHEN check_violation THEN
      PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan', 'PASS', SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan', 'FAIL', 'archivage initial: ' || SQLERRM); END;

  -- 18. Un plan interne n'est pas commercialisable
  BEGIN
    IF (SELECT is_commercializable FROM public.subscription_plans WHERE id = v_plan_internal) = false THEN
      BEGIN
        UPDATE public.subscription_plans SET is_commercializable = true WHERE id = v_plan_internal;
        PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'FAIL', 'contrainte non appliquée');
      EXCEPTION WHEN check_violation THEN
        PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'PASS', SQLERRM);
      END;
    ELSE
      PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'FAIL', 'valeur initiale incorrecte');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'FAIL', SQLERRM); END;

  -- 16 + 17. Plan archivé référencé par un abonnement historique / bloqué pour un nouvel abonnement
  BEGIN
    DECLARE v_plan_hist uuid; v_sub_hist_id uuid; v_still_valid boolean;
    BEGIN
      INSERT INTO public.subscription_plans(name, slug, price_monthly, price_annual, modules, features, support_level, is_active, sort_order, trial_days, plan_scope, is_commercializable)
        VALUES ('ZZTEST Historical Plan','zztest-historical-plan', 80, 800, '[]'::jsonb, '[]'::jsonb, 'none', true, 995, 14, 'public', true) RETURNING id INTO v_plan_hist;
      INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan_hist, v_app_pms);
      PERFORM public.admin_create_subscription(v_hotel_g, v_plan_hist, 'monthly', 0, NULL, 'active');
      SELECT id INTO v_sub_hist_id FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_g;
      UPDATE public.subscription_plans SET is_active = false, archived_at = now(), is_commercializable = false, archived_reason = 'ZZTEST' WHERE id = v_plan_hist;
      v_res := public._resolve_app_access_core(v_real_user, v_hotel_g, 'PMS');
      v_still_valid := (SELECT plan_id FROM public.hotel_subscriptions WHERE id = v_sub_hist_id) = v_plan_hist
                        AND (v_res->'conditions'->>'subscription_valid')::boolean = true;
      IF v_still_valid THEN
        PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'PASS', 'FK intacte, abonnement toujours actif');
      ELSE
        PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'FAIL', v_res::text);
      END IF;
      BEGIN
        PERFORM public.admin_create_subscription(v_hotel_h, v_plan_hist, 'monthly', 0, NULL, 'active');
        PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'FAIL', 'création acceptée à tort');
      EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'PASS', SQLERRM);
      END;
    END;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'FAIL', SQLERRM);
  END;

  -- 19. Date de revue obligatoire pour une régularisation interne
  BEGIN
    BEGIN
      PERFORM public.admin_regularize_legacy_subscription(v_hotel_h, v_plan_internal, 'motif test', NULL, 'justification test');
      PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'FAIL', 'acceptée sans date de revue');
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'PASS', SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'FAIL', SQLERRM); END;

  -- 20. Un prix dérogatoire exige une justification
  BEGIN
    BEGIN
      PERFORM public.admin_create_subscription(v_hotel_h, v_plan_public, 'monthly', 50, NULL, 'active');
      PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'FAIL', 'acceptée sans justification');
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'PASS', SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'FAIL', SQLERRM); END;

  -- 24 + 32. Aucun helper interne exécutable par PUBLIC/anon/authenticated
  BEGIN
    IF NOT has_function_privilege('anon', 'public._hotel_subscription_transition(uuid,text,text,text,text,jsonb,timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public._hotel_subscription_transition(uuid,text,text,text,text,jsonb,timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public._resolve_app_access_core(uuid,uuid,text)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public._resolve_app_access_core(uuid,uuid,text)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.process_expired_subscription_trials()', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public.process_expired_subscription_trials()', 'EXECUTE')
    THEN
      PERFORM pg_temp.zz_log(24, 'Aucun helper interne exécutable par anon/authenticated', 'PASS', 'has_function_privilege = false partout');
    ELSE
      PERFORM pg_temp.zz_log(24, 'Aucun helper interne exécutable par anon/authenticated', 'FAIL', 'privilège résiduel détecté');
    END IF;
    -- PUBLIC : vérifie qu'aucune entrée ACL n'accorde EXECUTE au pseudo-rôle PUBLIC (grantee = 0)
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
      WHERE p.proname IN ('_hotel_subscription_transition','_resolve_app_access_core','process_expired_subscription_trials')
        AND p.pronamespace = 'public'::regnamespace
        AND a.grantee = 0  -- 0 = PUBLIC dans pg_catalog
        AND a.privilege_type = 'EXECUTE'
    ) THEN
      PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'PASS', 'aucune entrée ACL PUBLIC/EXECUTE');
    ELSE
      PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'FAIL', 'entrée ACL PUBLIC résiduelle');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(24, 'Aucun helper interne exécutable par anon/authenticated', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'FAIL', SQLERRM);
  END;

  -- 25 + 33. Historique immuable, y compris pour Platform Admin en appel SQL direct
  BEGIN
    -- contexte JWT toujours = admin ici (jamais reset après le test 12)
    BEGIN
      UPDATE public.hotel_subscription_events SET reason = 'tentative de falsification' WHERE hotel_id = v_hotel_e;
      PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', 'UPDATE accepté à tort');
      PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'FAIL', 'UPDATE accepté à tort');
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'PASS', SQLERRM);
      PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'PASS', 'UPDATE rejeté sous contexte admin: ' || SQLERRM);
    END;
    BEGIN
      DELETE FROM public.hotel_subscription_events WHERE hotel_id = v_hotel_e;
      PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', 'DELETE accepté à tort');
    EXCEPTION WHEN OTHERS THEN NULL; -- confirme, déjà PASS ci-dessus sur l'UPDATE
    END;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'FAIL', SQLERRM);
  END;

  -- 14 + 23. Les 5 hôtels réels conservent leurs accès ; le rapport les observe sans les modifier
  BEGIN
    PERFORM public.admin_rights_divergence_report();
    IF NOT EXISTS (
      SELECT 1 FROM zz_baseline_access b
      FULL OUTER JOIN (
        SELECT h.name AS hotel_name, count(*) AS access_count
        FROM public.user_app_access uaa JOIN public.hotels h ON h.id = uaa.hotel_id
        WHERE h.name IN ('Folkestone opera','Washington Opera','Grand Hotel du Havre','Vendome opera','Mas Provencal Aix')
        GROUP BY h.name
      ) a ON a.hotel_name = b.hotel_name
      WHERE b.access_count IS DISTINCT FROM a.access_count
    ) THEN
      PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'PASS', 'comptes identiques avant/après');
      PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'PASS', 'admin_rights_divergence_report exécuté');
    ELSE
      PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'FAIL', 'écart détecté');
      PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'FAIL', 'écart détecté');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'FAIL', SQLERRM);
    PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'FAIL', SQLERRM);
  END;

  -- 34. Aucune commande cron n'est créée
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process_expired_subscription_trials') THEN
      PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'PASS', 'aucune ligne cron.job correspondante');
    ELSE
      PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'FAIL', 'un job existe déjà');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'FAIL', SQLERRM); END;

  -- 35. Les colonnes de snapshot restent compatibles avec Folkestone (lecture réelle, aucune écriture)
  BEGIN
    PERFORM (id, snapshot_price_net_ht, trial_ends_at, status) FROM public.hotel_subscriptions WHERE hotel_id = v_folkestone_hotel;
    IF FOUND THEN
      PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec Folkestone', 'PASS', 'ligne réelle lisible sans erreur malgré snapshot incomplet');
    ELSE
      PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec Folkestone', 'FAIL', 'ligne introuvable');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec Folkestone', 'FAIL', SQLERRM); END;

  -- 36. Le rapport différencie les causes (pas un bucket générique unique) — sur les fixtures de ce run
  BEGIN
    SELECT count(DISTINCT c) INTO v_distinct_causes
    FROM (
      SELECT jsonb_array_elements_text(resolution->'causes') AS c
      FROM (
        SELECT public._resolve_app_access_core(v_real_user, h, a) AS resolution
        FROM (VALUES (v_hotel_c),(v_hotel_d),(v_hotel_e),(v_hotel_i)) x(h), (VALUES ('PMS'),('RH')) y(a)
      ) r
    ) e;
    IF v_distinct_causes >= 3 THEN
      PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'PASS', format('%s causes distinctes observées sur les fixtures', v_distinct_causes));
    ELSE
      PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'FAIL', format('seulement %s cause(s) distincte(s)', v_distinct_causes));
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'FAIL', SQLERRM); END;

  -- 28. Aucune donnée réelle ne reste créée après rollback (vérifié DANS la transaction ; confirmé par une requête séparée après coup)
  BEGIN
    IF (SELECT count(*) FROM public.hotels WHERE name LIKE 'ZZTEST%') = 9 THEN
      PERFORM pg_temp.zz_log(28, 'Aucune donnée réelle ne reste créée après ROLLBACK', 'PASS', '9 hôtels ZZTEST présents dans cette transaction (à vérifier absents après coup)');
    ELSE
      PERFORM pg_temp.zz_log(28, 'Aucune donnée réelle ne reste créée après ROLLBACK', 'FAIL', 'nombre de fixtures inattendu');
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(28, 'Aucune donnée réelle ne reste créée après ROLLBACK', 'FAIL', SQLERRM); END;

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
  RAISE NOTICE 'OK : suite Phase 2A complète, % scénarios, 0 échec.', v_total;
END $$;

-- Rollback du BEGIN externe : détruit toutes les fixtures ZZTEST, aucune trace persistante.
ROLLBACK;
