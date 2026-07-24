-- ============================================================================
-- RUNBOOK — Concurrence RÉELLE à deux connexions PostgreSQL (STAGING, psql).
-- Deux terminaux psql = deux backends. Sorties instrumentées et vérifiables.
-- NON exécutable depuis le sandbox (dblink exige le mot de passe DB ; réseau
-- sortant bloqué). Remplacer les <PLACEHOLDERS>.
--
-- Variables à définir (session admin, une fois) :
--   <MGR>  = auth_id d'un manager ayant accès aux 2 hôtels
--   <FO>,<VO> = hotel_id origine / destination
--   <EMP>  = employee_id de test (rattaché à <FO>)
-- Les identifiants de propositions (<PID_*>) sont produits par la préparation.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0) TABLE DE RÉSULTATS INSTRUMENTÉE (session admin)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cc_results (
  scenario     text, session_label text,
  t_start      timestamptz, t_end timestamptz,
  wait_ms      numeric,                 -- durée réelle de l'appel (blocage inclus)
  backend_pid  int,
  proposal_id  uuid, employee_id uuid, locked_day date,
  rpc_result   jsonb, error_text text,
  operation_id uuid,
  final_status text,                    -- statut proposition après
  sp_count     int,                     -- lignes staff_planning (emp, jours test)
  audit_count  int,                     -- lignes planning_audit (jours test)
  idem_key     text, idem_status text,  -- cycle de vie idempotence
  deadlock     boolean, timeout_hit boolean
);
TRUNCATE public.cc_results;

-- Wrapper d'instrumentation : mesure PID, timing, capture résultat/erreur,
-- deadlock/timeout, état final. NE tient PAS le verrou (retourne aussitôt).
CREATE OR REPLACE FUNCTION public.cc_apply(p_scn text, p_sess text, p_pid uuid, p_key text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); res jsonb; err text; op uuid; st text;
        v_emp uuid; v_dl boolean := false; v_to boolean := false; d0 date; d1 date; spc int; auc int; ik text; ist text;
BEGIN
  SELECT employee_id, period_from, period_to INTO v_emp, d0, d1 FROM group_move_proposals WHERE id=p_pid;
  BEGIN
    res := public.group_move_apply(p_pid, p_key);
    op := (res->>'operation_id')::uuid;
  EXCEPTION
    WHEN deadlock_detected THEN err := SQLERRM; v_dl := true;
    WHEN query_canceled     THEN err := SQLERRM; v_to := true;   -- statement_timeout
    WHEN others             THEN err := SQLERRM;
  END;
  SELECT status INTO st FROM group_move_proposals WHERE id=p_pid;
  SELECT count(*) INTO spc FROM staff_planning WHERE employee_id=v_emp AND day BETWEEN coalesce(d0,'2035-01-01') AND coalesce(d1,d0,'2035-12-31');
  SELECT count(*) INTO auc FROM planning_audit  WHERE employee_id=v_emp AND day BETWEEN coalesce(d0,'2035-01-01') AND coalesce(d1,d0,'2035-12-31');
  SELECT idempotency_key, status INTO ik, ist FROM group_move_applications WHERE idempotency_key=p_key;
  INSERT INTO public.cc_results VALUES
   (p_scn,p_sess,t0,clock_timestamp(),extract(epoch FROM (clock_timestamp()-t0))*1000,
    pg_backend_pid(),p_pid,v_emp,d0,res,err,op,st,spc,auc,p_key,ist,v_dl,v_to);
  RETURN jsonb_build_object('result',res,'error',err,'wait_ms',extract(epoch FROM (clock_timestamp()-t0))*1000,'final_status',st);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) PRÉPARATION DES PROPOSITIONS (session admin). Workflow [] = auto-approuvé.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claim.sub','<MGR>',true);
SELECT group_move_workflow_set((SELECT group_id FROM hotels WHERE id='<FO>'), '[]'::jsonb);

