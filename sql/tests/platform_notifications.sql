-- ============================================================================
-- sql/tests/platform_notifications.sql — Lot 2, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Zéro donnée réelle laissée en place.
-- ============================================================================
BEGIN;

-- 1) Idempotence stricte : deux insertions avec la même dedupe_key -> une seule ligne
INSERT INTO public.platform_notifications (category, reference_type, reference_id, dedupe_key, recipient_email, template)
VALUES ('trial_ending','hotel_subscription','00000000-0000-0000-0000-000000000001','zz-test:trial:1:7','zz@example.invalid','trial_ending_soon')
ON CONFLICT (dedupe_key) DO NOTHING;
INSERT INTO public.platform_notifications (category, reference_type, reference_id, dedupe_key, recipient_email, template)
VALUES ('trial_ending','hotel_subscription','00000000-0000-0000-0000-000000000001','zz-test:trial:1:7','zz@example.invalid','trial_ending_soon')
ON CONFLICT (dedupe_key) DO NOTHING;

DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.platform_notifications WHERE dedupe_key='zz-test:trial:1:7';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ECHEC idempotence : % ligne(s) pour la même dedupe_key (attendu: 1)', v_count;
  END IF;
  RAISE NOTICE 'PASS idempotence dedupe_key (1 ligne pour 2 tentatives d''insertion identiques).';
END $$;

-- 2) Concurrence du passage à 'sending' : UPDATE ... WHERE status='pending' ne doit
--    matcher qu'une fois même si tenté deux fois de suite (simulateur simple, pas de
--    vrai parallélisme SQL, mais vérifie la clause de garde).
DO $$
DECLARE v_rows1 int; v_rows2 int;
BEGIN
  UPDATE public.platform_notifications SET status='sending' WHERE dedupe_key='zz-test:trial:1:7' AND status='pending';
  GET DIAGNOSTICS v_rows1 = ROW_COUNT;
  UPDATE public.platform_notifications SET status='sending' WHERE dedupe_key='zz-test:trial:1:7' AND status='pending';
  GET DIAGNOSTICS v_rows2 = ROW_COUNT;
  IF v_rows1 <> 1 OR v_rows2 <> 0 THEN
    RAISE EXCEPTION 'ECHEC garde de concurrence : premier UPDATE=% (attendu 1), second UPDATE=% (attendu 0)', v_rows1, v_rows2;
  END IF;
  RAISE NOTICE 'PASS garde de concurrence pending->sending (une seule transition possible).';
END $$;

-- 3) RLS : aucun accès anon/authenticated, même en lecture
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.platform_notifications;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : anon voit % ligne(s) de platform_notifications (attendu: 0 ou permission denied)', v_count;
  END IF;
  RAISE NOTICE 'PASS anon SELECT filtré à 0 ligne (RLS sans policy).';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS anon SELECT bloqué par grant (permission denied) — équivalent ou plus strict que le filtrage RLS.';
END $$;
DO $$ BEGIN
  INSERT INTO public.platform_notifications (category, reference_type, reference_id, dedupe_key, recipient_email, template)
  VALUES ('trial_ending','x','00000000-0000-0000-0000-000000000002','zz-test-anon-insert','x@x.invalid','x');
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu insérer dans platform_notifications';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS anon INSERT bloqué (permission denied).';
END $$;

RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM count(*) FROM public.platform_notifications;
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated a pu lire platform_notifications';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS authenticated SELECT bloqué (permission denied).';
END $$;

-- 4) service_role : accès complet confirmé
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.platform_notifications WHERE dedupe_key='zz-test:trial:1:7';
  IF v_count <> 1 THEN RAISE EXCEPTION 'ECHEC : service_role ne voit pas la ligne de test'; END IF;
  RAISE NOTICE 'PASS service_role a accès complet (attendu).';
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES platform_notifications PASSENT.'; END $$;
ROLLBACK;
