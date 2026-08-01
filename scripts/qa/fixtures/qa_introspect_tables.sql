-- ============================================================================
-- scripts/qa/fixtures/qa_introspect_tables.sql
-- Helper d'introspection en lecture seule utilisé EXCLUSIVEMENT par
-- scripts/qa/phase2-staging-acceptance.sh (comparaison structurelle staging/
-- production, section STRUCTURE).
--
-- Portée : lecture seule (aucun DDL/DML sur les tables introspectées), jamais
-- exposé à anon/authenticated (EXECUTE réservé à service_role, jamais accordé
-- par défaut car révoqué explicitement ci-dessous), jamais appliqué à la
-- production. N'existe et ne doit exister que sur la branche de staging
-- Supabase utilisée par ce workflow.
--
-- Cette fonction n'appartient PAS à la lignée de migrations du produit
-- (sql/NN_*.sql) : c'est un outillage QA, appliqué une seule fois sur la
-- branche de staging (cf. README §1bis), jamais rejoué en production, jamais
-- compté dans le rejeu des 262 migrations réelles.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._qa_introspect_tables(p_tables text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog', 'information_schema', 'pg_temp'
AS $function$
DECLARE
  v_result jsonb := '{}'::jsonb;
  v_table text;
  v_obj jsonb;
BEGIN
  FOREACH v_table IN ARRAY p_tables LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = v_table AND c.relkind = 'r'
    ) THEN
      CONTINUE;
    END IF;

    SELECT jsonb_build_object(
      'rls_enabled', c.relrowsecurity,
      'rls_forced', c.relforcerowsecurity,
      'owner', pg_get_userbyid(c.relowner),
      'columns', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'name', col.column_name, 'type', col.data_type,
          'nullable', (col.is_nullable = 'YES'), 'default', col.column_default
        ) ORDER BY col.ordinal_position), '[]'::jsonb)
        FROM information_schema.columns col
        WHERE col.table_schema = 'public' AND col.table_name = v_table
      ),
      'constraints', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'name', con.conname, 'type', con.contype::text,
          'definition', pg_get_constraintdef(con.oid)
        ) ORDER BY con.conname), '[]'::jsonb)
        FROM pg_constraint con WHERE con.conrelid = c.oid
      ),
      'indexes', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'name', idx.indexname, 'definition', idx.indexdef
        ) ORDER BY idx.indexname), '[]'::jsonb)
        FROM pg_indexes idx WHERE idx.schemaname = 'public' AND idx.tablename = v_table
      ),
      'triggers', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'name', tg.trigger_name
        ) ORDER BY tg.trigger_name), '[]'::jsonb)
        FROM information_schema.triggers tg
        WHERE tg.event_object_schema = 'public' AND tg.event_object_table = v_table
      ),
      'policies', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'name', pol.policyname, 'cmd', pol.cmd, 'roles', pol.roles,
          'using', pol.qual, 'check', pol.with_check
        ) ORDER BY pol.policyname), '[]'::jsonb)
        FROM pg_policies pol WHERE pol.schemaname = 'public' AND pol.tablename = v_table
      ),
      'grants', (
        SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
          'grantee', g.grantee, 'privilege', g.privilege_type
        )), '[]'::jsonb)
        FROM information_schema.role_table_grants g
        WHERE g.table_schema = 'public' AND g.table_name = v_table
      )
    ) INTO v_obj
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname = v_table;

    v_result := v_result || jsonb_build_object(v_table, v_obj);
  END LOOP;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._qa_introspect_tables(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._qa_introspect_tables(text[]) TO service_role;
