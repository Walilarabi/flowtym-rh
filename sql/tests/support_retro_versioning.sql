-- ============================================================================
-- sql/tests/support_retro_versioning.sql
-- Lot 1, PR-01 — Test transactionnel du rétro-versionnement Support
--
-- Ce fichier, et lui seul, est responsable de BEGIN/ROLLBACK — sql/80 n'en
-- contient aucun (voir son en-tête), pour pouvoir être inclus ici via \ir
-- sans valider accidentellement la transaction englobante.
--
-- Preuve apportée : application de sql/80_support_retro_versioning.sql
-- (littéralement, par inclusion — jamais une copie de son contenu) contre la
-- production réelle est un no-op strict :
--   - les OID de tous les objets du domaine restent identiques avant/après
--     (preuve qu'aucun objet n'a été supprimé puis recréé) ;
--   - les empreintes structurelles par catégorie restent identiques ;
--   - le nombre de lignes et le hash de contenu des deux tables restent
--     identiques (aucune donnée métier modifiée, valeurs jamais codées en dur) ;
--   - support_ticket_seq.last_value reste identique (aucun nextval() appelé
--     sur la séquence de production — ni par ce test, ni par sql/80).
--
-- Invocation : psql -f sql/tests/support_retro_versioning.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Instantané AVANT inclusion
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE zz_before AS
WITH
support_tickets_fp AS (
  SELECT
    (SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='support_tickets') AS columns_fp,
    (SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
       FROM pg_constraint WHERE conrelid='public.support_tickets'::regclass) AS constraints_fp,
    (SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
       FROM pg_indexes WHERE schemaname='public' AND tablename='support_tickets') AS indexes_fp,
    (SELECT format('start:%s|inc:%s|min:%s|max:%s|cache:%s|cycle:%s|owner:%s', start_value, increment_by, min_value, max_value, cache_size, cycle, sequenceowner)
       FROM pg_sequences WHERE schemaname='public' AND sequencename='support_ticket_seq') AS sequence_fp,
    (SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
       FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('support_set_ticket_number','support_set_updated_at')) AS functions_fp,
    (SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
       FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='support_tickets') AS triggers_fp,
    (SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
       FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets') AS policies_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='support_tickets') AS grants_table_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_usage_grants WHERE object_schema='public' AND object_name='support_ticket_seq') AS grants_seq_fp,
    (SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
       FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('support_set_ticket_number','support_set_updated_at')) AS grants_fn_fp,
    (SELECT string_agg(column_name||':'||col_description('public.support_tickets'::regclass::oid, ordinal_position), '|' ORDER BY column_name)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='support_tickets'
         AND col_description('public.support_tickets'::regclass::oid, ordinal_position) IS NOT NULL) AS comments_fp,
    (SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text FROM pg_class WHERE oid='public.support_tickets'::regclass) AS rls_fp
),
help_articles_fp AS (
  SELECT
    (SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='help_articles') AS columns_fp,
    (SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
       FROM pg_constraint WHERE conrelid='public.help_articles'::regclass) AS constraints_fp,
    (SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
       FROM pg_indexes WHERE schemaname='public' AND tablename='help_articles') AS indexes_fp,
    (SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
       FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_help_articles_updated_at')) AS functions_fp,
    (SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
       FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='help_articles') AS triggers_fp,
    (SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
       FROM pg_policies WHERE schemaname='public' AND tablename='help_articles') AS policies_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='help_articles') AS grants_table_fp,
    (SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
       FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('trg_help_articles_updated_at')) AS grants_fn_fp,
    (SELECT obj_description('public.help_articles'::regclass)) AS comments_fp,
    (SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text FROM pg_class WHERE oid='public.help_articles'::regclass) AS rls_fp
)
SELECT 'support_tickets'::text AS domain,
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_tickets')::text AS table_oid,
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_ticket_seq')::text AS seq_oid,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('support_set_ticket_number','support_set_updated_at')) AS fn_oids,
  (SELECT string_agg(indexrelid::text,',' ORDER BY indexrelid) FROM pg_index WHERE indrelid='public.support_tickets'::regclass) AS index_oids,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_constraint WHERE conrelid='public.support_tickets'::regclass) AS constraint_oids,
  (SELECT string_agg(tg.oid::text,',' ORDER BY tg.oid) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relname='support_tickets' AND c.relnamespace='public'::regnamespace) AS trigger_oids,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_policy WHERE polrelid='public.support_tickets'::regclass) AS policy_oids,
  (SELECT last_value FROM pg_sequences WHERE schemaname='public' AND sequencename='support_ticket_seq')::text AS seq_last_value,
  (SELECT count(*) FROM public.support_tickets)::text AS row_count,
  (SELECT md5(coalesce(string_agg(t::text,'|' ORDER BY id),'')) FROM public.support_tickets t) AS content_hash,
  md5(coalesce(f.columns_fp,'')) AS columns_fp, md5(coalesce(f.constraints_fp,'')) AS constraints_fp, md5(coalesce(f.indexes_fp,'')) AS indexes_fp,
  md5(coalesce(f.sequence_fp,'')) AS sequence_fp, md5(coalesce(f.functions_fp,'')) AS functions_fp, md5(coalesce(f.triggers_fp,'')) AS triggers_fp,
  md5(coalesce(f.policies_fp,'')) AS policies_fp, md5(coalesce(f.grants_table_fp,'')) AS grants_table_fp, md5(coalesce(f.grants_seq_fp,'')) AS grants_seq_fp,
  md5(coalesce(f.grants_fn_fp,'')) AS grants_fn_fp, md5(coalesce(f.comments_fp,'')) AS comments_fp, md5(coalesce(f.rls_fp,'')) AS rls_fp
