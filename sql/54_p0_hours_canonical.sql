-- ============================================================================
-- 54_p0_hours_canonical.sql — Migration P0 : segments = source de vérité des heures.
--
-- Contenu :
--   A. Garde-fou PAIE CLÔTURÉE (réel, testé) : table de périodes + triggers
--      bloquant toute écriture (segments CRUD, grille, déplacement,
--      reconstruction, group_move_apply) impactant une période close.
--      Refus atomique, code d'erreur stable (SQLSTATE 'FL001').
--   B. service_id sur les segments (clé fonctionnelle R6) + peuplement par
--      group_move_apply.
--   C. Feature flag hotel_groups.features.hours.source ∈ {legacy, segments}
--      (défaut legacy, activation manuelle, journalisée, ne contourne jamais A).
--   D. Fonction canonique UNIQUE des heures (brut / pauses / net / ventilation
--      hôtel / ventilation service_id / total jour / total semaine).
--
-- NON appliqué en production. Développé et testé sur cluster local jetable
-- (scripts/concurrency/local + tests P0). Corps runnable (pas un stub).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. GARDE-FOU PAIE CLÔTURÉE
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.staff_payroll_periods (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  period_start date NOT NULL,
  period_end   date NOT NULL,
  status       text NOT NULL DEFAULT 'open',
  closed_at    timestamptz,
  closed_by    uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end >= period_start),
  CHECK (status IN ('open','closed')),
  UNIQUE (hotel_id, period_start, period_end)
);
CREATE INDEX IF NOT EXISTS idx_payroll_periods_lookup
  ON public.staff_payroll_periods (hotel_id, status, period_start, period_end);

-- Une période close couvrant (hotel, jour) verrouille toute écriture d'heures.
CREATE OR REPLACE FUNCTION public._payroll_period_locked(p_hotel uuid, p_day date)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff_payroll_periods
    WHERE hotel_id = p_hotel AND status = 'closed'
      AND p_day BETWEEN period_start AND period_end);
$$;

-- Refus explicite + code stable, AUCUNE écriture partielle (raise -> rollback txn).
CREATE OR REPLACE FUNCTION public._assert_payroll_open(p_hotel uuid, p_day date)
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF p_hotel IS NULL OR p_day IS NULL THEN RETURN; END IF;
  IF public._payroll_period_locked(p_hotel, p_day) THEN
    RAISE EXCEPTION 'PAYROLL_PERIOD_LOCKED: heures/segments non modifiables (période de paie clôturée) hotel=% jour=%', p_hotel, p_day
      USING ERRCODE = 'FL001';
  END IF;
END $$;

-- Trigger grille (staff_planning) : INSERT/UPDATE/DELETE bloqués si période close.
CREATE OR REPLACE FUNCTION public.trg_payroll_lock_planning()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') THEN PERFORM public._assert_payroll_open(NEW.hotel_id, NEW.day); END IF;
  IF TG_OP IN ('UPDATE','DELETE') THEN PERFORM public._assert_payroll_open(OLD.hotel_id, OLD.day); END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

-- Trigger segments (staff_planning_segments) : idem, couvre create/update/delete.
CREATE OR REPLACE FUNCTION public.trg_payroll_lock_segments()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') THEN PERFORM public._assert_payroll_open(NEW.hotel_id, NEW.day); END IF;
  IF TG_OP IN ('UPDATE','DELETE') THEN PERFORM public._assert_payroll_open(OLD.hotel_id, OLD.day); END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS trg_payroll_lock_sp ON public.staff_planning;
CREATE TRIGGER trg_payroll_lock_sp
  BEFORE INSERT OR UPDATE OR DELETE ON public.staff_planning
  FOR EACH ROW EXECUTE FUNCTION public.trg_payroll_lock_planning();

DROP TRIGGER IF EXISTS trg_payroll_lock_seg ON public.staff_planning_segments;
CREATE TRIGGER trg_payroll_lock_seg
  BEFORE INSERT OR UPDATE OR DELETE ON public.staff_planning_segments
  FOR EACH ROW EXECUTE FUNCTION public.trg_payroll_lock_segments();

