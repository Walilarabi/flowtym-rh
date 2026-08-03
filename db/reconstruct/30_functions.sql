-- ============================================================================
-- Fonctions & triggers — corps VERBATIM extraits du schéma live (DDL only).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pl_my_hotels()
 RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$
  SELECT uh.hotel_id FROM public.user_hotels uh
  JOIN public.users u ON u.id = uh.user_id WHERE u.auth_id = auth.uid();
$function$;

-- get_user_hotel_id()/set_active_hotel() (verbatim schéma live) — l'hôtel réellement ACTIF de
-- l'appelant, source de vérité déjà utilisée par la RLS de `hotels` (hotels_select : id =
-- get_user_hotel_id()) ; sql/98 en fait aussi la source de vérité pour le groupe courant.
CREATE OR REPLACE FUNCTION public.get_user_hotel_id()
 RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid(); v_user_id uuid; v_hotel_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_user_id FROM public.users WHERE auth_id = v_auth_uid LIMIT 1;
  IF v_user_id IS NULL THEN RETURN NULL; END IF;

  SELECT uah.hotel_id INTO v_hotel_id FROM public.user_active_hotel uah
    WHERE uah.user_id = v_user_id
      AND EXISTS (SELECT 1 FROM public.user_hotels uh WHERE uh.user_id = v_user_id AND uh.hotel_id = uah.hotel_id)
    LIMIT 1;
  IF v_hotel_id IS NOT NULL THEN RETURN v_hotel_id; END IF;

  SELECT uh.hotel_id INTO v_hotel_id FROM public.user_hotels uh
    WHERE uh.user_id = v_user_id AND uh.is_default = true LIMIT 1;
  RETURN v_hotel_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_active_hotel(p_hotel_id uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE v_user_id uuid; v_has_access boolean;
BEGIN
  SELECT id INTO v_user_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT EXISTS (SELECT 1 FROM public.user_hotels WHERE user_id = v_user_id AND hotel_id = p_hotel_id) INTO v_has_access;
  IF NOT v_has_access THEN RAISE EXCEPTION 'User does not have access to hotel %', p_hotel_id USING ERRCODE = '42501'; END IF;
  INSERT INTO public.user_active_hotel (user_id, hotel_id, switched_at)
  VALUES (v_user_id, p_hotel_id, now())
  ON CONFLICT (user_id) DO UPDATE SET hotel_id = EXCLUDED.hotel_id, switched_at = EXCLUDED.switched_at;
  RETURN true;
END;
$function$;

-- RLS employees (verbatim schéma live) — nécessaire pour que
-- sql/tests/tenant_isolation_group_planning.sql exerce une isolation réelle sous le rôle
-- `authenticated`, pas seulement la logique interne des RPC SECURITY DEFINER. Dépend de
-- pl_my_hotels() ci-dessus, d'où son placement ici plutôt que dans 10_foundation.sql.
CREATE OR REPLACE FUNCTION public.pl_portal_employee_id()
 RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT id FROM public.employees WHERE portal_auth_id = auth.uid() AND portal_enabled = true LIMIT 1
$function$;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
CREATE POLICY employees_rls ON public.employees
  FOR ALL USING (hotel_id IN (SELECT pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT pl_my_hotels()));
CREATE POLICY employees_portal_self ON public.employees
  FOR SELECT USING (id = pl_portal_employee_id());
GRANT SELECT ON public.employees TO authenticated, anon;

ALTER TABLE public.group_move_proposals ENABLE ROW LEVEL SECURITY;
CREATE POLICY gmp_access ON public.group_move_proposals
  FOR ALL
  USING (from_hotel_id IN (SELECT pl_my_hotels()) AND to_hotel_id IN (SELECT pl_my_hotels()))
  WITH CHECK (from_hotel_id IN (SELECT pl_my_hotels()) AND to_hotel_id IN (SELECT pl_my_hotels()));
GRANT SELECT ON public.group_move_proposals TO authenticated, anon;

ALTER TABLE public.staff_planning_segments ENABLE ROW LEVEL SECURITY;
CREATE POLICY sps_manager ON public.staff_planning_segments
  FOR SELECT USING (hotel_id IN (SELECT pl_my_hotels()) OR origin_hotel_id IN (SELECT pl_my_hotels()));
GRANT SELECT ON public.staff_planning_segments TO authenticated, anon;
GRANT SELECT ON public.v_staff_day_flags TO authenticated, anon;

CREATE OR REPLACE FUNCTION public._gmp_can_access(p_from uuid, p_to uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT p_from IN (SELECT public.pl_my_hotels()) AND p_to IN (SELECT public.pl_my_hotels());
$function$;

CREATE OR REPLACE FUNCTION public._gmp_notify(p_proposal uuid, p_event text, p_recipient text, p_hotel uuid, p_payload jsonb)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  INSERT INTO group_move_notifications(proposal_id, event, recipient_type, recipient_hotel_id, payload)
  VALUES (p_proposal, p_event, p_recipient, p_hotel, coalesce(p_payload,'{}'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public._gmp_subtract(p_os integer, p_oe integer, p_cuts int4range[])
 RETURNS int4range[] LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE segs int4range[] := ARRAY[int4range(p_os,p_oe)]; c int4range; s int4range; out int4range[];
BEGIN
  FOREACH c IN ARRAY coalesce(p_cuts, ARRAY[]::int4range[]) LOOP
    out := ARRAY[]::int4range[];
    FOREACH s IN ARRAY segs LOOP
      IF NOT (s && c) THEN out := out || s;
      ELSE
        IF lower(s) < lower(c) THEN out := out || int4range(lower(s), lower(c)); END IF;
        IF upper(s) > upper(c) THEN out := out || int4range(upper(c), upper(s)); END IF;
      END IF;
    END LOOP;
    segs := out;
  END LOOP;
  RETURN segs;
END $function$;

CREATE OR REPLACE FUNCTION public._gmp_fingerprint(p_emp uuid, p_from date, p_to date, p_from_hotel uuid, p_to_hotel uuid, p_to_service text)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT md5(
       'PLAN:' || coalesce((SELECT string_agg(hotel_id::text||'|'||day::text||'|'||status||'|'||coalesce(shift_start::text,'')||'|'||coalesce(shift_end::text,'')||'|'||coalesce(hours::text,''), ';' ORDER BY hotel_id, day)
                  FROM staff_planning WHERE employee_id=p_emp AND day BETWEEN p_from AND coalesce(p_to,p_from)),'∅')
    ||'#ABS:' || coalesce((SELECT string_agg(type||'|'||start_date::text||'|'||end_date::text||'|'||status, ';' ORDER BY start_date)
                  FROM staff_absences WHERE employee_id=p_emp AND start_date<=coalesce(p_to,p_from) AND end_date>=p_from),'∅')
    ||'#REQ:' || coalesce((SELECT string_agg(weekday::text||coalesce('/'||shift,'')||':'||required_count::text, ',' ORDER BY weekday, coalesce(shift,''))
                  FROM group_staffing_requirements WHERE hotel_id=p_to_hotel AND service_name=p_to_service),'∅')
    ||'#TRV:' || coalesce((SELECT duration_min::text||'/'||safety_margin_min::text FROM hotel_travel_times WHERE from_hotel_id=p_from_hotel AND to_hotel_id=p_to_hotel LIMIT 1),'∅')
    ||'#WF:'  || coalesce((SELECT w.steps::text FROM group_move_workflows w JOIN hotels h ON h.group_id=w.group_id WHERE h.id=p_from_hotel LIMIT 1),'default')
    ||'#COV:' || coalesce((SELECT (g.features->'coverage')::text FROM hotel_groups g JOIN hotels h ON h.group_id=g.id WHERE h.id=p_from_hotel LIMIT 1),'default')
  );
$function$;

CREATE OR REPLACE FUNCTION public._gmp_guard(p_id uuid)
 RETURNS group_move_proposals LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r group_move_proposals;
BEGIN
  SELECT * INTO r FROM group_move_proposals WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition introuvable'; END IF;
  IF NOT public._gmp_can_access(r.from_hotel_id, r.to_hotel_id) THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  RETURN r;
END $function$;

-- group_move_timeline : version corrigée (sql/97, P0 sécurité 2026-08-03) — filtre désormais
-- from_hotel_id/to_hotel_id dans pl_my_hotels() comme toutes les fonctions sœurs ci-dessous ;
-- la version live avant correctif ne vérifiait que l'existence de l'id, tous groupes confondus.
CREATE OR REPLACE FUNCTION public.group_move_timeline(p_id uuid)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('action',action,'old_status',old_status,'new_status',new_status,'comment',comment,'metadata',metadata,'at',created_at) ORDER BY created_at),'[]'::jsonb)
               FROM group_move_proposal_events WHERE proposal_id=p_id),
    'approvals', (SELECT coalesce(jsonb_agg(jsonb_build_object('step',step_index,'key',step_key,'approver_type',approver_type,'status',status,'decided_at',decided_at,'comment',comment) ORDER BY step_index),'[]'::jsonb)
                 FROM group_move_approvals WHERE proposal_id=p_id),
    'notifications', (SELECT coalesce(jsonb_agg(jsonb_build_object('event',event,'recipient',recipient_type,'sent_at',sent_at,'at',created_at) ORDER BY created_at),'[]'::jsonb)
                     FROM group_move_notifications WHERE proposal_id=p_id)
  )
  WHERE p_id IN (
    SELECT id FROM group_move_proposals
    WHERE from_hotel_id IN (SELECT public.pl_my_hotels())
      AND to_hotel_id IN (SELECT public.pl_my_hotels())
  );
