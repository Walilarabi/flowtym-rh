-- ============================================================================
-- Reconstruction locale FIDÈLE du sous-schéma "déplacement inter-hôtels".
-- Source des corps de fonctions/triggers/contraintes : schéma live (DDL only,
-- AUCUNE donnée de production). Objets minimaux référencés (hotels, employees,
-- users…) réduits aux colonnes utiles ; corps métier reproduits VERBATIM.
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Shim d'authentification Supabase (auth.uid() lit le claim JWT via GUC)
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

-- ── Tables de base (minimales) ───────────────────────────────────────────────
CREATE TABLE hotel_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text, status text NOT NULL DEFAULT 'active',
  features jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE hotels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL, city text,
  group_id uuid REFERENCES hotel_groups(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now());

CREATE TABLE employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name text, last_name text, portal_auth_id uuid);

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid, full_name text, email text);

CREATE TABLE user_hotels (
  user_id uuid REFERENCES users(id) ON DELETE CASCADE,
  hotel_id uuid REFERENCES hotels(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, hotel_id));

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
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (from_hotel_id <> to_hotel_id), CHECK (duration_min >= 0), CHECK (safety_margin_min >= 0));

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
