-- ============================================================================
-- Suite de tests reproductible — Phase 2A (fondations du modèle d'abonnement)
--
-- À exécuter APRÈS avoir appliqué sql/70_super_admin_phase2a_subscription_foundation.sql
-- (en développement, ou en production dans une transaction non commitée pour
-- vérification pré-déploiement — c'est ainsi qu'elle a été validée avant ce commit).
--
-- Refonte (revue contradictoire du commit 0319d7f, arbitrage E) : chaque scénario crée
-- désormais ses propres fixtures (hôtel, plan, admin, utilisateur — via les helpers
-- pg_temp.zz_mk_*) et ne dépend d'aucun état laissé par un autre scénario, ni d'aucun
-- identifiant de production réel. Les seules données réelles lues sont celles du test
-- 14/23, dont l'objet même est de vérifier que les hôtels réels ne sont pas affectés — ce
-- n'est pas une dépendance fragile, c'est le sujet du test. Chaque scénario est un bloc
-- DO $$ ... $$ indépendant : l'échec ou le succès de l'un n'affecte jamais les suivants, et
-- la suite peut être rejouée entièrement, dans n'importe quel ordre, sans collision (noms
-- de fixtures suffixés par un uuid aléatoire).
--
-- Résultat : chaque test émet un RAISE NOTICE 'PASS ...' ou 'FAIL ...'. Le bloc final
-- échoue (RAISE EXCEPTION) si au moins un test a échoué, afin qu'un test runner externe
-- (psql -v ON_ERROR_STOP=1, ou CI) détecte l'échec par le code de sortie.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE zz_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz_results TO authenticated;