$function$;

CREATE OR REPLACE FUNCTION public.group_move_open_for_employee(p_emp uuid, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, employee_id uuid, status text, slots jsonb, created_at timestamp with time zone, score integer, scheduled_at timestamp with time zone)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT id, employee_id, status, slots, created_at, score, scheduled_at
  FROM group_move_proposals
  WHERE employee_id = p_emp AND status IN ('draft','pending_review','approved','scheduled')
    AND (p_exclude IS NULL OR id <> p_exclude)
    AND from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels());
$function$;

CREATE OR REPLACE FUNCTION public.group_move_workflow_get(p_group uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  SELECT steps INTO v FROM group_move_workflows WHERE group_id=p_group;
  IF v IS NULL THEN
    v := jsonb_build_array(jsonb_build_object('key','dest_director','label','Directeur hôtel destination','approver_type','dest_director','hotel_scope','dest'));
  END IF;
  RETURN v;
END $function$;

CREATE OR REPLACE FUNCTION public.group_move_workflow_set(p_group uuid, p_steps jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF p_group NOT IN (SELECT group_id FROM hotels WHERE id IN (SELECT public.pl_my_hotels())) THEN RAISE EXCEPTION 'Accès refusé à ce groupe'; END IF;
  IF jsonb_typeof(p_steps) <> 'array' THEN RAISE EXCEPTION 'steps doit être un tableau'; END IF;
  INSERT INTO group_move_workflows(group_id, steps, updated_by, updated_at)
  VALUES (p_group, p_steps, auth.uid(), now())
  ON CONFLICT (group_id) DO UPDATE SET steps=EXCLUDED.steps, updated_by=auth.uid(), updated_at=now();
END $function$;

CREATE OR REPLACE FUNCTION public.group_move_proposal_create(p jsonb)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_from uuid := (p->>'from_hotel_id')::uuid; v_to uuid := (p->>'to_hotel_id')::uuid;
        v_gid uuid; v_hard int; v_decision text := p->>'decision'; v_pf date := (p->>'period_from')::date; v_pt date := (p->>'period_to')::date; v_svc text := p->>'to_service'; v_emp uuid := (p->>'employee_id')::uuid;
BEGIN
  IF NOT public._gmp_can_access(v_from, v_to) THEN RAISE EXCEPTION 'Accès refusé aux établissements concernés'; END IF;
  v_hard := (SELECT count(*) FROM jsonb_array_elements(coalesce(p->'simulation'->'blockers','[]'::jsonb)) b WHERE coalesce((b->>'waivable')::boolean,false) = false);
  IF v_hard > 0 THEN RAISE EXCEPTION 'Blocage non dérogeable : création du brouillon impossible'; END IF;
  SELECT group_id INTO v_gid FROM hotels WHERE id = v_from;
  INSERT INTO group_move_proposals(group_id, employee_id, from_hotel_id, to_hotel_id, from_service, to_service,
     period_from, period_to, slots, reason, status, decision, score, confidence, simulation,
     simulation_created_at, simulation_input_hash, simulation_result_hash, expires_at, created_by, server_fingerprint)
  VALUES (v_gid, v_emp, v_from, v_to, p->>'from_service', v_svc,
     v_pf, v_pt, coalesce(p->'slots','[]'::jsonb), p->>'reason',
     'draft', v_decision, nullif(p->>'score','')::int, nullif(p->>'confidence','')::int, p->'simulation',
     coalesce((p->>'simulation_created_at')::timestamptz, now()), p->>'simulation_input_hash', p->>'simulation_result_hash',
     coalesce((p->>'expires_at')::timestamptz, now() + interval '7 days'), auth.uid(),
     public._gmp_fingerprint(v_emp, v_pf, v_pt, v_from, v_to, v_svc))
  RETURNING id INTO v_id;
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (v_id, auth.uid(), 'created', null, 'draft', jsonb_build_object('decision', v_decision));
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.group_move_proposal_submit(p_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r group_move_proposals; v_missing int; v_steps jsonb; v_step jsonb; i int; v_scope text; v_hotel uuid; v_gid uuid;
BEGIN
  r := public._gmp_guard(p_id);
  IF r.status <> 'draft' THEN RAISE EXCEPTION 'Seul un brouillon peut être soumis'; END IF;
  v_missing := (SELECT count(*) FROM jsonb_array_elements(coalesce(r.simulation->'blockers','[]'::jsonb)) b
                WHERE (b->>'code') NOT IN (SELECT check_code FROM group_move_proposal_waivers WHERE proposal_id = p_id));
  IF v_missing > 0 THEN RAISE EXCEPTION 'Dérogation requise pour chaque blocage avant soumission'; END IF;

  SELECT group_id INTO v_gid FROM hotels WHERE id=r.from_hotel_id;
  v_steps := public.group_move_workflow_get(v_gid);
  DELETE FROM group_move_approvals WHERE proposal_id=p_id;

  IF jsonb_array_length(v_steps) = 0 THEN
    UPDATE group_move_proposals SET status='approved', updated_at=now() WHERE id=p_id;
    INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
    VALUES (p_id, auth.uid(), 'approved', 'draft', 'approved', jsonb_build_object('auto', true));
    PERFORM public._gmp_notify(p_id, 'approved', 'creator', null, jsonb_build_object('auto', true));
    RETURN;
  END IF;

  FOR i IN 0 .. jsonb_array_length(v_steps)-1 LOOP
    v_step := v_steps->i;
    v_scope := coalesce(v_step->>'hotel_scope','any');
    INSERT INTO group_move_approvals(proposal_id, step_index, step_key, approver_type, hotel_scope, status)
    VALUES (p_id, i, v_step->>'key', v_step->>'approver_type', v_scope, 'pending');
  END LOOP;

  UPDATE group_move_proposals SET status='pending_review', updated_at=now() WHERE id=p_id;
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (p_id, auth.uid(), 'submitted', 'draft', 'pending_review', jsonb_build_object('steps', jsonb_array_length(v_steps)));

  v_step := v_steps->0; v_scope := coalesce(v_step->>'hotel_scope','any');
  v_hotel := CASE v_scope WHEN 'origin' THEN r.from_hotel_id WHEN 'dest' THEN r.to_hotel_id ELSE NULL END;
  PERFORM public._gmp_notify(p_id, 'review_requested', v_step->>'approver_type', v_hotel, jsonb_build_object('step', 0));
END $function$;

CREATE OR REPLACE FUNCTION public.group_move_apply(p_id uuid, p_idempotency_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r group_move_proposals; v_op uuid; v_cur_fp text; v_unwaived int; v_existing group_move_applications;
        v_self_rank int; v_other record; v_days date[]; d date; v_applied int := 0; v_vacated int := 0; v_segs int := 0;
        v_cuts int4range[]; v_dstart int; v_dend int; v_full boolean; v_slot jsonb; v_kept int4range[]; kr int4range;
        v_oshift record; v_os int; v_oe int; v_dmin int; v_dmax int; v_anyfull boolean; v_result jsonb; v_validation jsonb;
BEGIN
  SELECT * INTO r FROM group_move_proposals WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition introuvable'; END IF;
  IF NOT public._gmp_can_access(r.from_hotel_id, r.to_hotel_id) THEN RAISE EXCEPTION 'Accès refusé'; END IF;

  SELECT array_agg(DISTINCT (s->>'date')::date ORDER BY (s->>'date')::date) INTO v_days
    FROM jsonb_array_elements(r.slots) s WHERE (s->>'date') IS NOT NULL;
  FOREACH d IN ARRAY coalesce(v_days, ARRAY[]::date[]) LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(r.employee_id::text || '|' || d::text, 0));
  END LOOP;

  SELECT * INTO v_existing FROM group_move_applications WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.status='completed' THEN RETURN coalesce(v_existing.result, jsonb_build_object('idempotent', true)); END IF;
    RAISE EXCEPTION 'Application déjà en cours pour cette clé';
  END IF;
  v_op := gen_random_uuid();
  INSERT INTO group_move_applications(idempotency_key, proposal_id, operation_id, applied_by, status)
  VALUES (p_idempotency_key, p_id, v_op, auth.uid(), 'processing');

  IF r.status = 'scheduled' THEN
    IF r.scheduled_at IS NULL OR r.scheduled_at > now() THEN RAISE EXCEPTION 'Programmé non arrivé à échéance'; END IF;
  ELSIF r.status <> 'approved' THEN RAISE EXCEPTION 'Statut non applicable (%).', r.status; END IF;

  IF r.decision = 'blocked' THEN RAISE EXCEPTION 'Proposition bloquée'; END IF;
  v_unwaived := (SELECT count(*) FROM jsonb_array_elements(coalesce(r.simulation->'blockers','[]'::jsonb)) b
                 WHERE (b->>'code') NOT IN (SELECT check_code FROM group_move_proposal_waivers WHERE proposal_id=p_id));
  IF v_unwaived > 0 THEN RAISE EXCEPTION 'Blocage non dérogé'; END IF;
  IF r.expires_at IS NOT NULL AND r.expires_at < now() THEN RAISE EXCEPTION 'Proposition expirée'; END IF;
  v_cur_fp := public._gmp_fingerprint(r.employee_id, r.period_from, r.period_to, r.from_hotel_id, r.to_hotel_id, r.to_service);
  IF r.server_fingerprint IS NOT NULL AND v_cur_fp <> r.server_fingerprint THEN
    UPDATE group_move_proposals SET staleness='to_refresh' WHERE id=p_id;
    RAISE EXCEPTION 'Données modifiées depuis la simulation : re-simulation requise';
  END IF;
  v_self_rank := CASE r.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 ELSE 0 END;
  FOR v_other IN SELECT * FROM group_move_open_for_employee(r.employee_id, p_id) o
    WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(r.slots) a JOIN jsonb_array_elements(o.slots) b ON (a->>'date')=(b->>'date'))
  LOOP
    IF (CASE v_other.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 WHEN 'pending_review' THEN 3 WHEN 'draft' THEN 2 ELSE 0 END) > v_self_rank
       OR ((CASE v_other.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 WHEN 'pending_review' THEN 3 WHEN 'draft' THEN 2 ELSE 0 END)=v_self_rank AND v_other.created_at < r.created_at) THEN
      RAISE EXCEPTION 'Proposition concurrente prioritaire : revalidation nécessaire';
    END IF;
  END LOOP;

  PERFORM 1 FROM staff_planning WHERE employee_id=r.employee_id AND day = ANY(v_days) FOR UPDATE;

  v_validation := jsonb_build_object(
    'level', CASE WHEN jsonb_array_length(coalesce(r.simulation->'missing','[]'::jsonb)) > 0 THEN 'validation_partielle' ELSE 'valide_sur_donnees_disponibles' END,
    'checks_run', jsonb_build_array('planning','couverture','absences','trajet','chevauchement','expiration','concurrence','derogations','visibilite_extra'),
    'checks_unavailable', jsonb_build_array('competences','disponibilites','regles_rh_variables'),
    'missing', coalesce(r.simulation->'missing','[]'::jsonb)
  );

  PERFORM set_config('flowtym.audit_source','group_planning', true);
  PERFORM set_config('flowtym.audit_reason', coalesce(r.reason,'Renfort inter-hôtels'), true);
  PERFORM set_config('flowtym.operation_id', v_op::text, true);
  PERFORM set_config('flowtym.allow_move_write','on', true);

  FOREACH d IN ARRAY coalesce(v_days, ARRAY[]::date[]) LOOP
    v_cuts := ARRAY[]::int4range[]; v_dmin := NULL; v_dmax := NULL; v_anyfull := false;
    FOR v_slot IN SELECT * FROM jsonb_array_elements(r.slots) WHERE (value->>'date')::date = d LOOP
      IF nullif(v_slot->>'start','') IS NULL OR nullif(v_slot->>'end','') IS NULL THEN v_dstart := 0; v_dend := 1440; v_anyfull := true;
      ELSE v_dstart := extract(hour FROM (v_slot->>'start')::time)*60 + extract(minute FROM (v_slot->>'start')::time);
           v_dend := extract(hour FROM (v_slot->>'end')::time)*60 + extract(minute FROM (v_slot->>'end')::time); END IF;
      v_cuts := v_cuts || int4range(v_dstart, v_dend);
      INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
      VALUES (r.to_hotel_id, r.employee_id, d, v_dstart, v_dend, 'destination', 'PE', p_id, r.from_hotel_id);
      v_segs := v_segs + 1; v_dmin := least(coalesce(v_dmin,v_dstart), v_dstart); v_dmax := greatest(coalesce(v_dmax,v_dend), v_dend);
    END LOOP;
    SELECT shift_start, shift_end, status INTO v_oshift FROM staff_planning WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d;
    IF FOUND THEN
      IF v_oshift.shift_start IS NOT NULL THEN v_os := extract(hour FROM v_oshift.shift_start)*60 + extract(minute FROM v_oshift.shift_start);
           v_oe := extract(hour FROM v_oshift.shift_end)*60 + extract(minute FROM v_oshift.shift_end);
      ELSE v_os := 0; v_oe := 1440; END IF;
      v_kept := public._gmp_subtract(v_os, v_oe, v_cuts);
      FOREACH kr IN ARRAY v_kept LOOP
        INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
        VALUES (r.from_hotel_id, r.employee_id, d, lower(kr), upper(kr), 'origin', 'P', p_id, r.from_hotel_id);
        v_segs := v_segs + 1;
      END LOOP;
      IF coalesce(array_length(v_kept,1),0)=0 THEN
        UPDATE staff_planning SET status='MAD', shift_label=NULL, shift_start=NULL, shift_end=NULL, hours=NULL, source_proposal_id=p_id, updated_by=auth.uid(), updated_at=now()
         WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d;
        v_vacated := v_vacated + 1;
      ELSE
        UPDATE staff_planning SET shift_start=make_time((lower(v_kept[1])/60),(lower(v_kept[1])%60),0),
               shift_end=make_time(least(upper(v_kept[array_length(v_kept,1)]),1439)/60, upper(v_kept[array_length(v_kept,1)])%60,0),
               source_proposal_id=p_id, updated_by=auth.uid(), updated_at=now()
         WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d AND status IN ('P','PE');
      END IF;
    END IF;
    INSERT INTO staff_planning(hotel_id, employee_id, day, status, duration, break_minutes, shift_start, shift_end, shift_label, source_proposal_id, origin_hotel_id, updated_by)
    VALUES (r.to_hotel_id, r.employee_id, d, 'PE', 1, 0,
            CASE WHEN v_anyfull THEN NULL ELSE make_time(v_dmin/60, v_dmin%60, 0) END,
            CASE WHEN v_anyfull THEN NULL ELSE make_time(least(v_dmax,1439)/60, v_dmax%60, 0) END,
            CASE WHEN v_anyfull THEN NULL ELSE 'custom' END, p_id, r.from_hotel_id, auth.uid())
    ON CONFLICT (hotel_id, employee_id, day) DO UPDATE SET status='PE', shift_start=EXCLUDED.shift_start, shift_end=EXCLUDED.shift_end,
      shift_label=EXCLUDED.shift_label, source_proposal_id=EXCLUDED.source_proposal_id, origin_hotel_id=EXCLUDED.origin_hotel_id, updated_by=EXCLUDED.updated_by, updated_at=now();
    v_applied := v_applied + 1;
  END LOOP;

  -- Visibilité extra (cf. sql/57_group_move_apply_visibility.sql) — même
  -- transaction : toute exception rollback l'intégralité (atomicité plpgsql).
  PERFORM public._gmp_ensure_visibility(
    r.employee_id, r.from_hotel_id, r.to_hotel_id, r.to_service, v_days,
    'group_move:' || p_id::text
  );

  UPDATE group_move_proposals SET status='applied', applied_at=now(), applied_operation_id=v_op, staleness='valid', updated_at=now() WHERE id=p_id;
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (p_id, auth.uid(), 'applied', r.status, 'applied', jsonb_build_object('operation_id', v_op, 'days', v_applied, 'segments', v_segs, 'origin_vacated', v_vacated, 'validation', v_validation));
  PERFORM public._gmp_notify(p_id, 'applied', 'creator', null, jsonb_build_object('operation_id', v_op));

  UPDATE group_move_proposals SET status='cancelled', updated_at=now()
   WHERE employee_id=r.employee_id AND id<>p_id AND status IN ('draft','pending_review','approved','scheduled')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(slots) b JOIN jsonb_array_elements(r.slots) a ON (a->>'date')=(b->>'date'));

  v_result := jsonb_build_object('applied', true, 'proposal_id', p_id, 'operation_id', v_op, 'days', v_applied, 'segments', v_segs, 'origin_vacated', v_vacated, 'validation', v_validation);
  UPDATE group_move_applications SET status='completed', result=v_result WHERE idempotency_key=p_idempotency_key;
  RETURN v_result;
END $function$;

CREATE OR REPLACE FUNCTION public.staff_planning_rebuild_day(p_emp uuid, p_day date)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE n int := 0; rec record;
BEGIN
  FOR rec IN
    SELECT hotel_id, min(seg_start_min) s, max(seg_end_min) e,
           max(source_proposal_id::text)::uuid sp, max(origin_hotel_id::text)::uuid oh,
           bool_or(seg_start_min=0 AND seg_end_min=1440) anyfull
    FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day AND kind='destination' GROUP BY hotel_id
  LOOP
    INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_start,shift_end,shift_label,source_proposal_id,origin_hotel_id)
    VALUES (rec.hotel_id,p_emp,p_day,'PE',1,0,
            CASE WHEN rec.anyfull THEN NULL ELSE make_time(rec.s/60,rec.s%60,0) END,
            CASE WHEN rec.anyfull THEN NULL ELSE make_time(least(rec.e,1439)/60,rec.e%60,0) END,
            CASE WHEN rec.anyfull THEN NULL ELSE 'custom' END, rec.sp, rec.oh)
    ON CONFLICT (hotel_id,employee_id,day) DO UPDATE SET status='PE',shift_start=EXCLUDED.shift_start,shift_end=EXCLUDED.shift_end,shift_label=EXCLUDED.shift_label,source_proposal_id=EXCLUDED.source_proposal_id,origin_hotel_id=EXCLUDED.origin_hotel_id;
    n := n+1;
  END LOOP;
  FOR rec IN
    SELECT hotel_id, min(seg_start_min) s, max(seg_end_min) e, max(source_proposal_id::text)::uuid sp
    FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day AND kind='origin' GROUP BY hotel_id
  LOOP
    INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_start,shift_end,shift_label,source_proposal_id,origin_hotel_id)
    VALUES (rec.hotel_id,p_emp,p_day,'P',1,0,make_time(rec.s/60,rec.s%60,0),make_time(least(rec.e,1439)/60,rec.e%60,0),'custom',rec.sp,rec.hotel_id)
    ON CONFLICT (hotel_id,employee_id,day) DO UPDATE SET status='P',shift_start=EXCLUDED.shift_start,shift_end=EXCLUDED.shift_end,shift_label=EXCLUDED.shift_label,source_proposal_id=EXCLUDED.source_proposal_id,origin_hotel_id=EXCLUDED.origin_hotel_id;
    n := n+1;
  END LOOP;
  FOR rec IN
    SELECT DISTINCT s.origin_hotel_id oh, max(s.source_proposal_id::text)::uuid sp
    FROM staff_planning_segments s
    WHERE s.employee_id=p_emp AND s.day=p_day AND s.kind='destination' AND s.origin_hotel_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM staff_planning_segments o WHERE o.employee_id=p_emp AND o.day=p_day AND o.kind='origin' AND o.hotel_id=s.origin_hotel_id)
    GROUP BY s.origin_hotel_id
  LOOP
    INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,source_proposal_id)
    VALUES (rec.oh,p_emp,p_day,'MAD',1,0,rec.sp)
    ON CONFLICT (hotel_id,employee_id,day) DO UPDATE SET status='MAD',shift_start=NULL,shift_end=NULL,shift_label=NULL,hours=NULL,source_proposal_id=EXCLUDED.source_proposal_id;
    n := n+1;
  END LOOP;
  RETURN n;
