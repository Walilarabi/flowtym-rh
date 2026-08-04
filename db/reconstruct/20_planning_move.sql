-- ============================================================================
-- 20_planning_move.sql — Planning + moteur de déplacement inter-hôtels.
-- Tables : staff_absences, planning_audit, group_move_*, staff_planning,
-- staff_planning_segments (contrainte d'exclusion). DDL fidèle (schéma live).
-- (Les tables fondationnelles viennent de 10_foundation.sql.)
-- ============================================================================
CREATE TABLE staff_absences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  type text NOT NULL, start_date date NOT NULL, end_date date NOT NULL,
  status text NOT NULL DEFAULT 'approved',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date));

CREATE TABLE planning_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hotel_id uuid NOT NULL, employee_id uuid, day date, action text NOT NULL,
  old_values jsonb, new_values jsonb, actor_auth_id uuid, actor_name text,
  source text, created_at timestamptz NOT NULL DEFAULT now(),
  operation_id uuid, reason text);

-- ── Config déplacement ───────────────────────────────────────────────────────
CREATE TABLE group_move_workflows (
  group_id uuid PRIMARY KEY, steps jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE group_staffing_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  service_name text NOT NULL, weekday int NOT NULL,
  required_count int NOT NULL DEFAULT 0, shift text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (weekday BETWEEN 0 AND 6));

CREATE TABLE hotel_travel_times (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  to_hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  duration_min int NOT NULL, safety_margin_min int NOT NULL DEFAULT 10,
  transport_type text, valid_from date, valid_to date,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (from_hotel_id <> to_hotel_id), CHECK (duration_min >= 0), CHECK (safety_margin_min >= 0));

CREATE TABLE employee_extra_activations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  year int NOT NULL, month int NOT NULL,
  host_service_id uuid, host_role text, active boolean NOT NULL DEFAULT true,
  comment text, created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, hotel_id, year, month, host_service_id));

CREATE TABLE employee_hotel_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  source_hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  target_hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  active boolean DEFAULT true, notes text, authorized_by text,
  created_at timestamptz DEFAULT now());
GRANT SELECT ON employee_hotel_assignments TO authenticated, anon;

-- ── Propositions & cycle de vie ──────────────────────────────────────────────
CREATE TABLE group_move_proposals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid, employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  from_hotel_id uuid NOT NULL REFERENCES hotels(id),
  to_hotel_id uuid NOT NULL REFERENCES hotels(id),
  from_service text, to_service text, period_from date, period_to date,
  slots jsonb NOT NULL DEFAULT '[]'::jsonb, reason text,
  status text NOT NULL DEFAULT 'draft', decision text, score int, confidence int,
  simulation jsonb, simulation_created_at timestamptz,
  simulation_input_hash text, simulation_result_hash text,
  staleness text NOT NULL DEFAULT 'valid', expires_at timestamptz,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), scheduled_at timestamptz,
  server_fingerprint text, applied_at timestamptz, applied_operation_id uuid,
  CHECK (from_hotel_id <> to_hotel_id),
  CHECK (decision = ANY (ARRAY['allowed','allowed_with_warnings','blocked'])),
  CHECK (staleness = ANY (ARRAY['valid','to_refresh','conflict','expired'])),
  CHECK (status = ANY (ARRAY['draft','pending_review','approved','scheduled','rejected','cancelled','expired','applied'])));
-- RLS + GRANT sur group_move_proposals : voir 30_functions.sql (dépend de pl_my_hotels(),
-- défini plus tard dans l'ordre de reconstruction — cf. rebuild.sh).

CREATE TABLE group_move_applications (
  idempotency_key text PRIMARY KEY,
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL, applied_by uuid,
  applied_at timestamptz NOT NULL DEFAULT now(), result jsonb,
  status text NOT NULL DEFAULT 'completed',
  CHECK (status = ANY (ARRAY['processing','completed'])));

CREATE TABLE group_move_proposal_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  actor uuid, action text NOT NULL, old_status text, new_status text,
  comment text, metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE group_move_proposal_waivers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  check_code text NOT NULL, justification text NOT NULL,
  value_before text, overage_value text, waived_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (proposal_id, check_code));

CREATE TABLE group_move_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  event text NOT NULL, recipient_type text, recipient_hotel_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz);

CREATE TABLE group_move_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  step_index int NOT NULL, step_key text, approver_type text, hotel_scope text,
  status text NOT NULL DEFAULT 'pending', decided_by uuid, decided_at timestamptz,
  comment text, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (proposal_id, step_index),
  CHECK (status = ANY (ARRAY['pending','approved','rejected','skipped'])));

-- group_move_cancellations / group_move_replacements : ajoutées par sql/97 (P0 sécurité
-- 2026-08-03, cf. incident isolation inter-groupes) — RLS activée dès la création ici (le
-- schéma live avait dérivé sans RLS ; cf. sql/97 pour le correctif appliqué en production).
CREATE TABLE group_move_cancellations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  scope text NOT NULL, scope_day date, cancelled_by uuid,
  status text NOT NULL DEFAULT 'processing', result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (scope = ANY (ARRAY['full','day'])),
  CHECK (status = ANY (ARRAY['processing','completed'])));