-- ─────────────────────────────────────────────────────────────────────────────
-- B. service_id sur les segments (clé fonctionnelle R6 ; nom = affichage)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.staff_planning_segments
  ADD COLUMN IF NOT EXISTS service_id uuid REFERENCES public.staff_departments(id);

-- Peuplement automatique de service_id pour les segments issus d'un déplacement
-- (résolution NOM de service -> service_id de l'hôtel concerné selon kind).
-- Évite de dupliquer group_move_apply ; service_id reste NULL si non résolu.
CREATE OR REPLACE FUNCTION public.trg_seg_fill_service()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.service_id IS NULL AND NEW.source_proposal_id IS NOT NULL THEN
    SELECT sd.id INTO NEW.service_id
    FROM group_move_proposals p
    JOIN staff_departments sd
      ON sd.hotel_id = NEW.hotel_id
     AND sd.name = CASE WHEN NEW.kind='destination' THEN p.to_service ELSE p.from_service END
    WHERE p.id = NEW.source_proposal_id
    LIMIT 1;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_seg_fill_service ON public.staff_planning_segments;
CREATE TRIGGER trg_seg_fill_service
  BEFORE INSERT ON public.staff_planning_segments
  FOR EACH ROW EXECUTE FUNCTION public.trg_seg_fill_service();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. FEATURE FLAG + journalisation (jamais de contournement du garde-fou A)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.hotel_group_flag_audit (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id   uuid NOT NULL REFERENCES public.hotel_groups(id) ON DELETE CASCADE,
  flag_path  text NOT NULL,
  old_value  text,
  new_value  text,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public._hours_source(p_hotel uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT coalesce((g.features->'hours'->>'source'), 'legacy')
  FROM hotels h JOIN hotel_groups g ON g.id = h.group_id WHERE h.id = p_hotel;
$$;

-- Activation manuelle par groupe, journalisée. Aucun basculement automatique.
CREATE OR REPLACE FUNCTION public.set_group_hours_source(p_group uuid, p_source text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_old text; v_feat jsonb;
BEGIN
  IF p_source NOT IN ('legacy','segments') THEN
    RAISE EXCEPTION 'hours.source invalide (attendu legacy|segments) : %', p_source USING ERRCODE = 'FL002';
  END IF;
  SELECT features INTO v_feat FROM hotel_groups WHERE id = p_group FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Groupe introuvable'; END IF;
  v_old := coalesce(v_feat->'hours'->>'source','legacy');
  -- Fusion sûre : jsonb_set ne peut PAS créer un parent '{hours}' manquant sur '{}'.
  UPDATE hotel_groups
    SET features = coalesce(features,'{}'::jsonb)
                   || jsonb_build_object('hours',
                        coalesce(features->'hours','{}'::jsonb) || jsonb_build_object('source', p_source))
    WHERE id = p_group;
  INSERT INTO hotel_group_flag_audit(group_id, flag_path, old_value, new_value, changed_by)
  VALUES (p_group, 'hours.source', v_old, p_source, auth.uid());
  RETURN jsonb_build_object('group_id', p_group, 'flag', 'hours.source', 'old', v_old, 'new', p_source);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. FONCTION CANONIQUE UNIQUE des heures (explicable, testable)
--    net = somme des durées de présence (segments) — AUCUN double compte.
--    pauses (segments) = trous intra-hôtel entre segments d'un même hôtel.
--    Respecte le flag : 'segments' => segments ; sinon chemin grille (legacy).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.staff_hours_day(p_emp uuid, p_day date, p_default_hpd numeric DEFAULT 7)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_has_seg boolean; v_group_src text; v_net numeric; v_break numeric; v_gross numeric;
        v_by_hotel jsonb; v_by_service jsonb; v_source text; v_ref_hotel uuid;
BEGIN
  SELECT EXISTS(SELECT 1 FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day) INTO v_has_seg;
  v_ref_hotel := coalesce(
     (SELECT hotel_id FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day LIMIT 1),
     (SELECT hotel_id FROM staff_planning WHERE employee_id=p_emp AND day=p_day LIMIT 1));
  v_group_src := coalesce(public._hours_source(v_ref_hotel), 'legacy');

  IF v_has_seg AND v_group_src = 'segments' THEN
    v_source := 'segments';
    -- Minutes EFFECTIVES : un segment marqueur "journée entière" (0..1440) vaut
    -- la durée conventionnelle (hpd), pas 24 h de présence littérale.
    SELECT round(sum(CASE WHEN seg_start_min=0 AND seg_end_min=1440 THEN p_default_hpd*60
                          ELSE seg_end_min-seg_start_min END)/60.0, 2) INTO v_net
      FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day;
    -- pauses = trous intra-hôtel (segments non "journée entière" uniquement)
    SELECT round(coalesce(sum(span - net),0)/60.0, 2) INTO v_break FROM (
      SELECT hotel_id, max(seg_end_min)-min(seg_start_min) AS span, sum(seg_end_min-seg_start_min) AS net
      FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day
        AND NOT (seg_start_min=0 AND seg_end_min=1440) GROUP BY hotel_id) z;
    v_gross := round(coalesce(v_net,0) + coalesce(v_break,0), 2);
    SELECT jsonb_agg(jsonb_build_object('hotel_id',hotel_id,'net_hours',h) ORDER BY hotel_id)
      INTO v_by_hotel FROM (
        SELECT hotel_id, round(sum(CASE WHEN seg_start_min=0 AND seg_end_min=1440 THEN p_default_hpd*60
                                        ELSE seg_end_min-seg_start_min END)/60.0,2) AS h
        FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day GROUP BY hotel_id) s;
    SELECT jsonb_agg(jsonb_build_object('service_id', service_id, 'net_hours', h) ORDER BY service_id NULLS LAST)
      INTO v_by_service FROM (
        SELECT service_id, round(sum(CASE WHEN seg_start_min=0 AND seg_end_min=1440 THEN p_default_hpd*60
                                          ELSE seg_end_min-seg_start_min END)/60.0,2) AS h
        FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day GROUP BY service_id) s;
  ELSE
    v_source := CASE WHEN v_has_seg THEN 'grid_legacy_flag' ELSE 'grid' END;
    SELECT round(coalesce(sum(coalesce(hours,
        CASE WHEN shift_start IS NOT NULL AND shift_end IS NOT NULL
             THEN (extract(epoch FROM shift_end)-extract(epoch FROM shift_start))/3600.0 - coalesce(break_minutes,0)/60.0
             ELSE p_default_hpd END)),0),2),
           round(coalesce(sum(break_minutes),0)/60.0,2)
      INTO v_net, v_break
      FROM staff_planning WHERE employee_id=p_emp AND day=p_day AND status IN ('P','PE');
    v_gross := round(coalesce(v_net,0) + coalesce(v_break,0), 2);
    SELECT jsonb_agg(jsonb_build_object('hotel_id',hotel_id,'net_hours',
        round(coalesce(hours, CASE WHEN shift_start IS NOT NULL AND shift_end IS NOT NULL
            THEN (extract(epoch FROM shift_end)-extract(epoch FROM shift_start))/3600.0 - coalesce(break_minutes,0)/60.0
            ELSE p_default_hpd END),2)) ORDER BY hotel_id)
      INTO v_by_hotel FROM staff_planning WHERE employee_id=p_emp AND day=p_day AND status IN ('P','PE');
    v_by_service := '[]'::jsonb;  -- la grille ne porte pas service_id (dimension P1)
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_emp, 'day', p_day, 'source', v_source,
    'gross_hours', coalesce(v_gross,0), 'break_hours', coalesce(v_break,0), 'net_hours', coalesce(v_net,0),
    'by_hotel', coalesce(v_by_hotel,'[]'::jsonb), 'by_service', coalesce(v_by_service,'[]'::jsonb),
    'total_net', coalesce(v_net,0));
END $$;

-- Agrégat SEMAINE (7 jours à partir d'un lundi) : total net + détail par jour.
CREATE OR REPLACE FUNCTION public.staff_hours_week(p_emp uuid, p_week_start date, p_default_hpd numeric DEFAULT 7)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE d date; v_days jsonb := '[]'::jsonb; v_total numeric := 0; v_day jsonb;
BEGIN
  FOR i IN 0..6 LOOP
    d := p_week_start + i;
    v_day := public.staff_hours_day(p_emp, d, p_default_hpd);
    v_total := v_total + coalesce((v_day->>'net_hours')::numeric, 0);
    v_days := v_days || jsonb_build_array(v_day);
  END LOOP;
  RETURN jsonb_build_object('employee_id', p_emp, 'week_start', p_week_start,
    'total_net', round(v_total,2), 'days', v_days);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. CORRECTION group_move_apply — R5 : un déplacement "journée entière" doit
--    PRÉSERVER les heures réelles de l'origine (et non écrire un marqueur 0..1440
--    interprété comme hpd, ce qui SUPPRIMERAIT des heures). Le shift d'origine est
--    lu AVANT la boucle de créneaux ; un créneau plein réutilise son intervalle.
--    Aucune autre logique modifiée (verrous/idempotence/exclusion inchangés).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_move_apply(p_id uuid, p_idempotency_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r group_move_proposals; v_op uuid; v_cur_fp text; v_unwaived int; v_existing group_move_applications;
        v_self_rank int; v_other record; v_days date[]; d date; v_applied int := 0; v_vacated int := 0; v_segs int := 0;
        v_cuts int4range[]; v_dstart int; v_dend int; v_full boolean; v_slot jsonb; v_kept int4range[]; kr int4range;
        v_oshift record; v_os int; v_oe int; v_dmin int; v_dmax int; v_anyfull boolean; v_result jsonb; v_validation jsonb;
        v_ofound boolean;
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
    'checks_run', jsonb_build_array('planning','couverture','absences','trajet','chevauchement','expiration','concurrence','derogations'),
    'checks_unavailable', jsonb_build_array('competences','disponibilites','regles_rh_variables'),
    'missing', coalesce(r.simulation->'missing','[]'::jsonb)
  );

  PERFORM set_config('flowtym.audit_source','group_planning', true);
  PERFORM set_config('flowtym.audit_reason', coalesce(r.reason,'Renfort inter-hôtels'), true);
  PERFORM set_config('flowtym.operation_id', v_op::text, true);
  PERFORM set_config('flowtym.allow_move_write','on', true);

  FOREACH d IN ARRAY coalesce(v_days, ARRAY[]::date[]) LOOP
    v_cuts := ARRAY[]::int4range[]; v_dmin := NULL; v_dmax := NULL; v_anyfull := false;
    -- Shift d'origine du jour, lu AVANT la boucle (préservation des heures).
    SELECT shift_start, shift_end, status INTO v_oshift FROM staff_planning WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d;
    v_ofound := FOUND;
    IF v_ofound AND v_oshift.shift_start IS NOT NULL THEN
      v_os := extract(hour FROM v_oshift.shift_start)*60 + extract(minute FROM v_oshift.shift_start);
      v_oe := extract(hour FROM v_oshift.shift_end)*60 + extract(minute FROM v_oshift.shift_end);
    ELSIF v_ofound THEN v_os := 0; v_oe := 1440;
    ELSE v_os := NULL; v_oe := NULL; END IF;

    FOR v_slot IN SELECT * FROM jsonb_array_elements(r.slots) WHERE (value->>'date')::date = d LOOP
      IF nullif(v_slot->>'start','') IS NULL OR nullif(v_slot->>'end','') IS NULL THEN
        -- Créneau "journée entière" : réutiliser l'intervalle RÉEL d'origine si connu
        -- (R5 : aucune heure supprimée), sinon marqueur 0..1440.
        IF v_ofound AND v_oshift.shift_start IS NOT NULL THEN v_dstart := v_os; v_dend := v_oe;
        ELSE v_dstart := 0; v_dend := 1440; v_anyfull := true; END IF;
      ELSE v_dstart := extract(hour FROM (v_slot->>'start')::time)*60 + extract(minute FROM (v_slot->>'start')::time);
           v_dend := extract(hour FROM (v_slot->>'end')::time)*60 + extract(minute FROM (v_slot->>'end')::time); END IF;
      v_cuts := v_cuts || int4range(v_dstart, v_dend);
      INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
      VALUES (r.to_hotel_id, r.employee_id, d, v_dstart, v_dend, 'destination', 'PE', p_id, r.from_hotel_id);
      v_segs := v_segs + 1; v_dmin := least(coalesce(v_dmin,v_dstart), v_dstart); v_dmax := greatest(coalesce(v_dmax,v_dend), v_dend);
    END LOOP;

    IF v_ofound THEN
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

-- ─────────────────────────────────────────────────────────────────────────────
-- F. RPC de plage pour les consommateurs frontend (C1 paie / C2 suivi) :
--    heures nettes de CET hôtel par (salarié, jour), segments-first si flag actif,
--    sinon grille. Un jour marqueur "journée entière" vaut hpd (pas 24 h).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.staff_hotel_hours_range(p_hotel uuid, p_from date, p_to date, p_default_hpd numeric DEFAULT 7)
 RETURNS TABLE(employee_id uuid, day date, net_hours numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  WITH flag AS (SELECT public._hours_source(p_hotel) AS src),
  seg AS (
    SELECT s.employee_id, s.day,
      round(sum(CASE WHEN s.seg_start_min=0 AND s.seg_end_min=1440 THEN p_default_hpd*60
                     ELSE s.seg_end_min-s.seg_start_min END)/60.0,2) AS h
    FROM staff_planning_segments s WHERE s.hotel_id=p_hotel AND s.day BETWEEN p_from AND p_to
    GROUP BY s.employee_id, s.day),
  grid AS (
    SELECT sp.employee_id, sp.day,
      round(coalesce(sp.hours, CASE WHEN sp.shift_start IS NOT NULL AND sp.shift_end IS NOT NULL
        THEN (extract(epoch FROM sp.shift_end)-extract(epoch FROM sp.shift_start))/3600.0 - coalesce(sp.break_minutes,0)/60.0
        ELSE p_default_hpd END),2) AS h
    FROM staff_planning sp WHERE sp.hotel_id=p_hotel AND sp.day BETWEEN p_from AND p_to AND sp.status IN ('P','PE'))
  SELECT k.emp, k.d,
    CASE WHEN (SELECT src FROM flag)='segments' AND s.h IS NOT NULL THEN s.h ELSE coalesce(g.h,0) END
  FROM (SELECT DISTINCT employee_id AS emp, day AS d
        FROM (SELECT employee_id, day FROM seg UNION SELECT employee_id, day FROM grid) u) k
  LEFT JOIN seg  s ON s.employee_id=k.emp AND s.day=k.d
  LEFT JOIN grid g ON g.employee_id=k.emp AND g.day=k.d;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Exposition frontend : wrapper public du flag + GRANTs PostgREST.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_hours_source(p_hotel uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT public._hours_source(p_hotel); $$;

-- GRANTs conditionnels : le rôle 'authenticated' existe sur Supabase mais pas sur
-- un cluster local nu. On n'échoue donc pas hors Supabase.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.group_hours_source(uuid) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.staff_hotel_hours_range(uuid,date,date,numeric) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.staff_hours_day(uuid,date,numeric) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.staff_hours_week(uuid,date,numeric) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.set_group_hours_source(uuid,text) TO authenticated;
  END IF;
END $$;