END $function$;

-- ── Triggers sur staff_planning (audit, touch, move guard) ───────────────────
CREATE OR REPLACE FUNCTION public.pl_touch_updated_at()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'pg_catalog','public'
AS $function$ begin new.updated_at = now(); return new; end $function$;

CREATE OR REPLACE FUNCTION public.trg_planning_audit()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_actor uuid := auth.uid(); v_name text; v_src text; v_action text; v_hotel uuid; v_emp uuid; v_day date;
        v_old jsonb; v_new jsonb; v_op uuid; v_reason text;
BEGIN
  IF TG_OP='INSERT' THEN
    v_action:='insert'; v_hotel:=NEW.hotel_id; v_emp:=NEW.employee_id; v_day:=NEW.day;
    v_new:=jsonb_build_object('status',NEW.status,'shift_label',NEW.shift_label,'duration',NEW.duration,'hours',NEW.hours,'note',NEW.note);
  ELSIF TG_OP='UPDATE' THEN
    IF OLD.status IS NOT DISTINCT FROM NEW.status AND OLD.shift_label IS NOT DISTINCT FROM NEW.shift_label
       AND OLD.duration IS NOT DISTINCT FROM NEW.duration AND OLD.hours IS NOT DISTINCT FROM NEW.hours
       AND OLD.note IS NOT DISTINCT FROM NEW.note THEN RETURN NEW; END IF;
    v_action:='update'; v_hotel:=NEW.hotel_id; v_emp:=NEW.employee_id; v_day:=NEW.day;
    v_old:=jsonb_build_object('status',OLD.status,'shift_label',OLD.shift_label,'duration',OLD.duration,'hours',OLD.hours,'note',OLD.note);
    v_new:=jsonb_build_object('status',NEW.status,'shift_label',NEW.shift_label,'duration',NEW.duration,'hours',NEW.hours,'note',NEW.note);
  ELSE
    v_action:='delete'; v_hotel:=OLD.hotel_id; v_emp:=OLD.employee_id; v_day:=OLD.day;
    v_old:=jsonb_build_object('status',OLD.status,'shift_label',OLD.shift_label,'duration',OLD.duration,'hours',OLD.hours,'note',OLD.note);
  END IF;

  v_src := nullif(current_setting('flowtym.audit_source', true),'');
  IF v_actor IS NOT NULL THEN
    SELECT coalesce(full_name,email) INTO v_name FROM users WHERE auth_id=v_actor LIMIT 1;
    IF v_name IS NOT NULL THEN IF v_src IS NULL THEN v_src:='app'; END IF;
    ELSE
      SELECT (first_name||' '||last_name) INTO v_name FROM employees WHERE portal_auth_id=v_actor LIMIT 1;
      IF v_name IS NOT NULL AND v_src IS NULL THEN v_src:='portail'; END IF;
    END IF;
  END IF;
  IF v_src IS NULL THEN v_src:='système'; END IF;

  v_op := coalesce(nullif(current_setting('flowtym.operation_id', true),'')::uuid,
                   md5(txid_current()::text||'|'||statement_timestamp()::text)::uuid);
  v_reason := nullif(current_setting('flowtym.audit_reason', true),'');

  INSERT INTO planning_audit(hotel_id,employee_id,day,action,old_values,new_values,actor_auth_id,actor_name,source,operation_id,reason)
    VALUES(v_hotel,v_emp,v_day,v_action,v_old,v_new,v_actor,coalesce(v_name,'Système'),v_src,v_op,v_reason);
  RETURN COALESCE(NEW,OLD);
