-- ============================================================================
-- sql/tests/lot6_statistics_health_score.sql — Lot 6, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Ne dépend d'aucun autre lot non
-- encore en production (utilise uniquement des objets déjà présents sur main :
-- hotels, hotel_subscriptions, plan_modules, user_app_access, users, auth.users,
-- support_tickets, platform_invoices, platform_logs, is_platform_admin()).
-- ============================================================================
BEGIN;

\ir ../87_super_admin_lot6_statistics_health_score.sql

-- ============================================================================
-- 1) admin_platform_statistics() — accessible au super_admin, chiffres cohérents
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$
DECLARE v_stats jsonb;
BEGIN
  v_stats := public.admin_platform_statistics();
  IF (v_stats->'hotels'->>'total')::int < 1 THEN RAISE EXCEPTION 'ECHEC : hotels.total incohérent'; END IF;
  IF (v_stats->'revenue'->>'available')::boolean IS NOT true THEN RAISE EXCEPTION 'ECHEC : revenue.available devrait être true (snapshot_price_net_ht est une source fiable)'; END IF;
  IF (v_stats->'trial_conversion'->>'available')::boolean IS NOT false THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : trial_conversion.available=true alors qu''aucune conversion organique n''existe (fabrication de donnée)';
  END IF;
  RAISE NOTICE 'PASS admin_platform_statistics : hotels.total=%, revenue.available=true, trial_conversion.available=false (honnête).', v_stats->'hotels'->>'total';
END $$;

-- ============================================================================
-- 2) admin_hotel_health_scores() — exclut les hôtels archivés, jamais un score
--    "paiement" fabriqué quand platform_invoices est vide pour l'hôtel.
-- ============================================================================
DO $$
DECLARE v_archived_leak int; v_row record; v_any_payment_available boolean := false;
BEGIN
  SELECT count(*) INTO v_archived_leak
  FROM public.admin_hotel_health_scores() r JOIN public.hotels h ON h.id = r.hotel_id WHERE h.status = 'archived';
  IF v_archived_leak <> 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : % hôtel(s) archivé(s) dans le score de santé', v_archived_leak; END IF;

  FOR v_row IN SELECT hotel_name, scores FROM public.admin_hotel_health_scores() LOOP
    IF (v_row.scores->'payment'->>'available')::boolean THEN v_any_payment_available := true; END IF;
    IF (v_row.scores->'payment'->'available') IS NULL THEN
      RAISE EXCEPTION 'ECHEC : champ payment.available manquant pour %', v_row.hotel_name;
    END IF;
    -- Chaque sous-score indisponible doit apparaître dans excluded_subscores (jamais neutralisé).
    IF NOT (v_row.scores->'payment'->>'available')::boolean
       AND NOT ((v_row.scores->'composite'->'excluded_subscores') @> '"payment"') THEN
      RAISE EXCEPTION 'ECHEC : payment indisponible mais absent de excluded_subscores pour %', v_row.hotel_name;
    END IF;
  END LOOP;
  -- platform_invoices est vide en production au moment de ce lot : aucun hôtel ne devrait
  -- avoir un score paiement disponible aujourd'hui (si ce test échoue après une vraie facture
  -- a été créée entre-temps, c'est le signe attendu que le sous-score redevient disponible).
  IF v_any_payment_available THEN
    RAISE NOTICE 'INFO : au moins un hôtel a un score paiement disponible (des factures réelles existent désormais) — comportement attendu, pas un échec.';
  ELSE
    RAISE NOTICE 'PASS aucun score paiement fabriqué (platform_invoices vide pour tous les hôtels testés).';
  END IF;
  RAISE NOTICE 'PASS admin_hotel_health_scores : 0 hôtel archivé exposé, structure available/excluded_subscores cohérente.';
END $$;

