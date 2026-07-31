-- ============================================================================
-- sql/tests/trial_ending_notifications.sql — Lot 4, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Dépend de Lot 2 (platform_notifications,
-- sql/82) : ce fichier inclut aussi sql/82 dans la transaction, cette dernière
-- n'étant pas encore appliquée en production au moment de ce lot.
-- ============================================================================
BEGIN;

\ir ../82_platform_notifications.sql
\ir ../84_trial_ending_notifications.sql

-- Fixtures : deux abonnements trial réels, dates d'échéance déplacées temporairement
-- (annulé par le ROLLBACK final, jamais persisté).
-- Fixture A : J-6 -> éligible uniquement au palier 7 (6 <= 7, 6 > 3, 6 > 1).
UPDATE public.hotel_subscriptions
SET trial_ends_at = (now() AT TIME ZONE 'Europe/Paris')::date + 6 + time '12:00' AT TIME ZONE 'Europe/Paris'
WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';
-- Fixture B : J-1, mais sans aucun email de contact (billing_email et email absents).
UPDATE public.hotels SET billing_email = NULL, email = NULL
WHERE id = (SELECT hotel_id FROM public.hotel_subscriptions WHERE id = '99f181f6-49c8-468d-9a63-b7daee6e6f43');
UPDATE public.hotel_subscriptions
SET trial_ends_at = (now() AT TIME ZONE 'Europe/Paris')::date + 1 + time '12:00' AT TIME ZONE 'Europe/Paris'
WHERE id = '99f181f6-49c8-468d-9a63-b7daee6e6f43';

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';

-- 1) Preview : prédicat correct (fixture A uniquement palier 7 ; fixture B signalée sans email)
DO $$
DECLARE v_count7 int; v_count_other int; v_skip_reason text;
BEGIN
  SELECT count(*) INTO v_count7 FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7 AND would_send;
  IF v_count7 <> 1 THEN RAISE EXCEPTION 'ECHEC : fixture A pas candidate au palier 7 (%)', v_count7; END IF;

  SELECT count(*) INTO v_count_other FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days IN (3,1);
  IF v_count_other <> 0 THEN RAISE EXCEPTION 'ECHEC : fixture A candidate à un palier non atteint (%)', v_count_other; END IF;
  RAISE NOTICE 'PASS preview : fixture A (J-6) candidate uniquement au palier 7 (jamais 3 ni 1).';

  SELECT skip_reason INTO v_skip_reason FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='99f181f6-49c8-468d-9a63-b7daee6e6f43' AND threshold_days=1;
  IF v_skip_reason IS NULL THEN RAISE EXCEPTION 'ECHEC : fixture B (sans email) pas signalée comme non-envoyable'; END IF;
  RAISE NOTICE 'PASS preview : fixture B (sans email de contact) signalée avec un skip_reason explicite.';
END $$;

-- 2) Run : prédicat identique au preview (fixture A envoyée, fixture B comptée en skipped_no_email)
DO $$
DECLARE v_sent int; v_skip_sent int; v_skip_email int;
BEGIN
  SELECT sent_count, skipped_already_sent, skipped_no_email INTO v_sent, v_skip_sent, v_skip_email
  FROM public.admin_run_trial_ending_notifications();
  IF v_sent < 1 THEN RAISE EXCEPTION 'ECHEC : sent_count=% (attendu au moins 1 pour la fixture A)', v_sent; END IF;
  IF v_skip_email < 1 THEN RAISE EXCEPTION 'ECHEC : skipped_no_email=% (attendu au moins 1 pour la fixture B)', v_skip_email; END IF;
  RAISE NOTICE 'PASS run : sent=%, skipped_already_sent=%, skipped_no_email=%.', v_sent, v_skip_sent, v_skip_email;
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$
DECLARE v_notif_count int; v_category text; v_template text; v_payload jsonb;
BEGIN
  SELECT count(*) INTO v_notif_count FROM public.platform_notifications
    WHERE dedupe_key = 'trial:00497366-522b-4c8a-bc91-c992fdfb1822:7';
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'ECHEC : notification fixture A absente ou dupliquée (%)', v_notif_count; END IF;

  SELECT category, template, template_payload INTO v_category, v_template, v_payload
  FROM public.platform_notifications WHERE dedupe_key = 'trial:00497366-522b-4c8a-bc91-c992fdfb1822:7';
  IF v_category <> 'trial_ending' OR v_template <> 'trial_ending_soon' THEN
    RAISE EXCEPTION 'ECHEC : catégorie/template incorrects (% / %)', v_category, v_template;
  END IF;
  IF NOT (v_payload ? 'hotel_name' AND v_payload ? 'days_remaining' AND v_payload ? 'trial_ends_at') THEN
    RAISE EXCEPTION 'ECHEC : payload incomplet (%)', v_payload;
  END IF;
  RAISE NOTICE 'PASS notification fixture A : catégorie/template/payload corrects (%).', v_payload;
END $$;

-- 3) Idempotence stricte : re-preview -> would_send=false ; re-run -> aucune nouvelle ligne
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$
DECLARE v_would boolean; v_skip_sent2 int;
BEGIN
  SELECT would_send INTO v_would FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;
  IF v_would IS NOT FALSE THEN RAISE EXCEPTION 'ECHEC idempotence preview : would_send=% (attendu false)', v_would; END IF;

  SELECT skipped_already_sent INTO v_skip_sent2 FROM public.admin_run_trial_ending_notifications();
  IF v_skip_sent2 < 1 THEN RAISE EXCEPTION 'ECHEC : second run ne compte pas la fixture A en skipped_already_sent'; END IF;
  RAISE NOTICE 'PASS idempotence : second passage sans renvoi (preview would_send=false, run skipped_already_sent=%).', v_skip_sent2;
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$
DECLARE v_notif_count int;
BEGIN
  SELECT count(*) INTO v_notif_count FROM public.platform_notifications
    WHERE dedupe_key = 'trial:00497366-522b-4c8a-bc91-c992fdfb1822:7';
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'ECHEC idempotence stricte : % ligne(s) après deux runs (attendu 1)', v_notif_count; END IF;
  RAISE NOTICE 'PASS idempotence stricte confirmée : toujours 1 seule ligne après 2 exécutions.';
END $$;

-- 4) Sécurité : anon et authenticated non-admin bloqués sur les deux RPC ET sur le helper interne
DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE anon;
  PERFORM public.admin_preview_trial_ending_notifications();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu prévisualiser';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur preview (grant révoqué).'; END $$;

DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE anon;
  PERFORM public.admin_run_trial_ending_notifications();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu exécuter';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur run (grant révoqué).'; END $$;

DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public.admin_run_trial_ending_notifications();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu exécuter';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS authenticated non-admin bloqué sur run (is_platform_admin).'; END $$;

DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public._trial_ending_notification_candidates();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated a pu appeler directement le helper interne';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS helper interne inaccessible directement (grant révoqué, comme _platform_log).'; END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES trial_ending_notifications PASSENT.'; END $$;
ROLLBACK;