END $function$;

CREATE OR REPLACE FUNCTION public.trg_staff_planning_move_guard()
 RETURNS trigger LANGUAGE plpgsql
AS $function$
BEGIN
  IF current_user IN ('authenticated','anon') THEN
    IF TG_OP='UPDATE' AND OLD.source_proposal_id IS NOT NULL THEN
      IF NEW.status IS DISTINCT FROM OLD.status OR NEW.shift_start IS DISTINCT FROM OLD.shift_start
         OR NEW.shift_end IS DISTINCT FROM OLD.shift_end OR NEW.hours IS DISTINCT FROM OLD.hours
         OR NEW.source_proposal_id IS DISTINCT FROM OLD.source_proposal_id THEN
        RAISE EXCEPTION 'Ligne issue d''un déplacement inter-hôtels : modifier via le déplacement (segments), pas directement';
      END IF;
    END IF;
    IF TG_OP='DELETE' AND OLD.source_proposal_id IS NOT NULL THEN
      RAISE EXCEPTION 'Suppression interdite d''une ligne issue d''un déplacement inter-hôtels';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$;

CREATE TRIGGER planning_audit_trg AFTER INSERT OR DELETE OR UPDATE ON public.staff_planning FOR EACH ROW EXECUTE FUNCTION trg_planning_audit();
CREATE TRIGGER trg_planning_touch BEFORE UPDATE ON public.staff_planning FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
CREATE TRIGGER trg_sp_move_guard BEFORE DELETE OR UPDATE ON public.staff_planning FOR EACH ROW EXECUTE FUNCTION trg_staff_planning_move_guard();

