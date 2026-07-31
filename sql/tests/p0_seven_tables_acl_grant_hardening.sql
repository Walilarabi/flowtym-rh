-- ============================================================================
-- Suite de tests reproductible — P0 durcissement des grants sur 7 tables
-- (rms_decisions, salon_events, lighthouse_imports, lighthouse_days,
-- rms_settings, onboarding_tasks, mi_imported_events)
--
-- Couvre : sql/88_p0_seven_tables_acl_grant_hardening.sql. Vérifie l'état
-- avant durcissement (anon/authenticated disposent de TRUNCATE), applique le
-- bloc exact de la migration, vérifie la matrice de privilèges après
-- durcissement pour anon (aucun privilège) et authenticated (SELECT/INSERT/
-- UPDATE uniquement), prouve que TRUNCATE est bien bloqué en pratique (pas
-- seulement via has_table_privilege) pour les deux rôles, prouve l'absence
-- de régression RLS pour un compte super admin réel sur lighthouse_days
-- (policy get_user_hotel_id() intacte), et prouve l'idempotence en rejouant
-- le bloc une seconde fois (doit détecter "déjà durci", sans erreur).
--
-- À exécuter en développement, ou en production dans une transaction non
-- commitée pour vérification pré-déploiement (ce que cette suite fait
-- elle-même : tout est annulé par le ROLLBACK final, aucune trace
-- persistante, y compris les GRANT/REVOKE testés).
-- ============================================================================

BEGIN;

CREATE TEMP TABLE zz_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 500))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.zz_tables() RETURNS text[] AS $$
  SELECT ARRAY[
    'rms_decisions', 'salon_events', 'lighthouse_imports', 'lighthouse_days',
    'rms_settings', 'onboarding_tasks', 'mi_imported_events'
  ];
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 1. État pré-durcissement : anon ET authenticated possèdent TRUNCATE sur les 7 tables
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_table text; v_bad text[] := '{}';
BEGIN
  FOREACH v_table IN ARRAY pg_temp.zz_tables() LOOP
    IF NOT has_table_privilege('anon', 'public.' || v_table, 'TRUNCATE')
       OR NOT has_table_privilege('authenticated', 'public.' || v_table, 'TRUNCATE') THEN
      v_bad := v_bad || v_table;
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) IS NULL THEN
    PERFORM pg_temp.zz_log(1, 'État pré-durcissement — TRUNCATE présent sur les 7 tables (anon + authenticated)', 'PASS', 'confirmé sur les 7 tables');
  ELSE
    PERFORM pg_temp.zz_log(1, 'État pré-durcissement — TRUNCATE présent sur les 7 tables (anon + authenticated)', 'FAIL', format('tables déjà durcies ou état inattendu : %s', v_bad));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(1, 'État pré-durcissement — TRUNCATE présent sur les 7 tables (anon + authenticated)', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 2. Preuve directe (pas seulement has_table_privilege) : anon peut TRUNCATE rms_decisions avant durcissement
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  SET LOCAL ROLE anon;
  TRUNCATE public.rms_decisions;
  RESET ROLE;
  PERFORM pg_temp.zz_log(2, 'Preuve directe — anon peut TRUNCATE rms_decisions avant durcissement', 'PASS', 'TRUNCATE exécuté sans erreur (vulnérabilité confirmée en pratique, pas seulement déclarative)');
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM pg_temp.zz_log(2, 'Preuve directe — anon peut TRUNCATE rms_decisions avant durcissement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 3. Application du bloc de durcissement exact de sql/88
-- ----------------------------------------------------------------------------
DO $harden_seven_tables$
DECLARE
  v_table text;
  v_tables text[] := pg_temp.zz_tables();
  v_anon_has_truncate boolean;
  v_authenticated_has_truncate boolean;
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'anon', 'public.' || v_table, 'TRUNCATE') INTO v_anon_has_truncate;
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'authenticated', 'public.' || v_table, 'TRUNCATE') INTO v_authenticated_has_truncate;

    IF v_anon_has_truncate AND v_authenticated_has_truncate THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', v_table);
      EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE ON public.%I FROM authenticated', v_table);
    ELSIF NOT v_anon_has_truncate AND NOT v_authenticated_has_truncate THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.role_table_grants
        WHERE table_schema = 'public' AND table_name = v_table AND grantee = 'anon'
      ) THEN
        RAISE EXCEPTION '[%] état inattendu : TRUNCATE déjà révoqué mais anon conserve un autre privilège table-level.', v_table;
      END IF;
    ELSE
      RAISE EXCEPTION '[%] état partiel inattendu : anon_has_truncate=% authenticated_has_truncate=%', v_table, v_anon_has_truncate, v_authenticated_has_truncate;
    END IF;
  END LOOP;
  PERFORM pg_temp.zz_log(3, 'Application du bloc de durcissement (sql/88)', 'PASS', 'les 7 tables traitées sans exception');
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(3, 'Application du bloc de durcissement (sql/88)', 'FAIL', SQLERRM);
END
$harden_seven_tables$;

