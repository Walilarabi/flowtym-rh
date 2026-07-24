CREATE TABLE IF NOT EXISTS public.cc_results (
  scenario     text, session_label text,
  t_start      timestamptz, t_end timestamptz,
  wait_ms      numeric,
  backend_pid  int,
  proposal_id  uuid, employee_id uuid, locked_day date,
  rpc_result   jsonb, error_text text,
  operation_id uuid,
  final_status text,
  sp_count     int,
  audit_count  int,
  idem_key     text, idem_status text,
  deadlock     boolean, timeout_hit boolean
);
TRUNCATE public.cc_results;

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
    WHEN query_canceled     THEN err := SQLERRM; v_to := true;
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
