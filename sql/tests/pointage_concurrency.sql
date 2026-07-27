-- =============================================================================
-- Test de concurrence : deux transactions parallèles tentent de créer un
-- pointage ouvert pour le même employé. Le SQL doit garantir qu'une seule
-- réussit (via l'index unique partiel staff_clockings_one_open_per_employee).
--
-- Le script est piloté par scripts/test-pointage-concurrency.sh qui ouvre
-- deux sessions en parallèle. Ce fichier ne contient que le SETUP et les
-- REQUETES à jouer côté A et côté B.
-- =============================================================================

-- Fournit une session UNIQUE de setup : appelée AVANT les 2 sessions
-- concurrentes. Reset des données de test.
CREATE OR REPLACE FUNCTION public._concurrency_setup()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_terminal jsonb;
BEGIN
  DELETE FROM public.staff_clocking_idempotency;
  DELETE FROM public.staff_clockings;
  DELETE FROM public.pointage_terminal_events;
  DELETE FROM public.pointage_terminals;

  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);
  v_terminal := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111','ConcurrencyTerminal');
  -- Le terminal_id est le premier créé
END $$;

-- Vérification finale : au maximum 1 pointage ouvert pour l'employé cible
CREATE OR REPLACE FUNCTION public._concurrency_assert()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_count int; v_total int;
BEGIN
  SELECT count(*) INTO v_count FROM public.staff_clockings
   WHERE employee_id='e0000001-0000-0000-0000-000000000001'
     AND clock_out_ts IS NULL;
  SELECT count(*) INTO v_total FROM public.staff_clockings
   WHERE employee_id='e0000001-0000-0000-0000-000000000001';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'CONCURRENCY FAIL: % pointages ouverts (attendu 1), % total', v_count, v_total;
  END IF;
  IF v_total <> 1 THEN
    RAISE EXCEPTION 'CONCURRENCY FAIL: % pointages totaux (attendu 1)', v_total;
  END IF;
  RAISE NOTICE 'OK concurrence : exactement 1 pointage créé sur 2 requêtes parallèles';
END $$;
