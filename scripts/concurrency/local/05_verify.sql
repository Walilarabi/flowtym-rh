\echo '===== (1) SORTIE BRUTE ====='
SELECT scenario, session_label, backend_pid, round(wait_ms) AS wait_ms, final_status,
       left(operation_id::text,8) op8, idem_key, idem_status, sp_count, audit_count, deadlock, timeout_hit,
       coalesce(error_text, 'applied='||(rpc_result->>'applied')) AS outcome
FROM public.cc_results ORDER BY scenario, session_label;

\echo '===== (2) SYNTHÈSE A-G (PASS/FAIL) ====='
WITH agg AS (
  SELECT scenario, count(DISTINCT backend_pid) AS pids,
         count(DISTINCT operation_id) FILTER (WHERE operation_id IS NOT NULL) AS effective_apps,
         round(max(wait_ms)) AS max_wait_ms, round(min(wait_ms)) AS min_wait_ms,
         bool_or(deadlock) AS any_deadlock, bool_or(timeout_hit) AS any_timeout,
         count(*) FILTER (WHERE error_text IS NOT NULL) AS n_errors,
         string_agg(DISTINCT final_status, ',') AS final_statuses
  FROM public.cc_results GROUP BY scenario),
exp(scenario, effective_expected, both_apply, expect_block) AS (VALUES
  ('A',1,false,true), ('B',1,false,true), ('C',1,false,true),
  ('D',2,true,false),  ('E',1,false,true), ('F',1,false,true), ('G',1,false,false))
SELECT e.scenario, a.pids, a.effective_apps, e.effective_expected,
       a.min_wait_ms, a.max_wait_ms, a.any_deadlock, a.any_timeout, a.n_errors, a.final_statuses,
       CASE
         WHEN a.scenario IS NULL THEN 'NON EXÉCUTÉ'
         WHEN a.any_deadlock THEN 'FAIL: deadlock'
         WHEN a.effective_apps <> e.effective_expected THEN 'FAIL: '||a.effective_apps||' appli. (attendu '||e.effective_expected||')'
         WHEN e.expect_block AND a.max_wait_ms < 1000 THEN 'FAIL: pas de blocage observé'
         WHEN NOT e.expect_block AND e.both_apply AND a.max_wait_ms >= 1000 THEN 'WARN: sérialisation inattendue (jours différents)'
         ELSE 'PASS'
       END AS verdict
FROM exp e LEFT JOIN agg a USING (scenario) ORDER BY e.scenario;

\echo '===== (3) ÉTAT FINAL DES TABLES ====='
SELECT 'staff_planning' t, hotel_id::text, day::text, status, shift_start::text, shift_end::text, left(source_proposal_id::text,8)
  FROM staff_planning WHERE day >= '2035-01-01' ORDER BY day, hotel_id;
SELECT 'segments' t, hotel_id::text, day::text, kind, (seg_start_min/60)||'h-'||(seg_end_min/60)||'h', status
  FROM staff_planning_segments WHERE day >= '2035-01-01' ORDER BY day, seg_start_min;
SELECT 'applications' t, idem_key, status, left(operation_id::text,8) FROM group_move_applications g JOIN (SELECT idempotency_key idem_key FROM group_move_applications) x ON true WHERE g.idempotency_key=x.idem_key GROUP BY idem_key, status, operation_id ORDER BY idem_key;

\echo '===== (4) ANOMALIES (doivent renvoyer 0 ligne) ====='
SELECT 'orphan_processing' anomaly, count(*) FROM group_move_applications WHERE status='processing';
SELECT 'segment_overlap' anomaly, count(*) FROM staff_planning_segments s
  WHERE EXISTS (SELECT 1 FROM staff_planning_segments t WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
                AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min));
SELECT 'multi_operation_per_apply' anomaly, count(*) FROM (
  SELECT source_proposal_id FROM staff_planning sp JOIN group_move_proposals p ON p.id=sp.source_proposal_id
  WHERE sp.day >= '2035-01-01' GROUP BY 1,p.applied_operation_id HAVING count(DISTINCT p.applied_operation_id) > 1) z;

\echo '===== (5) VERDICT GO / NO-GO ====='
WITH agg AS (
  SELECT scenario, bool_or(deadlock) dl,
         count(DISTINCT operation_id) FILTER (WHERE operation_id IS NOT NULL) eff
  FROM public.cc_results GROUP BY scenario),
exp(scenario, eff_exp) AS (VALUES ('A',1),('B',1),('C',1),('D',2),('E',1),('F',1),('G',1)),
checks AS (
  SELECT
    (SELECT count(*) FROM exp WHERE scenario NOT IN (SELECT scenario FROM agg)) AS missing_scenarios,
    (SELECT count(*) FROM agg WHERE dl) AS deadlocks,
    (SELECT count(*) FROM exp e JOIN agg a USING(scenario) WHERE a.eff <> e.eff_exp) AS wrong_effective,
    (SELECT count(*) FROM group_move_applications WHERE status='processing') AS orphans,
    (SELECT count(*) FROM staff_planning_segments s WHERE EXISTS (SELECT 1 FROM staff_planning_segments t
        WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
          AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min))) AS overlaps)
SELECT *, CASE WHEN missing_scenarios=0 AND deadlocks=0 AND wrong_effective=0 AND orphans=0 AND overlaps=0
               THEN 'GO' ELSE 'NO-GO' END AS verdict
FROM checks;