-- helper de création d'une proposition approuvée (retourne l'id) :
--   SELECT create_appr(:day1, :day2, :slots_jsonb)  -- à adapter
-- Exemple journée complète (jour J) :
--   INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end)
--     VALUES ('<FO>','<EMP>','2035-06-02','P',1,0,'J','08:00','16:00');       -- (omettre pour scénario E)
--   WITH p AS (SELECT group_move_proposal_create(jsonb_build_object(
--     'employee_id','<EMP>','from_hotel_id','<FO>','to_hotel_id','<VO>',
--     'to_service','Réception','from_service','Réception',
--     'period_from','2035-06-02','period_to','2035-06-02',
--     'slots', jsonb_build_array(jsonb_build_object('date','2035-06-02')),
--     'decision','allowed','simulation',jsonb_build_object('blockers','[]'::jsonb))) id)
--   SELECT group_move_proposal_submit(id) FROM p RETURNING (SELECT id FROM p);  -- => <PID>
-- Créer ainsi : <PID_A> (jour J), <PID_C2> (2e prop, même jour J, même créneau),
--   <PID_D2> (jour J+1), <PID_E> (jour K, SANS ligne staff_planning préalable),
--   <PID_F> (jour L), <PID_G> (jour M).

-- Chaque session psql doit d'abord poser l'identité :
--   SELECT set_config('request.jwt.claim.sub','<MGR>', true);
--   SELECT pg_backend_pid();       -- noter le PID de la session
--   \timing on

-- ─────────────────────────────────────────────────────────────────────────────
-- SCÉNARIO A — MÊME proposition, MÊME clé d'idempotence
--   Attendu : une seule application ; la 2e session récupère le résultat mémorisé
--   (idempotent) OU attend puis retourne le même operation_id ; jamais de doublon.
-- Session A : BEGIN; SELECT set_config('request.jwt.claim.sub','<MGR>',true);
--             SELECT cc_apply('A','A','<PID_A>','KEY-A'); SELECT pg_sleep(10); COMMIT;
-- Session B (<10s après) : BEGIN; SELECT set_config('request.jwt.claim.sub','<MGR>',true);
--             SELECT cc_apply('A','B','<PID_A>','KEY-A');  -- BLOQUE (advisory) puis idempotent
--             COMMIT;

-- SCÉNARIO B — MÊME proposition, DEUX clés différentes
--   Attendu : A applique ; B attend le verrou puis échoue proprement
--   ('Statut non applicable (applied)') ; une seule application.
-- Session A : BEGIN; ...; SELECT cc_apply('B','A','<PID_A>','KEY-B1'); SELECT pg_sleep(10); COMMIT;
-- Session B : BEGIN; ...; SELECT cc_apply('B','B','<PID_A>','KEY-B2'); COMMIT;   -- wait_ms ~ reste de A

-- SCÉNARIO C — DEUX propositions, même collaborateur & même créneau
--   Attendu : une seule appliquée ; l'autre refusée (priorité/concurrence) OU
--   exclusion_violation sur segments ; contrainte d'exclusion intacte.
-- Session A : BEGIN; ...; SELECT cc_apply('C','A','<PID_A>','KEY-C1'); SELECT pg_sleep(10); COMMIT;
-- Session B : BEGIN; ...; SELECT cc_apply('C','B','<PID_C2>','KEY-C2'); COMMIT;

-- SCÉNARIO D — DEUX propositions, même collaborateur, JOURS DIFFÉRENTS
--   Attendu : AUCUN blocage (clés advisory (emp||jour) distinctes) ; les DEUX
--   réussissent ; wait_ms de B faible (pas de sérialisation excessive).
-- Session A : BEGIN; ...; SELECT cc_apply('D','A','<PID_A>','KEY-D1'); SELECT pg_sleep(10); COMMIT;
-- Session B : BEGIN; ...; SELECT cc_apply('D','B','<PID_D2>','KEY-D2'); COMMIT;   -- ne bloque pas

-- SCÉNARIO E — AUCUNE ligne destination préexistante
--   (<PID_E> créé SANS insertion staff_planning). Rejouer A/B.
--   Attendu : B BLOQUE quand même (advisory lock sur (emp||jour), indépendant de
--   FOR UPDATE) puis échoue proprement -> prouve la sérialisation sans ligne.
-- Session A : BEGIN; ...; SELECT cc_apply('E','A','<PID_E>','KEY-E1'); SELECT pg_sleep(10); COMMIT;
-- Session B : BEGIN; ...; SELECT cc_apply('E','B','<PID_E>','KEY-E2'); COMMIT;

