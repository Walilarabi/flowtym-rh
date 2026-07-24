-- ============================================================================
-- 00_bootstrap.sql — Amorçage compatible Supabase pour une base VIERGE.
-- Crée les rôles/schemas/extensions/shims qu'une instance Supabase fournit
-- nativement mais qu'un cluster PostgreSQL nu n'a pas. Idempotent.
-- ============================================================================
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
-- Shim minimal du contexte d'authentification Supabase (JWT via GUC).
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $f$
  SELECT nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $f$;
CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text);
