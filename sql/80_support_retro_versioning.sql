-- ============================================================================
-- sql/80_support_retro_versioning.sql
-- Lot 1, PR-01 — Rétro-versionnement à l'identique du domaine Support
-- Contrat : support_contract_v1
--
-- Objets versionnés (déjà présents en production, jamais créés par cette PR
-- dans le cas normal — voir ADR-012 §2.5/§3.5.1) :
--   - public.support_tickets (table, 5 CHECK/FK/PK/UNIQUE, 4 index)
--   - public.help_articles (table, 1 PK, 3 index)
--   - public.support_ticket_seq (séquence, utilisée par support_tickets)
--   - support_set_ticket_number(), support_set_updated_at(),
--     trg_help_articles_updated_at() (3 fonctions trigger)
--   - trg_support_ticket_number, trg_support_updated_at,
--     trg_help_articles_updated (3 triggers)
--   - 7 policies RLS (5 sur support_tickets, 2 sur help_articles)
--   - grants table/séquence/fonction, commentaires de colonne/table
--
-- Doctrine :
--   - AUCUN changement de comportement ni de permission (durcissement ACL :
--     PR-02, distincte, jamais mélangée à cette PR).
--   - AUCUNE donnée métier modifiée (DDL uniquement).
--   - Trois états par domaine : totalement absent (création complète),
--     totalement présent et conforme (aucune action), partiel ou divergent
--     (échec explicite, aucune réparation automatique).
--   - Décision globale par domaine via une empreinte structurelle unique
--     (support_contract_v1) ; le détail par catégorie reste dans le
--     diagnostic, jamais un moteur de décision indépendant par catégorie.
--
-- RÉVISION (audit post-commit initial) : la version précédente utilisait des
-- méta-commandes psql (\gset, \if/\elif/\else/\endif, \set, \echo) pour
-- piloter la branche de création. Vérification faite : le mécanisme réel
-- d'application des migrations de ce projet (Supabase Management API, outil
-- `apply_migration`) envoie la chaîne SQL brute au serveur — il n'existe
-- aucun client psql interactif dans ce chemin, donc AUCUNE méta-commande
-- psql n'y est interprétée. Le fichier committé initialement n'aurait donc
-- jamais pu être appliqué en production par le mécanisme réellement utilisé,
-- malgré des tests locaux verts via `psql -f` (qui, lui, interprète bien ces
-- méta-commandes — c'est ce qui masquait le problème). Corrigé : ce fichier
-- est désormais du SQL pur / PL/pgSQL standard, sans aucune méta-commande
-- client — compatible avec `apply_migration`, avec `psql -f` direct, et avec
-- une inclusion `\i`/`\ir` depuis un script de test psql.
--
-- CE FICHIER NE CONTIENT AUCUN BEGIN / COMMIT / ROLLBACK — invocation :
--   Production      : `apply_migration` (Management API) ou tout exécuteur
--                      SQL standard — transaction gérée par l'appelant.
--   Reconstruction  : \i / \ir sql/80_support_retro_versioning.sql à
--                      l'intérieur d'un BEGIN...ROLLBACK piloté par
--                      sql/tests/support_retro_versioning.sql (psql,
--                      contexte de test uniquement — le fichier de test n'a
--                      pas cette contrainte de compatibilité, il n'est
--                      jamais appliqué en production par cette voie).
--   Base jetable    : psql -v ON_ERROR_STOP=1 --single-transaction \
--                        -f sql/80_support_retro_versioning.sql
--                      (sur une base neuve dotée des préalables minimaux —
--                      voir le rapport de PR-01 pour la procédure exacte,
--                      non versionnée dans ce fichier).
-- ============================================================================

-- ============================================================================
-- DOMAINE 1/2 — support_tickets (table, séquence, 2 fonctions/triggers, 5 policies)
-- ============================================================================
DO $domain_support_tickets$
DECLARE
  v_all_absent boolean;
  v_all_present boolean;
BEGIN
  SELECT
    ( NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_tickets' AND relkind='r')
      AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_ticket_seq' AND relkind='S')
      AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_ticket_number')
      AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_updated_at')
      AND NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_ticket_number')
      AND NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_updated_at')
      AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets')
    ),
    ( EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_tickets' AND relkind='r')
      AND EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_ticket_seq' AND relkind='S')
      AND EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_ticket_number')
      AND EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_updated_at')
      AND EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_ticket_number')
      AND EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_updated_at')
      AND (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets') = 5
    )
  INTO v_all_absent, v_all_present;

  IF v_all_absent THEN
    RAISE NOTICE '[support_tickets] domaine totalement absent — création complète (support_contract_v1).';

    EXECUTE $ddl$
      CREATE TABLE public.support_tickets (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        hotel_id uuid NOT NULL,
        ticket_number text,
        module text NOT NULL,
        feature text NOT NULL,
        problem_type text NOT NULL DEFAULT 'autre'::text,
        description text NOT NULL,
        steps jsonb NOT NULL DEFAULT '[]'::jsonb,
        expected_result text,
        actual_result text,
        priority text NOT NULL DEFAULT 'moyen'::text,
        attachment_url text,
        user_id uuid,
        user_email text,
        user_role text,
        current_module text,
        current_page text,
        browser_info jsonb,
        related_entity_id text,
        status text NOT NULL DEFAULT 'nouveau'::text,
        assigned_to text,
        claude_response text,
        classification text,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now(),
        risk_score text,
        diagnostic_details jsonb,
        CONSTRAINT support_tickets_pkey PRIMARY KEY (id),
        CONSTRAINT support_tickets_ticket_number_key UNIQUE (ticket_number),
        CONSTRAINT support_tickets_hotel_id_fkey FOREIGN KEY (hotel_id) REFERENCES public.hotels(id) ON DELETE CASCADE,
        CONSTRAINT support_tickets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id),
        CONSTRAINT support_tickets_status_check CHECK (status = ANY (ARRAY['nouveau'::text,'en_analyse'::text,'attente_utilisateur'::text,'en_correction'::text,'resolu'::text,'ferme'::text])),
        CONSTRAINT support_tickets_priority_check CHECK (priority = ANY (ARRAY['bloquant'::text,'eleve'::text,'moyen'::text,'faible'::text])),
        CONSTRAINT support_tickets_classification_check CHECK ((classification = ANY (ARRAY['bug'::text,'amelioration'::text,'question'::text])) OR classification IS NULL),
        CONSTRAINT support_tickets_risk_score_check CHECK (risk_score = ANY (ARRAY['faible'::text,'moyen'::text,'eleve'::text,'critique'::text])),
        CONSTRAINT support_tickets_description_check CHECK (char_length(description) <= 500)
      )
    $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_support_tickets_hotel ON public.support_tickets USING btree (hotel_id, created_at DESC) $ddl$;
    EXECUTE $ddl$ CREATE INDEX idx_support_tickets_status ON public.support_tickets USING btree (hotel_id, status) $ddl$;

    EXECUTE $ddl$
      CREATE SEQUENCE public.support_ticket_seq
        START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE
    $ddl$;

    EXECUTE $ddl$
      CREATE FUNCTION public.support_set_ticket_number()
       RETURNS trigger
       LANGUAGE plpgsql
       SET search_path TO 'pg_catalog', 'public'
      AS $fn$
      BEGIN
        NEW.ticket_number := 'SUP-' || TO_CHAR(NEW.created_at, 'YYYYMM') || '-' || LPAD(nextval('support_ticket_seq')::text, 4, '0');
        RETURN NEW;
      END;
      $fn$
    $ddl$;

    EXECUTE $ddl$
      CREATE FUNCTION public.support_set_updated_at()
       RETURNS trigger
       LANGUAGE plpgsql
       SET search_path TO 'pg_catalog', 'public'
      AS $fn$
      BEGIN NEW.updated_at = now(); RETURN NEW; END;
      $fn$
    $ddl$;

    EXECUTE $ddl$ CREATE TRIGGER trg_support_ticket_number BEFORE INSERT ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.support_set_ticket_number() $ddl$;
    EXECUTE $ddl$ CREATE TRIGGER trg_support_updated_at BEFORE UPDATE ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.support_set_updated_at() $ddl$;

    EXECUTE $ddl$ ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY $ddl$;

    EXECUTE $ddl$ CREATE POLICY platform_admin_read_tickets ON public.support_tickets FOR SELECT TO public USING (is_platform_admin()) $ddl$;
    EXECUTE $ddl$ CREATE POLICY platform_admin_update_tickets ON public.support_tickets FOR UPDATE TO public USING (is_platform_admin()) WITH CHECK (is_platform_admin()) $ddl$;
    EXECUTE $ddl$ CREATE POLICY support_select ON public.support_tickets FOR SELECT TO public USING (hotel_id IN (SELECT user_hotels.hotel_id FROM public.user_hotels WHERE user_hotels.user_id = auth.uid())) $ddl$;
    EXECUTE $ddl$ CREATE POLICY support_update ON public.support_tickets FOR UPDATE TO public USING (hotel_id IN (SELECT user_hotels.hotel_id FROM public.user_hotels WHERE user_hotels.user_id = auth.uid())) $ddl$;
    EXECUTE $ddl$ CREATE POLICY support_insert ON public.support_tickets FOR INSERT TO public WITH CHECK (hotel_id IN (SELECT user_hotels.hotel_id FROM public.user_hotels WHERE user_hotels.user_id = auth.uid())) $ddl$;

    EXECUTE $ddl$ GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.support_tickets TO anon, authenticated, service_role, postgres $ddl$;
    EXECUTE $ddl$ GRANT USAGE ON SEQUENCE public.support_ticket_seq TO anon, authenticated, service_role, postgres $ddl$;
    EXECUTE $ddl$ GRANT EXECUTE ON FUNCTION public.support_set_ticket_number() TO anon, authenticated, service_role, postgres $ddl$;
    EXECUTE $ddl$ GRANT EXECUTE ON FUNCTION public.support_set_updated_at() TO anon, authenticated, service_role, postgres $ddl$;

    EXECUTE $ddl$ COMMENT ON COLUMN public.support_tickets.risk_score IS 'Computed risk level: faible | moyen | eleve | critique' $ddl$;
    EXECUTE $ddl$ COMMENT ON COLUMN public.support_tickets.diagnostic_details IS 'Structured diagnostic: externalCheckResult, riskAnalysis, correctionStrategy, affectedModules, testChecklist' $ddl$;

    RAISE NOTICE '[support_tickets] création complète terminée.';

  ELSIF v_all_present THEN
    DECLARE
      v_columns text; v_constraints text; v_indexes text; v_sequence text; v_functions text;
      v_triggers text; v_policies text; v_grants_table text; v_grants_seq text; v_grants_fn text;
      v_comments text; v_rls text;
      v_global text;
      v_expected_global CONSTANT text := '0c371c57d7482d7d3d235a484ccd2f03';
      v_expected_columns CONSTANT text := '69472e64ecceded5f7d4149e1166be5b';
      v_expected_constraints CONSTANT text := 'de145df1d8c49d65b341a7dd707f4ef0';
      v_expected_indexes CONSTANT text := 'd4e76ef700bc38f226f2449d89f6f35f';
      v_expected_sequence CONSTANT text := '81cc7f628934d2c028d303e04fd1e4d7';
      v_expected_functions CONSTANT text := '729f1d904e31e2d2fefddd84bd488e6b';
      v_expected_triggers CONSTANT text := 'ff50898c6dd6e8791227fb916eb59e76';
      v_expected_policies CONSTANT text := '9fbbae35d3fde21fa78f196bf6342055';
      v_expected_grants_table CONSTANT text := '314ce422130988b285304cc5e0e686ec';
      v_expected_grants_seq CONSTANT text := 'e46e706eaac24f4d5c3e1f7298c27f2b';
      v_expected_grants_fn CONSTANT text := '6cd677eb657a2ce50f7ae6aaace75278';
      v_expected_comments CONSTANT text := '95259d60c21e53dd4b82436a923a0a7b';
      v_expected_rls CONSTANT text := '6bac509a1f0a43ba1b9e59f572f0aa41';
      v_diag text := '';
    BEGIN
      SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
        INTO v_columns FROM information_schema.columns WHERE table_schema='public' AND table_name='support_tickets';

      SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
        INTO v_constraints FROM pg_constraint WHERE conrelid='public.support_tickets'::regclass;

      SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
        INTO v_indexes FROM pg_indexes WHERE schemaname='public' AND tablename='support_tickets';

      SELECT format('start:%s|inc:%s|min:%s|max:%s|cache:%s|cycle:%s|owner:%s', start_value, increment_by, min_value, max_value, cache_size, cycle, sequenceowner)
        INTO v_sequence FROM pg_sequences WHERE schemaname='public' AND sequencename='support_ticket_seq';
      -- NB: last_value volontairement exclu (non transactionnel, varie légitimement).

      SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
        INTO v_functions FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('support_set_ticket_number','support_set_updated_at');

      SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
        INTO v_triggers FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='support_tickets';

      SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
        INTO v_policies FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets';

      SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
        INTO v_grants_table FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='support_tickets';

      SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
        INTO v_grants_seq FROM information_schema.role_usage_grants WHERE object_schema='public' AND object_name='support_ticket_seq';

      SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
        INTO v_grants_fn FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('support_set_ticket_number','support_set_updated_at');

      SELECT string_agg(column_name||':'||col_description('public.support_tickets'::regclass::oid, ordinal_position), '|' ORDER BY column_name)
        INTO v_comments FROM information_schema.columns
        WHERE table_schema='public' AND table_name='support_tickets' AND col_description('public.support_tickets'::regclass::oid, ordinal_position) IS NOT NULL;

      SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text
        INTO v_rls FROM pg_class WHERE oid='public.support_tickets'::regclass;

      v_global := md5(concat_ws('|',
        md5(coalesce(v_columns,'')), md5(coalesce(v_constraints,'')), md5(coalesce(v_indexes,'')), md5(coalesce(v_sequence,'')),
        md5(coalesce(v_functions,'')), md5(coalesce(v_triggers,'')), md5(coalesce(v_policies,'')), md5(coalesce(v_grants_table,'')),
        md5(coalesce(v_grants_seq,'')), md5(coalesce(v_grants_fn,'')), md5(coalesce(v_comments,'')), md5(coalesce(v_rls,''))));

      IF v_global IS DISTINCT FROM v_expected_global THEN
        IF md5(coalesce(v_columns,'')) IS DISTINCT FROM v_expected_columns THEN v_diag := v_diag || E'\n  - colonnes'; END IF;
        IF md5(coalesce(v_constraints,'')) IS DISTINCT FROM v_expected_constraints THEN v_diag := v_diag || E'\n  - contraintes'; END IF;
        IF md5(coalesce(v_indexes,'')) IS DISTINCT FROM v_expected_indexes THEN v_diag := v_diag || E'\n  - index'; END IF;
        IF md5(coalesce(v_sequence,'')) IS DISTINCT FROM v_expected_sequence THEN v_diag := v_diag || E'\n  - séquence (hors last_value)'; END IF;
        IF md5(coalesce(v_functions,'')) IS DISTINCT FROM v_expected_functions THEN v_diag := v_diag || E'\n  - fonctions trigger'; END IF;
        IF md5(coalesce(v_triggers,'')) IS DISTINCT FROM v_expected_triggers THEN v_diag := v_diag || E'\n  - triggers'; END IF;
        IF md5(coalesce(v_policies,'')) IS DISTINCT FROM v_expected_policies THEN v_diag := v_diag || E'\n  - policies RLS'; END IF;
        IF md5(coalesce(v_grants_table,'')) IS DISTINCT FROM v_expected_grants_table THEN v_diag := v_diag || E'\n  - grants table'; END IF;
        IF md5(coalesce(v_grants_seq,'')) IS DISTINCT FROM v_expected_grants_seq THEN v_diag := v_diag || E'\n  - grants séquence'; END IF;
        IF md5(coalesce(v_grants_fn,'')) IS DISTINCT FROM v_expected_grants_fn THEN v_diag := v_diag || E'\n  - grants EXECUTE fonctions'; END IF;
        IF md5(coalesce(v_comments,'')) IS DISTINCT FROM v_expected_comments THEN v_diag := v_diag || E'\n  - commentaires'; END IF;
        IF md5(coalesce(v_rls,'')) IS DISTINCT FROM v_expected_rls THEN v_diag := v_diag || E'\n  - RLS activée / propriétaire'; END IF;
        RAISE EXCEPTION E'[support_tickets] diverge du contrat support_contract_v1.\nFingerprint attendu : %\nFingerprint observé : %\nCatégories divergentes :%\nAucune réparation automatique — corriger manuellement ou ouvrir une PR dédiée.', v_expected_global, v_global, v_diag;
      END IF;

      RAISE NOTICE '[support_tickets] conforme au contrat support_contract_v1 (fingerprint %). Aucune action.', v_global;
    END;

  ELSE
    DECLARE
      v_msg text := '[support_tickets] état partiel détecté — ni totalement absent, ni totalement présent :';
    BEGIN
      v_msg := v_msg || E'\n  - table support_tickets : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_tickets' AND relkind='r') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - séquence support_ticket_seq : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='support_ticket_seq' AND relkind='S') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - fonction support_set_ticket_number() : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_ticket_number') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - fonction support_set_updated_at() : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='support_set_updated_at') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - trigger trg_support_ticket_number : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_ticket_number') THEN 'présent' ELSE 'absent' END);
      v_msg := v_msg || E'\n  - trigger trg_support_updated_at : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='support_tickets' AND tg.tgname='trg_support_updated_at') THEN 'présent' ELSE 'absent' END);
      v_msg := v_msg || E'\n  - policies RLS présentes : ' || (SELECT count(*)::text FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets') || ' / 5 attendues';
      v_msg := v_msg || E'\nAucune réparation automatique — corriger manuellement l''écart avant de rejouer cette migration.';
      RAISE EXCEPTION '%', v_msg;
    END;
  END IF;
END
$domain_support_tickets$;

-- ============================================================================
-- DOMAINE 2/2 — help_articles (table, 1 fonction/trigger, 2 policies)
-- ============================================================================
DO $domain_help_articles$
DECLARE
  v_all_absent boolean;
  v_all_present boolean;
BEGIN
  SELECT
    ( NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='help_articles' AND relkind='r')
      AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='trg_help_articles_updated_at')
      AND NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='help_articles' AND tg.tgname='trg_help_articles_updated')
      AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='help_articles')
    ),
    ( EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='help_articles' AND relkind='r')
      AND EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='trg_help_articles_updated_at')
      AND EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='help_articles' AND tg.tgname='trg_help_articles_updated')
      AND (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='help_articles') = 2
    )
  INTO v_all_absent, v_all_present;

  IF v_all_absent THEN
    RAISE NOTICE '[help_articles] domaine totalement absent — création complète (support_contract_v1).';

    EXECUTE $ddl$
      CREATE TABLE public.help_articles (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        module text NOT NULL,
        title text NOT NULL,
        slug text,
        excerpt text,
        body text NOT NULL DEFAULT ''::text,
        tags text[] NOT NULL DEFAULT '{}'::text[],
        sort_order integer NOT NULL DEFAULT 0,
        is_published boolean NOT NULL DEFAULT false,
        view_count integer NOT NULL DEFAULT 0,
        created_by uuid,
        updated_by uuid,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT help_articles_pkey PRIMARY KEY (id)
      )
    $ddl$;

    EXECUTE $ddl$ COMMENT ON TABLE public.help_articles IS 'Documentation Flowtym par module. Lecture pour tout utilisateur authentifié (articles publiés). Écriture pour super_admin / support_agent.' $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_help_articles_module ON public.help_articles USING btree (module, sort_order) $ddl$;
    EXECUTE $ddl$ CREATE INDEX idx_help_articles_published ON public.help_articles USING btree (is_published, module) $ddl$;

    EXECUTE $ddl$
      CREATE FUNCTION public.trg_help_articles_updated_at()
       RETURNS trigger
       LANGUAGE plpgsql
       SET search_path TO 'pg_catalog', 'public'
      AS $fn$
      BEGIN NEW.updated_at = now(); RETURN NEW; END;
      $fn$
    $ddl$;

    EXECUTE $ddl$ CREATE TRIGGER trg_help_articles_updated BEFORE UPDATE ON public.help_articles FOR EACH ROW EXECUTE FUNCTION public.trg_help_articles_updated_at() $ddl$;

    EXECUTE $ddl$ ALTER TABLE public.help_articles ENABLE ROW LEVEL SECURITY $ddl$;

    EXECUTE $ddl$ CREATE POLICY help_articles_select ON public.help_articles FOR SELECT TO public USING ((is_published = true) OR is_platform_admin()) $ddl$;
    EXECUTE $ddl$ CREATE POLICY help_articles_write ON public.help_articles FOR ALL TO public USING (platform_admin_role() = ANY (ARRAY['super_admin'::text,'support_agent'::text])) WITH CHECK (platform_admin_role() = ANY (ARRAY['super_admin'::text,'support_agent'::text])) $ddl$;

    EXECUTE $ddl$ GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.help_articles TO anon, authenticated, service_role, postgres $ddl$;
    EXECUTE $ddl$ GRANT EXECUTE ON FUNCTION public.trg_help_articles_updated_at() TO anon, authenticated, service_role, postgres $ddl$;

    RAISE NOTICE '[help_articles] création complète terminée.';

  ELSIF v_all_present THEN
    DECLARE
      v_columns text; v_constraints text; v_indexes text; v_functions text;
      v_triggers text; v_policies text; v_grants_table text; v_grants_fn text;
      v_comments text; v_rls text;
      v_global text;
      v_expected_global CONSTANT text := 'c9fa10d12917bce4d013fc465916e54c';
      v_expected_columns CONSTANT text := 'b8ad7364eefff2a2b8d4259efa5da993';
      v_expected_constraints CONSTANT text := '849fdc22a3f19f569a32163fcbaed9d0';
      v_expected_indexes CONSTANT text := '1bcd8da8c0f4cd6dce7557e5ed5e2308';
      v_expected_functions CONSTANT text := '7b3a30bbd007e447abc24ebfeefdc5e1';
      v_expected_triggers CONSTANT text := '87322bc8b539cefdf8d0a9c4f630be47';
      v_expected_policies CONSTANT text := '92b55bc4114b0a608024982e7c92aab7';
      v_expected_grants_table CONSTANT text := '314ce422130988b285304cc5e0e686ec';
      v_expected_grants_fn CONSTANT text := 'de4bf7c09bbc7a1bd99935fb243e4e79';
      v_expected_comments CONSTANT text := '1ecf9d3ce622f837dad3cbadfe5b1464';
      v_expected_rls CONSTANT text := '6bac509a1f0a43ba1b9e59f572f0aa41';
      v_diag text := '';
    BEGIN
      SELECT string_agg(format('%s:%s:%s:%s:%s', column_name, data_type, is_nullable, coalesce(column_default,'∅'), coalesce(character_maximum_length::text,'∅')), '|' ORDER BY ordinal_position)
        INTO v_columns FROM information_schema.columns WHERE table_schema='public' AND table_name='help_articles';

      SELECT string_agg(conname||':'||contype::text||':'||pg_get_constraintdef(oid,true), '|' ORDER BY conname)
        INTO v_constraints FROM pg_constraint WHERE conrelid='public.help_articles'::regclass;

      SELECT string_agg(indexname||':'||indexdef, '|' ORDER BY indexname)
        INTO v_indexes FROM pg_indexes WHERE schemaname='public' AND tablename='help_articles';

      SELECT string_agg(proname||':'||prosecdef::text||':'||provolatile::text||':'||regexp_replace(pg_get_functiondef(oid),'\s+',' ','g'), '|' ORDER BY proname)
        INTO v_functions FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('trg_help_articles_updated_at');

      SELECT string_agg(trigger_name||':'||action_timing||':'||event_manipulation||':'||action_statement, '|' ORDER BY trigger_name)
        INTO v_triggers FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='help_articles';

      SELECT string_agg(policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,',')||':'||coalesce(qual,'∅')||':'||coalesce(with_check,'∅'), '|' ORDER BY policyname)
        INTO v_policies FROM pg_policies WHERE schemaname='public' AND tablename='help_articles';

      SELECT string_agg(grantee||':'||privilege_type, '|' ORDER BY grantee, privilege_type)
        INTO v_grants_table FROM information_schema.role_table_grants WHERE table_schema='public' AND table_name='help_articles';

      SELECT string_agg(routine_name||':'||grantee||':'||privilege_type, '|' ORDER BY routine_name, grantee, privilege_type)
        INTO v_grants_fn FROM information_schema.role_routine_grants WHERE routine_schema='public' AND routine_name IN ('trg_help_articles_updated_at');

      SELECT obj_description('public.help_articles'::regclass) INTO v_comments;

      SELECT 'rls:'||relrowsecurity::text||':owner:'||relowner::regrole::text
        INTO v_rls FROM pg_class WHERE oid='public.help_articles'::regclass;

      v_global := md5(concat_ws('|',
        md5(coalesce(v_columns,'')), md5(coalesce(v_constraints,'')), md5(coalesce(v_indexes,'')),
        md5(coalesce(v_functions,'')), md5(coalesce(v_triggers,'')), md5(coalesce(v_policies,'')),
        md5(coalesce(v_grants_table,'')), md5(coalesce(v_grants_fn,'')), md5(coalesce(v_comments,'')), md5(coalesce(v_rls,''))));

      IF v_global IS DISTINCT FROM v_expected_global THEN
        IF md5(coalesce(v_columns,'')) IS DISTINCT FROM v_expected_columns THEN v_diag := v_diag || E'\n  - colonnes'; END IF;
        IF md5(coalesce(v_constraints,'')) IS DISTINCT FROM v_expected_constraints THEN v_diag := v_diag || E'\n  - contraintes'; END IF;
        IF md5(coalesce(v_indexes,'')) IS DISTINCT FROM v_expected_indexes THEN v_diag := v_diag || E'\n  - index'; END IF;
        IF md5(coalesce(v_functions,'')) IS DISTINCT FROM v_expected_functions THEN v_diag := v_diag || E'\n  - fonction trigger'; END IF;
        IF md5(coalesce(v_triggers,'')) IS DISTINCT FROM v_expected_triggers THEN v_diag := v_diag || E'\n  - trigger'; END IF;
        IF md5(coalesce(v_policies,'')) IS DISTINCT FROM v_expected_policies THEN v_diag := v_diag || E'\n  - policies RLS'; END IF;
        IF md5(coalesce(v_grants_table,'')) IS DISTINCT FROM v_expected_grants_table THEN v_diag := v_diag || E'\n  - grants table'; END IF;
        IF md5(coalesce(v_grants_fn,'')) IS DISTINCT FROM v_expected_grants_fn THEN v_diag := v_diag || E'\n  - grants EXECUTE fonction'; END IF;
        IF md5(coalesce(v_comments,'')) IS DISTINCT FROM v_expected_comments THEN v_diag := v_diag || E'\n  - commentaire de table'; END IF;
        IF md5(coalesce(v_rls,'')) IS DISTINCT FROM v_expected_rls THEN v_diag := v_diag || E'\n  - RLS activée / propriétaire'; END IF;
        RAISE EXCEPTION E'[help_articles] diverge du contrat support_contract_v1.\nFingerprint attendu : %\nFingerprint observé : %\nCatégories divergentes :%\nAucune réparation automatique — corriger manuellement ou ouvrir une PR dédiée.', v_expected_global, v_global, v_diag;
      END IF;

      RAISE NOTICE '[help_articles] conforme au contrat support_contract_v1 (fingerprint %). Aucune action.', v_global;
    END;

  ELSE
    DECLARE
      v_msg text := '[help_articles] état partiel détecté — ni totalement absent, ni totalement présent :';
    BEGIN
      v_msg := v_msg || E'\n  - table help_articles : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='help_articles' AND relkind='r') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - fonction trg_help_articles_updated_at() : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='trg_help_articles_updated_at') THEN 'présente' ELSE 'absente' END);
      v_msg := v_msg || E'\n  - trigger trg_help_articles_updated : ' || (CASE WHEN EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='help_articles' AND tg.tgname='trg_help_articles_updated') THEN 'présent' ELSE 'absent' END);
      v_msg := v_msg || E'\n  - policies RLS présentes : ' || (SELECT count(*)::text FROM pg_policies WHERE schemaname='public' AND tablename='help_articles') || ' / 2 attendues';
      v_msg := v_msg || E'\nAucune réparation automatique — corriger manuellement l''écart avant de rejouer cette migration.';
      RAISE EXCEPTION '%', v_msg;
    END;
  END IF;
END
$domain_help_articles$;
