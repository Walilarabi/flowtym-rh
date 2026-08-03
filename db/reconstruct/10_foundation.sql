-- ============================================================================
-- 10_foundation.sql — Tables FONDATIONNELLES (pré-01), absentes du dépôt jusqu'ici.
-- DDL fidèle extrait du schéma live (schéma uniquement, aucune donnée de prod).
-- Périmètre PILOTE : groupes, hôtels, collaborateurs, accès, services.
-- (FK vers modules hors périmètre volontairement omises pour l'auto-suffisance.)
-- ============================================================================
CREATE TYPE public.admin_user_role AS ENUM
  ('reception','gouvernante','femme_de_chambre','maintenance','breakfast','direction','admin_hotel','comptabilite','revenue_manager');

CREATE TABLE public.hotel_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text, created_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'active', logo_url text,
  features jsonb NOT NULL DEFAULT '{}'::jsonb);

CREATE TABLE public.hotels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL, city text, address text, zip text, country text DEFAULT 'France',
  phone text, email text, siret text, tva_number text, logo_url text,
  timezone text DEFAULT 'Europe/Paris', currency text DEFAULT 'EUR',
  active boolean DEFAULT true, created_at timestamptz DEFAULT now(),
  status text DEFAULT 'active', legal_representative text,
  latitude double precision, longitude double precision,
  group_id uuid REFERENCES public.hotel_groups(id) ON DELETE SET NULL,
  hotel_code varchar(5));

CREATE TABLE public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid NOT NULL, hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  email text NOT NULL, full_name text NOT NULL,
  role admin_user_role NOT NULL DEFAULT 'reception',
  is_active boolean NOT NULL DEFAULT true, last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE public.user_hotels (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  role admin_user_role NOT NULL DEFAULT 'reception',
  is_default boolean NOT NULL DEFAULT false,
  granted_at timestamptz NOT NULL DEFAULT now(), granted_by uuid,
  PRIMARY KEY (user_id, hotel_id));

CREATE TABLE public.staff_departments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  name text NOT NULL, sort_order integer DEFAULT 0, created_at timestamptz DEFAULT now(),
  default_start_time text, default_end_time text, break_minutes integer,
  hours_per_day numeric, cp_days_per_month numeric);

CREATE TABLE public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  first_name text NOT NULL, last_name text NOT NULL,
  role text, department text, department_id uuid REFERENCES public.staff_departments(id),
  contract_type text NOT NULL DEFAULT 'CDI', hire_date date,
  rest_days integer[] NOT NULL DEFAULT '{}'::integer[],
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  departure_date date, planning_sort_order integer NOT NULL DEFAULT 0,
  portal_auth_id uuid, schedule_id uuid, email text, phone text, manager_id uuid,
  portal_enabled boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'actif', departure_reason text, last_worked_date date);

-- Admins transverses (RH Groupe / Super Admin) — mécanisme existant, réutilisé.
CREATE TABLE IF NOT EXISTS public.platform_admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid NOT NULL UNIQUE, email text NOT NULL, full_name text, role text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
