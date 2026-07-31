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
DECLARE v_notif_count int; v_category text; v_template text; v_payload jsonb; v_dedupe_a text;
BEGIN
  SELECT dedupe_key INTO v_dedupe_a FROM public._trial_ending_notification_candidates()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;

  SELECT count(*) INTO v_notif_count FROM public.platform_notifications WHERE dedupe_key = v_dedupe_a;
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'ECHEC : notification fixture A absente ou dupliquée (%)', v_notif_count; END IF;

  SELECT category, template, template_payload INTO v_category, v_template, v_payload
  FROM public.platform_notifications WHERE dedupe_key = v_dedupe_a;
  IF v_category <> 'trial_ending' OR v_template <> 'trial_ending_soon' THEN
    RAISE EXCEPTION 'ECHEC : catégorie/template incorrects (% / %)', v_category, v_template;
  END IF;
  IF NOT (v_payload ? 'hotel_name' AND v_payload ? 'days_remaining' AND v_payload ? 'trial_ends_at') THEN
    RAISE EXCEPTION 'ECHEC : payload incomplet (%)', v_payload;
  END IF;
  RAISE NOTICE 'PASS notification fixture A : catégorie/template/payload corrects (dedupe_key=%, %).', v_dedupe_a, v_payload;
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
DECLARE v_notif_count int; v_dedupe_a text;
BEGIN
  SELECT dedupe_key INTO v_dedupe_a FROM public._trial_ending_notification_candidates()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;
  SELECT count(*) INTO v_notif_count FROM public.platform_notifications WHERE dedupe_key = v_dedupe_a;
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'ECHEC idempotence stricte : % ligne(s) après deux runs (attendu 1)', v_notif_count; END IF;
  RAISE NOTICE 'PASS idempotence stricte confirmée : toujours 1 seule ligne après 2 exécutions.';
END $$;

-- 3bis) Item 10 (revue de stabilisation CTO) : cycle d'échéance réel — la clé
-- d'idempotence doit inclure trial_ends_at normalisé, pas seulement le palier.
-- Prolongation de l'essai DANS LA MÊME FENÊTRE DE SEUIL (fixture A, J-6 -> J-5,
-- les deux <= 7) : un NOUVEAU palier 7 doit redevenir éligible pour la nouvelle
-- échéance, sans jamais renvoyer celui déjà notifié pour l'ancienne échéance
-- (qui reste une ligne historique intacte). (Une extension qui sort de la
-- fenêtre, ex. J-6 -> J-8, rendrait légitimement le palier 7 inéligible tant
-- que J-7 n'est pas atteint — testé indirectement par le prédicat déjà couvert
-- au scénario 1 ci-dessus, pas reproduit ici pour ne pas confondre les deux
-- comportements distincts : fenêtre de seuil vs clé d'idempotence.)
DO $$
DECLARE v_dedupe_old text; v_dedupe_new text; v_would boolean; v_old_still_exists boolean;
BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT dedupe_key INTO v_dedupe_old FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;

  RESET ROLE; RESET request.jwt.claims;
  UPDATE public.hotel_subscriptions
  SET trial_ends_at = (now() AT TIME ZONE 'Europe/Paris')::date + 5 + time '12:00' AT TIME ZONE 'Europe/Paris'
  WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT dedupe_key, would_send INTO v_dedupe_new, v_would FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;

  IF v_dedupe_new = v_dedupe_old THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : la prolongation de l''essai ne change pas la clé d''idempotence (ancien=%, nouveau=%)', v_dedupe_old, v_dedupe_new;
  END IF;
  IF v_would IS NOT TRUE THEN
    RAISE EXCEPTION 'ECHEC : nouveau palier J-7 (nouvelle échéance) pas éligible après prolongation (would_send=%)', v_would;
  END IF;

  RESET ROLE; RESET request.jwt.claims;
  SET LOCAL ROLE service_role;
  SELECT EXISTS(SELECT 1 FROM public.platform_notifications WHERE dedupe_key = v_dedupe_old) INTO v_old_still_exists;
  RESET ROLE;
  IF NOT v_old_still_exists THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : la notification de l''ancienne échéance a disparu (perte d''historique)';
  END IF;

  RAISE NOTICE 'PASS prolongation d''essai : nouvelle clé (%) distincte de l''ancienne (%), nouveau J-7 éligible, historique de l''ancienne échéance préservé.', v_dedupe_new, v_dedupe_old;
END $$;

-- 3ter) Exécution du nouveau palier après prolongation, puis raccourcissement de
-- l'essai (J-5 -> J-1) : encore un nouveau cycle, encore aucune perte d'historique.
DO $$
DECLARE v_dedupe_after_run text; v_dedupe_shortened text; v_would boolean;
BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  PERFORM public.admin_run_trial_ending_notifications();
  SELECT dedupe_key INTO v_dedupe_after_run FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=7;

  RESET ROLE; RESET request.jwt.claims;
  UPDATE public.hotel_subscriptions
  SET trial_ends_at = (now() AT TIME ZONE 'Europe/Paris')::date + 1 + time '12:00' AT TIME ZONE 'Europe/Paris'
  WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT dedupe_key, would_send INTO v_dedupe_shortened, v_would FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=1;

  IF v_dedupe_shortened = v_dedupe_after_run THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : le raccourcissement de l''essai ne change pas la clé d''idempotence';
  END IF;
  IF v_would IS NOT TRUE THEN
    RAISE EXCEPTION 'ECHEC : palier J-1 (échéance raccourcie) pas éligible (would_send=%)', v_would;
  END IF;
  RAISE NOTICE 'PASS raccourcissement d''essai : nouvelle clé d''idempotence distincte, palier J-1 de la nouvelle échéance éligible.';
