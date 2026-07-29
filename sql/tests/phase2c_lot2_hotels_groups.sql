-- sql/tests/phase2c_lot2_hotels_groups.sql
-- Suite de tests Lot 2 (sql/72_super_admin_phase2c_lot2_hotels_groups.sql).
-- Convention du projet : BEGIN...ROLLBACK, chaque scénario est un DO $$ ... $$ indépendant avec
-- ses propres fixtures synthétiques (mêmes helpers pg_temp que les suites précédentes).
--
-- Portée : les RPC neuves (admin_restore_group, admin_create_hotel_with_subscription) et les
-- comportements déjà existants mais non encore testés dans une suite versionnée (transitions de
-- statut hôtel, rattachement/détachement/transfert de groupe, archivage de groupe non vide
-- refusé) + ACL des 11 fonctions du périmètre hôtels/groupes.
--
-- Usage : coller entre BEGIN; et ROLLBACK; (jamais de COMMIT en local/CI).

BEGIN;

CREATE TEMP TABLE zz3_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz3_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz3_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz3_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.zz3_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins(auth_id, email, role, is_active)
    VALUES (v_auth, 'zz3test-admin-' || v_auth::text || '@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz3_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz3_mk_plan(p_active boolean DEFAULT true, p_archived boolean DEFAULT false) RETURNS uuid AS $$
DECLARE v_id uuid; v_slug text := 'zz3test-plan-' || gen_random_uuid()::text;
BEGIN
  INSERT INTO public.subscription_plans(
    name, slug, price_monthly, price_annual, modules, features, support_level,
    is_active, sort_order, trial_days, plan_scope, is_commercializable, archived_at
  ) VALUES (
    'ZZ3TEST Plan', v_slug, 100, 1000, '[]'::jsonb, '[]'::jsonb, 'none',
    p_active, 999, 14, 'public', true, CASE WHEN p_archived THEN now() ELSE NULL END
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz3_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 1. Création d'un hôtel autonome (sans groupe) avec abonnement d'essai, atomique
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_res jsonb; v_hotel_id uuid; v_sub_count int;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_res := public.admin_create_hotel_with_subscription(
    jsonb_build_object('name','ZZ3TEST Hotel Autonome-'||gen_random_uuid()::text), v_plan, 'trial', 'admin@zz3test.invalid', 'Jean Test'
  );
  v_hotel_id := (v_res->'hotel'->>'id')::uuid;
  SELECT count(*) INTO v_sub_count FROM public.hotel_subscriptions WHERE hotel_id = v_hotel_id;
  IF v_hotel_id IS NOT NULL AND (v_res->'hotel'->>'group_id') IS NULL AND v_sub_count = 1
     AND (v_res->'subscription'->>'status') = 'trial' THEN
    PERFORM pg_temp.zz3_log(1, 'Création hôtel autonome + essai, atomique', 'PASS', 'hôtel sans groupe, 1 abonnement trial');
  ELSE
    PERFORM pg_temp.zz3_log(1, 'Création hôtel autonome + essai, atomique', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(1, 'Création hôtel autonome + essai, atomique', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Création d'un hôtel dans un groupe avec abonnement actif
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_group uuid; v_res jsonb;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_group := (public.admin_create_group(jsonb_build_object('name','ZZ3TEST Groupe-'||gen_random_uuid()::text))->>'id')::uuid;
  v_res := public.admin_create_hotel_with_subscription(
    jsonb_build_object('name','ZZ3TEST Hotel Groupe-'||gen_random_uuid()::text, 'group_id', v_group::text), v_plan, 'active'
  );
  IF (v_res->'hotel'->>'group_id')::uuid = v_group AND (v_res->'subscription'->>'status') = 'active' THEN
    PERFORM pg_temp.zz3_log(2, 'Création hôtel dans un groupe + abonnement actif', 'PASS', 'group_id correct, statut actif');
  ELSE
    PERFORM pg_temp.zz3_log(2, 'Création hôtel dans un groupe + abonnement actif', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(2, 'Création hôtel dans un groupe + abonnement actif', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Refus d'un code hôtel dupliqué
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_code text := upper(substr(md5(gen_random_uuid()::text),1,5)); v_failed boolean := false;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  PERFORM public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST A','hotel_code',v_code), v_plan);
  BEGIN
    PERFORM public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST B','hotel_code',v_code), v_plan);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%CODE_EXISTANT%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz3_log(3, 'Refus code hôtel dupliqué', 'PASS', 'CODE_EXISTANT levé');
  ELSE
    PERFORM pg_temp.zz3_log(3, 'Refus code hôtel dupliqué', 'FAIL', 'pas de refus CODE_EXISTANT');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(3, 'Refus code hôtel dupliqué', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Atomicité : un plan invalide n'aboutit à AUCUN hôtel créé (rollback interne)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_name text := 'ZZ3TEST Atomicite-'||gen_random_uuid()::text; v_count_before int; v_count_after int; v_failed boolean := false;
BEGIN
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  SELECT count(*) INTO v_count_before FROM public.hotels WHERE name = v_name;
  BEGIN
    -- p_plan_id inexistant -> admin_create_subscription lève une exception APRÈS l'INSERT hôtel :
    -- toute la fonction doit annuler cet INSERT (une seule transaction PL/pgSQL).
    PERFORM public.admin_create_hotel_with_subscription(jsonb_build_object('name', v_name), gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_failed := true;
  END;
  SELECT count(*) INTO v_count_after FROM public.hotels WHERE name = v_name;
  IF v_failed AND v_count_before = 0 AND v_count_after = 0 THEN
    PERFORM pg_temp.zz3_log(4, 'Atomicité : échec abonnement -> aucun hôtel créé', 'PASS', 'hôtel absent après échec, comme avant l''appel');
  ELSE
    PERFORM pg_temp.zz3_log(4, 'Atomicité : échec abonnement -> aucun hôtel créé', 'FAIL', format('failed=%s, before=%s, after=%s', v_failed, v_count_before, v_count_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(4, 'Atomicité : échec abonnement -> aucun hôtel créé', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Modification complète (admin_update_hotel_full)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_updated jsonb;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Avant'), v_plan))->'hotel'->>'id')::uuid;
  v_updated := public.admin_update_hotel_full(v_hotel_id, jsonb_build_object('name','ZZ3TEST Après','city','Paris'));
  IF (v_updated->>'name') = 'ZZ3TEST Après' AND (v_updated->>'city') = 'Paris' THEN
    PERFORM pg_temp.zz3_log(5, 'Modification complète (admin_update_hotel_full)', 'PASS', 'champs mis à jour');
  ELSE
    PERFORM pg_temp.zz3_log(5, 'Modification complète (admin_update_hotel_full)', 'FAIL', v_updated::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(5, 'Modification complète (admin_update_hotel_full)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Activation / désactivation (suspension) / archivage d'un hôtel
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_r1 jsonb; v_r2 jsonb; v_r3 jsonb;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Cycle'), v_plan))->'hotel'->>'id')::uuid;
  v_r1 := public.admin_set_hotel_status(v_hotel_id, 'suspended');
  v_r2 := public.admin_set_hotel_status(v_hotel_id, 'archived');
  v_r3 := public.admin_set_hotel_status(v_hotel_id, 'active');
  IF (v_r1->>'status')='suspended' AND (v_r2->>'status')='archived' AND (v_r3->>'status')='active' AND (v_r3->>'active')::boolean = true THEN
    PERFORM pg_temp.zz3_log(6, 'Activation/désactivation/archivage/restauration hôtel', 'PASS', 'suspended -> archived -> active, active bool cohérent');
  ELSE
    PERFORM pg_temp.zz3_log(6, 'Activation/désactivation/archivage/restauration hôtel', 'FAIL', format('%s / %s / %s', v_r1->>'status', v_r2->>'status', v_r3->>'status'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(6, 'Activation/désactivation/archivage/restauration hôtel', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Impossibilité de suppression destructive (aucune RPC hôtel n'expose de DELETE réel)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_count int;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Archive'), v_plan))->'hotel'->>'id')::uuid;
  PERFORM public.admin_set_hotel_status(v_hotel_id, 'archived');
  SELECT count(*) INTO v_count FROM public.hotels WHERE id = v_hotel_id;
  IF v_count = 1 THEN
    PERFORM pg_temp.zz3_log(7, 'Archivage jamais destructif (ligne hôtel conservée)', 'PASS', 'ligne toujours présente après archivage');
  ELSE
    PERFORM pg_temp.zz3_log(7, 'Archivage jamais destructif (ligne hôtel conservée)', 'FAIL', format('%s ligne(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(7, 'Archivage jamais destructif (ligne hôtel conservée)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Rattachement à un groupe, transfert vers un autre groupe, détachement
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_group_a uuid; v_group_b uuid; v_g1 uuid; v_g2 uuid; v_g3 uuid;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Transfert'), v_plan))->'hotel'->>'id')::uuid;
  v_group_a := (public.admin_create_group(jsonb_build_object('name','ZZ3TEST Groupe A-'||gen_random_uuid()::text))->>'id')::uuid;
  v_group_b := (public.admin_create_group(jsonb_build_object('name','ZZ3TEST Groupe B-'||gen_random_uuid()::text))->>'id')::uuid;

  PERFORM public.admin_attach_hotel_to_group(v_hotel_id, v_group_a);
  SELECT group_id INTO v_g1 FROM public.hotels WHERE id = v_hotel_id;
  PERFORM public.admin_attach_hotel_to_group(v_hotel_id, v_group_b); -- transfert = ré-attacher
  SELECT group_id INTO v_g2 FROM public.hotels WHERE id = v_hotel_id;
  PERFORM public.admin_detach_hotel_from_group(v_hotel_id);
  SELECT group_id INTO v_g3 FROM public.hotels WHERE id = v_hotel_id;

  IF v_g1 = v_group_a AND v_g2 = v_group_b AND v_g3 IS NULL THEN
    PERFORM pg_temp.zz3_log(8, 'Rattachement, transfert, détachement de groupe', 'PASS', 'A -> B -> aucun, conforme');
  ELSE
    PERFORM pg_temp.zz3_log(8, 'Rattachement, transfert, détachement de groupe', 'FAIL', format('%s / %s / %s', v_g1, v_g2, v_g3));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(8, 'Rattachement, transfert, détachement de groupe', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Groupe non vide : archivage refusé, puis vidé + archivé + restauré
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_group uuid; v_hotel_id uuid; v_failed boolean := false; v_restored jsonb;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_group := (public.admin_create_group(jsonb_build_object('name','ZZ3TEST Groupe Plein-'||gen_random_uuid()::text))->>'id')::uuid;
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Rattaché','group_id',v_group::text), v_plan))->'hotel'->>'id')::uuid;

  BEGIN
    PERFORM public.admin_delete_group(v_group);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%GROUPE_NON_VIDE%';
  END;
  IF NOT v_failed THEN
    PERFORM pg_temp.zz3_log(9, 'Groupe non vide refuse l''archivage, puis restauration après vidage', 'FAIL', 'GROUPE_NON_VIDE non levé');
    RETURN;
  END IF;

  PERFORM public.admin_detach_hotel_from_group(v_hotel_id);
  PERFORM public.admin_delete_group(v_group);
  v_restored := public.admin_restore_group(v_group);
  IF (v_restored->>'status') = 'active' THEN
    PERFORM pg_temp.zz3_log(9, 'Groupe non vide refuse l''archivage, puis restauration après vidage', 'PASS', 'refus initial confirmé, archivage puis restauration réussis une fois vide');
  ELSE
    PERFORM pg_temp.zz3_log(9, 'Groupe non vide refuse l''archivage, puis restauration après vidage', 'FAIL', v_restored::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(9, 'Groupe non vide refuse l''archivage, puis restauration après vidage', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. L'abonnement d'un hôtel survit à l'archivage de l'hôtel (aucune disparition)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_sub_id uuid; v_count int;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  DECLARE v_res jsonb;
  BEGIN
    v_res := public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST SubSurvit'), v_plan, 'active');
    v_hotel_id := (v_res->'hotel'->>'id')::uuid;
    v_sub_id := (v_res->'subscription'->>'id')::uuid;
  END;
  PERFORM public.admin_set_hotel_status(v_hotel_id, 'archived');
  SELECT count(*) INTO v_count FROM public.hotel_subscriptions WHERE id = v_sub_id;
  IF v_count = 1 THEN
    PERFORM pg_temp.zz3_log(10, 'Abonnement conservé après archivage de l''hôtel', 'PASS', 'ligne hotel_subscriptions toujours présente');
  ELSE
    PERFORM pg_temp.zz3_log(10, 'Abonnement conservé après archivage de l''hôtel', 'FAIL', format('%s ligne(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(10, 'Abonnement conservé après archivage de l''hôtel', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11. Historique (platform_logs) conservé pour toutes les mutations de ce lot
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_hotel_id uuid; v_count int;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_hotel_id := ((public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST Audit'), v_plan))->'hotel'->>'id')::uuid;
  PERFORM public.admin_set_hotel_status(v_hotel_id, 'suspended');
  SELECT count(*) INTO v_count FROM public.platform_logs
    WHERE entity_id = v_hotel_id::text AND action IN ('hotel.create_with_subscription','hotel.status_change');
  IF v_count = 2 THEN
    PERFORM pg_temp.zz3_log(11, 'Audit : création + changement de statut journalisés', 'PASS', '2 entrées platform_logs');
  ELSE
    PERFORM pg_temp.zz3_log(11, 'Audit : création + changement de statut journalisés', 'FAIL', format('%s entrée(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(11, 'Audit : création + changement de statut journalisés', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. ACL : les 11 RPC du périmètre sont fermées à PUBLIC/anon/service_role
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_remaining int;
BEGIN
  SELECT count(*) INTO v_remaining FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('admin_create_hotel','admin_update_hotel','admin_update_hotel_full','admin_set_hotel_status',
                       'admin_create_group','admin_update_group','admin_delete_group','admin_attach_hotel_to_group',
                       'admin_detach_hotel_from_group','admin_restore_group','admin_create_hotel_with_subscription')
    AND a.privilege_type = 'EXECUTE'
    AND (a.grantee = 0 OR a.grantee IN (
      (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
      (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
    ));
  IF v_remaining = 0 THEN
    PERFORM pg_temp.zz3_log(12, 'ACL : 11 RPC hôtels/groupes fermées à PUBLIC/anon/service_role', 'PASS', 'aucun privilège résiduel');
  ELSE
    PERFORM pg_temp.zz3_log(12, 'ACL : 11 RPC hôtels/groupes fermées à PUBLIC/anon/service_role', 'FAIL', format('%s privilège(s) résiduel(s)', v_remaining));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(12, 'ACL : 11 RPC hôtels/groupes fermées à PUBLIC/anon/service_role', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. Refus anon (has_function_privilege) sur les 2 nouvelles RPC
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT has_function_privilege('anon', 'public.admin_restore_group(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.admin_create_hotel_with_subscription(jsonb,uuid,text,text,text)', 'EXECUTE') THEN
    PERFORM pg_temp.zz3_log(13, 'Refus anon sur les 2 nouvelles RPC', 'PASS', 'has_function_privilege = false');
  ELSE
    PERFORM pg_temp.zz3_log(13, 'Refus anon sur les 2 nouvelles RPC', 'FAIL', 'privilège anon résiduel détecté');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(13, 'Refus anon sur les 2 nouvelles RPC', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14. Refus utilisateur authenticated non Super Admin
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_failed boolean := false;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_nonadmin());
  BEGIN
    PERFORM public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST NonAdmin'), v_plan);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%Accès refusé%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz3_log(14, 'Refus authenticated non Super Admin', 'PASS', 'Accès refusé confirmé');
  ELSE
    PERFORM pg_temp.zz3_log(14, 'Refus authenticated non Super Admin', 'FAIL', 'pas de refus 42501');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(14, 'Refus authenticated non Super Admin', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 15. Autorisation Super Admin (contrôle positif, cycle complet en une session)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_plan uuid; v_res jsonb;
BEGIN
  v_plan := pg_temp.zz3_mk_plan();
  PERFORM pg_temp.zz3_as(pg_temp.zz3_mk_admin());
  v_res := public.admin_create_hotel_with_subscription(jsonb_build_object('name','ZZ3TEST OK Admin'), v_plan);
  IF (v_res->'hotel'->>'id') IS NOT NULL THEN
    PERFORM pg_temp.zz3_log(15, 'Autorisation Super Admin (contrôle positif)', 'PASS', 'création réussie pour un Super Admin');
  ELSE
    PERFORM pg_temp.zz3_log(15, 'Autorisation Super Admin (contrôle positif)', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz3_log(15, 'Autorisation Super Admin (contrôle positif)', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_total int; v_failed int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status <> 'PASS') INTO v_total, v_failed FROM zz3_results;
  RAISE NOTICE 'Suite Lot 2 : % scénarios, % échec(s).', v_total, v_failed;
  IF v_failed > 0 THEN
    RAISE EXCEPTION 'Suite Lot 2 : % échec(s) sur % scénarios — voir zz3_results.', v_failed, v_total;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz3_results ORDER BY test_no;

ROLLBACK;