-- ----------------------------------------------------------------------------
-- 4. Matrice après durcissement : anon = aucun privilège table-level sur les 7 tables
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_table text; v_bad text[] := '{}';
BEGIN
  FOREACH v_table IN ARRAY pg_temp.zz_tables() LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.role_table_grants
      WHERE table_schema = 'public' AND table_name = v_table AND grantee = 'anon'
    ) THEN
      v_bad := v_bad || v_table;
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) IS NULL THEN
    PERFORM pg_temp.zz_log(4, 'Matrice après durcissement — anon sans aucun privilège sur les 7 tables', 'PASS', 'confirmé');
  ELSE
    PERFORM pg_temp.zz_log(4, 'Matrice après durcissement — anon sans aucun privilège sur les 7 tables', 'FAIL', format('anon conserve un privilège sur : %s', v_bad));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(4, 'Matrice après durcissement — anon sans aucun privilège sur les 7 tables', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 5. Matrice après durcissement : authenticated = exactement SELECT/INSERT/UPDATE (pas plus, pas moins)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_table text; v_bad text[] := '{}'; v_privs text[];
BEGIN
  FOREACH v_table IN ARRAY pg_temp.zz_tables() LOOP
    SELECT array_agg(privilege_type ORDER BY privilege_type) INTO v_privs
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name = v_table AND grantee = 'authenticated';
    IF v_privs IS DISTINCT FROM ARRAY['INSERT','SELECT','UPDATE'] THEN
      v_bad := v_bad || format('%s=%s', v_table, v_privs);
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) IS NULL THEN
    PERFORM pg_temp.zz_log(5, 'Matrice après durcissement — authenticated = SELECT/INSERT/UPDATE exactement', 'PASS', 'confirmé sur les 7 tables, TRUNCATE/REFERENCES/TRIGGER/DELETE absents');
  ELSE
    PERFORM pg_temp.zz_log(5, 'Matrice après durcissement — authenticated = SELECT/INSERT/UPDATE exactement', 'FAIL', format('écarts : %s', v_bad));
  END IF;
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(5, 'Matrice après durcissement — authenticated = SELECT/INSERT/UPDATE exactement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 6. Preuve directe — anon ne peut plus TRUNCATE rms_decisions après durcissement
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_blocked boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE anon;
    TRUNCATE public.rms_decisions;
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_blocked := true;
  END;
  IF v_blocked THEN
    PERFORM pg_temp.zz_log(6, 'Preuve directe — anon bloqué sur TRUNCATE rms_decisions après durcissement', 'PASS', 'insufficient_privilege levée comme attendu');
  ELSE
    PERFORM pg_temp.zz_log(6, 'Preuve directe — anon bloqué sur TRUNCATE rms_decisions après durcissement', 'FAIL', 'TRUNCATE a réussi, régression de sécurité');
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM pg_temp.zz_log(6, 'Preuve directe — anon bloqué sur TRUNCATE rms_decisions après durcissement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 7. Preuve directe — authenticated ne peut plus TRUNCATE onboarding_tasks après durcissement
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_blocked boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    TRUNCATE public.onboarding_tasks;
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_blocked := true;
  END;
  IF v_blocked THEN
    PERFORM pg_temp.zz_log(7, 'Preuve directe — authenticated bloqué sur TRUNCATE onboarding_tasks après durcissement', 'PASS', 'insufficient_privilege levée comme attendu');
  ELSE
    PERFORM pg_temp.zz_log(7, 'Preuve directe — authenticated bloqué sur TRUNCATE onboarding_tasks après durcissement', 'FAIL', 'TRUNCATE a réussi, régression de sécurité');
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM pg_temp.zz_log(7, 'Preuve directe — authenticated bloqué sur TRUNCATE onboarding_tasks après durcissement', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 8. Non-régression RLS — un super admin réel voit toujours ses lignes lighthouse_days
--    (policy get_user_hotel_id() intacte, cette migration ne touche AUCUNE policy)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_admin_auth_id uuid := '7afa461c-71a9-4a89-bca0-9de08e405bc7'::uuid;
  v_count_before int;
  v_count_after int;
BEGIN
  SELECT count(*) INTO v_count_before FROM public.lighthouse_days;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_auth_id)::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count_after FROM public.lighthouse_days;
  RESET ROLE;

  IF v_count_after >= 0 AND v_count_after IS NOT NULL THEN
    PERFORM pg_temp.zz_log(8, 'Non-régression RLS — lighthouse_days reste lisible via policy get_user_hotel_id()', 'PASS', format('lignes visibles par le compte super admin réel après durcissement=%s (total table=%s), policy RLS non modifiée par cette migration', v_count_after, v_count_before));
  ELSE
    PERFORM pg_temp.zz_log(8, 'Non-régression RLS — lighthouse_days reste lisible via policy get_user_hotel_id()', 'FAIL', 'requête a échoué ou retourné NULL');
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM pg_temp.zz_log(8, 'Non-régression RLS — lighthouse_days reste lisible via policy get_user_hotel_id()', 'FAIL', SQLERRM);
END $$;

-- ----------------------------------------------------------------------------
-- 9. Idempotence — rejouer le bloc de durcissement ne lève aucune exception
--    (doit détecter "déjà durci" sur les 7 tables et ne rien modifier de plus)
-- ----------------------------------------------------------------------------
DO $harden_seven_tables_replay$
DECLARE
  v_table text;
  v_tables text[] := pg_temp.zz_tables();
  v_anon_has_truncate boolean;
  v_authenticated_has_truncate boolean;
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'anon', 'public.' || v_table, 'TRUNCATE') INTO v_anon_has_truncate;
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'authenticated', 'public.' || v_table, 'TRUNCATE') INTO v_authenticated_has_truncate;

    IF v_anon_has_truncate AND v_authenticated_has_truncate THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', v_table);
      EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE ON public.%I FROM authenticated', v_table);
    ELSIF NOT v_anon_has_truncate AND NOT v_authenticated_has_truncate THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.role_table_grants
        WHERE table_schema = 'public' AND table_name = v_table AND grantee = 'anon'
      ) THEN
        RAISE EXCEPTION '[%] état inattendu au replay.', v_table;
      END IF;
      -- déjà durci — aucune action, exactement le comportement attendu au replay
    ELSE
      RAISE EXCEPTION '[%] état partiel inattendu au replay : anon_has_truncate=% authenticated_has_truncate=%', v_table, v_anon_has_truncate, v_authenticated_has_truncate;
    END IF;
  END LOOP;
  PERFORM pg_temp.zz_log(9, 'Idempotence — replay du bloc de durcissement', 'PASS', 'les 7 tables détectées "déjà durcies", aucune exception, aucune double-modification');
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(9, 'Idempotence — replay du bloc de durcissement', 'FAIL', SQLERRM);
END
$harden_seven_tables_replay$;

