-- sql/tests/phase2d_lot3_users_access.sql
-- Suite de tests Lot 3 (sql/73_super_admin_phase2d_lot3_users_access.sql).
-- Convention du projet : BEGIN...ROLLBACK, chaque scénario est un DO $$ ... $$ indépendant.

BEGIN;

CREATE TEMP TABLE zz4_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz4_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz4_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz4_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.zz4_mk_hotel(p_status text DEFAULT 'active') RETURNS uuid AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.hotels(name, status) VALUES ('ZZ4TEST-' || gen_random_uuid()::text, p_status) RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz4_mk_admin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.platform_admins(auth_id, email, role, is_active)
    VALUES (v_auth, 'zz4test-admin-' || v_auth::text || '@example.invalid', 'super_admin', true);
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz4_mk_nonadmin() RETURNS uuid AS $$
DECLARE v_auth uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  RETURN v_auth;
END; $$ LANGUAGE plpgsql;

-- Crée un employé (public.users) rattaché à un hôtel "domicile" — indépendant de user_hotels.
CREATE OR REPLACE FUNCTION pg_temp.zz4_mk_user(p_home_hotel uuid, p_active boolean DEFAULT true) RETURNS uuid AS $$
DECLARE v_auth uuid; v_id uuid;
BEGIN
  INSERT INTO auth.users(id) VALUES (gen_random_uuid()) RETURNING id INTO v_auth;
  INSERT INTO public.users(auth_id, hotel_id, email, full_name, role, is_active)
    VALUES (v_auth, p_home_hotel, 'zz4test-user-' || v_auth::text || '@example.invalid', 'ZZ4TEST User', 'reception', p_active)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.zz4_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 1. Création d'un rattachement utilisateur/hôtel
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_count int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  SELECT count(*) INTO v_count FROM public.user_hotels WHERE user_id = v_user AND hotel_id = v_hotel;
  IF v_count = 1 THEN
    PERFORM pg_temp.zz4_log(1, 'Création d''un rattachement utilisateur/hôtel', 'PASS', '1 ligne user_hotels');
  ELSE
    PERFORM pg_temp.zz4_log(1, 'Création d''un rattachement utilisateur/hôtel', 'FAIL', format('%s ligne(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(1, 'Création d''un rattachement utilisateur/hôtel', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Doublon : deuxième appel = upsert (1 ligne, rôle mis à jour), jamais 2 lignes
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_count int; v_role text;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'direction');
  SELECT count(*), max(role::text) INTO v_count, v_role FROM public.user_hotels WHERE user_id = v_user AND hotel_id = v_hotel;
  IF v_count = 1 AND v_role = 'direction' THEN
    PERFORM pg_temp.zz4_log(2, 'Doublon absorbé en upsert (jamais 2 lignes)', 'PASS', 'rôle mis à jour sur la même ligne');
  ELSE
    PERFORM pg_temp.zz4_log(2, 'Doublon absorbé en upsert (jamais 2 lignes)', 'FAIL', format('count=%s role=%s', v_count, v_role));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(2, 'Doublon absorbé en upsert (jamais 2 lignes)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Affectation multi-hôtel
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_a uuid; v_b uuid; v_user uuid; v_count int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_a := pg_temp.zz4_mk_hotel(); v_b := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_a, 'reception');
  PERFORM public.admin_grant_hotel(v_user, v_b, 'reception');
  SELECT count(*) INTO v_count FROM public.user_hotels WHERE user_id = v_user;
  IF v_count = 2 THEN
    PERFORM pg_temp.zz4_log(3, 'Affectation multi-hôtel', 'PASS', '2 hôtels rattachés simultanément');
  ELSE
    PERFORM pg_temp.zz4_log(3, 'Affectation multi-hôtel', 'FAIL', format('%s hôtel(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(3, 'Affectation multi-hôtel', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 4. Retrait d'un seul hôtel sans affecter les autres
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_a uuid; v_b uuid; v_user uuid; v_remaining uuid;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_a := pg_temp.zz4_mk_hotel(); v_b := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_a, 'reception');
  PERFORM public.admin_grant_hotel(v_user, v_b, 'reception');
  PERFORM public.admin_revoke_hotel(v_user, v_a);
  SELECT hotel_id INTO v_remaining FROM public.user_hotels WHERE user_id = v_user;
  IF v_remaining = v_b THEN
    PERFORM pg_temp.zz4_log(4, 'Retrait d''un seul hôtel sans affecter les autres', 'PASS', 'hôtel B conservé, A retiré');
  ELSE
    PERFORM pg_temp.zz4_log(4, 'Retrait d''un seul hôtel sans affecter les autres', 'FAIL', format('restant=%s', v_remaining));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(4, 'Retrait d''un seul hôtel sans affecter les autres', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Changement de rôle
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_role text;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  PERFORM public.admin_set_hotel_role(v_user, v_hotel, 'direction');
  SELECT role::text INTO v_role FROM public.user_hotels WHERE user_id = v_user AND hotel_id = v_hotel;
  IF v_role = 'direction' THEN
    PERFORM pg_temp.zz4_log(5, 'Changement de rôle', 'PASS', 'reception -> direction');
  ELSE
    PERFORM pg_temp.zz4_log(5, 'Changement de rôle', 'FAIL', v_role);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(5, 'Changement de rôle', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Affectation groupe (en masse sur les hôtels actuels du groupe)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_group uuid; v_h1 uuid; v_h2 uuid; v_user uuid; v_count int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  v_group := (public.admin_create_group(jsonb_build_object('name','ZZ4TEST Groupe-'||gen_random_uuid()::text))->>'id')::uuid;
  v_h1 := pg_temp.zz4_mk_hotel(); v_h2 := pg_temp.zz4_mk_hotel();
  PERFORM public.admin_attach_hotel_to_group(v_h1, v_group);
  PERFORM public.admin_attach_hotel_to_group(v_h2, v_group);
  PERFORM public.admin_grant_hotel_group_access(v_user, v_group, 'reception');
  SELECT count(*) INTO v_count FROM public.user_hotels WHERE user_id = v_user AND hotel_id IN (v_h1, v_h2);
  IF v_count = 2 THEN
    PERFORM pg_temp.zz4_log(6, 'Affectation groupe (en masse)', 'PASS', 'accès accordé sur les 2 hôtels du groupe');
  ELSE
    PERFORM pg_temp.zz4_log(6, 'Affectation groupe (en masse)', 'FAIL', format('%s hôtel(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(6, 'Affectation groupe (en masse)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Retrait groupe (en masse)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_group uuid; v_h1 uuid; v_h2 uuid; v_user uuid; v_count int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  v_group := (public.admin_create_group(jsonb_build_object('name','ZZ4TEST Groupe2-'||gen_random_uuid()::text))->>'id')::uuid;
  v_h1 := pg_temp.zz4_mk_hotel(); v_h2 := pg_temp.zz4_mk_hotel();
  PERFORM public.admin_attach_hotel_to_group(v_h1, v_group);
  PERFORM public.admin_attach_hotel_to_group(v_h2, v_group);
  PERFORM public.admin_grant_hotel_group_access(v_user, v_group, 'reception');
  PERFORM public.admin_revoke_hotel_group_access(v_user, v_group);
  SELECT count(*) INTO v_count FROM public.user_hotels WHERE user_id = v_user AND hotel_id IN (v_h1, v_h2);
  IF v_count = 0 THEN
    PERFORM pg_temp.zz4_log(7, 'Retrait groupe (en masse)', 'PASS', 'accès retiré sur les 2 hôtels du groupe');
  ELSE
    PERFORM pg_temp.zz4_log(7, 'Retrait groupe (en masse)', 'FAIL', format('%s ligne(s) restante(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(7, 'Retrait groupe (en masse)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Désactivation puis réactivation d'un utilisateur
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_user uuid; v_active1 boolean; v_active2 boolean;
BEGIN
  v_home := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_set_user_status(v_user, false);
  SELECT is_active INTO v_active1 FROM public.users WHERE id = v_user;
  PERFORM public.admin_set_user_status(v_user, true);
  SELECT is_active INTO v_active2 FROM public.users WHERE id = v_user;
  IF v_active1 = false AND v_active2 = true THEN
    PERFORM pg_temp.zz4_log(8, 'Désactivation puis réactivation d''un utilisateur', 'PASS', 'false puis true confirmés');
  ELSE
    PERFORM pg_temp.zz4_log(8, 'Désactivation puis réactivation d''un utilisateur', 'FAIL', format('%s / %s', v_active1, v_active2));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(8, 'Désactivation puis réactivation d''un utilisateur', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Promotion Super Admin (utilisateur déjà existant dans auth.users)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_target_auth uuid; v_row jsonb;
BEGIN
  v_target_auth := pg_temp.zz4_mk_nonadmin();
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  v_row := public.admin_grant_platform_admin(v_target_auth, 'super_admin', 'Test promotion');
  IF (v_row->>'is_active')::boolean = true AND (v_row->>'role') = 'super_admin' THEN
    PERFORM pg_temp.zz4_log(9, 'Promotion Super Admin', 'PASS', 'ligne platform_admins créée/activée');
  ELSE
    PERFORM pg_temp.zz4_log(9, 'Promotion Super Admin', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(9, 'Promotion Super Admin', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 10. Retrait Super Admin (avec un second Super Admin actif en parallèle)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_admin1 uuid; v_admin2_auth uuid; v_row jsonb;
BEGIN
  v_admin1 := pg_temp.zz4_mk_admin();
  v_admin2_auth := pg_temp.zz4_mk_nonadmin();
  PERFORM pg_temp.zz4_as(v_admin1);
  v_row := public.admin_grant_platform_admin(v_admin2_auth, 'super_admin', 'Second admin pour test retrait');
  v_row := public.admin_revoke_platform_admin(v_admin2_auth, 'Fin de test');
  IF (v_row->>'is_active')::boolean = false THEN
    PERFORM pg_temp.zz4_log(10, 'Retrait Super Admin (autre admin restant)', 'PASS', 'is_active=false confirmé');
  ELSE
    PERFORM pg_temp.zz4_log(10, 'Retrait Super Admin (autre admin restant)', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(10, 'Retrait Super Admin (autre admin restant)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 11. Interdiction de retirer le DERNIER Super Admin actif
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_admin uuid; v_failed boolean := false; v_others uuid[];
BEGIN
  v_admin := pg_temp.zz4_mk_admin();
  -- Neutralise temporairement tout AUTRE super_admin actif — réel (production) ou créé par les
  -- tests précédents dans cette même transaction (9 et 10 en ont créé) — pour isoler
  -- authentiquement le scénario "dernier Super Admin". Restauré explicitement ci-dessous, quel
  -- que soit le résultat ; de toute façon la suite entière tourne sous ROLLBACK final, rien ne
  -- persiste, mais la restauration évite de fausser les tests suivants dans cette transaction.
  SELECT array_agg(auth_id) INTO v_others FROM public.platform_admins
    WHERE auth_id <> v_admin AND role = 'super_admin' AND is_active = true;
  UPDATE public.platform_admins SET is_active = false
    WHERE auth_id <> v_admin AND role = 'super_admin' AND is_active = true;

  PERFORM pg_temp.zz4_as(v_admin);
  BEGIN
    PERFORM public.admin_revoke_platform_admin(v_admin, 'Tentative de se retirer soi-même, seul admin');
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%dernier Super Admin%';
  END;

  IF v_others IS NOT NULL THEN
    UPDATE public.platform_admins SET is_active = true WHERE auth_id = ANY(v_others);
  END IF;

  IF v_failed THEN
    PERFORM pg_temp.zz4_log(11, 'Interdiction de retirer le dernier Super Admin', 'PASS', 'exception levée comme attendu, autres admins restaurés');
  ELSE
    PERFORM pg_temp.zz4_log(11, 'Interdiction de retirer le dernier Super Admin', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(11, 'Interdiction de retirer le dernier Super Admin', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 12. Interdiction de retirer le dernier admin_hotel sans remplaçant, puis avec remplaçant
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user1 uuid; v_user2 uuid; v_failed boolean := false; v_count_after int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user1 := pg_temp.zz4_mk_user(v_home); v_user2 := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user1, v_hotel, 'admin_hotel');
  -- Neutralise l'effet du trigger historique trg_grant_superadmin_on_new_hotel (découvert lors
  -- de la validation : il accorde automatiquement un accès 'direction' au Super Admin réel le
  -- plus ancien sur TOUT nouvel hôtel, dès qu'un tel admin possède une ligne public.users).
  -- Sans ce nettoyage, ce test ne pourrait jamais observer un hôtel n'ayant qu'un seul
  -- administrateur. Portée strictement limitée à cet hôtel de test fraîchement créé.
  DELETE FROM public.user_hotels WHERE hotel_id = v_hotel AND user_id <> v_user1 AND role IN ('direction','admin_hotel');
  BEGIN
    PERFORM public.admin_revoke_hotel(v_user1, v_hotel);
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%sans administrateur%';
  END;
  IF NOT v_failed THEN
    PERFORM pg_temp.zz4_log(12, 'Dernier admin_hotel protégé, remplacement possible', 'FAIL', 'pas de refus sans remplaçant');
    RETURN;
  END IF;
  PERFORM public.admin_revoke_hotel(v_user1, v_hotel, v_user2);
  SELECT count(*) INTO v_count_after FROM public.user_hotels WHERE hotel_id = v_hotel AND role IN ('direction','admin_hotel');
  IF v_count_after = 1 THEN
    PERFORM pg_temp.zz4_log(12, 'Dernier admin_hotel protégé, remplacement possible', 'PASS', 'refus initial confirmé, remplacement réussi ensuite');
  ELSE
    PERFORM pg_temp.zz4_log(12, 'Dernier admin_hotel protégé, remplacement possible', 'FAIL', format('%s admin(s) après remplacement', v_count_after));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(12, 'Dernier admin_hotel protégé, remplacement possible', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 13. Interdiction d'attribuer un accès à un hôtel archivé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_failed boolean := false;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel('archived');
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  BEGIN
    PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%archivé%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz4_log(13, 'Interdiction d''accès à un hôtel archivé', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz4_log(13, 'Interdiction d''accès à un hôtel archivé', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(13, 'Interdiction d''accès à un hôtel archivé', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 14. Interdiction d'attribuer un accès à un utilisateur désactivé
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_failed boolean := false;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home, false);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  BEGIN
    PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%désactivé%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz4_log(14, 'Interdiction d''accès pour un utilisateur désactivé', 'PASS', 'exception levée comme attendu');
  ELSE
    PERFORM pg_temp.zz4_log(14, 'Interdiction d''accès pour un utilisateur désactivé', 'FAIL', 'aucune exception levée');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(14, 'Interdiction d''accès pour un utilisateur désactivé', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 15. Conservation de l'historique (platform_logs pour chaque mutation)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_count int;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  PERFORM public.admin_revoke_hotel(v_user, v_hotel);
  SELECT count(*) INTO v_count FROM public.platform_logs
    WHERE entity_id = v_user::text AND action IN ('user.grant_hotel','user.revoke_hotel');
  IF v_count = 2 THEN
    PERFORM pg_temp.zz4_log(15, 'Historique conservé pour chaque mutation', 'PASS', '2 entrées platform_logs');
  ELSE
    PERFORM pg_temp.zz4_log(15, 'Historique conservé pour chaque mutation', 'FAIL', format('%s entrée(s)', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(15, 'Historique conservé pour chaque mutation', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 16. Refus utilisateur authenticated non Super Admin
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid; v_failed boolean := false;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_nonadmin());
  BEGIN
    PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  EXCEPTION WHEN OTHERS THEN v_failed := SQLERRM LIKE '%Accès refusé%';
  END;
  IF v_failed THEN
    PERFORM pg_temp.zz4_log(16, 'Refus authenticated non Super Admin', 'PASS', 'Accès refusé confirmé');
  ELSE
    PERFORM pg_temp.zz4_log(16, 'Refus authenticated non Super Admin', 'FAIL', 'pas de refus 42501');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(16, 'Refus authenticated non Super Admin', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 17. ACL : les 9 RPC neuves/corrigées sont fermées à PUBLIC/anon/service_role
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_remaining int;
BEGIN
  SELECT count(*) INTO v_remaining FROM pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('admin_grant_hotel','admin_revoke_hotel','admin_set_hotel_role','admin_list_user_access',
                       'admin_set_app_access','admin_set_user_status','admin_list_unlinked_auth_users',
                       'admin_grant_platform_admin','admin_revoke_platform_admin',
                       'admin_grant_hotel_group_access','admin_revoke_hotel_group_access')
    AND a.privilege_type = 'EXECUTE'
    AND (a.grantee = 0 OR a.grantee IN (
      (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
      (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
    ));
  IF v_remaining = 0 THEN
    PERFORM pg_temp.zz4_log(17, 'ACL : RPC utilisateurs fermées à PUBLIC/anon/service_role', 'PASS', 'aucun privilège résiduel');
  ELSE
    PERFORM pg_temp.zz4_log(17, 'ACL : RPC utilisateurs fermées à PUBLIC/anon/service_role', 'FAIL', format('%s privilège(s) résiduel(s)', v_remaining));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(17, 'ACL : RPC utilisateurs fermées à PUBLIC/anon/service_role', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 18. Helper interne _admin_sync_user_default_role inaccessible aux rôles clients
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT has_function_privilege('anon', 'public._admin_sync_user_default_role(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._admin_sync_user_default_role(uuid)', 'EXECUTE') THEN
    PERFORM pg_temp.zz4_log(18, 'Helper interne inaccessible aux rôles clients', 'PASS', 'has_function_privilege = false');
  ELSE
    PERFORM pg_temp.zz4_log(18, 'Helper interne inaccessible aux rôles clients', 'FAIL', 'privilège résiduel détecté');
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(18, 'Helper interne inaccessible aux rôles clients', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 19. Autorisation Super Admin (contrôle positif, cycle complet)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_home uuid; v_hotel uuid; v_user uuid;
BEGIN
  v_home := pg_temp.zz4_mk_hotel(); v_hotel := pg_temp.zz4_mk_hotel();
  v_user := pg_temp.zz4_mk_user(v_home);
  PERFORM pg_temp.zz4_as(pg_temp.zz4_mk_admin());
  PERFORM public.admin_grant_hotel(v_user, v_hotel, 'reception');
  PERFORM public.admin_set_hotel_role(v_user, v_hotel, 'direction');
  PERFORM public.admin_set_user_status(v_user, false);
  PERFORM public.admin_set_user_status(v_user, true);
  PERFORM public.admin_revoke_hotel(v_user, v_hotel);
  PERFORM pg_temp.zz4_log(19, 'Autorisation Super Admin (cycle complet)', 'PASS', 'grant/set_role/deactivate/reactivate/revoke réussissent en séquence');
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz4_log(19, 'Autorisation Super Admin (cycle complet)', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE v_total int; v_failed int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status <> 'PASS') INTO v_total, v_failed FROM zz4_results;
  RAISE NOTICE 'Suite Lot 3 : % scénarios, % échec(s).', v_total, v_failed;
  IF v_failed > 0 THEN
    RAISE EXCEPTION 'Suite Lot 3 : % échec(s) sur % scénarios — voir zz4_results.', v_failed, v_total;
  END IF;
END $$;

SELECT test_no, name, status, detail FROM zz4_results ORDER BY test_no;

ROLLBACK;