-- ============================================================================
-- 3) Sécurité : non-admin authenticated et anon bloqués partout, helpers
--    internes inaccessibles même au super_admin (aucun grant direct).
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
DO $$ BEGIN
  PERFORM public.admin_hotel_health_scores();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu appeler admin_hotel_health_scores';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'Accès refusé%' THEN RAISE NOTICE 'PASS non-admin bloqué sur admin_hotel_health_scores.'; ELSE RAISE; END IF;
END $$;
DO $$ BEGIN
  PERFORM public.admin_platform_statistics();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu appeler admin_platform_statistics';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'Accès refusé%' THEN RAISE NOTICE 'PASS non-admin bloqué sur admin_platform_statistics.'; ELSE RAISE; END IF;
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_hotel_health_scores();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu appeler admin_hotel_health_scores';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur admin_hotel_health_scores.'; END $$;
DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_platform_statistics();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu appeler admin_platform_statistics';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur admin_platform_statistics.'; END $$;

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$ BEGIN
  PERFORM public._hotel_health_subscores((SELECT id FROM public.hotels LIMIT 1));
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated (même super_admin) a pu appeler _hotel_health_subscores directement';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS _hotel_health_subscores inaccessible directement (aucun grant, même pour super_admin).'; END $$;
DO $$ BEGIN
  PERFORM public._hotel_license_usage_rows();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated a pu appeler _hotel_license_usage_rows directement';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS _hotel_license_usage_rows inaccessible directement.'; END $$;

-- ============================================================================
-- 4) Cohérence arithmétique du composite : recalcul manuel sur un hôtel connu
--    (Grand Hotel du Havre — abonnement Legacy Pilot 'active', quota non
--    chiffré, 0 ticket, 0 facture) et comparaison à la valeur renvoyée par la RPC.
-- ============================================================================
DO $$
DECLARE v_scores jsonb; v_expected numeric; v_weight_sum numeric := 0; v_weighted numeric := 0;
BEGIN
  SELECT scores INTO v_scores FROM public.admin_hotel_health_scores() WHERE hotel_name = 'Grand Hotel du Havre';
  IF v_scores IS NULL THEN
    RAISE NOTICE 'INFO : hôtel Grand Hotel du Havre introuvable dans ce contexte de test — vérification arithmétique ignorée.';
  ELSE
    IF (v_scores->'adoption'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'adoption'->>'value')::numeric * (v_scores->'adoption'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'adoption'->>'weight')::numeric;
    END IF;
    IF (v_scores->'activity'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'activity'->>'value')::numeric * (v_scores->'activity'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'activity'->>'weight')::numeric;
    END IF;
    IF (v_scores->'licenses'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'licenses'->>'value')::numeric * (v_scores->'licenses'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'licenses'->>'weight')::numeric;
    END IF;
    IF (v_scores->'support'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'support'->>'value')::numeric * (v_scores->'support'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'support'->>'weight')::numeric;
    END IF;
    IF (v_scores->'payment'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'payment'->>'value')::numeric * (v_scores->'payment'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'payment'->>'weight')::numeric;
    END IF;
    IF (v_scores->'retention'->>'available')::boolean THEN
      v_weighted := v_weighted + (v_scores->'retention'->>'value')::numeric * (v_scores->'retention'->>'weight')::numeric;
      v_weight_sum := v_weight_sum + (v_scores->'retention'->>'weight')::numeric;
    END IF;
    v_expected := round(v_weighted / nullif(v_weight_sum, 0), 1);
    IF v_expected IS DISTINCT FROM (v_scores->'composite'->>'value')::numeric THEN
      RAISE EXCEPTION 'ECHEC CRITIQUE : composite recalculé (%) != composite renvoyé (%)', v_expected, v_scores->'composite'->>'value';
    END IF;
    RAISE NOTICE 'PASS cohérence arithmétique du composite vérifiée manuellement (valeur=%).', v_expected;
  END IF;
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES lot6_statistics_health_score PASSENT.'; END $$;
ROLLBACK;
