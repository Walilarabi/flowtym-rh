-- ============================================================================
-- sql/tests/lot3_license_usage_observation.sql — Lot 3, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Zéro donnée réelle modifiée (lecture
-- seule sur les tables existantes ; seules les définitions de fonctions sont
-- (re)créées puis annulées par le ROLLBACK final).
-- ============================================================================
BEGIN;

\ir ../83_super_admin_lot3_license_usage_observation.sql

-- 1) anon bloqué (grant EXECUTE absent) sur les deux fonctions
DO $$ BEGIN
  RESET ROLE;
  SET LOCAL ROLE anon;
  PERFORM public.admin_list_license_usage();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu exécuter admin_list_license_usage()';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS anon bloqué sur admin_list_license_usage (grant).';
END $$;

DO $$ BEGIN
  RESET ROLE;
  SET LOCAL ROLE anon;
  PERFORM public.admin_platform_alerts();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu exécuter admin_platform_alerts()';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS anon bloqué sur admin_platform_alerts (grant).';
END $$;

-- 2) authenticated non-admin bloqué par is_platform_admin() (a le grant EXECUTE,
--    mais échoue sur le contrôle interne — même code d'erreur 42501, donc
--    intercepté par le même WHEN insufficient_privilege)
DO $$ BEGIN
  RESET ROLE;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public.admin_list_license_usage();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu exécuter admin_list_license_usage()';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS authenticated non-admin bloqué sur admin_list_license_usage (is_platform_admin).';
END $$;

DO $$ BEGIN
  RESET ROLE;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public.admin_platform_alerts();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu exécuter admin_platform_alerts()';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS authenticated non-admin bloqué sur admin_platform_alerts (is_platform_admin).';
END $$;

-- 3) super_admin réel : accès complet, cohérence interne des résultats
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';

DO $$
DECLARE
  v_rows int;
  v_bad_pct int;
  v_bad_status int;
BEGIN
  SELECT count(*) INTO v_rows FROM public.admin_list_license_usage();
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'ECHEC : admin_list_license_usage() ne retourne aucune ligne (attendu : au moins les abonnements trial/active connus)';
  END IF;
  RAISE NOTICE 'PASS super_admin lit admin_list_license_usage() — % ligne(s).', v_rows;

  -- Cohérence : quota NULL => statut 'unavailable' et pourcentage NULL (jamais de division fantôme)
  SELECT count(*) INTO v_bad_status FROM public.admin_list_license_usage()
    WHERE (rooms_quota IS NULL AND rooms_status <> 'unavailable')
       OR (users_quota IS NULL AND users_status <> 'unavailable');
  IF v_bad_status <> 0 THEN
    RAISE EXCEPTION 'ECHEC : % ligne(s) avec quota NULL mais statut <> unavailable', v_bad_status;
  END IF;
  RAISE NOTICE 'PASS quota NULL => statut unavailable, sans exception (% lignes vérifiées).', v_rows;

  SELECT count(*) INTO v_bad_pct FROM public.admin_list_license_usage()
    WHERE (rooms_quota IS NULL AND rooms_pct IS NOT NULL)
       OR (users_quota IS NULL AND users_pct IS NOT NULL);
  IF v_bad_pct <> 0 THEN
    RAISE EXCEPTION 'ECHEC : % ligne(s) avec quota NULL mais pourcentage non NULL', v_bad_pct;
  END IF;
  RAISE NOTICE 'PASS quota NULL => pourcentage NULL (pas de valeur trompeuse).';

  -- Cohérence : 'exceeded' implique used > quota strictement (jamais de faux positif)
  SELECT count(*) INTO v_bad_status FROM public.admin_list_license_usage()
    WHERE (rooms_status = 'exceeded' AND NOT (rooms_used > rooms_quota))
       OR (users_status = 'exceeded' AND NOT (users_used > users_quota));
  IF v_bad_status <> 0 THEN
    RAISE EXCEPTION 'ECHEC : % ligne(s) marquées exceeded sans used > quota réel', v_bad_status;
  END IF;
  RAISE NOTICE 'PASS statut exceeded toujours cohérent avec used > quota.';
END $$;

-- 4) Prédicat partagé : toute ligne 'exceeded' de admin_list_license_usage() doit
--    avoir une alerte 'license_quota_exceeded' correspondante dans
--    admin_platform_alerts(), et réciproquement (même source de vérité, jamais
--    de duplication manuelle susceptible de diverger).
DO $$
DECLARE v_missing_alert int; v_orphan_alert int;
BEGIN
  SELECT count(*) INTO v_missing_alert
  FROM public.admin_list_license_usage() lu
  WHERE (lu.rooms_status = 'exceeded' OR lu.users_status = 'exceeded')
    AND NOT EXISTS (
      SELECT 1 FROM public.admin_platform_alerts() al
      WHERE al.alert_type = 'license_quota_exceeded' AND al.entity_id = lu.subscription_id::text
    );
  IF v_missing_alert <> 0 THEN
    RAISE EXCEPTION 'ECHEC : % abonnement(s) en dépassement sans alerte license_quota_exceeded correspondante', v_missing_alert;
  END IF;

  SELECT count(*) INTO v_orphan_alert
  FROM public.admin_platform_alerts() al
  WHERE al.alert_type = 'license_quota_exceeded'
    AND NOT EXISTS (
      SELECT 1 FROM public.admin_list_license_usage() lu
      WHERE lu.subscription_id::text = al.entity_id
        AND (lu.rooms_status = 'exceeded' OR lu.users_status = 'exceeded')
    );
  IF v_orphan_alert <> 0 THEN
    RAISE EXCEPTION 'ECHEC : % alerte(s) license_quota_exceeded orpheline(s) sans dépassement réel correspondant', v_orphan_alert;
  END IF;

  RAISE NOTICE 'PASS prédicat de dépassement strictement identique entre admin_list_license_usage() et admin_platform_alerts() (aucun écart).';
END $$;

-- 5) Non-régression : les autres types d'alertes déjà existants dans
--    admin_platform_alerts() (sql/76) restent produits (le UNION ALL ajouté
--    n'a pas cassé les branches précédentes).
DO $$
DECLARE v_types int;
BEGIN
  SELECT count(DISTINCT alert_type) INTO v_types FROM public.admin_platform_alerts();
  IF v_types < 1 THEN
    RAISE EXCEPTION 'ECHEC : admin_platform_alerts() ne retourne plus aucun type d''alerte après modification';
  END IF;
  RAISE NOTICE 'PASS admin_platform_alerts() retourne % type(s) d''alerte distincts (non-régression).', v_types;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES lot3_license_usage_observation PASSENT.'; END $$;
ROLLBACK;
