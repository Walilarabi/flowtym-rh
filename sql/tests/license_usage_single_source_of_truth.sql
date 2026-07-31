-- ============================================================================
-- sql/tests/license_usage_single_source_of_truth.sql — sql/89, tests
-- transactionnels BEGIN...ROLLBACK sur production réelle.
--
-- Preuve exigée : les 4 consommateurs (admin_list_license_usage, l'ancienne
-- branche license_quota_exceeded de admin_platform_alerts, admin_platform_
-- statistics, _hotel_health_subscores) retournent une interprétation
-- identique pour le même hôtel réel, avant ET après le passage à la source
-- unique _hotel_license_usage_snapshot(). L'ancien helper dupliqué
-- (_hotel_license_usage_rows()) doit avoir disparu après application.
-- ============================================================================
BEGIN;

\ir ../81_support_acl_hardening.sql
\ir ../82_platform_notifications.sql
\ir ../83_super_admin_lot3_license_usage_observation.sql
\ir ../85_support_ticket_replies.sql
\ir ../86_support_ticket_attachments.sql
\ir ../87_super_admin_lot6_statistics_health_score.sql

CREATE TEMP TABLE zz_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.zz_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO zz_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 500))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;
GRANT INSERT, SELECT ON zz_results TO authenticated;

-- Snapshot AVANT sql/89 (helpers/RPC encore dupliqués, tels que livrés par
-- sql/83 et sql/87 indépendamment) pour un hôtel réel avec un quota chiffré.
CREATE TEMP TABLE zz_before (rooms_used int, rooms_status text, users_used int, users_status text);
GRANT INSERT, SELECT ON zz_before TO authenticated;
DO $$
DECLARE v_row record;
BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT rooms_used, rooms_status, users_used, users_status INTO v_row
  FROM public.admin_list_license_usage() WHERE hotel_id = 'b833efe8-c71e-4822-87a1-b9b6bf06f1e8';
  INSERT INTO zz_before VALUES (v_row.rooms_used, v_row.rooms_status, v_row.users_used, v_row.users_status);
END $$;
RESET ROLE; RESET request.jwt.claims;

\ir ../89_super_admin_license_usage_single_source_of_truth.sql