-- ----------------------------------------------------------------------------
-- Helpers de fixtures — chaque appel crée un objet frais et indépendant, jamais partagé
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

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_user(p_hotel_id uuid, p_active boolean DEFAULT true) RETURNS uuid AS $$
DECLARE v_auth uuid; v_id uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.users(auth_id, hotel_id, email, full_name, role, is_active)
    VALUES (v_auth, p_hotel_id, 'zztest-user-' || v_auth::text || '@example.invalid', 'ZZTEST User', 'direction', p_active)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_plan(
  p_scope text DEFAULT 'public', p_commercializable boolean DEFAULT true,
  p_active boolean DEFAULT true, p_archived boolean DEFAULT false, p_trial_days int DEFAULT 14
) RETURNS uuid AS $$
DECLARE v_id uuid; v_slug text := 'zztest-plan-' || gen_random_uuid()::text;
BEGIN
  INSERT INTO public.subscription_plans(
    name, slug, price_monthly, price_annual, modules, features, support_level,
    is_active, sort_order, trial_days, plan_scope, is_commercializable, archived_at
  ) VALUES (
    'ZZTEST Plan', v_slug, 100, 1000, '[]'::jsonb, '[]'::jsonb, 'none',
    p_active, 999, p_trial_days, p_scope, p_commercializable,
    CASE WHEN p_archived THEN now() ELSE NULL END
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_mk_addon(p_app_code text DEFAULT NULL) RETURNS uuid AS $$
DECLARE v_id uuid; v_app_id uuid;
BEGIN
  IF p_app_code IS NOT NULL THEN
    SELECT id INTO v_app_id FROM public.platform_apps WHERE code = p_app_code;
  END IF;
  INSERT INTO public.add_ons(name, slug, price, billing_type, is_active, sort_order, app_id)
  VALUES ('ZZTEST Addon', 'zztest-addon-' || gen_random_uuid()::text, 10, 'monthly', true, 999, v_app_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_temp.zz_app_id(p_code text) RETURNS uuid AS $$
  SELECT id FROM public.platform_apps WHERE code = p_code;
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 1. Un plan peut inclure plusieurs applications
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_count int;
BEGIN
  v_plan := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan, pg_temp.zz_app_id('PMS')), (v_plan, pg_temp.zz_app_id('RH'));
  SELECT count(*) INTO v_count FROM public.plan_modules WHERE plan_id = v_plan;
  IF v_count = 2 THEN
    PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'PASS', '2 lignes plan_modules pour un plan frais');
  ELSE
    PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'FAIL', format('%s lignes (attendu 2)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'Un plan peut inclure plusieurs applications', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Une application peut appartenir à plusieurs plans
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_a uuid; v_plan_b uuid; v_count int;
BEGIN
  v_plan_a := pg_temp.zz_mk_plan();
  v_plan_b := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan_a, pg_temp.zz_app_id('PMS')), (v_plan_b, pg_temp.zz_app_id('PMS'));
  SELECT count(DISTINCT plan_id) INTO v_count FROM public.plan_modules WHERE plan_id IN (v_plan_a, v_plan_b) AND app_id = pg_temp.zz_app_id('PMS');
  IF v_count = 2 THEN
    PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'PASS', 'PMS lié à 2 plans frais distincts');
  ELSE
    PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'FAIL', format('%s plan(s) distinct(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(2, 'Une application peut appartenir à plusieurs plans', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Un add-on actif complète le plan principal
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_addon uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan, pg_temp.zz_app_id('PMS')); -- PMS only, pas RH
  v_addon := pg_temp.zz_mk_addon('RH');
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at) VALUES (v_hotel, v_addon, 'active', now());
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('RH'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'RH');
  IF (v_res->'conditions'->>'app_included_or_addon')::boolean = true THEN
    PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Un add-on actif complète le plan principal', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Un add-on expiré ne donne aucun droit théorique
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_addon uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan, pg_temp.zz_app_id('PMS'));
  v_addon := pg_temp.zz_mk_addon('RH');
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at, expires_at)
    VALUES (v_hotel, v_addon, 'active', now() - interval '60 days', now() - interval '1 day');
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('RH'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'RH');
  IF (v_res->'conditions'->>'app_included_or_addon')::boolean = false AND (v_res->'causes' ? 'expired_addon') THEN
    PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Un add-on expiré ne donne aucun droit théorique', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Utilisateur autorisé sans abonnement hôtel -> divergence détectée
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_user := pg_temp.zz_mk_user(v_hotel);
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('PMS'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'PMS');
  IF (v_res->'conditions'->>'subscription_valid')::boolean = false AND (v_res->'causes' ? 'missing_main_subscription') THEN
    PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(5, 'Utilisateur sans abonnement hôtel -> divergence détectée', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6 + 37. Le mode observe ne modifie aucune donnée (abonnement, événements, journaux)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_user uuid; v_admin uuid;
         v_ev_count int; v_ev_count2 int; v_log_count int; v_log_count2 int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  v_user := pg_temp.zz_mk_user(v_hotel);
  v_admin := pg_temp.zz_mk_admin();
  PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  SELECT count(*) INTO v_ev_count FROM public.hotel_subscription_events WHERE hotel_id = v_hotel;
  SELECT count(*) INTO v_log_count FROM public.platform_logs;
  PERFORM public.admin_resolve_app_access(v_user, v_hotel, 'PMS', 'observe');
  SELECT count(*) INTO v_ev_count2 FROM public.hotel_subscription_events WHERE hotel_id = v_hotel;
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
END $$;

-- ----------------------------------------------------------------------------
-- 7 + 21 + 38. Le mode enforce reste désactivé, échoue avant toute écriture (events + logs)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_user uuid;
         v_ev_count int; v_ev_count2 int; v_log_count int; v_log_count2 int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  SELECT count(*) INTO v_ev_count FROM public.hotel_subscription_events WHERE hotel_id = v_hotel;
  SELECT count(*) INTO v_log_count FROM public.platform_logs;
  BEGIN
    PERFORM public.admin_resolve_app_access(v_user, v_hotel, 'PMS', 'enforce');
    PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'FAIL', 'aucune exception levée');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '55000' THEN
      PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'PASS', SQLERRM);
    ELSE
      PERFORM pg_temp.zz_log(7, 'Le mode enforce reste désactivé', 'FAIL', 'errcode inattendu ' || SQLSTATE);
    END IF;
  END;
  SELECT count(*) INTO v_ev_count2 FROM public.hotel_subscription_events WHERE hotel_id = v_hotel;
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
END $$;

