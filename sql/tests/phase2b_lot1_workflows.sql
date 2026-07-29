-- sql/tests/phase2b_lot1_workflows.sql
-- Suite de tests Lot 1 (sql/71_super_admin_phase2b_lot1_workflows.sql) : admin_change_subscription_plan
-- + les 5 RPC de catalogue des offres. Convention du projet : BEGIN...ROLLBACK, chaque scénario
-- est un DO $$ ... $$ indépendant avec ses propres fixtures synthétiques (mêmes helpers pg_temp
-- que sql/tests/phase2a_subscription_foundation.sql, redéfinis ici pour que ce fichier reste
-- exécutable seul, sans dépendre de l'ordre d'exécution avec l'autre suite).
--
-- Portée : uniquement les RPC NEUVES de ce lot. Les 17 RPC de cycle de vie/résolution déjà
-- livrées et testées par le Lot 0 (41/41 PASS, cf. sql/tests/phase2a_subscription_foundation.sql)
-- ne sont pas re-testées ici — ce serait une duplication, pas une preuve supplémentaire.
--
-- Usage : coller entre BEGIN; et ROLLBACK; (jamais de COMMIT en local/CI).

BEGIN;

CREATE TEMP TABLE zz2_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz2_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz2_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz2_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.zz2_mk_hotel() RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels(name, status) VALUES ('ZZ2TEST-' || gen_random_uuid()::text, 'active') RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz2_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins(auth_id, email, role, is_active)
    VALUES (v_auth, 'zz2test-admin-' || v_auth::text || '@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz2_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz2_mk_plan(
  p_active boolean DEFAULT true, p_archived boolean DEFAULT false, p_commercializable boolean DEFAULT true
) RETURNS uuid AS $$
DECLARE v_id uuid; v_slug text := 'zz2test-plan-' || gen_random_uuid()::text;
BEGIN
  INSERT INTO public.subscription_plans(
    name, slug, price_monthly, price_annual, modules, features, support_level,
    is_active, sort_order, trial_days, plan_scope, is_commercializable, archived_at
  ) VALUES (
    'ZZ2TEST Plan', v_slug, 100, 1000, '[]'::jsonb, '[]'::jsonb, 'none',
    p_active, 999, 14, 'public', p_commercializable,
    CASE WHEN p_archived THEN now() ELSE NULL END
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz2_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 1. Changement de plan réussi : snapshot mis à jour, événement plan_changed créé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan_a uuid; v_plan_b uuid; v_sub public.hotel_subscriptions; v_events int;
BEGIN
  v_hotel := pg_temp.zz2_mk_hotel();
  v_plan_a := pg_temp.zz2_mk_plan();
  v_plan_b := pg_temp.zz2_mk_plan();
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_sub := public.admin_create_subscription(v_hotel, v_plan_a, 'monthly', 0, NULL, 'active');
  v_sub := public.admin_change_subscription_plan(v_sub.id, v_plan_b, 'Montée en gamme');
  SELECT count(*) INTO v_events FROM public.hotel_subscription_events
    WHERE subscription_id = v_sub.id AND event_type = 'plan_changed';
  IF v_sub.plan_id = v_plan_b AND v_events = 1 THEN
    PERFORM pg_temp.zz2_log(1, 'Changement de plan réussi', 'PASS', format('plan_id=%s, 1 event plan_changed', v_sub.plan_id));
  ELSE
    PERFORM pg_temp.zz2_log(1, 'Changement de plan réussi', 'FAIL', format('plan_id=%s, events=%s', v_sub.plan_id, v_events));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(1, 'Changement de plan réussi', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Changement de plan refusé si identique au plan actuel
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan uuid; v_sub public.hotel_subscriptions; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz2_mk_hotel();
  v_plan := pg_temp.zz2_mk_plan();
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_sub := public.admin_create_subscription(v_hotel, v_plan, 'monthly', 0, NULL, 'active');
  BEGIN
    PERFORM public.admin_change_subscription_plan(v_sub.id, v_plan, 'Sans changement réel');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz2_log(2, 'Changement de plan refusé si identique', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz2_log(2, 'Changement de plan refusé si identique', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(2, 'Changement de plan refusé si identique', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Changement de plan refusé vers un plan archivé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan_a uuid; v_plan_b uuid; v_sub public.hotel_subscriptions; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz2_mk_hotel();
  v_plan_a := pg_temp.zz2_mk_plan();
  v_plan_b := pg_temp.zz2_mk_plan(false, true, false);
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_sub := public.admin_create_subscription(v_hotel, v_plan_a, 'monthly', 0, NULL, 'active');
  BEGIN
    PERFORM public.admin_change_subscription_plan(v_sub.id, v_plan_b, 'Vers un plan archivé');
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz2_log(3, 'Changement de plan refusé vers un plan archivé', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz2_log(3, 'Changement de plan refusé vers un plan archivé', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(3, 'Changement de plan refusé vers un plan archivé', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Changement de plan refusé pour un non-admin
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan_a uuid; v_plan_b uuid; v_sub public.hotel_subscriptions; v_failed boolean := false;
BEGIN
  v_hotel := pg_temp.zz2_mk_hotel();
  v_plan_a := pg_temp.zz2_mk_plan();
  v_plan_b := pg_temp.zz2_mk_plan();
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_sub := public.admin_create_subscription(v_hotel, v_plan_a, 'monthly', 0, NULL, 'active');
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_nonadmin());
  BEGIN
    PERFORM public.admin_change_subscription_plan(v_sub.id, v_plan_b, 'Tentative non admin');
  EXCEPTION WHEN OTHERS THEN
    v_failed := SQLERRM LIKE '%Accès refusé%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz2_log(4, 'Changement de plan refusé pour un non-admin', 'PASS', 'Accès refusé confirmé');
  ELSE
    PERFORM pg_temp.zz2_log(4, 'Changement de plan refusé pour un non-admin', 'FAIL', 'pas de refus 42501');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(4, 'Changement de plan refusé pour un non-admin', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Création d'un plan + audit
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan public.subscription_plans; v_slug text := 'zz2test-newplan-' || gen_random_uuid()::text; v_log_count int;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan := public.admin_create_plan(v_slug, v_slug, 'Description test', 49, 490, 14, 50, 10, 1, 'public', true, 5);
  SELECT count(*) INTO v_log_count FROM public.platform_logs WHERE action = 'plan.create' AND entity_id = v_plan.id::text;
  IF v_plan.slug = v_slug AND v_log_count = 1 THEN
    PERFORM pg_temp.zz2_log(5, 'Création d''un plan + audit', 'PASS', format('plan créé, %s log(s)', v_log_count));
  ELSE
    PERFORM pg_temp.zz2_log(5, 'Création d''un plan + audit', 'FAIL', format('slug=%s, logs=%s', v_plan.slug, v_log_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(5, 'Création d''un plan + audit', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Création d'un plan refusée si slug déjà existant
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_slug text := 'zz2test-dup-' || gen_random_uuid()::text; v_failed boolean := false;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  PERFORM public.admin_create_plan(v_slug, v_slug);
  BEGIN
    PERFORM public.admin_create_plan(v_slug, v_slug);
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz2_log(6, 'Création de plan refusée si slug dupliqué', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz2_log(6, 'Création de plan refusée si slug dupliqué', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(6, 'Création de plan refusée si slug dupliqué', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Modification d'un plan existant
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_id uuid; v_updated public.subscription_plans;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan_id := pg_temp.zz2_mk_plan();
  v_updated := public.admin_update_plan(v_plan_id, 'Nom modifié', 'Nouvelle description', 79, 790, 30, 100, 20, 2, 10);
  IF v_updated.name = 'Nom modifié' AND v_updated.price_monthly = 79 THEN
    PERFORM pg_temp.zz2_log(7, 'Modification d''un plan existant', 'PASS', 'champs mis à jour');
  ELSE
    PERFORM pg_temp.zz2_log(7, 'Modification d''un plan existant', 'FAIL', to_jsonb(v_updated)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(7, 'Modification d''un plan existant', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Désactivation d'un plan force is_commercializable=false (contrainte du Lot 0)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_id uuid; v_updated public.subscription_plans;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan_id := pg_temp.zz2_mk_plan(true, false, true);
  v_updated := public.admin_set_plan_active(v_plan_id, false, 'Retiré du catalogue');
  IF v_updated.is_active = false AND v_updated.is_commercializable = false THEN
    PERFORM pg_temp.zz2_log(8, 'Désactivation force is_commercializable=false', 'PASS', 'contrainte respectée sans erreur');
  ELSE
    PERFORM pg_temp.zz2_log(8, 'Désactivation force is_commercializable=false', 'FAIL', to_jsonb(v_updated)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(8, 'Désactivation force is_commercializable=false', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Archivage d'un plan : is_active=false, is_commercializable=false, archived_at posé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_id uuid; v_updated public.subscription_plans;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan_id := pg_temp.zz2_mk_plan();
  v_updated := public.admin_set_plan_archived(v_plan_id, true, 'Plan retiré définitivement');
  IF v_updated.archived_at IS NOT NULL AND v_updated.is_active = false AND v_updated.is_commercializable = false THEN
    PERFORM pg_temp.zz2_log(9, 'Archivage d''un plan', 'PASS', 'archived_at posé, is_active/is_commercializable=false');
  ELSE
    PERFORM pg_temp.zz2_log(9, 'Archivage d''un plan', 'FAIL', to_jsonb(v_updated)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(9, 'Archivage d''un plan', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. Un plan archivé reste référencé par un abonnement historique (aucune perte)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_hotel uuid; v_plan_id uuid; v_sub public.hotel_subscriptions; v_sub_after public.hotel_subscriptions;
BEGIN
  v_hotel := pg_temp.zz2_mk_hotel();
  v_plan_id := pg_temp.zz2_mk_plan();
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_sub := public.admin_create_subscription(v_hotel, v_plan_id, 'monthly', 0, NULL, 'active');
  PERFORM public.admin_set_plan_archived(v_plan_id, true, 'Archivage pendant qu''un hôtel y souscrit encore');
  SELECT * INTO v_sub_after FROM public.hotel_subscriptions WHERE id = v_sub.id;
  IF v_sub_after.plan_id = v_plan_id AND v_sub_after.status = 'active' THEN
    PERFORM pg_temp.zz2_log(10, 'Plan archivé reste référencé par abonnement historique', 'PASS', 'FK intacte, abonnement toujours actif');
  ELSE
    PERFORM pg_temp.zz2_log(10, 'Plan archivé reste référencé par abonnement historique', 'FAIL', to_jsonb(v_sub_after)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(10, 'Plan archivé reste référencé par abonnement historique', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11. Désarchivage : redevient actif mais reste non commercialisable par défaut
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_id uuid; v_updated public.subscription_plans;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan_id := pg_temp.zz2_mk_plan();
  PERFORM public.admin_set_plan_archived(v_plan_id, true, 'Archivage initial');
  v_updated := public.admin_set_plan_archived(v_plan_id, false, NULL);
  IF v_updated.archived_at IS NULL AND v_updated.is_active = true AND v_updated.is_commercializable = false THEN
    PERFORM pg_temp.zz2_log(11, 'Désarchivage : actif mais non commercialisable', 'PASS', 'comportement conforme à la doctrine');
  ELSE
    PERFORM pg_temp.zz2_log(11, 'Désarchivage : actif mais non commercialisable', 'FAIL', to_jsonb(v_updated)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(11, 'Désarchivage : actif mais non commercialisable', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. admin_set_plan_modules remplace atomiquement les applications incluses
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan_id uuid; v_pms uuid; v_rh uuid; v_count int;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan_id := pg_temp.zz2_mk_plan();
  SELECT id INTO v_pms FROM public.platform_apps WHERE code = 'PMS';
  SELECT id INTO v_rh FROM public.platform_apps WHERE code = 'RH';
  PERFORM public.admin_set_plan_modules(v_plan_id, ARRAY[v_pms, v_rh]);
  SELECT count(*) INTO v_count FROM public.plan_modules WHERE plan_id = v_plan_id;
  IF v_count = 2 THEN
    PERFORM public.admin_set_plan_modules(v_plan_id, ARRAY[v_pms]);
    SELECT count(*) INTO v_count FROM public.plan_modules WHERE plan_id = v_plan_id;
    IF v_count = 1 THEN
      PERFORM pg_temp.zz2_log(12, 'admin_set_plan_modules remplace atomiquement', 'PASS', '2 puis 1 app après remplacement');
    ELSE
      PERFORM pg_temp.zz2_log(12, 'admin_set_plan_modules remplace atomiquement', 'FAIL', format('2e appel: %s lignes', v_count));
    END IF;
  ELSE
    PERFORM pg_temp.zz2_log(12, 'admin_set_plan_modules remplace atomiquement', 'FAIL', format('1er appel: %s lignes', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(12, 'admin_set_plan_modules remplace atomiquement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. ACL : aucune des 6 nouvelles RPC n'est exécutable par PUBLIC/anon/service_role
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_remaining int;
BEGIN
  SELECT count(*) INTO v_remaining FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('admin_change_subscription_plan','admin_create_plan','admin_update_plan',
                       'admin_set_plan_active','admin_set_plan_archived','admin_set_plan_modules')
    AND a.privilege_type = 'EXECUTE'
    AND (a.grantee = 0 OR a.grantee IN (
      (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
      (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
    ));
  IF v_remaining = 0 THEN
    PERFORM pg_temp.zz2_log(13, 'ACL : 6 nouvelles RPC fermées à PUBLIC/anon/service_role', 'PASS', 'aucun privilège résiduel');
  ELSE
    PERFORM pg_temp.zz2_log(13, 'ACL : 6 nouvelles RPC fermées à PUBLIC/anon/service_role', 'FAIL', format('%s privilège(s) résiduel(s)', v_remaining));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(13, 'ACL : 6 nouvelles RPC fermées à PUBLIC/anon/service_role', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14. ACL : authenticated peut exécuter les 6 nouvelles RPC
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_missing int;
BEGIN
  SELECT count(*) INTO v_missing FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('admin_change_subscription_plan','admin_create_plan','admin_update_plan',
                       'admin_set_plan_active','admin_set_plan_archived','admin_set_plan_modules')
    AND NOT EXISTS (
      SELECT 1 FROM aclexplode(coalesce(p.proacl,'{}')) a
      WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname='authenticated') AND a.privilege_type='EXECUTE'
    );
  IF v_missing = 0 THEN
    PERFORM pg_temp.zz2_log(14, 'ACL : authenticated peut exécuter les 6 nouvelles RPC', 'PASS', 'GRANT confirmé sur les 6');
  ELSE
    PERFORM pg_temp.zz2_log(14, 'ACL : authenticated peut exécuter les 6 nouvelles RPC', 'FAIL', format('%s fonction(s) sans GRANT', v_missing));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(14, 'ACL : authenticated peut exécuter les 6 nouvelles RPC', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 15. Un Super Admin autorisé peut créer, modifier, archiver un plan de bout en bout
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan public.subscription_plans; v_slug text := 'zz2test-e2e-' || gen_random_uuid()::text;
BEGIN
  PERFORM pg_temp.zz2_as(pg_temp.zz2_mk_admin());
  v_plan := public.admin_create_plan(v_slug, v_slug);
  v_plan := public.admin_update_plan(v_plan.id, 'Nom final', NULL, 59, 590, 14, NULL, NULL, 1, 1);
  v_plan := public.admin_set_plan_archived(v_plan.id, true, 'Fin de cycle de vie test');
  IF v_plan.name = 'Nom final' AND v_plan.archived_at IS NOT NULL THEN
    PERFORM pg_temp.zz2_log(15, 'Cycle de vie complet Super Admin (create/update/archive)', 'PASS', 'les 3 opérations réussissent en séquence');
  ELSE
    PERFORM pg_temp.zz2_log(15, 'Cycle de vie complet Super Admin (create/update/archive)', 'FAIL', to_jsonb(v_plan)::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz2_log(15, 'Cycle de vie complet Super Admin (create/update/archive)', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_total int; v_failed int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status <> 'PASS') INTO v_total, v_failed FROM zz2_results;
  RAISE NOTICE 'Suite Lot 1 : % scénarios, % échec(s).', v_total, v_failed;
  IF v_failed > 0 THEN
    RAISE EXCEPTION 'Suite Lot 1 : % échec(s) sur % scénarios — voir zz2_results.', v_failed, v_total;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz2_results ORDER BY test_no;

ROLLBACK;