-- Wrapper de test pour appeler le helper interne _hotel_health_subscores()
-- comme le fait la vraie RPC publique admin_hotel_health_scores() (même
-- schéma d'accès : la RPC publique, propriétaire, appelle le helper interne).
CREATE OR REPLACE FUNCTION pg_temp.zz_health_licenses(p_hotel_id uuid) RETURNS jsonb AS $$
  SELECT public._hotel_health_subscores(p_hotel_id)->'licenses';
$$ LANGUAGE sql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION pg_temp.zz_health_licenses(uuid) TO authenticated;

DO $$
DECLARE v_before record; v_after_list record; v_after_stats jsonb; v_after_licenses jsonb; v_after_alert_count int;
BEGIN
  SELECT * INTO v_before FROM zz_before;

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';

  SELECT rooms_used, rooms_status, users_used, users_status INTO v_after_list
  FROM public.admin_list_license_usage() WHERE hotel_id = 'b833efe8-c71e-4822-87a1-b9b6bf06f1e8';

  IF v_before.rooms_used = v_after_list.rooms_used AND v_before.rooms_status = v_after_list.rooms_status
     AND v_before.users_used = v_after_list.users_used AND v_before.users_status = v_after_list.users_status THEN
    PERFORM pg_temp.zz_log(1, '1) admin_list_license_usage identique avant/après sql/89', 'PASS',
      format('rooms_used=%s rooms_status=%s users_used=%s users_status=%s', v_after_list.rooms_used, v_after_list.rooms_status, v_after_list.users_used, v_after_list.users_status));
  ELSE
    PERFORM pg_temp.zz_log(1, '1) admin_list_license_usage identique avant/après sql/89', 'FAIL',
      format('avant: %s/%s/%s/%s | après: %s/%s/%s/%s', v_before.rooms_used, v_before.rooms_status, v_before.users_used, v_before.users_status,
        v_after_list.rooms_used, v_after_list.rooms_status, v_after_list.users_used, v_after_list.users_status));
  END IF;

  SELECT pg_temp.zz_health_licenses('b833efe8-c71e-4822-87a1-b9b6bf06f1e8') INTO v_after_licenses;
  IF (v_after_licenses->>'rooms_status') = v_after_list.rooms_status AND (v_after_licenses->>'users_status') = v_after_list.users_status THEN
    PERFORM pg_temp.zz_log(2, '2) _hotel_health_subscores.licenses = même statut que admin_list_license_usage', 'PASS',
      format('rooms_status=%s users_status=%s', v_after_licenses->>'rooms_status', v_after_licenses->>'users_status'));
  ELSE
    PERFORM pg_temp.zz_log(2, '2) _hotel_health_subscores.licenses = même statut que admin_list_license_usage', 'FAIL',
      format('health=%s vs list=%s/%s', v_after_licenses, v_after_list.rooms_status, v_after_list.users_status));
  END IF;

  SELECT public.admin_platform_statistics()->'licenses' INTO v_after_stats;
  IF (v_after_list.rooms_status='ok' AND v_after_list.users_status='ok' AND (v_after_stats->>'ok')::int >= 1)
     OR ((v_after_list.rooms_status='approaching' OR v_after_list.users_status='approaching') AND (v_after_stats->>'approaching')::int >= 1)
     OR ((v_after_list.rooms_status='exceeded' OR v_after_list.users_status='exceeded') AND (v_after_stats->>'exceeded')::int >= 1) THEN
    PERFORM pg_temp.zz_log(3, '3) admin_platform_statistics.licenses classe correctement cet hôtel', 'PASS', v_after_stats::text);
  ELSE
    PERFORM pg_temp.zz_log(3, '3) admin_platform_statistics.licenses classe correctement cet hôtel', 'FAIL',
      format('list=%s/%s stats=%s', v_after_list.rooms_status, v_after_list.users_status, v_after_stats::text));
  END IF;

  SELECT count(*) INTO v_after_alert_count FROM public.admin_platform_alerts()
    WHERE alert_type = 'license_quota_exceeded' AND hotel_id = 'b833efe8-c71e-4822-87a1-b9b6bf06f1e8';
  IF (v_after_list.rooms_status = 'exceeded' OR v_after_list.users_status = 'exceeded') THEN
    IF v_after_alert_count >= 1 THEN
      PERFORM pg_temp.zz_log(4, '4) admin_platform_alerts signale bien le dépassement (cohérent avec admin_list_license_usage)', 'PASS', format('%s alerte(s)', v_after_alert_count));
    ELSE
      PERFORM pg_temp.zz_log(4, '4) admin_platform_alerts signale bien le dépassement (cohérent avec admin_list_license_usage)', 'FAIL', 'statut exceeded mais aucune alerte');
    END IF;
  ELSE
    IF v_after_alert_count = 0 THEN
      PERFORM pg_temp.zz_log(4, '4) admin_platform_alerts silencieux quand aucun dépassement', 'PASS', 'aucune alerte, cohérent');
    ELSE
      PERFORM pg_temp.zz_log(4, '4) admin_platform_alerts silencieux quand aucun dépassement', 'FAIL', format('%s alerte(s) inattendue(s)', v_after_alert_count));
    END IF;
  END IF;
END $$;

-- Helper interne inaccessible directement (aucun GRANT, y compris service_role).
DO $$ BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  PERFORM public._hotel_license_usage_snapshot();
  PERFORM pg_temp.zz_log(5, '5) _hotel_license_usage_snapshot inaccessible directement (aucun grant)', 'FAIL', 'appel accepté');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM pg_temp.zz_log(5, '5) _hotel_license_usage_snapshot inaccessible directement (aucun grant)', 'PASS', 'insufficient_privilege');
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  SET LOCAL ROLE service_role;
  PERFORM public._hotel_license_usage_snapshot();
  PERFORM pg_temp.zz_log(6, '6) _hotel_license_usage_snapshot inaccessible même pour service_role', 'FAIL', 'appel accepté');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM pg_temp.zz_log(6, '6) _hotel_license_usage_snapshot inaccessible même pour service_role', 'PASS', 'insufficient_privilege');
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='_hotel_license_usage_rows') THEN
    PERFORM pg_temp.zz_log(7, '7) ancien helper dupliqué _hotel_license_usage_rows supprimé', 'PASS', 'DROP FUNCTION confirmé');
  ELSE
    PERFORM pg_temp.zz_log(7, '7) ancien helper dupliqué _hotel_license_usage_rows supprimé', 'FAIL', 'la fonction existe encore');
  END IF;
END $$;

DO $$
DECLARE v_total int; v_failed int; v_row record;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE status = 'FAIL') INTO v_total, v_failed FROM zz_results;
  FOR v_row IN SELECT * FROM zz_results ORDER BY test_no LOOP
    RAISE NOTICE '[%] % — %: %', v_row.test_no, v_row.status, v_row.name, v_row.detail;
  END LOOP;
  IF v_failed > 0 THEN
    RAISE EXCEPTION '% test(s) en échec sur %', v_failed, v_total;
  END IF;
  RAISE NOTICE 'OK : suite source unique de licences (sql/89) complète, % scénarios, 0 échec.', v_total;
END $$;

ROLLBACK;