END $$;

-- 3quater : minuit Europe/Paris — trial_ends_at fixé à 23h59 heure de Paris ce
-- soir doit être classé J-0 (jour civil identique), pas J-1, quel que soit le
-- décalage horaire UTC/Paris au moment de l'exécution du test.
DO $$
DECLARE v_days_remaining int; v_sub_id uuid;
BEGIN
  RESET ROLE; RESET request.jwt.claims;
  SELECT hotel_id INTO v_sub_id FROM public.hotel_subscriptions WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';
  UPDATE public.hotel_subscriptions
  SET trial_ends_at = ((now() AT TIME ZONE 'Europe/Paris')::date + time '23:59:00') AT TIME ZONE 'Europe/Paris'
  WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT days_remaining INTO v_days_remaining FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id='00497366-522b-4c8a-bc91-c992fdfb1822' AND threshold_days=1;
  IF v_days_remaining <> 0 THEN
    RAISE EXCEPTION 'ECHEC fuseau Europe/Paris : trial_ends_at à 23h59 Paris aujourd''hui classé days_remaining=% (attendu 0, jour civil identique)', v_days_remaining;
  END IF;
  RAISE NOTICE 'PASS fuseau Europe/Paris : échéance à 23h59 heure de Paris aujourd''hui correctement classée days_remaining=0 (jour civil, pas un décalage UTC).';
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

-- 3quinquies : transition de statut (trial -> active/suspended/cancelled) — sort
-- immédiatement des candidats, quelle que soit l'échéance ou la clé d'idempotence.
DO $$
DECLARE v_count int;
BEGIN
  RESET ROLE; RESET request.jwt.claims;
  UPDATE public.hotel_subscriptions SET status = 'active' WHERE id = '00497366-522b-4c8a-bc91-c992fdfb1822';

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  SELECT count(*) INTO v_count FROM public.admin_preview_trial_ending_notifications()
    WHERE subscription_id = '00497366-522b-4c8a-bc91-c992fdfb1822';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : abonnement passé status=active toujours candidat (%)', v_count;
  END IF;
  RAISE NOTICE 'PASS transition trial->active : abonnement immédiatement exclu des candidats (status <> ''trial'').';
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES trial_ending_notifications PASSENT.'; END $$;
ROLLBACK;