ALTER TABLE group_move_cancellations ENABLE ROW LEVEL SECURITY;
CREATE POLICY gmc_access ON group_move_cancellations
  FOR SELECT USING (proposal_id IN (SELECT id FROM group_move_proposals));
GRANT SELECT ON group_move_cancellations TO authenticated, anon;

CREATE TABLE group_move_replacements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  old_proposal_id uuid NOT NULL REFERENCES group_move_proposals(id),
  new_proposal_id uuid REFERENCES group_move_proposals(id),
  replaced_by uuid, status text NOT NULL DEFAULT 'processing', result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status = ANY (ARRAY['processing','completed'])));
ALTER TABLE group_move_replacements ENABLE ROW LEVEL SECURITY;
CREATE POLICY gmr_access ON group_move_replacements
  FOR SELECT USING (
    old_proposal_id IN (SELECT id FROM group_move_proposals)
    OR new_proposal_id IN (SELECT id FROM group_move_proposals)
  );
GRANT SELECT ON group_move_replacements TO authenticated, anon;

-- ── Grille (résumé/cache) et Segments (source de vérité) ─────────────────────
CREATE TABLE staff_planning (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  day date NOT NULL, status text NOT NULL, duration numeric NOT NULL DEFAULT 1.0,
  note text, updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  shift_label text, shift_start time, shift_end time,
  break_minutes int NOT NULL DEFAULT 0, hours numeric,
  source_proposal_id uuid REFERENCES group_move_proposals(id) ON DELETE SET NULL,
  origin_hotel_id uuid REFERENCES hotels(id),
  UNIQUE (hotel_id, employee_id, day),
  CHECK ((hours IS NULL) OR ((status = 'P') AND (hours > 0) AND (hours <= 24))),
  CHECK ((shift_label IS NULL) OR ((status = ANY (ARRAY['P','PE'])) AND (shift_label = ANY (ARRAY['M','S','N','J','PD','C','custom'])))),
  CHECK (((shift_start IS NULL) AND (shift_end IS NULL)) OR ((shift_start IS NOT NULL) AND (shift_end IS NOT NULL))),
  CHECK ((duration > 0) AND (duration <= 1)),
  CHECK (status = ANY (ARRAY['P','PE','CP','RTT','MAL','MAT','CSS','AE','F','PAT','ABS','REC','FORM','MAD'])));

CREATE TABLE staff_planning_segments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  day date NOT NULL, seg_start_min int NOT NULL DEFAULT 0, seg_end_min int NOT NULL DEFAULT 1440,
  kind text NOT NULL, status text NOT NULL DEFAULT 'PE',
  source_proposal_id uuid REFERENCES group_move_proposals(id) ON DELETE SET NULL,
  origin_hotel_id uuid REFERENCES hotels(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (seg_end_min > seg_start_min),
  CHECK (kind = ANY (ARRAY['origin','destination'])),
  CHECK ((seg_end_min > 0) AND (seg_end_min <= 1440)),
  CHECK ((seg_start_min >= 0) AND (seg_start_min < 1440)),
  EXCLUDE USING gist (employee_id WITH =, day WITH =, int4range(seg_start_min, seg_end_min) WITH &&));

-- ── Helpers heures depuis les segments (source de vérité) ──
CREATE OR REPLACE FUNCTION public.staff_segment_hours(p_emp uuid, p_day date)
 RETURNS TABLE(hotel_id uuid, minutes integer, hours numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT hotel_id, sum(seg_end_min - seg_start_min)::int AS minutes,
         round(sum(seg_end_min - seg_start_min)/60.0, 2) AS hours
  FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day
  GROUP BY hotel_id;
$function$;

CREATE OR REPLACE FUNCTION public.staff_day_hours(p_emp uuid, p_day date, p_default_hpd numeric DEFAULT 7)
 RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v numeric;
BEGIN
  SELECT round(sum(seg_end_min - seg_start_min)/60.0, 2) INTO v FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT coalesce(hours,
           CASE WHEN shift_start IS NOT NULL AND shift_end IS NOT NULL
                THEN round((extract(epoch FROM shift_end)-extract(epoch FROM shift_start))/3600.0,2)
                ELSE p_default_hpd END)
    INTO v FROM staff_planning
    WHERE employee_id=p_emp AND day=p_day AND status IN ('P','PE')
    ORDER BY updated_at DESC LIMIT 1;
  RETURN coalesce(v, 0);
END $function$;

-- Vue d'indicateurs jour (security_invoker : respecte la RLS de l'appelant).
CREATE OR REPLACE VIEW public.v_staff_day_flags
WITH (security_invoker = on) AS
  SELECT employee_id, day,
    count(*) AS segment_count,
    count(*) > 0 AS is_segmented,
    count(DISTINCT hotel_id) > 1 AS has_multiple_hotels,
    count(DISTINCT status) > 1 AS has_multiple_statuses,
    true AS derived_from_segments
  FROM public.staff_planning_segments
  GROUP BY employee_id, day;