-- ── Accès : rôle par hôtel + admin transverse (verbatim schéma live) ─────────
CREATE OR REPLACE FUNCTION public.rh_my_role(p_hotel uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select uh.role::text from public.user_hotels uh
  join public.users u on u.id = uh.user_id
  where u.auth_id = auth.uid() and uh.hotel_id = p_hotel limit 1
$function$;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.platform_admins WHERE auth_id = auth.uid() AND is_active = true);
$function$;

-- ── Groupes hôteliers : lecture scopée par le GROUPE DE L'HÔTEL ACTIF (sql/98, verbatim
-- schéma live post-correctif — voir sql/98_security_group_scope_active_hotel.sql pour la
-- version pré-correctif et la cause racine : un scan sans ORDER BY sur tous les hôtels
-- accessibles à l'appelant, jamais lié à get_user_hotel_id()) ────────────────────────────
CREATE OR REPLACE FUNCTION public.group_staff_directory()
 RETURNS TABLE(employee_id uuid, first_name text, last_name text, role text, department text, hotel_id uuid, hotel_name text, phone text, email text, active boolean, status text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.id, e.first_name, e.last_name, e.role, e.department,
         e.hotel_id, h.name, e.phone, e.email, e.active, e.status
  FROM public.employees e
  JOIN public.hotels h ON h.id = e.hotel_id
  WHERE public.is_platform_admin()
     OR h.group_id = (SELECT group_id FROM public.hotels WHERE id = public.get_user_hotel_id())
  ORDER BY h.name, e.last_name, e.first_name;
$function$;

CREATE OR REPLACE FUNCTION public.hotel_group_get(p_hotel uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid; v_name text;
BEGIN
  IF p_hotel NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;
  SELECT group_id INTO v_gid FROM hotels WHERE id=p_hotel;
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null,'group_name',null,'members','[]'::jsonb); END IF;
  SELECT name INTO v_name FROM hotel_groups WHERE id=v_gid;
  RETURN jsonb_build_object('group_id',v_gid,'group_name',v_name,'members',
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'hotel_code',hotel_code,'is_self',(id=p_hotel)) ORDER BY name),'[]'::jsonb)
     FROM hotels WHERE group_id=v_gid));
