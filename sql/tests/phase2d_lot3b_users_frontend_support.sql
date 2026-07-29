-- Tests pour sql/74_super_admin_phase2d_lot3b_users_frontend_support.sql
-- Exécuté à l'intérieur d'un BEGIN...ROLLBACK (jamais committé). Pattern identique aux suites
-- précédentes : helpers pg_temp préfixés zz5_, résultats accumulés dans une table temporaire,
-- RAISE EXCEPTION final si au moins un FAIL (neutralisé en RAISE NOTICE lors des validations
-- combinées, jamais dans le fichier committé lui-même).

BEGIN;

CREATE TEMP TABLE zz5_results(test_no int, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz5_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
BEGIN INSERT INTO zz5_results VALUES (p_no, p_name, p_status, p_detail); END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz5_mk_hotel() RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels (id, name, status, hotel_code)
  VALUES (gen_random_uuid(), 'ZZ5 Hotel '||substr(gen_random_uuid()::text,1,6), 'active', upper(substr(gen_random_uuid()::text,1,5)))
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz5_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins (auth_id, email, role, is_active)
  VALUES (v_auth, 'zz5admin-'||v_auth::text||'@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz5_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz5_mk_user(p_hotel uuid) RETURNS uuid AS $$
DECLARE v_auth uuid; v_id uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.users (auth_id, hotel_id, email, full_name, role, is_active)
  VALUES (v_auth, p_hotel, 'zz5user-'||v_auth::text||'@example.invalid', 'ZZ5 User', 'reception', true)
  RETURNING id INTO v_id;
  INSERT INTO public.user_hotels (user_id, hotel_id, role, is_default) VALUES (v_id, p_hotel, 'reception', true);
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz5_as(p_auth uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth)::text, true);
$$ LANGUAGE sql;

-- Test 1 : Super Admin SANS ligne public.users apparaît dans admin_list_user_access
DO $$
DECLARE v_admin uuid; v_found record;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  PERFORM pg_temp.zz5_as(v_admin);
  SELECT * INTO v_found FROM public.admin_list_user_access() WHERE auth_id = v_admin AND is_platform_only = true;
  IF v_found.auth_id = v_admin AND v_found.is_super_admin = true AND v_found.user_id IS NULL THEN
    PERFORM pg_temp.zz5_log(1, 'Super Admin sans profil users listé (is_platform_only)', 'PASS', 'trouvé, user_id NULL comme attendu');
  ELSE
    PERFORM pg_temp.zz5_log(1, 'Super Admin sans profil users listé (is_platform_only)', 'FAIL', 'non trouvé ou champs incorrects');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(1, 'Super Admin sans profil users listé (is_platform_only)', 'FAIL', SQLERRM);
END $$;

-- Test 2 : group_names peuplé pour un utilisateur dont l'hôtel appartient à un groupe
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_group uuid; v_user uuid; v_row record;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  v_hotel := pg_temp.zz5_mk_hotel();
  INSERT INTO public.hotel_groups (id, name, status) VALUES (gen_random_uuid(), 'ZZ5 Group', 'active') RETURNING id INTO v_group;
  UPDATE public.hotels SET group_id = v_group WHERE id = v_hotel;
  v_user := pg_temp.zz5_mk_user(v_hotel);

  PERFORM pg_temp.zz5_as(v_admin);
  SELECT * INTO v_row FROM public.admin_list_user_access() WHERE user_id = v_user;
  IF v_row.group_names @> '["ZZ5 Group"]'::jsonb THEN
    PERFORM pg_temp.zz5_log(2, 'group_names peuplé depuis les hôtels rattachés', 'PASS', v_row.group_names::text);
  ELSE
    PERFORM pg_temp.zz5_log(2, 'group_names peuplé depuis les hôtels rattachés', 'FAIL', coalesce(v_row.group_names::text,'NULL'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(2, 'group_names peuplé depuis les hôtels rattachés', 'FAIL', SQLERRM);
END $$;

-- Test 3 : admin_get_user_detail renvoie les 5 sections pour un utilisateur normal
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_user uuid; v_detail jsonb;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  v_hotel := pg_temp.zz5_mk_hotel();
  v_user := pg_temp.zz5_mk_user(v_hotel);

  PERFORM pg_temp.zz5_as(v_admin);
  v_detail := public.admin_get_user_detail(v_user);

  IF v_detail ? 'identity' AND v_detail ? 'hotel_access' AND v_detail ? 'group_access'
     AND v_detail ? 'platform_role' AND v_detail ? 'history'
     AND jsonb_array_length(v_detail->'hotel_access') = 1
     AND (v_detail->'hotel_access'->0->>'hotel_id') = v_hotel::text
  THEN
    PERFORM pg_temp.zz5_log(3, 'admin_get_user_detail : 5 sections + accès hôtel correct', 'PASS', '1 hôtel retrouvé');
  ELSE
    PERFORM pg_temp.zz5_log(3, 'admin_get_user_detail : 5 sections + accès hôtel correct', 'FAIL', v_detail::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(3, 'admin_get_user_detail : 5 sections + accès hôtel correct', 'FAIL', SQLERRM);
END $$;

-- Test 4 : admin_get_user_detail refuse un appelant non-admin
DO $$
DECLARE v_plain uuid; v_hotel uuid; v_user uuid; v_failed boolean := false;
BEGIN
  v_plain := pg_temp.zz5_mk_nonadmin();
  v_hotel := pg_temp.zz5_mk_hotel();
  v_user := pg_temp.zz5_mk_user(v_hotel);

  PERFORM pg_temp.zz5_as(v_plain);
  BEGIN
    PERFORM public.admin_get_user_detail(v_user);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLSTATE = '42501';
  END;

  IF v_failed THEN
    PERFORM pg_temp.zz5_log(4, 'admin_get_user_detail refuse un utilisateur non-admin', 'PASS', 'errcode 42501 confirmé');
  ELSE
    PERFORM pg_temp.zz5_log(4, 'admin_get_user_detail refuse un utilisateur non-admin', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(4, 'admin_get_user_detail refuse un utilisateur non-admin', 'FAIL', SQLERRM);
END $$;

-- Test 5 : admin_get_user_detail sur un utilisateur inexistant lève P0002
DO $$
DECLARE v_admin uuid; v_failed boolean := false;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  PERFORM pg_temp.zz5_as(v_admin);
  BEGIN
    PERFORM public.admin_get_user_detail(gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_failed := SQLSTATE = 'P0002';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz5_log(5, 'admin_get_user_detail : utilisateur inexistant refusé (P0002)', 'PASS', 'errcode P0002 confirmé');
  ELSE
    PERFORM pg_temp.zz5_log(5, 'admin_get_user_detail : utilisateur inexistant refusé (P0002)', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(5, 'admin_get_user_detail : utilisateur inexistant refusé (P0002)', 'FAIL', SQLERRM);
END $$;

-- Test 6 : admin_set_hotel_role journalise désormais le changement (visible dans l'historique fiche)
DO $$
DECLARE v_admin uuid; v_hotel uuid; v_user uuid; v_detail jsonb; v_found boolean;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  v_hotel := pg_temp.zz5_mk_hotel();
  v_user := pg_temp.zz5_mk_user(v_hotel);

  PERFORM pg_temp.zz5_as(v_admin);
  PERFORM public.admin_set_hotel_role(v_user, v_hotel, 'direction');
  v_detail := public.admin_get_user_detail(v_user);

  SELECT EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_detail->'history') e WHERE e->>'action' = 'user.change_role'
  ) INTO v_found;

  IF v_found AND (v_detail->'hotel_access'->0->>'role') = 'direction' THEN
    PERFORM pg_temp.zz5_log(6, 'admin_set_hotel_role journalise le changement de rôle', 'PASS', 'entrée user.change_role présente, rôle mis à jour');
  ELSE
    PERFORM pg_temp.zz5_log(6, 'admin_set_hotel_role journalise le changement de rôle', 'FAIL', v_detail::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(6, 'admin_set_hotel_role journalise le changement de rôle', 'FAIL', SQLERRM);
END $$;

-- Test 7 : ACL — admin_get_user_detail fermé à anon/service_role, ouvert à authenticated
DO $$
DECLARE v_anon boolean; v_svc boolean; v_auth boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.admin_get_user_detail(uuid)', 'EXECUTE') INTO v_anon;
  SELECT has_function_privilege('service_role', 'public.admin_get_user_detail(uuid)', 'EXECUTE') INTO v_svc;
  SELECT has_function_privilege('authenticated', 'public.admin_get_user_detail(uuid)', 'EXECUTE') INTO v_auth;
  IF NOT v_anon AND NOT v_svc AND v_auth THEN
    PERFORM pg_temp.zz5_log(7, 'ACL admin_get_user_detail : anon/service_role fermés, authenticated ouvert', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz5_log(7, 'ACL admin_get_user_detail : anon/service_role fermés, authenticated ouvert', 'FAIL',
      format('anon=%s service_role=%s authenticated=%s', v_anon, v_svc, v_auth));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(7, 'ACL admin_get_user_detail : anon/service_role fermés, authenticated ouvert', 'FAIL', SQLERRM);
END $$;

-- Test 8 : ACL — admin_list_user_access fermé à anon/service_role, ouvert à authenticated
-- (re-vérifié après le DROP+CREATE de cette migration, qui réinitialise les privilèges par défaut)
DO $$
DECLARE v_anon boolean; v_svc boolean; v_auth boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.admin_list_user_access()', 'EXECUTE') INTO v_anon;
  SELECT has_function_privilege('service_role', 'public.admin_list_user_access()', 'EXECUTE') INTO v_svc;
  SELECT has_function_privilege('authenticated', 'public.admin_list_user_access()', 'EXECUTE') INTO v_auth;
  IF NOT v_anon AND NOT v_svc AND v_auth THEN
    PERFORM pg_temp.zz5_log(8, 'ACL admin_list_user_access : anon/service_role fermés, authenticated ouvert', 'PASS', 'conforme');
  ELSE
    PERFORM pg_temp.zz5_log(8, 'ACL admin_list_user_access : anon/service_role fermés, authenticated ouvert', 'FAIL',
      format('anon=%s service_role=%s authenticated=%s', v_anon, v_svc, v_auth));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(8, 'ACL admin_list_user_access : anon/service_role fermés, authenticated ouvert', 'FAIL', SQLERRM);
END $$;

-- Test 9 : group_access dérivé — hôtel_count cohérent (1 accessible sur 2 dans le groupe)
DO $$
DECLARE v_admin uuid; v_group uuid; v_hotel1 uuid; v_hotel2 uuid; v_user uuid; v_detail jsonb; v_g jsonb;
BEGIN
  v_admin := pg_temp.zz5_mk_admin();
  INSERT INTO public.hotel_groups (id, name, status) VALUES (gen_random_uuid(), 'ZZ5 Group2', 'active') RETURNING id INTO v_group;
  v_hotel1 := pg_temp.zz5_mk_hotel(); UPDATE public.hotels SET group_id = v_group WHERE id = v_hotel1;
  v_hotel2 := pg_temp.zz5_mk_hotel(); UPDATE public.hotels SET group_id = v_group WHERE id = v_hotel2;
  v_user := pg_temp.zz5_mk_user(v_hotel1);

  PERFORM pg_temp.zz5_as(v_admin);
  v_detail := public.admin_get_user_detail(v_user);
  SELECT e INTO v_g FROM jsonb_array_elements(v_detail->'group_access') e WHERE e->>'group_id' = v_group::text;

  IF (v_g->>'accessible_hotel_count')::int = 1 AND (v_g->>'total_hotel_count')::int = 2 THEN
    PERFORM pg_temp.zz5_log(9, 'group_access : comptage accessible/total cohérent', 'PASS', v_g::text);
  ELSE
    PERFORM pg_temp.zz5_log(9, 'group_access : comptage accessible/total cohérent', 'FAIL', coalesce(v_g::text,'NULL'));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz5_log(9, 'group_access : comptage accessible/total cohérent', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_fail_count int;
BEGIN
  SELECT count(*) INTO v_fail_count FROM zz5_results WHERE status = 'FAIL';
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'ECHEC DE % TEST(S)', v_fail_count;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz5_results ORDER BY test_no;

ROLLBACK;