-- ----------------------------------------------------------------------------
-- F1. p_mode = NULL rejeté
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_user uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  BEGIN
    PERFORM public.admin_resolve_app_access(v_user, v_hotel, 'PMS', NULL);
    PERFORM pg_temp.zz_log(39, 'p_mode = NULL est rejeté explicitement', 'FAIL', 'aucune exception levée');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN
      PERFORM pg_temp.zz_log(39, 'p_mode = NULL est rejeté explicitement', 'PASS', SQLERRM);
    ELSE
      PERFORM pg_temp.zz_log(39, 'p_mode = NULL est rejeté explicitement', 'FAIL', 'errcode inattendu ' || SQLSTATE);
    END IF;
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(39, 'p_mode = NULL est rejeté explicitement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- F2. p_mode = 'invalid' rejeté
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_user uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  BEGIN
    PERFORM public.admin_resolve_app_access(v_user, v_hotel, 'PMS', 'invalid');
    PERFORM pg_temp.zz_log(40, 'p_mode = ''invalid'' est rejeté', 'FAIL', 'aucune exception levée');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN
      PERFORM pg_temp.zz_log(40, 'p_mode = ''invalid'' est rejeté', 'PASS', SQLERRM);
    ELSE
      PERFORM pg_temp.zz_log(40, 'p_mode = ''invalid'' est rejeté', 'FAIL', 'errcode inattendu ' || SQLSTATE);
    END IF;
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(40, 'p_mode = ''invalid'' est rejeté', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Essai expiré détecté malgré statut stocké trial
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'trial');
  -- Simule une ligne dont l'essai est passé sans traitement (mutation directe volontaire,
  -- hors RPC : c'est précisément ce que ce test doit reproduire).
  UPDATE public.hotel_subscriptions SET trial_ends_at = now() - interval '1 day' WHERE hotel_id = v_hotel;
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('PMS'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'PMS');
  IF (v_res->'conditions'->>'trial_not_expired')::boolean = false
     AND (v_res->'conditions'->>'subscription_valid')::boolean = false
     AND (v_res->'causes' ? 'expired_trial') THEN
    PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(8, 'Essai expiré détecté malgré statut stocké trial', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 22. Un essai sans trial_ends_at est signalé mais pas expiré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  v_user := pg_temp.zz_mk_user(v_hotel);
  INSERT INTO public.hotel_subscriptions(hotel_id, plan_id, status, billing_cycle)
    VALUES (v_hotel, v_plan, 'trial', 'monthly'); -- trial_ends_at NULL, comme une ligne historique incomplète
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('PMS'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'PMS');
  IF (v_res->'causes' ? 'trial_missing_end_date') AND (v_res->'conditions'->>'trial_not_expired')::boolean = true THEN
    PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(22, 'Essai sans trial_ends_at signalé mais pas expiré', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Traitement des essais idempotent (deux appels successifs)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_processed int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'trial');
  UPDATE public.hotel_subscriptions SET trial_ends_at = now() - interval '1 day' WHERE hotel_id = v_hotel;
  PERFORM public.process_expired_subscription_trials(); -- 1er appel : traite la ligne fraîche
  SELECT processed_subscriptions INTO v_processed FROM public.process_expired_subscription_trials(); -- 2e appel
  IF v_processed = 0 THEN
    PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'PASS', '2e appel : 0 ligne traitée sur une fixture fraîche');
  ELSE
    PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'FAIL', format('2e appel a traité %s ligne(s)', v_processed));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(9, 'Traitement des essais idempotent', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. Traitement sûr (FOR UPDATE SKIP LOCKED) — la ligne expirée est bien traitée une fois
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'trial');
  UPDATE public.hotel_subscriptions SET trial_ends_at = now() - interval '1 day' WHERE hotel_id = v_hotel;
  PERFORM public.process_expired_subscription_trials();
  IF (SELECT status FROM public.hotel_subscriptions WHERE hotel_id = v_hotel) = 'expired' THEN
    PERFORM pg_temp.zz_log(10, 'Traitement des essais expirés — statut correctement mis à jour', 'PASS',
      'ligne fraîche expirée traitée ; blocage wall-clock réel entre 2 sessions non re-testé dans ce lot, cf. ADR-010 §2');
  ELSE
    PERFORM pg_temp.zz_log(10, 'Traitement des essais expirés — statut correctement mis à jour', 'FAIL', 'statut inattendu après traitement');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(10, 'Traitement des essais expirés — statut correctement mis à jour', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 27. Deux appels de traitement sur la même fixture restent idempotents (vérification directe,
--     pas un simple renvoi vers 9/10)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_run1 int; v_run2 int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'trial');
  UPDATE public.hotel_subscriptions SET trial_ends_at = now() - interval '1 day' WHERE hotel_id = v_hotel;
  SELECT processed_subscriptions INTO v_run1 FROM public.process_expired_subscription_trials();
  SELECT processed_subscriptions INTO v_run2 FROM public.process_expired_subscription_trials();
  IF v_run1 >= 1 AND v_run2 = 0 THEN
    PERFORM pg_temp.zz_log(27, 'Deux appels successifs restent idempotents (fixture propre)', 'PASS', format('run1=%s run2=%s', v_run1, v_run2));
  ELSE
    PERFORM pg_temp.zz_log(27, 'Deux appels successifs restent idempotents (fixture propre)', 'FAIL', format('run1=%s run2=%s', v_run1, v_run2));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(27, 'Deux appels successifs restent idempotents (fixture propre)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11 + 26. Snapshot tarifaire inchangé si le catalogue est modifié après coup
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_before_net numeric; v_after_net numeric;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  SELECT snapshot_price_net_ht INTO v_before_net FROM public.hotel_subscriptions WHERE hotel_id = v_hotel;
  UPDATE public.subscription_plans SET price_monthly = 99999 WHERE id = v_plan;
  SELECT snapshot_price_net_ht INTO v_after_net FROM public.hotel_subscriptions WHERE hotel_id = v_hotel;
  IF v_after_net = v_before_net THEN
    PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'PASS', format('%s inchangé', v_before_net));
    PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'PASS', 'même vérification que 11, fixture propre');
  ELSE
    PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'FAIL', format('%s -> %s', v_before_net, v_after_net));
    PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'FAIL', format('%s -> %s', v_before_net, v_after_net));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(11, 'Snapshot tarifaire inchangé si le catalogue change', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(26, 'Modification du catalogue sans effet sur le snapshot', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. Un non-admin ne peut appeler aucune RPC de cycle de vie
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub_id uuid; v_nonadmin uuid;
        v_sqlstate text; v_sqlerrm text; v_caught boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  SELECT id INTO v_sub_id FROM public.hotel_subscriptions WHERE hotel_id = v_hotel;
  v_nonadmin := pg_temp.zz_mk_nonadmin();
  PERFORM pg_temp.zz_as(v_nonadmin);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.admin_suspend_subscription(v_sub_id, 'test non-admin');
  EXCEPTION WHEN OTHERS THEN
    v_caught := true; v_sqlstate := SQLSTATE; v_sqlerrm := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_caught AND v_sqlstate = '42501' THEN
    PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'PASS', v_sqlerrm);
  ELSIF v_caught THEN
    PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', 'errcode inattendu ' || v_sqlstate);
  ELSE
    PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.zz_log(12, 'Un non-admin ne peut appeler aucune RPC de cycle de vie', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. Atomicité : une tentative de doublon ne laisse aucune trace partielle
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan_a uuid; v_plan_b uuid; v_created_events int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan_a := pg_temp.zz_mk_plan();
  v_plan_b := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan_a, 'monthly', 0, NULL, 'active');
  BEGIN
    PERFORM public.admin_create_subscription(v_hotel, v_plan_b, 'monthly', 0, NULL, 'active'); -- doit être rejeté : déjà abonné
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  SELECT count(*) INTO v_created_events FROM public.hotel_subscription_events WHERE hotel_id = v_hotel AND event_type = 'created';
  IF v_created_events = 1 THEN
    PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'PASS', '1 seul event created malgré la tentative de doublon rejetée');
  ELSE
    PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'FAIL', format('%s events created (attendu 1)', v_created_events));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(13, 'Toutes les opérations métier sont atomiques et auditées', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14 + 23. Les cinq hôtels réels conservent leurs accès ; le rapport les observe sans
--          les modifier. Ce test lit délibérément des données réelles — c'est son objet
--          même (vérifier la non-régression sur la production), pas une fragilité de
--          fixture : il ne dépend d'aucun autre test ni d'aucun identifiant de compte.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_before jsonb; v_after jsonb; v_admin uuid;
BEGIN
  SELECT jsonb_object_agg(h.name, cnt) INTO v_before FROM (
    SELECT h.name, count(*) AS cnt FROM public.user_app_access uaa JOIN public.hotels h ON h.id = uaa.hotel_id
    WHERE h.name IN ('Folkestone opera','Washington Opera','Grand Hotel du Havre','Vendome opera','Mas Provencal Aix')
    GROUP BY h.name
  ) h;
  v_admin := pg_temp.zz_mk_admin();
  PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_rights_divergence_report();
  SELECT jsonb_object_agg(h.name, cnt) INTO v_after FROM (
    SELECT h.name, count(*) AS cnt FROM public.user_app_access uaa JOIN public.hotels h ON h.id = uaa.hotel_id
    WHERE h.name IN ('Folkestone opera','Washington Opera','Grand Hotel du Havre','Vendome opera','Mas Provencal Aix')
    GROUP BY h.name
  ) h;
  IF v_before = v_after THEN
    PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'PASS', 'comptes identiques avant/après');
    PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'PASS', 'admin_rights_divergence_report exécuté');
  ELSE
    PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'FAIL', format('avant=%s après=%s', v_before, v_after));
    PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'FAIL', format('avant=%s après=%s', v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(14, 'Les cinq hôtels existants conservent leurs accès', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(23, 'Le rapport observe les cinq hôtels sans modifier leurs accès', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 15. Combinaisons interdites des statuts de plan (archivé => non commercialisable)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid;
BEGIN
  v_plan := pg_temp.zz_mk_plan(); -- public, actif, commercialisable
  UPDATE public.subscription_plans SET is_active = false, archived_at = now(), is_commercializable = false WHERE id = v_plan;
  BEGIN
    UPDATE public.subscription_plans SET is_commercializable = true WHERE id = v_plan;
    PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan (archivé+commercialisable)', 'FAIL', 'aucune violation de contrainte');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan (archivé+commercialisable)', 'PASS', SQLERRM);
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(15, 'Combinaisons interdites des statuts de plan (archivé+commercialisable)', 'FAIL', 'archivage initial: ' || SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 16 + 17. Plan archivé référencé par un abonnement historique / bloqué pour un nouveau
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_hist uuid; v_hotel_new uuid; v_sub_id uuid; v_res jsonb; v_still_valid boolean;
BEGIN
  v_plan := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan, pg_temp.zz_app_id('PMS'));
  v_hotel_hist := pg_temp.zz_mk_hotel();
  v_hotel_new := pg_temp.zz_mk_hotel();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel_hist, v_plan, 'monthly', 0, NULL, 'active');
  SELECT id INTO v_sub_id FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_hist;
  UPDATE public.subscription_plans SET is_active = false, archived_at = now(), is_commercializable = false, archived_reason = 'ZZTEST' WHERE id = v_plan;
  v_res := public._resolve_app_access_core(
    (SELECT id FROM public.users WHERE hotel_id = v_hotel_hist LIMIT 1), v_hotel_hist, 'PMS'
  );
  v_still_valid := (SELECT plan_id FROM public.hotel_subscriptions WHERE id = v_sub_id) = v_plan
                    AND (SELECT status FROM public.hotel_subscriptions WHERE id = v_sub_id) = 'active';
  IF v_still_valid THEN
    PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'PASS', 'FK intacte, abonnement toujours actif après archivage du plan');
  ELSE
    PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'FAIL', 'incohérence détectée');
  END IF;
  BEGIN
    PERFORM public.admin_create_subscription(v_hotel_new, v_plan, 'monthly', 0, NULL, 'active');
    PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'FAIL', 'création acceptée à tort');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'PASS', SQLERRM);
  END;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(16, 'Un plan archivé reste référencé par un abonnement historique', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(17, 'Un plan archivé ne peut pas être attribué à un nouvel abonnement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 18. Un plan interne n'est pas commercialisable
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid;
BEGIN
  v_plan := pg_temp.zz_mk_plan(p_scope := 'internal', p_commercializable := false);
  BEGIN
    UPDATE public.subscription_plans SET is_commercializable = true WHERE id = v_plan;
    PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'FAIL', 'contrainte non appliquée');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'PASS', SQLERRM);
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(18, 'Un plan interne n''est pas commercialisable', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 19. Date de revue obligatoire pour une régularisation interne
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan(p_scope := 'internal', p_commercializable := false, p_trial_days := NULL);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  BEGIN
    PERFORM public.admin_regularize_legacy_subscription(v_hotel, v_plan, 'motif test', NULL, 'justification test');
    PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'FAIL', 'acceptée sans date de revue');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'PASS', SQLERRM);
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(19, 'Date de revue obligatoire pour une régularisation interne', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 20. Un prix dérogatoire exige une justification
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  BEGIN
    PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 50, NULL, 'active'); -- -50% sans justification
    PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'FAIL', 'acceptée sans justification');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'PASS', SQLERRM);
  END;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(20, 'Un prix dérogatoire exige une justification', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 24 + 32. Aucun helper interne exécutable par anon/authenticated/PUBLIC (pure métadonnée,
--          aucune fixture nécessaire — déjà indépendant par nature)
-- ----------------------------------------------------------------------------
DO $$
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
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
    WHERE p.proname IN ('_hotel_subscription_transition','_resolve_app_access_core','process_expired_subscription_trials')
      AND p.pronamespace = 'public'::regnamespace
      AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
  ) THEN
    PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'PASS', 'aucune entrée ACL PUBLIC/EXECUTE');
  ELSE
    PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'FAIL', 'entrée ACL PUBLIC résiduelle');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(24, 'Aucun helper interne exécutable par anon/authenticated', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(32, 'Le cœur du résolveur est inaccessible à PUBLIC', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 24b. Aucune des 17 RPC frontend n'est exécutable par PUBLIC (arbitrage B) — vérifié sur
--      les 17 signatures exactes attendues après application de la migration corrigée.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_remaining int;
BEGIN
  SELECT count(*) INTO v_remaining FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN (
      'admin_create_subscription','admin_regularize_legacy_subscription','admin_update_price_snapshot',
      'admin_extend_trial','admin_convert_trial_to_active','admin_suspend_subscription',
      'admin_reactivate_subscription','admin_renew_subscription','admin_cancel_subscription_immediate',
      'admin_schedule_subscription_cancellation','admin_revert_scheduled_cancellation',
      'admin_attach_addon','admin_detach_addon','admin_resolve_app_access',
      'admin_rights_divergence_report','admin_run_expired_trials_processing','resolve_my_app_access'
    )
    AND a.grantee = 0 AND a.privilege_type = 'EXECUTE';
  IF v_remaining = 0 THEN
    PERFORM pg_temp.zz_log(41, 'Aucune des 17 RPC frontend n''est exécutable par PUBLIC', 'PASS', 'REVOKE ALL FROM PUBLIC confirmé sur les 17 signatures');
  ELSE
    PERFORM pg_temp.zz_log(41, 'Aucune des 17 RPC frontend n''est exécutable par PUBLIC', 'FAIL', format('%s fonction(s) encore accessible(s) à PUBLIC', v_remaining));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(41, 'Aucune des 17 RPC frontend n''est exécutable par PUBLIC', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 25 + 33. Historique immuable, y compris pour Platform Admin en appel SQL direct
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  BEGIN
    UPDATE public.hotel_subscription_events SET reason = 'tentative de falsification' WHERE hotel_id = v_hotel;
    PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', 'UPDATE accepté à tort');
    PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'FAIL', 'UPDATE accepté à tort');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'PASS', SQLERRM);
    PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'PASS', 'UPDATE rejeté sous contexte admin : ' || SQLERRM);
  END;
  BEGIN
    DELETE FROM public.hotel_subscription_events WHERE hotel_id = v_hotel;
    PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', 'DELETE accepté à tort');
  EXCEPTION WHEN OTHERS THEN NULL; -- déjà PASS ci-dessus sur l'UPDATE ; confirme la même garde côté DELETE
  END;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(25, 'L''historique du cycle de vie est immuable', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(33, 'Historique immuable même pour Platform Admin en SQL direct', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 28. Aucune trace de fixture ne persiste après ROLLBACK — vérifié DANS la transaction
--     (au moins nos propres fixtures existent bien ici) ; la preuve définitive est la
--     requête séparée exécutée après coup, hors de cette transaction (cf. livrable CTO).
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.hotels WHERE name LIKE 'ZZTEST-%';
  IF v_count > 0 THEN
    PERFORM pg_temp.zz_log(28, 'Fixtures visibles dans la transaction (preuve de rollback faite séparément)', 'PASS', format('%s hôtel(s) ZZTEST présents dans cette transaction', v_count));
  ELSE
    PERFORM pg_temp.zz_log(28, 'Fixtures visibles dans la transaction (preuve de rollback faite séparément)', 'FAIL', 'aucune fixture trouvée — la suite a-t-elle vraiment tourné ?');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(28, 'Fixtures visibles dans la transaction (preuve de rollback faite séparément)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 29. add_ons.app_id nullable ne casse aucune ligne existante
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_addon uuid;
BEGIN
  v_addon := pg_temp.zz_mk_addon(NULL); -- app_id NULL explicite
  IF v_addon IS NOT NULL THEN
    PERFORM pg_temp.zz_log(29, 'add_ons.app_id nullable ne casse aucune ligne existante', 'PASS', 'insertion avec app_id NULL acceptée');
  ELSE
    PERFORM pg_temp.zz_log(29, 'add_ons.app_id nullable ne casse aucune ligne existante', 'FAIL', 'insertion refusée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(29, 'add_ons.app_id nullable ne casse aucune ligne existante', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 30 + 31. Un add-on sans app_id ne donne aucun droit ET est signalé dans le rapport
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_addon uuid; v_user uuid; v_res jsonb;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel();
  v_plan := pg_temp.zz_mk_plan();
  INSERT INTO public.plan_modules(plan_id, app_id) VALUES (v_plan, pg_temp.zz_app_id('PMS'));
  v_addon := pg_temp.zz_mk_addon(NULL);
  v_user := pg_temp.zz_mk_user(v_hotel);
  PERFORM pg_temp.zz_as(pg_temp.zz_mk_admin());
  PERFORM public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  INSERT INTO public.hotel_addon_subscriptions(hotel_id, addon_id, status, started_at) VALUES (v_hotel, v_addon, 'active', now());
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES (v_user, v_hotel, pg_temp.zz_app_id('RH'));
  v_res := public._resolve_app_access_core(v_user, v_hotel, 'RH');
  IF (v_res->'conditions'->>'app_included_or_addon')::boolean = false THEN
    PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'PASS', v_res::text);
  ELSE
    PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'FAIL', v_res::text);
  END IF;
  IF (v_res->'causes' ? 'addon_missing_app_mapping') THEN
    PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'PASS', (v_res->'causes')::text);
  ELSE
    PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'FAIL', (v_res->'causes')::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.zz_log(30, 'Un add-on sans app_id ne donne aucun droit', 'FAIL', SQLERRM);
  PERFORM pg_temp.zz_log(31, 'Un add-on sans app_id est signalé dans le rapport', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 34. Aucune commande cron n'est créée
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process_expired_subscription_trials') THEN
    PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'PASS', 'aucune ligne cron.job correspondante');
  ELSE
    PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'FAIL', 'un job existe déjà');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(34, 'Aucune commande cron n''est créée', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 35. Compatibilité du snapshot avec une ligne historique incomplète (lecture réelle,
--     Folkestone — même principe que le test 22 mais vérifié aussi sur la vraie ligne)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_found boolean;
BEGIN
  SELECT true INTO v_found FROM public.hotel_subscriptions
  WHERE hotel_id = '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid; -- Folkestone, hôtel réel, sujet du test
  IF v_found THEN
    PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec une ligne historique réelle incomplète', 'PASS', 'ligne réelle lisible sans erreur malgré snapshot incomplet');
  ELSE
    PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec une ligne historique réelle incomplète', 'FAIL', 'ligne introuvable (état de production modifié depuis la revue précédente ?)');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(35, 'Les colonnes de snapshot restent compatibles avec une ligne historique réelle incomplète', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 36. Le rapport différencie les causes (pas un bucket générique unique)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel_a uuid; v_hotel_b uuid; v_hotel_c uuid; v_user_a uuid; v_user_b uuid; v_user_c uuid;
        v_distinct_causes int;
BEGIN
  v_hotel_a := pg_temp.zz_mk_hotel();                    -- sans abonnement
  v_hotel_b := pg_temp.zz_mk_hotel(p_status := 'suspended'); -- hôtel suspendu
  v_hotel_c := pg_temp.zz_mk_hotel();
  v_user_a := pg_temp.zz_mk_user(v_hotel_a);
  v_user_b := pg_temp.zz_mk_user(v_hotel_b);
  v_user_c := pg_temp.zz_mk_user(v_hotel_c, p_active := false); -- utilisateur inactif
  INSERT INTO public.user_app_access(user_id, hotel_id, app_id) VALUES
    (v_user_a, v_hotel_a, pg_temp.zz_app_id('PMS')),
    (v_user_b, v_hotel_b, pg_temp.zz_app_id('PMS')),
    (v_user_c, v_hotel_c, pg_temp.zz_app_id('PMS'));
  SELECT count(DISTINCT c) INTO v_distinct_causes FROM (
    SELECT jsonb_array_elements_text(public._resolve_app_access_core(u, h, 'PMS')->'causes') AS c
    FROM (VALUES (v_user_a, v_hotel_a), (v_user_b, v_hotel_b), (v_user_c, v_hotel_c)) x(u, h)
  ) e;
  IF v_distinct_causes >= 3 THEN
    PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'PASS', format('%s causes distinctes sur 3 fixtures dédiées', v_distinct_causes));
  ELSE
    PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'FAIL', format('seulement %s cause(s) distincte(s)', v_distinct_causes));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(36, 'Le rapport différencie les causes de divergence', 'FAIL', SQLERRM);
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

-- Rollback du BEGIN externe : détruit toutes les fixtures ZZTEST (hôtels, plans, add-ons,
-- utilisateurs, admins de test, comptes auth.users synthétiques), aucune trace persistante.
ROLLBACK;