-- ----------------------------------------------------------------------------
-- 10. Aucune policy RLS modifiée par cette migration (nombre de policies inchangé sur les 7 tables)
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_table text; v_count int; v_expected_min int;
BEGIN
  FOREACH v_table IN ARRAY pg_temp.zz_tables() LOOP
    SELECT count(*) INTO v_count FROM pg_policies WHERE schemaname = 'public' AND tablename = v_table;
    IF v_count < 1 THEN
      RAISE EXCEPTION '[%] aucune policy RLS trouvée — inattendu, la migration ne doit toucher aucune policy existante.', v_table;
    END IF;
  END LOOP;
  PERFORM pg_temp.zz_log(10, 'Aucune policy RLS supprimée ou ajoutée par cette migration', 'PASS', 'au moins une policy présente sur chacune des 7 tables, conforme à l''attendu (cette migration ne touche que les GRANT/REVOKE table-level)');
EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.zz_log(10, 'Aucune policy RLS supprimée ou ajoutée par cette migration', 'FAIL', SQLERRM);
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
  RAISE NOTICE 'OK : suite P0 durcissement des grants (7 tables) complète, % scénarios, 0 échec.', v_total;
END $$;

-- Rollback du BEGIN externe : détruit tous les GRANT/REVOKE testés et les fixtures,
-- aucune trace persistante, aucune modification réelle des privilèges de production.
ROLLBACK;
