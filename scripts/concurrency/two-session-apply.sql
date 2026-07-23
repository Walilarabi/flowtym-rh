-- ============================================================================
-- RUNBOOK — Test de concurrence RÉEL à deux connexions (staging, psql).
-- Impossible via le bac à sable actuel (dblink exige le mot de passe DB ; réseau
-- sortant bloqué). À exécuter sur STAGING avec deux sessions psql indépendantes.
-- Remplacer <MGR> par l'auth_id d'un manager ayant accès aux 2 hôtels, et
-- <EMP>/<FO>/<VO> par des identifiants de test.
-- ============================================================================

-- ---- PRÉPARATION (session admin unique) ----
-- Crée une proposition 'approved' journée complète pour <EMP> le 2035-01-06.
--   (adapter selon vos données ; suppose workflow [] pour auto-approbation)
-- SELECT set_config('request.jwt.claim.sub','<MGR>',true);
-- SELECT group_move_workflow_set((SELECT group_id FROM hotels WHERE id='<FO>'), '[]'::jsonb);
-- INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end)
--   VALUES ('<FO>','<EMP>','2035-01-06','P',1,0,'J','08:00','16:00');
-- WITH p AS (
--   SELECT group_move_proposal_create(jsonb_build_object(
--     'employee_id','<EMP>','from_hotel_id','<FO>','to_hotel_id','<VO>',
--     'to_service','Réception','from_service','Réception',
--     'period_from','2035-01-06','period_to','2035-01-06',
--     'slots',jsonb_build_array(jsonb_build_object('date','2035-01-06')),
--     'decision','allowed','simulation',jsonb_build_object('blockers','[]'::jsonb))) AS id)
-- SELECT group_move_proposal_submit(id) FROM p;   -- => approved  (noter :PID)

-- ============================================================================
-- SCÉNARIO A — même salarié / même jour / deux clés différentes.
-- Session A :
--   BEGIN;
--   SELECT set_config('request.jwt.claim.sub','<MGR>',true);
--   SELECT pg_sleep(0);                         -- prêt
--   SELECT group_move_apply('<PID>','keyA');    -- prend le verrou advisory + écrit
--   SELECT pg_sleep(8);                          -- garder la transaction OUVERTE 8s
--   COMMIT;
-- Session B (démarrée < 8s après A) :
--   BEGIN;
--   SELECT set_config('request.jwt.claim.sub','<MGR>',true);
--   \timing on
--   SELECT group_move_apply('<PID>','keyB');    -- BLOQUE sur pg_advisory_xact_lock
--   -- se débloque au COMMIT de A, relit le statut => 'applied' =>
--   -- ERREUR: 'Statut non applicable (applied)'  (une seule application)
--   ROLLBACK;
-- Attendu : A applique ; B attend (temps ~ durée restante de A) puis échoue
--   proprement ; aucun chevauchement ; aucune double écriture.

-- SCÉNARIO B — même salarié / même jour, AUCUNE ligne préalable.
--   Ne pas insérer la ligne staff_planning en préparation (ni segments).
--   Rejouer A/B : B doit quand même BLOQUER (advisory lock sur employee||jour,
--   indépendant de FOR UPDATE) puis échouer. Prouve la sérialisation sans ligne.

-- SCÉNARIO C — même idempotency_key dans deux sessions.
--   A: group_move_apply('<PID>','SAME') ; garder ouvert.
--   B: group_move_apply('<PID>','SAME') ; BLOQUE (advisory) ; après COMMIT de A =>
--      la clé existe status='completed' => retour du résultat MÉMORISÉ (idempotent),
--      OU si A rollback => B ré-exécute. Une seule application métier.

-- SCÉNARIO D — deux propositions <PID1>/<PID2> (même salarié/jour), clés distinctes.
--   A applique <PID1> (garder ouvert) ; B applique <PID2>.
--   B: soit bloquée par la priorité/concurrence, soit exclusion_violation sur les
--      segments au moment de l'écriture => refusée. Une seule appliquée ; contrainte
--      d'exclusion intacte ; aucune modif partielle.

-- SCÉNARIO E — même salarié, JOURS DIFFÉRENTS (compatibles).
--   A applique <PIDday1> ; B applique <PIDday2> (jour différent).
--   Les verrous advisory portent sur (employee||jour) distincts => AUCUN blocage ;
--   les DEUX réussissent en parallèle. Prouve l'absence de sérialisation excessive.

-- ---- VÉRIFICATIONS FINALES (session admin) ----
-- SELECT * FROM staff_planning              WHERE employee_id='<EMP>' AND day BETWEEN '2035-01-06' AND '2035-01-08' ORDER BY day,hotel_id;
-- SELECT * FROM staff_planning_segments     WHERE employee_id='<EMP>' AND day BETWEEN '2035-01-06' AND '2035-01-08' ORDER BY day,seg_start_min;
-- SELECT idempotency_key,status,result      FROM group_move_applications WHERE proposal_id IN ('<PID>','<PID2>');
-- SELECT proposal_id,action,new_status,created_at FROM group_move_proposal_events WHERE proposal_id IN ('<PID>','<PID2>') ORDER BY created_at;
-- SELECT operation_id,count(*)              FROM planning_audit WHERE day BETWEEN '2035-01-06' AND '2035-01-08' GROUP BY 1;
-- Attendu global : une seule application compatible ; aucun segment chevauchant ;
--   aucune ligne 'processing' orpheline ; audit cohérent avec le planning écrit.

-- ---- NETTOYAGE ----
-- DELETE FROM group_move_proposals WHERE id IN ('<PID>','<PID2>');  -- cascade events/waivers/approvals/applications
-- DELETE FROM staff_planning_segments WHERE employee_id='<EMP>' AND day BETWEEN '2035-01-06' AND '2035-01-08';
-- DELETE FROM staff_planning          WHERE employee_id='<EMP>' AND day BETWEEN '2035-01-06' AND '2035-01-08';
-- DELETE FROM planning_audit          WHERE day BETWEEN '2035-01-06' AND '2035-01-08';