END; $function$;

CREATE OR REPLACE FUNCTION public.org_get()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid; g record;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null); END IF;
  SELECT * INTO g FROM hotel_groups WHERE id=v_gid;
  RETURN jsonb_build_object(
    'group_id',v_gid,'name',g.name,'status',g.status,'logo_url',g.logo_url,
    'features',coalesce(g.features,'{}'::jsonb),'created_at',g.created_at,
    'members',(SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'name',name,'hotel_code',hotel_code,'city',city,'address',address,'country',country,
        'phone',phone,'email',email,'currency',currency,'timezone',timezone,
        'active',active,'status',coalesce(status,'active')) ORDER BY name),'[]'::jsonb) FROM hotels WHERE group_id=v_gid),
    'counts',jsonb_build_object(
      'hotels',(SELECT count(*) FROM hotels WHERE group_id=v_gid),
      'employees',(SELECT count(*) FROM employees WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid)),
      'users',(SELECT count(DISTINCT user_id) FROM user_hotels WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid))
    ));
END $function$;

CREATE OR REPLACE FUNCTION public.group_planning(p_service text, p_from date, p_to date)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null,'hotels','[]'::jsonb,'services','[]'::jsonb,'cells','[]'::jsonb,'requirements','[]'::jsonb); END IF;
  RETURN jsonb_build_object(
    'group_id', v_gid,
    'hotels', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'hotel_code',hotel_code) ORDER BY name),'[]'::jsonb)
               FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels())),
    'services', (SELECT coalesce(jsonb_agg(DISTINCT name),'[]'::jsonb) FROM staff_departments
                 WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND id IN (SELECT public.pl_my_hotels()))),
    'cells', (SELECT coalesce(jsonb_agg(c),'[]'::jsonb) FROM (
        SELECT jsonb_build_object('hotel_id',e.hotel_id,'employee_id',e.id,'name',e.first_name||' '||e.last_name,
               'role',e.role,'is_extra',false,'origin_hotel_id',e.hotel_id,'day',gd.day::date,
               'status',coalesce(sp.status,''),
               'emp_status',coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END),
               'service',p_service,'shift_label',sp.shift_label) AS c
        FROM employees e
        CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gd(day)
        LEFT JOIN staff_planning sp ON sp.employee_id=e.id AND sp.hotel_id=e.hotel_id AND sp.day=gd.day::date
        WHERE e.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels()))
          AND e.department=p_service
          AND coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END) <> 'parti'
        UNION ALL
        SELECT jsonb_build_object('hotel_id',sp.hotel_id,'employee_id',e.id,'name',e.first_name||' '||e.last_name,
               'role',coalesce(act.host_role,e.role),'is_extra',true,'origin_hotel_id',e.hotel_id,'day',sp.day,'status',sp.status,
               'emp_status',e.status,'service',p_service,'shift_label',sp.shift_label)
        FROM employee_extra_activations act
        JOIN staff_departments d ON d.id=act.host_service_id AND d.name=p_service
        JOIN employees e ON e.id=act.employee_id
        JOIN staff_planning sp ON sp.employee_id=act.employee_id AND sp.hotel_id=act.hotel_id
          AND sp.day BETWEEN p_from AND p_to
          AND extract(year FROM sp.day)::int=act.year AND extract(month FROM sp.day)::int=act.month
        WHERE act.active AND act.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels()))
      ) sub),
    'requirements', (SELECT coalesce(jsonb_agg(jsonb_build_object('hotel_id',hotel_id,'weekday',weekday,'shift',shift,'required',required_count)),'[]'::jsonb)
                     FROM group_staffing_requirements
                     WHERE service_name=p_service AND hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND id IN (SELECT public.pl_my_hotels())))
  );
END $function$;

CREATE OR REPLACE FUNCTION public.group_requirements_list()
 RETURNS TABLE(hotel_id uuid, service_name text, weekday integer, required_count integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT hotel_id, service_name, weekday, required_count
  FROM group_staffing_requirements
  WHERE hotel_id IN (SELECT public.pl_my_hotels())
    AND hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;

CREATE OR REPLACE FUNCTION public.group_travel_times()
 RETURNS TABLE(from_hotel_id uuid, to_hotel_id uuid, duration_min integer, safety_margin_min integer, transport_type text, valid_from date, valid_to date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT from_hotel_id, to_hotel_id, duration_min, safety_margin_min, transport_type, valid_from, valid_to
  FROM hotel_travel_times
  WHERE from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels())
    AND from_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()))
    AND to_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;
