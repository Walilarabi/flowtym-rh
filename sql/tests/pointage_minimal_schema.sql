-- =============================================================================
-- pointage_minimal_schema.sql
-- Schéma minimal auto-suffisant nécessaire pour appliquer les migrations
-- 62 et 63 sur une base PostgreSQL vierge et exécuter la suite de tests
-- SQL / concurrence du module Pointage.
--
-- Reproduit fidèlement la portion du schéma production dont les migrations
-- dépendent :
--   • auth.uid()               (fake via GUC request.jwt.claim.sub)
--   • rôles authenticated/anon/service_role
--   • pl_my_hotels()           (isolation multi-tenant)
--   • pl_touch_updated_at()    (trigger touch commun)
--   • tables : hotels, users, user_hotels, employees,
--              employee_hotel_assignments, employee_extra_activations,
--              staff_planning, staff_clockings, hotel_qr_tokens
--
-- Utilisé par :
--   • sql/tests/pointage_hardening.sql
--   • sql/tests/pointage_concurrency.sql
--   • scripts/test-pointage-concurrency.sh
--   • le job CI « DB — pointage terminals + hardening ».
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Simule auth.uid() en variable de session (mimique Supabase).
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT current_setting('request.jwt.claim.sub', true)::uuid
$$;

-- Rôles attendus par les GRANTs du dépôt.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon;          END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.hotels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  timezone text,
  latitude double precision,
  longitude double precision,
  geofence_radius_meters int,
  qr_clocking_enabled boolean DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid UNIQUE,
  email text,
  full_name text
);

CREATE TABLE IF NOT EXISTS public.user_hotels (
  user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  hotel_id uuid REFERENCES public.hotels(id) ON DELETE CASCADE,
  role text,
  PRIMARY KEY (user_id, hotel_id)
);

CREATE OR REPLACE FUNCTION public.pl_my_hotels()
RETURNS SETOF uuid LANGUAGE sql STABLE AS $$
  SELECT h.hotel_id FROM public.user_hotels h
   JOIN public.users u ON u.id = h.user_id
  WHERE u.auth_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.pl_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE TABLE IF NOT EXISTS public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  first_name text NOT NULL,
  last_name text NOT NULL,
  portal_auth_id uuid,
  portal_enabled boolean DEFAULT true,
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.staff_planning (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  day date NOT NULL,
  status text NOT NULL,
  duration numeric(3,1) DEFAULT 1.0
);

CREATE TABLE IF NOT EXISTS public.employee_hotel_assignments (
  employee_id uuid,
  source_hotel_id uuid,
  target_hotel_id uuid,
  active boolean DEFAULT true,
  authorized_by text,
  notes text,
  UNIQUE(employee_id, target_hotel_id)
);

CREATE TABLE IF NOT EXISTS public.employee_extra_activations (
  employee_id uuid,
  hotel_id uuid,
  year int,
  month int,
  host_service_id uuid,
  host_role text,
  active boolean DEFAULT true,
  comment text,
  created_by uuid,
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_clockings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  day date NOT NULL,
  clock_in_ts timestamptz NOT NULL,
  clock_out_ts timestamptz,
  break_minutes int NOT NULL DEFAULT 0,
  notes text,
  source text NOT NULL DEFAULT 'manual',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hotel_qr_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  token text UNIQUE NOT NULL,
  is_active boolean DEFAULT true,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now(),
  created_by_email text
);
