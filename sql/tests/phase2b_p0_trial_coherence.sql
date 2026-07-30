-- ============================================================================
-- Suite de tests reproductible — P0 Cohérence essai principal / accès applicatifs
--
-- À exécuter APRÈS avoir appliqué sql/79_super_admin_p0_trial_app_access_coherence.sql
-- (en développement, ou en production dans une transaction non commitée pour vérification
-- pré-déploiement — combinée avec le contenu de la migration dans une même transaction
-- BEGIN...ROLLBACK, exactement comme pour les suites Phase 2A/2B précédentes).
--
-- Convention identique aux suites soeurs (phase2a_subscription_foundation.sql, arbitrage E) :
-- chaque scénario crée ses propres fixtures, suffixées par un uuid aléatoire, et ne dépend
-- d'aucun état laissé par un autre scénario — à l'exception explicite des scénarios 20-22 dont
-- le sujet même est la vraie ligne Folkestone en production (comme le test 35 de la suite
-- Phase 2A), et qui restent dans la transaction externe non commitée.
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
  p_hotel uuid, p_plan uuid, p_status text DEFAULT 'trial',
  p_trial_ends_at timestamptz DEFAULT NULL, p_trial_extensions int DEFAULT 0
) RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotel_subscriptions(hotel_id, plan_id, status, billing_cycle, trial_ends_at, trial_extensions_count)
  VALUES (p_hotel, p_plan, p_status, 'monthly', p_trial_ends_at, p_trial_extensions)
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
-- 1. Prolongation d'un essai principal (cas nominal)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_new timestamptz := now() + interval '30 days'; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_extend_trial(v_sub, v_new, 'Test extension');
  IF (v_row.subscription).trial_ends_at = v_new AND (v_row.subscription).trial_extensions_count = 1 THEN
    PERFORM pg_temp.zz_log(1, 'Prolongation d''un essai principal', 'PASS', format('trial_ends_at=%s, extensions=%s', (v_row.subscription).trial_ends_at, (v_row.subscription).trial_extensions_count));
  ELSE
    PERFORM pg_temp.zz_log(1, 'Prolongation d''un essai principal', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'Prolongation d''un essai principal', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Synchronisation de tous les accès applicatifs liés (RH + PMS, tous deux en trial)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_new timestamptz := now() + interval '30 days';
        v_rh uuid; v_pms uuid; v_row record; v_rh_after timestamptz; v_pms_after timestamptz;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_rh := pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'trial', now() - interval '10 days');   -- déjà "en retard", comme Folkestone
  v_pms := pg_temp.zz_mk_app_sub(v_hotel, 'PMS', 'trial', now() - interval '10 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_extend_trial(v_sub, v_new, 'Test sync');
  SELECT trial_ends_at INTO v_rh_after FROM public.hotel_app_subscriptions WHERE id = v_rh;
  SELECT trial_ends_at INTO v_pms_after FROM public.hotel_app_subscriptions WHERE id = v_pms;
  IF v_row.synced_app_count = 2 AND v_row.synced_apps = ARRAY['PMS','RH']
     AND v_rh_after = v_new AND v_pms_after = v_new THEN
    PERFORM pg_temp.zz_log(2, 'Synchronisation de tous les accès applicatifs liés', 'PASS', format('synced=%s apps=%s', v_row.synced_app_count, v_row.synced_apps));
  ELSE
    PERFORM pg_temp.zz_log(2, 'Synchronisation de tous les accès applicatifs liés', 'FAIL', format('synced=%s apps=%s rh=%s pms=%s', v_row.synced_app_count, v_row.synced_apps, v_rh_after, v_pms_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(2, 'Synchronisation de tous les accès applicatifs liés', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Absence d'accès applicatif — la prolongation réussit, synced_app_count=0
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test sans app');
  IF v_row.synced_app_count = 0 AND v_row.synced_apps = ARRAY[]::text[] THEN
    PERFORM pg_temp.zz_log(3, 'Absence d''accès applicatif', 'PASS', 'synced_app_count=0, aucune erreur');
  ELSE
    PERFORM pg_temp.zz_log(3, 'Absence d''accès applicatif', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Absence d''accès applicatif', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Accès déjà actif — ne doit PAS être touché (cycle de vie payant indépendant)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_rh uuid; v_before timestamptz := now() + interval '400 days'; v_after timestamptz;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_rh := pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'active', v_before);
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test actif intact');
  SELECT trial_ends_at INTO v_after FROM public.hotel_app_subscriptions WHERE id = v_rh;
  IF v_after = v_before THEN
    PERFORM pg_temp.zz_log(4, 'Accès déjà actif non modifié', 'PASS', 'trial_ends_at inchangé (statut active, hors périmètre de la synchronisation)');
  ELSE
    PERFORM pg_temp.zz_log(4, 'Accès déjà actif non modifié', 'FAIL', format('avant=%s après=%s', v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Accès déjà actif non modifié', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Accès déjà expiré mais contrat encore en trial — jamais ressuscité
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_rh uuid; v_before timestamptz := now() - interval '60 days'; v_after timestamptz; v_status text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_rh := pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'expired', v_before);
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test expired intact');
  SELECT trial_ends_at, status INTO v_after, v_status FROM public.hotel_app_subscriptions WHERE id = v_rh;
  IF v_after = v_before AND v_status = 'expired' THEN
    PERFORM pg_temp.zz_log(5, 'Accès déjà expiré non ressuscité', 'PASS', 'statut et date inchangés');
  ELSE
    PERFORM pg_temp.zz_log(5, 'Accès déjà expiré non ressuscité', 'FAIL', format('avant=%s après=%s statut=%s', v_before, v_after, v_status));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(5, 'Accès déjà expiré non ressuscité', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Date nouvelle antérieure à la date actuelle — rejetée
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  BEGIN
    PERFORM public.admin_extend_trial(v_sub, now() - interval '1 day', 'Test date passée');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_failed := true; END IF;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz_log(6, 'Date nouvelle antérieure rejetée', 'PASS', 'exception 22023 levée');
  ELSE
    PERFORM pg_temp.zz_log(6, 'Date nouvelle antérieure rejetée', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(6, 'Date nouvelle antérieure rejetée', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Abonnement non-trial — rejeté
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'active', NULL);
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  BEGIN
    PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test statut actif');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_failed := true; END IF;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz_log(7, 'Abonnement non-trial rejeté', 'PASS', 'exception 22023 levée');
  ELSE
    PERFORM pg_temp.zz_log(7, 'Abonnement non-trial rejeté', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(7, 'Abonnement non-trial rejeté', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Appel non-admin — rejeté (42501)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_nonadmin uuid; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_nonadmin := pg_temp.zz_mk_nonadmin(); PERFORM pg_temp.zz_as(v_nonadmin);
  BEGIN
    PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test non-admin');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN v_failed := true; END IF;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz_log(8, 'Appel non-admin rejeté', 'PASS', 'exception 42501 levée');
  ELSE
    PERFORM pg_temp.zz_log(8, 'Appel non-admin rejeté', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(8, 'Appel non-admin rejeté', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Appel direct de l'helper interne interdit (régression, non réouvert par ce lot)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_denied boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  BEGIN
    -- authenticated n'a aucun GRANT EXECUTE sur ce helper (REVOKE ALL FROM ... authenticated,
    -- sql/70 L361-362) : has_function_privilege reflète ce refus indépendamment de is_platform_admin().
    IF has_function_privilege('authenticated', 'public._hotel_subscription_transition(uuid,text,text,text,text,jsonb,timestamptz)', 'EXECUTE') THEN
      v_denied := false;
    ELSE
      v_denied := true;
    END IF;
  END;
  IF v_denied THEN
    PERFORM pg_temp.zz_log(9, 'Appel direct de l''helper interne interdit', 'PASS', 'authenticated ne possède pas EXECUTE sur _hotel_subscription_transition');
  ELSE
    PERFORM pg_temp.zz_log(9, 'Appel direct de l''helper interne interdit', 'FAIL', 'authenticated possède EXECUTE — régression ACL');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(9, 'Appel direct de l''helper interne interdit', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. Audit produit — hotel_subscription_events porte le détail de synchronisation
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_evt record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  PERFORM pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'trial', now() - interval '1 day');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test audit');
  SELECT * INTO v_evt FROM public.hotel_subscription_events
   WHERE subscription_id = v_sub AND event_type = 'trial_extended' ORDER BY created_at DESC LIMIT 1;
  IF v_evt.id IS NOT NULL AND (v_evt.metadata_after->>'synced_app_count')::int = 1
     AND v_evt.metadata_after->'synced_apps' ? 'RH' THEN
    PERFORM pg_temp.zz_log(10, 'Audit produit (hotel_subscription_events)', 'PASS', v_evt.metadata_after::text);
  ELSE
    PERFORM pg_temp.zz_log(10, 'Audit produit (hotel_subscription_events)', 'FAIL', coalesce(v_evt.metadata_after::text, 'aucun événement'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(10, 'Audit produit (hotel_subscription_events)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11. Log plateforme — platform_logs enregistre l'action
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Test log plateforme');
  SELECT count(*) INTO v_count FROM public.platform_logs
   WHERE action = 'subscription.extend_trial' AND entity_id = v_sub::text;
  IF v_count = 1 THEN
    PERFORM pg_temp.zz_log(11, 'Log plateforme (_platform_log)', 'PASS', '1 ligne platform_logs pour cette prolongation');
  ELSE
    PERFORM pg_temp.zz_log(11, 'Log plateforme (_platform_log)', 'FAIL', format('%s ligne(s) (attendu 1)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(11, 'Log plateforme (_platform_log)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. Rollback intégral si une mise à jour applicative échoue (preuve statique)
-- ----------------------------------------------------------------------------
-- Note méthodologique : forcer une erreur runtime au milieu de la fonction nécessiterait un
-- trigger temporaire posé sur hotel_app_subscriptions, une table de production à trafic réel —
-- le verrou DDL (AccessExclusiveLock) que prendrait CREATE TRIGGER bloquerait toute lecture/
-- écriture RH/PMS en cours pendant la durée du test, ce qui est exactement le risque que ce
-- correctif vise à éliminer. Preuve retenue à la place : inspection du corps de la fonction —
-- aucun bloc BEGIN...EXCEPTION interne entre les deux UPDATE (hotel_subscriptions puis
-- hotel_app_subscriptions). Sans savepoint implicite, toute erreur non interceptée dans le
-- second UPDATE remonte immédiatement à la transaction appelante et annule l'intégralité de
-- ses effets (sémantique standard PostgreSQL) — y compris le premier UPDATE déjà exécuté.
-- L'atomicité est garantie par le moteur, pas par une logique applicative qu'il faudrait tester
-- à l'exécution.
DO $$
DECLARE v_src text; v_has_internal_exception boolean;
BEGIN
  SELECT pg_get_functiondef('public.admin_extend_trial(uuid,timestamptz,text)'::regprocedure) INTO v_src;
  v_has_internal_exception := v_src ~* 'EXCEPTION\s+WHEN';
  IF NOT v_has_internal_exception THEN
    PERFORM pg_temp.zz_log(12, 'Rollback intégral si une mise à jour applicative échoue', 'PASS', 'aucun bloc EXCEPTION interne : atomicité garantie par la transaction appelante (sémantique PostgreSQL standard)');
  ELSE
    PERFORM pg_temp.zz_log(12, 'Rollback intégral si une mise à jour applicative échoue', 'FAIL', 'un bloc EXCEPTION interne existe — pourrait avaler une erreur partielle, à auditer manuellement');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(12, 'Rollback intégral si une mise à jour applicative échoue', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. Idempotence de admin_sync_app_trial_dates (régularisation)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_rh uuid;
        v_r1 record; v_r2 record; v_after timestamptz;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '60 days');
  v_rh := pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'trial', now() - interval '20 days'); -- divergent, comme Folkestone
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_r1 FROM public.admin_sync_app_trial_dates(v_sub, 'Régularisation divergence historique');
  SELECT * INTO v_r2 FROM public.admin_sync_app_trial_dates(v_sub, 'Second appel, idempotent');
  SELECT trial_ends_at INTO v_after FROM public.hotel_app_subscriptions WHERE id = v_rh;
  IF v_r1.synced_app_count = 1 AND v_r2.synced_app_count = 0 AND v_after = v_r1.target_trial_ends_at THEN
    PERFORM pg_temp.zz_log(13, 'Idempotence de admin_sync_app_trial_dates', 'PASS', format('1er appel=%s, 2e appel=%s', v_r1.synced_app_count, v_r2.synced_app_count));
  ELSE
    PERFORM pg_temp.zz_log(13, 'Idempotence de admin_sync_app_trial_dates', 'FAIL', format('r1=%s r2=%s after=%s', v_r1.synced_app_count, v_r2.synced_app_count, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(13, 'Idempotence de admin_sync_app_trial_dates', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14. Double exécution de admin_extend_trial — la 2e est rejetée (plafond trial_extensions)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '5 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  PERFORM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Premier appel');
  BEGIN
    PERFORM public.admin_extend_trial(v_sub, now() + interval '60 days', 'Second appel (double exécution)');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_failed := true; END IF;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz_log(14, 'Double exécution rejetée par le plafond de prolongations', 'PASS', 'second appel bloqué par max_trial_extensions, aucune double synchronisation');
  ELSE
    PERFORM pg_temp.zz_log(14, 'Double exécution rejetée par le plafond de prolongations', 'FAIL', 'le second appel n''a pas été rejeté');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(14, 'Double exécution rejetée par le plafond de prolongations', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 15. Prévisualisation sans écriture (aucun event, aucun log, deux appels sans effet)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid;
        v_evt_before int; v_evt_after int; v_log_before int; v_log_after int; v_status text;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '5 days'); -- expiré, éligible à la preview
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_evt_before FROM public.hotel_subscription_events WHERE subscription_id = v_sub;
  SELECT count(*) INTO v_log_before FROM public.platform_logs WHERE entity_id = v_sub::text;
  PERFORM public.admin_preview_expired_trials_processing();
  PERFORM public.admin_preview_expired_trials_processing();
  SELECT count(*) INTO v_evt_after FROM public.hotel_subscription_events WHERE subscription_id = v_sub;
  SELECT count(*) INTO v_log_after FROM public.platform_logs WHERE entity_id = v_sub::text;
  SELECT status INTO v_status FROM public.hotel_subscriptions WHERE id = v_sub;
  IF v_evt_before = v_evt_after AND v_log_before = v_log_after AND v_status = 'trial' THEN
    PERFORM pg_temp.zz_log(15, 'Prévisualisation sans écriture', 'PASS', 'aucun événement, aucun log, statut inchangé après 2 appels');
  ELSE
    PERFORM pg_temp.zz_log(15, 'Prévisualisation sans écriture', 'FAIL', format('evt %s->%s log %s->%s statut=%s', v_evt_before, v_evt_after, v_log_before, v_log_after, v_status));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(15, 'Prévisualisation sans écriture', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 16. Prévisualisation avec zéro ligne pour un hôtel sans rien d'expiré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '30 days');
  PERFORM pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'trial', now() + interval '30 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(16, 'Prévisualisation avec zéro ligne', 'PASS', 'aucune ligne pour cet hôtel (rien n''est expiré)');
  ELSE
    PERFORM pg_temp.zz_log(16, 'Prévisualisation avec zéro ligne', 'FAIL', format('%s ligne(s) inattendue(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(16, 'Prévisualisation avec zéro ligne', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 17. Prévisualisation avec abonnement principal expiré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() - interval '3 days');
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel AND entity_type = 'main_subscription';
  IF v_row.entity_id = v_sub AND v_row.days_since_expiry > 0 THEN
    PERFORM pg_temp.zz_log(17, 'Prévisualisation avec abonnement principal', 'PASS', format('days_since_expiry=%s effet=%s', v_row.days_since_expiry, v_row.theoretical_effect));
  ELSE
    PERFORM pg_temp.zz_log(17, 'Prévisualisation avec abonnement principal', 'FAIL', coalesce(v_row::text, 'aucune ligne'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(17, 'Prévisualisation avec abonnement principal', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 18. Prévisualisation avec accès applicatif expiré + anomalie (contrat principal encore valide)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_rh uuid; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', now() + interval '30 days'); -- encore valide
  v_rh := pg_temp.zz_mk_app_sub(v_hotel, 'RH', 'trial', now() - interval '5 days'); -- divergent, comme Folkestone AVANT correction
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT * INTO v_row FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel AND entity_type = 'app_subscription';
  IF v_row.entity_id = v_rh AND v_row.anomaly_causes @> ARRAY['main_subscription_still_valid'] THEN
    PERFORM pg_temp.zz_log(18, 'Prévisualisation avec accès applicatifs (anomalie détectée)', 'PASS', format('causes=%s', v_row.anomaly_causes));
  ELSE
    PERFORM pg_temp.zz_log(18, 'Prévisualisation avec accès applicatifs (anomalie détectée)', 'FAIL', coalesce(v_row::text, 'aucune ligne'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(18, 'Prévisualisation avec accès applicatifs (anomalie détectée)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 19. Essai avec trial_ends_at IS NULL — ignoré par la preview, prolongeable normalement
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub uuid; v_admin uuid; v_count int; v_row record;
BEGIN
  v_hotel := pg_temp.zz_mk_hotel(); v_plan := pg_temp.zz_mk_plan();
  v_sub := pg_temp.zz_mk_sub(v_hotel, v_plan, 'trial', NULL); -- comme Folkestone avant sa première correction
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel;
  SELECT * INTO v_row FROM public.admin_extend_trial(v_sub, now() + interval '30 days', 'Correction trial_ends_at NULL');
  IF v_count = 0 AND v_row.old_trial_ends_at IS NULL AND (v_row.subscription).trial_ends_at IS NOT NULL THEN
    PERFORM pg_temp.zz_log(19, 'Essai avec trial_ends_at IS NULL', 'PASS', 'ignoré par la preview, corrigeable via admin_extend_trial');
  ELSE
    PERFORM pg_temp.zz_log(19, 'Essai avec trial_ends_at IS NULL', 'FAIL', format('preview_count=%s old=%s new=%s', v_count, v_row.old_trial_ends_at, (v_row.subscription).trial_ends_at));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(19, 'Essai avec trial_ends_at IS NULL', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 20. Folkestone après régularisation (donnée réelle, dans la transaction non commitée)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel_id uuid := '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid; -- Folkestone opera, hôtel réel
        v_sub_id uuid; v_sub_trial timestamptz; v_admin uuid; v_row record; v_rh timestamptz; v_pms timestamptz;
BEGIN
  SELECT id, trial_ends_at INTO v_sub_id, v_sub_trial FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_id;
  IF v_sub_id IS NULL THEN
    PERFORM pg_temp.zz_log(20, 'Folkestone après régularisation', 'FAIL', 'abonnement Folkestone introuvable (état de production modifié depuis la revue)');
  ELSE
    v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
    SELECT * INTO v_row FROM public.admin_sync_app_trial_dates(v_sub_id, 'Régularisation P0 — divergence historique admin_extend_trial (rapport CTO)');
    SELECT trial_ends_at INTO v_rh FROM public.hotel_app_subscriptions WHERE hotel_id = v_hotel_id AND app_id = pg_temp.zz_app_id('RH');
    SELECT trial_ends_at INTO v_pms FROM public.hotel_app_subscriptions WHERE hotel_id = v_hotel_id AND app_id = pg_temp.zz_app_id('PMS');
    IF v_rh = v_sub_trial AND v_pms = v_sub_trial AND v_row.synced_app_count = 2 THEN
      PERFORM pg_temp.zz_log(20, 'Folkestone après régularisation', 'PASS', format('RH=%s PMS=%s abonnement=%s synced=%s', v_rh, v_pms, v_sub_trial, v_row.synced_app_count));
    ELSE
      PERFORM pg_temp.zz_log(20, 'Folkestone après régularisation', 'FAIL', format('RH=%s PMS=%s abonnement=%s synced=%s', v_rh, v_pms, v_sub_trial, v_row.synced_app_count));
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(20, 'Folkestone après régularisation', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 21. Traitement après régularisation ne doit plus cibler Folkestone
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel_id uuid := '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid; v_count int; v_admin uuid;
BEGIN
  v_admin := pg_temp.zz_mk_admin(); PERFORM pg_temp.zz_as(v_admin);
  SELECT count(*) INTO v_count FROM public.admin_preview_expired_trials_processing() WHERE hotel_id = v_hotel_id;
  IF v_count = 0 THEN
    PERFORM pg_temp.zz_log(21, 'Traitement après régularisation ne cible plus Folkestone', 'PASS', 'aucune ligne pour Folkestone dans la preview après régularisation (test 20)');
  ELSE
    PERFORM pg_temp.zz_log(21, 'Traitement après régularisation ne cible plus Folkestone', 'FAIL', format('%s ligne(s) encore présente(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(21, 'Traitement après régularisation ne cible plus Folkestone', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 22. Non-régression sur les autres hôtels (hors ZZTEST et hors Folkestone régularisée)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hs_count int; v_has_count int; v_bad_hs int; v_bad_has int;
BEGIN
  -- Aucune ligne hotel_subscriptions/hotel_app_subscriptions autre que les fixtures ZZTEST et
  -- Folkestone (seul hôtel réel volontairement modifié, par les tests 20/21) ne doit avoir
  -- changé de valeur trial_ends_at par rapport à ce qu'elle serait sans cette suite : ici, on
  -- vérifie l'absence de toute ligne dont updated_at a été touché hors de ce périmètre.
  SELECT count(*) INTO v_bad_hs FROM public.hotel_subscriptions hs
   JOIN public.hotels h ON h.id = hs.hotel_id
   WHERE h.name NOT LIKE 'ZZTEST-%' AND hs.hotel_id <> '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid
     AND hs.updated_at >= now() - interval '5 minutes';
  SELECT count(*) INTO v_bad_has FROM public.hotel_app_subscriptions has
   JOIN public.hotels h ON h.id = has.hotel_id
   WHERE h.name NOT LIKE 'ZZTEST-%' AND has.hotel_id <> '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'::uuid
     AND has.updated_at >= now() - interval '5 minutes';
  IF v_bad_hs = 0 AND v_bad_has = 0 THEN
    PERFORM pg_temp.zz_log(22, 'Non-régression sur les autres hôtels', 'PASS', 'aucune ligne hors ZZTEST/Folkestone modifiée pendant la suite');
  ELSE
    PERFORM pg_temp.zz_log(22, 'Non-régression sur les autres hôtels', 'FAIL', format('hs modifiées=%s has modifiées=%s', v_bad_hs, v_bad_has));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(22, 'Non-régression sur les autres hôtels', 'FAIL', SQLERRM);
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
  RAISE NOTICE 'OK : suite P0 cohérence essai/accès applicatifs complète, % scénarios, 0 échec.', v_total;
END $$;

-- Rollback du BEGIN externe : détruit toutes les fixtures ZZTEST et annule la régularisation
-- de test appliquée à Folkestone (tests 20/21) — la régularisation réelle sera un appel RPC
-- séparé, explicite, après validation CTO, jamais un effet de bord de cette suite.
ROLLBACK;