FROM support_tickets_fp f
UNION ALL
SELECT 'help_articles',
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='help_articles')::text,
  NULL,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_help_articles_updated_at')),
  (SELECT string_agg(indexrelid::text,',' ORDER BY indexrelid) FROM pg_index WHERE indrelid='public.help_articles'::regclass),
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_constraint WHERE conrelid='public.help_articles'::regclass),
  (SELECT string_agg(tg.oid::text,',' ORDER BY tg.oid) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relname='help_articles' AND c.relnamespace='public'::regnamespace),
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_policy WHERE polrelid='public.help_articles'::regclass),
  NULL,
  (SELECT count(*) FROM public.help_articles)::text,
  (SELECT md5(coalesce(string_agg(t::text,'|' ORDER BY id),'')) FROM public.help_articles t),
  md5(coalesce(f.columns_fp,'')), md5(coalesce(f.constraints_fp,'')), md5(coalesce(f.indexes_fp,'')),
  NULL, md5(coalesce(f.functions_fp,'')), md5(coalesce(f.triggers_fp,'')),
  md5(coalesce(f.policies_fp,'')), md5(coalesce(f.grants_table_fp,'')), NULL,
  md5(coalesce(f.grants_fn_fp,'')), md5(coalesce(f.comments_fp,'')), md5(coalesce(f.rls_fp,''))
FROM help_articles_fp f;

\echo '--- instantané AVANT capturé (zz_before) ---'
SELECT domain, table_oid, seq_oid, row_count, seq_last_value FROM zz_before ORDER BY domain;

-- ----------------------------------------------------------------------------
-- Inclusion littérale de la migration réelle — jamais une copie
-- ----------------------------------------------------------------------------
\ir ../80_support_retro_versioning.sql

