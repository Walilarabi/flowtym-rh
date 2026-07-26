-- ============================================================================
-- Test de rollback réel — group_move_apply atomicity
--
-- À exécuter dans un environnement de développement APRÈS avoir appliqué
-- sql/57_group_move_apply_visibility.sql.
--
-- Ce script démontre qu'une exception levée après l'écriture staff_planning
-- mais avant/pendant _gmp_ensure_visibility rollback l'intégralité de la
-- transaction : aucune ligne staff_planning ne subsiste, aucune activation
-- n'est créée, aucune autorisation n'est créée, la proposition reste
-- 'approved' (jamais 'applied').
--
-- Sécurité : le test crée puis supprime ses propres fixtures dans un bloc
-- transactionnel unique (BEGIN/ROLLBACK final). Il n'écrit rien en base à
-- la fin, même si l'assertion échoue. Ne pas exécuter en production.
-- ============================================================================

BEGIN;

-- Fixtures : proposition minimale approuvée pour un employé existant.
DO $$
DECLARE
  v_emp uuid;
  v_from uuid;
  v_to uuid;
  v_svc text;
  v_prop uuid := gen_random_uuid();
  v_key text := 'test_rollback_' || v_prop::text;
  v_sp_before int;
  v_sp_after int;
  v_eha_before int;
  v_eha_after int;
  v_eea_before int;
  v_eea_after int;
  v_status_after text;
  v_error_caught text;
BEGIN
  -- Sélectionne un employé + deux hôtels du même groupe pour le test.
  SELECT e.id, e.hotel_id INTO v_emp, v_from FROM employees e
    WHERE e.active = true ORDER BY e.id LIMIT 1;
  SELECT h.id INTO v_to FROM hotels h WHERE h.id <> v_from
    AND h.group_id = (SELECT group_id FROM hotels WHERE id = v_from) LIMIT 1;
  SELECT d.name INTO v_svc FROM staff_departments d WHERE d.hotel_id = v_to LIMIT 1;

  IF v_emp IS NULL OR v_from IS NULL OR v_to IS NULL OR v_svc IS NULL THEN
    RAISE EXCEPTION 'Fixtures indisponibles (employé/hôtels/service)';
  END IF;

  -- Snapshot BEFORE.
  SELECT count(*) INTO v_sp_before FROM staff_planning
    WHERE employee_id = v_emp AND day = '2099-01-15'::date;
  SELECT count(*) INTO v_eha_before FROM employee_hotel_assignments
    WHERE employee_id = v_emp AND target_hotel_id = v_to;
  SELECT count(*) INTO v_eea_before FROM employee_extra_activations
    WHERE employee_id = v_emp AND hotel_id = v_to AND year = 2099 AND month = 1;

  -- Proposition approuvée factice.
  INSERT INTO group_move_proposals (
    id, employee_id, from_hotel_id, to_hotel_id, from_service, to_service,
    period_from, period_to, slots, reason, status, decision, simulation
  ) VALUES (
    v_prop, v_emp, v_from, v_to, 'Réception', v_svc,
    '2099-01-15', '2099-01-15',
    jsonb_build_array(jsonb_build_object('date', '2099-01-15')),
    'test rollback', 'approved', 'allowed', '{"blockers":[],"missing":[]}'::jsonb
  );

  -- Cas 1 : forcer une exception AVANT la visibilité en cassant le service.
  -- On appelle group_move_apply avec un to_service inexistant, ce qui doit
  -- soulever une exception à l'étape _gmp_ensure_visibility et rollback tout.
  UPDATE group_move_proposals SET to_service = 'SERVICE_QUI_NEXISTE_PAS_'||v_prop
    WHERE id = v_prop;

  BEGIN
    PERFORM public.group_move_apply(v_prop, v_key);
    RAISE EXCEPTION 'Test échoué : group_move_apply devait lever une exception';
  EXCEPTION WHEN OTHERS THEN
    v_error_caught := SQLERRM;
  END;

  -- Vérifications AFTER (aucun changement attendu, la transaction entière
  -- du SECURITY DEFINER a été rollbackée par plpgsql).
  SELECT count(*) INTO v_sp_after FROM staff_planning
    WHERE employee_id = v_emp AND day = '2099-01-15'::date;
  SELECT count(*) INTO v_eha_after FROM employee_hotel_assignments
    WHERE employee_id = v_emp AND target_hotel_id = v_to;
  SELECT count(*) INTO v_eea_after FROM employee_extra_activations
    WHERE employee_id = v_emp AND hotel_id = v_to AND year = 2099 AND month = 1;
  SELECT status INTO v_status_after FROM group_move_proposals WHERE id = v_prop;

  RAISE NOTICE '========================================';
  RAISE NOTICE 'Test rollback — résultat';
  RAISE NOTICE '  Erreur capturée : %', v_error_caught;
  RAISE NOTICE '  staff_planning  before=% / after=% (attendu : identique)', v_sp_before, v_sp_after;
  RAISE NOTICE '  employee_hotel_assignments before=% / after=% (attendu : identique)', v_eha_before, v_eha_after;
  RAISE NOTICE '  employee_extra_activations before=% / after=% (attendu : identique)', v_eea_before, v_eea_after;
  RAISE NOTICE '  proposition.status = % (attendu : approved, pas applied)', v_status_after;
  RAISE NOTICE '========================================';

  IF v_sp_before <> v_sp_after THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ : staff_planning modifié malgré exception';
  END IF;
  IF v_eha_before <> v_eha_after THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ : employee_hotel_assignments modifié';
  END IF;
  IF v_eea_before <> v_eea_after THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ : employee_extra_activations créée';
  END IF;
  IF v_status_after <> 'approved' THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ : proposition passée à % au lieu de rester approved', v_status_after;
  END IF;

  RAISE NOTICE 'OK : rollback complet, atomicité prouvée.';
END $$;

-- Rollback du BEGIN externe : supprime aussi la proposition factice.
ROLLBACK;