-- SCÉNARIO F — ERREUR injectée dans la 1re transaction puis reprise par la 2e
--   Session A applique puis force un ROLLBACK (l'application est annulée, verrou
--   libéré). Session B applique ensuite avec succès.
-- Session A : BEGIN; SELECT set_config('request.jwt.claim.sub','<MGR>',true);
--             SELECT cc_apply('F','A','<PID_F>','KEY-F1');   -- écrit (non commité)
--             SELECT pg_sleep(6);
--             ROLLBACK;                                       -- erreur/annulation injectée
-- Session B (<6s après) : BEGIN; ...; SELECT cc_apply('F','B','<PID_F>','KEY-F2'); COMMIT;
--   Attendu : A annulée (aucune ligne, aucune clé) ; B appliquée normalement.

-- SCÉNARIO G — TIMEOUT client puis RETRY avec la même clé
--   Session A applique et COMMITE (serveur OK) mais le "client" ne reçoit pas la
--   réponse. Le retry (même clé) doit être idempotent (résultat mémorisé, aucun
--   doublon). Sous-cas G2 : si A avait rollback, le retry ré-applique.
-- Session A : BEGIN; ...; SELECT cc_apply('G','A','<PID_G>','KEY-G'); COMMIT;      -- serveur committé
-- Session A (retry, "après timeout") : BEGIN; ...; SELECT cc_apply('G','A-retry','<PID_G>','KEY-G'); COMMIT;
--   Attendu : 2e appel -> même operation_id, idem_status='completed', sp_count inchangé.

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) VÉRIFICATION FINALE (session admin) — une ligne par (scénario, session)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT scenario, session_label, backend_pid, proposal_id, employee_id, locked_day,
       round(wait_ms) AS wait_ms, final_status, operation_id, idem_key, idem_status,
       sp_count, audit_count, deadlock, timeout_hit,
       coalesce(error_text, (rpc_result->>'applied')) AS outcome
FROM public.cc_results ORDER BY scenario, session_label;

-- Contrôles d'intégrité attendus :
--   * A/B/C/E : exactement UNE ligne 'applied'=true par scénario ; l'autre en
--     erreur ('Statut non applicable' / concurrente prioritaire / exclusion).
--   * B/E : wait_ms de la session B >~ durée du pg_sleep de A (blocage réel).
--   * D : wait_ms de B faible ; les DEUX 'applied'=true.
--   * F : session A error/rollback (aucune écriture) ; B 'applied'=true.
--   * G : A-retry -> même operation_id, idem_status='completed', sp_count inchangé.
--   * deadlock = false partout ; timeout_hit = false (sauf test dédié).
-- Aucune ligne 'processing' orpheline :
SELECT * FROM group_move_applications WHERE status='processing';   -- attendu : 0 ligne
-- Aucun chevauchement de segments :
SELECT employee_id, day, count(*) FROM staff_planning_segments s
  WHERE EXISTS (SELECT 1 FROM staff_planning_segments t
                WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
                  AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min))
  GROUP BY 1,2;   -- attendu : 0 ligne

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) NETTOYAGE (session admin)
-- ─────────────────────────────────────────────────────────────────────────────
-- DELETE FROM group_move_proposals WHERE id IN ('<PID_A>','<PID_C2>','<PID_D2>','<PID_E>','<PID_F>','<PID_G>');
-- DELETE FROM staff_planning_segments WHERE employee_id='<EMP>' AND day >= '2035-01-01';
-- DELETE FROM staff_planning          WHERE employee_id='<EMP>' AND day >= '2035-01-01';
-- DELETE FROM planning_audit          WHERE employee_id='<EMP>' AND day >= '2035-01-01';
-- DROP FUNCTION public.cc_apply(text,text,uuid,text);
-- DROP TABLE public.cc_results;