-- ----------------------------------------------------------------------------
-- Instantané APRÈS inclusion (mêmes requêtes, exactement)
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE zz_after AS
WITH
support_tickets_fp AS (
  SELECT
    (SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='support_tickets') AS columns_fp,
    (SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
       FROM pg_constraint WHERE conrelid='public.support_tickets'::regclass) AS constraints_fp,
    (SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
       FROM pg_indexes WHERE schemaname='public' AND tablename='support_tickets') AS indexes_fp,
    (SELECT format('start:%s|inc:%s|min:%s|max:%s|cache:%s|cycle:%s|owner:%s', start_value, increment_by, min_value, max_value, cache_size, cycle, sequenceowner)
       FROM pg_sequences WHERE schemaname='public' AND sequencename='support_ticket_seq') AS sequence_fp,
    (SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
       FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('support_set_ticket_number','support_set_updated_at')) AS functions_fp,
    (SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
       FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='support_tickets') AS triggers_fp,
    (SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
       FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets') AS policies_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='support_tickets') AS grants_table_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_usage_grants WHERE object_schema='public' AND object_name='support_ticket_seq') AS grants_seq_fp,
    (SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
       FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('support_set_ticket_number','support_set_updated_at')) AS grants_fn_fp,
    (SELECT string_agg(column_name||':'||col_description('public.support_tickets'::regclass::oid, ordinal_position), '|' ORDER BY column_name)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='support_tickets'
         AND col_description('public.support_tickets'::regclass::oid, ordinal_position) IS NOT NULL) AS comments_fp,
    (SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text FROM pg_class WHERE oid='public.support_tickets'::regclass) AS rls_fp
),
help_articles_fp AS (
  SELECT
    (SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
       FROM information_schema.columns WHERE table_schema='public' AND table_name='help_articles') AS columns_fp,
    (SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
       FROM pg_constraint WHERE conrelid='public.help_articles'::regclass) AS constraints_fp,
    (SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
       FROM pg_indexes WHERE schemaname='public' AND tablename='help_articles') AS indexes_fp,
    (SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
       FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_help_articles_updated_at')) AS functions_fp,
    (SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
       FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='help_articles') AS triggers_fp,
    (SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
       FROM pg_policies WHERE schemaname='public' AND tablename='help_articles') AS policies_fp,
    (SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
       FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='help_articles') AS grants_table_fp,
    (SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
       FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('trg_help_articles_updated_at')) AS grants_fn_fp,
    (SELECT obj_description('public.help_articles'::regclass)) AS comments_fp,
    (SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text FROM pg_class WHERE oid='public.help_articles'::regclass) AS rls_fp
)
SELECT 'support_tickets'::text AS domain,
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_tickets')::text AS table_oid,
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_ticket_seq')::text AS seq_oid,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('support_set_ticket_number','support_set_updated_at')) AS fn_oids,
  (SELECT string_agg(indexrelid::text,',' ORDER BY indexrelid) FROM pg_index WHERE indrelid='public.support_tickets'::regclass) AS index_oids,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_constraint WHERE conrelid='public.support_tickets'::regclass) AS constraint_oids,
  (SELECT string_agg(tg.oid::text,',' ORDER BY tg.oid) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relname='support_tickets' AND c.relnamespace='public'::regnamespace) AS trigger_oids,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_policy WHERE polrelid='public.support_tickets'::regclass) AS policy_oids,
  (SELECT last_value FROM pg_sequences WHERE schemaname='public' AND sequencename='support_ticket_seq')::text AS seq_last_value,
  (SELECT count(*) FROM public.support_tickets)::text AS row_count,
  (SELECT md5(coalesce(string_agg(t::text,'|' ORDER BY id),'')) FROM public.support_tickets t) AS content_hash,
  md5(coalesce(f.columns_fp,'')) AS columns_fp, md5(coalesce(f.constraints_fp,'')) AS constraints_fp, md5(coalesce(f.indexes_fp,'')) AS indexes_fp,
  md5(coalesce(f.sequence_fp,'')) AS sequence_fp, md5(coalesce(f.functions_fp,'')) AS functions_fp, md5(coalesce(f.triggers_fp,'')) AS triggers_fp,
  md5(coalesce(f.policies_fp,'')) AS policies_fp, md5(coalesce(f.grants_table_fp,'')) AS grants_table_fp, md5(coalesce(f.grants_seq_fp,'')) AS grants_seq_fp,
  md5(coalesce(f.grants_fn_fp,'')) AS grants_fn_fp, md5(coalesce(f.comments_fp,'')) AS comments_fp, md5(coalesce(f.rls_fp,'')) AS rls_fp
FROM support_tickets_fp f
UNION ALL
SELECT 'help_articles',
  (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='help_articles')::text,
  NULL,
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_help_articles_updated_at')),
  (SELECT string_agg(indexrelid::text,',' ORDER BY indexrelid) FROM pg_index WHERE indrelid='public.help_articles'::regclass),
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_constraint WHERE conrelid='public.help_articles'::regclass),
  (SELECT string_agg(tg.oid::text,',' ORDER BY tg.oid) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relname='help_articles' AND c.relnamespace='public'::regnamespace),
  (SELECT string_agg(oid::text,',' ORDER BY oid) FROM pg_policy WHERE polrelid='public.help_articles'::regclass),
  NULL,
  (SELECT count(*) FROM public.help_articles)::text,
  (SELECT md5(coalesce(string_agg(t::text,'|' ORDER BY id),'')) FROM public.help_articles t),
  md5(coalesce(f.columns_fp,'')), md5(coalesce(f.constraints_fp,'')), md5(coalesce(f.indexes_fp,'')),
  NULL, md5(coalesce(f.functions_fp,'')), md5(coalesce(f.triggers_fp,'')),
  md5(coalesce(f.policies_fp,'')), md5(coalesce(f.grants_table_fp,'')), NULL,
  md5(coalesce(f.grants_fn_fp,'')), md5(coalesce(f.comments_fp,'')), md5(coalesce(f.rls_fp,''))
FROM help_articles_fp f;

\echo '--- instantané APRÈS capturé (zz_after) ---'
SELECT domain, table_oid, seq_oid, row_count, seq_last_value FROM zz_after ORDER BY domain;

-- ----------------------------------------------------------------------------
-- Comparaison AVANT/APRÈS — preuve du no-op (OID + structure + ACL + données)
-- ----------------------------------------------------------------------------
DO $compare$
DECLARE
  r RECORD;
  v_fail boolean := false;
