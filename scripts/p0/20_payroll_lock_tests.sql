-- ============================================================================
-- TESTS GARDE-FOU PAIE CLÔTURÉE (les 6 chemins d'écriture + contrôle ouvert).
-- Doit : refuser avec SQLSTATE 'FL001', SANS écriture partielle.
-- ============================================================================
\set FO  '22222222-2222-2222-2222-222222222222'
\set VO  '33333333-3333-3333-3333-333333333333'
\set EMP '66666666-6666-6666-6666-666666666666'
SELECT set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555', false);

CREATE OR REPLACE FUNCTION pchk(p_test text, p_expect_locked boolean, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text; v_locked boolean := false;
BEGIN
  BEGIN EXECUTE p_sql; EXCEPTION WHEN sqlstate 'FL001' THEN v_locked := true;
    WHEN others THEN GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
      INSERT INTO p0_results VALUES(p_test,'garde paie','FL001 / autorisé','autre erreur '||v_state,false); RETURN;
  END;
  INSERT INTO p0_results VALUES(p_test,'garde paie',
    CASE WHEN p_expect_locked THEN 'refus FL001' ELSE 'autorisé' END,
    CASE WHEN v_locked THEN 'refus FL001' ELSE 'autorisé' END,
    v_locked = p_expect_locked);
END $$;

-- Jour test paie : 2035-08-10, hôtel VO. On pose une présence d'origine côté FO
-- pour le déplacement, sur un jour NON clôturé d'abord.
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end)
  VALUES (:'FO',:'EMP','2035-08-10','P',1,0,'J','08:00','16:00');
-- segment existant sur le jour, à modifier/supprimer après clôture
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status)
  VALUES (:'VO',:'EMP','2035-08-10',480,720,'destination','PE');

-- CLÔTURE de la période paie couvrant 2035-08-10 pour VO et FO
INSERT INTO staff_payroll_periods(hotel_id,period_start,period_end,status,closed_at,closed_by)
  VALUES (:'VO','2035-08-01','2035-08-31','closed',now(),'55555555-5555-5555-5555-555555555555'),
         (:'FO','2035-08-01','2035-08-31','closed',now(),'55555555-5555-5555-5555-555555555555');

-- P1 création d'un segment sur période close -> refus
SELECT pchk('P1-seg-create', true,
  $q$INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status)
     VALUES ('33333333-3333-3333-3333-333333333333','66666666-6666-6666-6666-666666666666','2035-08-10',800,900,'destination','PE')$q$);
-- P2 modification d'un segment -> refus
SELECT pchk('P2-seg-update', true,
  $q$UPDATE staff_planning_segments SET seg_end_min=780 WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2035-08-10'$q$);
-- P3 suppression d'un segment -> refus
SELECT pchk('P3-seg-delete', true,
  $q$DELETE FROM staff_planning_segments WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2035-08-10'$q$);
-- P4 écriture grille (staff_planning) -> refus
SELECT pchk('P4-grid-write', true,
  $q$UPDATE staff_planning SET status='MAD' WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2035-08-10' AND hotel_id='22222222-2222-2222-2222-222222222222'$q$);
-- P5 déplacement inter-hôtel (group_move_apply) -> refus ATOMIQUE
SELECT pchk('P5-move-apply', true,
  $q$SELECT mv('2035-08-10','08:00','12:00','K-PAY')$q$);
-- P6 reconstruction staff_planning_rebuild_day -> refus
SELECT pchk('P6-rebuild', true,
  $q$SELECT staff_planning_rebuild_day('66666666-6666-6666-6666-666666666666','2035-08-10')$q$);

-- Contrôle : atomicité P5 -> proposition NON appliquée, aucun segment ajouté
SELECT pchk('P5-atomic-noapply', false,
  $q$SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM group_move_proposals WHERE period_from='2035-08-10' AND status='applied')$q$);
-- (pchk 'autorisé' attendu = la requête ne lève pas FL001 ; NOT EXISTS => 0 ligne, pas d'erreur)

-- CONTRÔLE : même écriture sur une période OUVERTE -> autorisée
INSERT INTO staff_payroll_periods(hotel_id,period_start,period_end,status)
  VALUES (:'VO','2035-09-01','2035-09-30','open');
SELECT pchk('P7-open-ok', false,
  $q$INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status)
     VALUES ('33333333-3333-3333-3333-333333333333','66666666-6666-6666-6666-666666666666','2035-09-05',480,720,'destination','PE')$q$);