BEGIN
  FOR r IN
    SELECT b.domain,
      (b.table_oid IS DISTINCT FROM a.table_oid) AS d_table_oid,
      (b.seq_oid IS DISTINCT FROM a.seq_oid) AS d_seq_oid,
      (b.fn_oids IS DISTINCT FROM a.fn_oids) AS d_fn_oids,
      (b.index_oids IS DISTINCT FROM a.index_oids) AS d_index_oids,
      (b.constraint_oids IS DISTINCT FROM a.constraint_oids) AS d_constraint_oids,
      (b.trigger_oids IS DISTINCT FROM a.trigger_oids) AS d_trigger_oids,
      (b.policy_oids IS DISTINCT FROM a.policy_oids) AS d_policy_oids,
      (b.seq_last_value IS DISTINCT FROM a.seq_last_value) AS d_seq_last_value,
      (b.row_count IS DISTINCT FROM a.row_count) AS d_row_count,
      (b.content_hash IS DISTINCT FROM a.content_hash) AS d_content_hash,
      (b.columns_fp IS DISTINCT FROM a.columns_fp) AS d_columns_fp,
      (b.constraints_fp IS DISTINCT FROM a.constraints_fp) AS d_constraints_fp,
      (b.indexes_fp IS DISTINCT FROM a.indexes_fp) AS d_indexes_fp,
      (b.sequence_fp IS DISTINCT FROM a.sequence_fp) AS d_sequence_fp,
      (b.functions_fp IS DISTINCT FROM a.functions_fp) AS d_functions_fp,
      (b.triggers_fp IS DISTINCT FROM a.triggers_fp) AS d_triggers_fp,
      (b.policies_fp IS DISTINCT FROM a.policies_fp) AS d_policies_fp,
      (b.grants_table_fp IS DISTINCT FROM a.grants_table_fp) AS d_grants_table_fp,
      (b.grants_seq_fp IS DISTINCT FROM a.grants_seq_fp) AS d_grants_seq_fp,
      (b.grants_fn_fp IS DISTINCT FROM a.grants_fn_fp) AS d_grants_fn_fp,
      (b.comments_fp IS DISTINCT FROM a.comments_fp) AS d_comments_fp,
      (b.rls_fp IS DISTINCT FROM a.rls_fp) AS d_rls_fp
    FROM zz_before b JOIN zz_after a USING (domain)
  LOOP
    IF r.d_table_oid OR r.d_seq_oid OR r.d_fn_oids OR r.d_index_oids OR r.d_constraint_oids OR r.d_trigger_oids
       OR r.d_policy_oids OR r.d_seq_last_value OR r.d_row_count OR r.d_content_hash
       OR r.d_columns_fp OR r.d_constraints_fp OR r.d_indexes_fp OR r.d_sequence_fp OR r.d_functions_fp
       OR r.d_triggers_fp OR r.d_policies_fp OR r.d_grants_table_fp OR r.d_grants_seq_fp OR r.d_grants_fn_fp
       OR r.d_comments_fp OR r.d_rls_fp THEN
      v_fail := true;
      RAISE WARNING '[%] ECHEC no-op — au moins un écart avant/après : table_oid=% seq_oid=% fn_oids=% index_oids=% constraint_oids=% trigger_oids=% policy_oids=% seq_last_value=% row_count=% content_hash=% columns=% constraints=% indexes=% sequence=% functions=% triggers=% policies=% grants_table=% grants_seq=% grants_fn=% comments=% rls=%',
        r.domain, r.d_table_oid, r.d_seq_oid, r.d_fn_oids, r.d_index_oids, r.d_constraint_oids, r.d_trigger_oids,
        r.d_policy_oids, r.d_seq_last_value, r.d_row_count, r.d_content_hash, r.d_columns_fp, r.d_constraints_fp,
        r.d_indexes_fp, r.d_sequence_fp, r.d_functions_fp, r.d_triggers_fp, r.d_policies_fp, r.d_grants_table_fp,
        r.d_grants_seq_fp, r.d_grants_fn_fp, r.d_comments_fp, r.d_rls_fp;
    ELSE
      RAISE NOTICE '[%] PASS — no-op prouvé (OID identiques, structure identique, ACL identiques, aucune donnée modifiée, aucun nextval() sur support_ticket_seq).', r.domain;
    END IF;
  END LOOP;

  IF v_fail THEN
    RAISE EXCEPTION 'sql/tests/support_retro_versioning.sql : ECHEC — voir les WARNING ci-dessus pour le détail des écarts.';
  END IF;

  RAISE NOTICE 'sql/tests/support_retro_versioning.sql : TOUS LES CONTROLES PASSENT (no-op prouvé par OID+fingerprint+snapshot dynamique pour support_tickets et help_articles).';
END
$compare$;

ROLLBACK;
