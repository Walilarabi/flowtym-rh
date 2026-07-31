-- ============================================================================
-- sql/85_support_ticket_replies.sql
-- Lot 5 — PR-06 : Support back-office (ADR-012 §3.5.3/§3.5.4/§3.5.6/§3.5.7)
--
-- Dépend de Lot 2 (platform_notifications, sql/82).
--
-- Ajoute :
--   1) public.support_ticket_replies — fil de réponses append-only (aucune
--      policy UPDATE/DELETE pour quiconque, y compris admin ; correction par
--      nouvelle ligne via corrects_reply_id, masquage audité via hidden_at).
--   2) public._is_support_staff() — moindre privilège : super_admin ET
--      support_agent uniquement (jamais billing_admin) pour tout ce module.
--   3) RPC back-office : admin_list_support_tickets, admin_get_support_ticket_
--      detail, admin_update_support_ticket, admin_reply_support_ticket,
--      admin_hide_support_ticket_reply, admin_unhide_support_ticket_reply.
--
-- Hors périmètre de cette PR (ADR-012 §3.5.5/§3.5.8, Lot 5 PR-07) : création de
-- ticket côté hôtel, réponse côté hôtel, pièces jointes, Storage. La policy
-- hotel_select_own_visible_replies est créée ici (elle ne dépend d'aucune RPC
-- de PR-07) pour que la lecture du fil par l'hôtel fonctionne dès cette PR,
-- mais aucune RPC ni UI hôtel n'est livrée ici.
--
-- Doctrine trois états (remplace l'ancien CREATE TABLE IF NOT EXISTS, qui
-- masquerait silencieusement toute divergence de schéma sur un replay) :
--   A. domaine absent            → création complète (table, index, commentaire).
--   B. domaine présent, conforme → no-op (contrat vérifié : colonnes,
--                                  contraintes, index, trigger, policies,
--                                  grants, commentaire, propriétaire).
--   C. domaine présent, divergent → RAISE EXCEPTION, aucune correction
--                                  automatique.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

DO $support_ticket_replies_table$
DECLARE
  v_table_exists boolean;
  v_col_count int;
  v_owner text;
  v_comment text;
  v_missing_constraints text[];
  v_c text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = 'support_ticket_replies' AND relkind = 'r'
  ) INTO v_table_exists;

  IF NOT v_table_exists THEN
    RAISE NOTICE '[support_ticket_replies] absente — création complète (table, index, commentaire).';

    EXECUTE $ddl$
      CREATE TABLE public.support_ticket_replies (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        ticket_id uuid NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
        seq bigserial NOT NULL,
        author_type text NOT NULL CHECK (author_type IN ('super_admin', 'hotel_user', 'system')),
        author_user_id uuid REFERENCES auth.users(id),
        author_label text NOT NULL,
        body text NOT NULL CHECK (char_length(body) <= 4000),
        is_internal_note boolean NOT NULL DEFAULT false,
        corrects_reply_id uuid REFERENCES public.support_ticket_replies(id),
        hidden_at timestamptz,
        hidden_by uuid REFERENCES auth.users(id),
        hidden_reason text,
        created_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT support_ticket_replies_pkey PRIMARY KEY (id),
        CONSTRAINT support_ticket_replies_author_user_id_check CHECK ((author_type = 'system') = (author_user_id IS NULL)),
        CONSTRAINT support_ticket_replies_internal_note_author_check CHECK (NOT is_internal_note OR author_type = 'super_admin'),
        CONSTRAINT support_ticket_replies_hidden_by_check CHECK ((hidden_at IS NULL) = (hidden_by IS NULL)),
        CONSTRAINT support_ticket_replies_hidden_reason_check CHECK ((hidden_at IS NULL) = (hidden_reason IS NULL))
      )
    $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_support_ticket_replies_ticket_seq ON public.support_ticket_replies USING btree (ticket_id, seq) $ddl$;

    EXECUTE $ddl$ COMMENT ON TABLE public.support_ticket_replies IS 'Lot 5 PR-06 (ADR-012 §3.5.7) — fil de réponses Support, append-only. Ordre canonique = seq (jamais created_at seul). Aucune policy UPDATE/DELETE : correction par nouvelle ligne (corrects_reply_id), masquage audité (hidden_at/by/reason). Écriture exclusivement via RPC (author_type/author_label/seq fixés côté serveur).' $ddl$;

    RAISE NOTICE '[support_ticket_replies] création terminée.';
  ELSE
    -- Cas B/C : la table existe déjà — vérification stricte du contrat avant
    -- de considérer le domaine conforme. Toute divergence lève une exception
    -- explicite ; aucune correction automatique n'est tentée.

    -- Colonnes (nombre exact — 13 attendues)
    SELECT count(*) INTO v_col_count FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'support_ticket_replies';
    IF v_col_count <> 13 THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : % colonne(s) trouvée(s), 13 attendues. Aucune correction automatique — vérifier manuellement avant de rejouer cette migration.', v_col_count;
    END IF;

    -- Colonnes clés : nullabilité/type des colonnes porteuses d'invariants métier
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'support_ticket_replies'
        AND ((column_name = 'author_type' AND (data_type <> 'text' OR is_nullable <> 'NO'))
          OR (column_name = 'body' AND (data_type <> 'text' OR is_nullable <> 'NO'))
          OR (column_name = 'is_internal_note' AND (data_type <> 'boolean' OR is_nullable <> 'NO' OR column_default IS DISTINCT FROM 'false'))
          OR (column_name = 'hidden_at' AND (data_type <> 'timestamp with time zone' OR is_nullable <> 'YES'))
          OR (column_name = 'id' AND is_nullable <> 'NO'))
    ) THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : type/nullabilité d''une colonne clé (author_type/body/is_internal_note/hidden_at/id) ne correspond pas au contrat attendu. Aucune correction automatique.';
    END IF;

    -- Contraintes attendues (5 nommées explicitement + PK + 3 FK + 2 CHECK auto-nommées)
    FOREACH v_c IN ARRAY ARRAY[
      'support_ticket_replies_pkey',
      'support_ticket_replies_ticket_id_fkey',
      'support_ticket_replies_author_type_check',
      'support_ticket_replies_author_user_id_fkey',
      'support_ticket_replies_corrects_reply_id_fkey',
      'support_ticket_replies_hidden_by_fkey',
      'support_ticket_replies_body_check',
      'support_ticket_replies_author_user_id_check',
      'support_ticket_replies_internal_note_author_check',
      'support_ticket_replies_hidden_by_check',
      'support_ticket_replies_hidden_reason_check'
    ] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_replies'::regclass AND conname = v_c) THEN
        v_missing_constraints := coalesce(v_missing_constraints, '{}') || v_c;
      END IF;
    END LOOP;
    IF v_missing_constraints IS NOT NULL THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : contrainte(s) manquante(s) : %. Aucune correction automatique.', v_missing_constraints;
    END IF;

    -- Prédicats des 4 contraintes CHECK métier nommées explicitement (le nom seul ne
    -- suffit pas à garantir que la règle imposée est bien celle attendue)
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_replies'::regclass AND conname = 'support_ticket_replies_author_user_id_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((author_type = ''system''::text) = (author_user_id IS NULL)))')
    THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : prédicat de support_ticket_replies_author_user_id_check différent de celui attendu. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_replies'::regclass AND conname = 'support_ticket_replies_internal_note_author_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((NOT is_internal_note) OR (author_type = ''super_admin''::text)))')
    THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : prédicat de support_ticket_replies_internal_note_author_check différent de celui attendu. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_replies'::regclass AND conname = 'support_ticket_replies_hidden_by_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((hidden_at IS NULL) = (hidden_by IS NULL)))')
    THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : prédicat de support_ticket_replies_hidden_by_check différent de celui attendu. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_replies'::regclass AND conname = 'support_ticket_replies_hidden_reason_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((hidden_at IS NULL) = (hidden_reason IS NULL)))')
    THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : prédicat de support_ticket_replies_hidden_reason_check différent de celui attendu. Aucune correction automatique.';
    END IF;

    -- Index
    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'support_ticket_replies'
        AND indexname = 'idx_support_ticket_replies_ticket_seq'
        AND indexdef ILIKE '%USING btree (ticket_id, seq)%'
    ) THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : index idx_support_ticket_replies_ticket_seq absent ou de définition différente. Aucune correction automatique.';
    END IF;

    -- Commentaire de table
    SELECT obj_description('public.support_ticket_replies'::regclass, 'pg_class') INTO v_comment;
    IF v_comment IS NULL OR v_comment = '' THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : commentaire de table absent. Aucune correction automatique.';
    END IF;

    -- Propriétaire (doit rester le rôle d'application des migrations — jamais un rôle applicatif)
    SELECT pg_get_userbyid(relowner) INTO v_owner FROM pg_class WHERE oid = 'public.support_ticket_replies'::regclass;
    IF v_owner IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION '[support_ticket_replies] DIVERGENT : propriétaire de la table = % (rôle applicatif), attendu un rôle de migration. Aucune correction automatique.', v_owner;
    END IF;

    RAISE NOTICE '[support_ticket_replies] déjà présente et conforme (colonnes, contraintes, index, commentaire, propriétaire) — aucune action sur le schéma.';
  END IF;
END
$support_ticket_replies_table$;

-- Trigger, RLS, policies et grants restent définis en dehors du bloc trois-états
-- ci-dessus : chacune de ces formes est déjà déterministe-convergente par
-- construction (DROP ... IF EXISTS puis CREATE, ou REVOKE explicite puis GRANT
-- précis), pas une forme masquante comme l'était CREATE TABLE IF NOT EXISTS —
-- rejouer ces instructions ne peut jamais laisser survivre un état divergent
-- silencieux, contrairement au problème corrigé ci-dessus.

-- corrects_reply_id doit référencer une réponse du MÊME ticket — une simple FOREIGN KEY ne
-- peut pas exprimer cette contrainte croisée (elle référence support_ticket_replies.id sans
-- connaître ticket_id de la ligne visée) ; vérifié ici par trigger.
CREATE OR REPLACE FUNCTION public._check_support_ticket_reply_correction_same_ticket()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_target_ticket_id uuid;
BEGIN
  IF NEW.corrects_reply_id IS NOT NULL THEN
    SELECT ticket_id INTO v_target_ticket_id FROM public.support_ticket_replies WHERE id = NEW.corrects_reply_id;
    IF v_target_ticket_id IS NULL THEN
      RAISE EXCEPTION 'corrects_reply_id référence une réponse introuvable' USING errcode = '23503';
    END IF;
    IF v_target_ticket_id <> NEW.ticket_id THEN
      RAISE EXCEPTION 'corrects_reply_id doit référencer une réponse du même ticket' USING errcode = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_support_ticket_reply_correction_same_ticket ON public.support_ticket_replies;
CREATE TRIGGER trg_support_ticket_reply_correction_same_ticket
  BEFORE INSERT OR UPDATE ON public.support_ticket_replies
  FOR EACH ROW EXECUTE FUNCTION public._check_support_ticket_reply_correction_same_ticket();

ALTER TABLE public.support_ticket_replies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS platform_admin_full_replies ON public.support_ticket_replies;
CREATE POLICY platform_admin_full_replies ON public.support_ticket_replies
  FOR ALL USING (public.is_platform_admin()) WITH CHECK (public.is_platform_admin());

-- user_hotels.user_id référence public.users(id), PAS auth.users(id) — auth.uid() renvoie
-- l'auth_id du JWT, donc la jointure doit impérativement passer par public.users.auth_id
-- (erreur trouvée et corrigée pendant les tests : la première version comparait
-- user_hotels.user_id = auth.uid() directement, ce qui ne matchait jamais aucun hôtel réel).
DROP POLICY IF EXISTS hotel_select_own_visible_replies ON public.support_ticket_replies;
CREATE POLICY hotel_select_own_visible_replies ON public.support_ticket_replies
  FOR SELECT USING (
    NOT is_internal_note AND hidden_at IS NULL
    AND ticket_id IN (
      SELECT id FROM public.support_tickets
      WHERE hotel_id IN (
        SELECT uh.hotel_id FROM public.user_hotels uh
        JOIN public.users u ON u.id = uh.user_id
        WHERE u.auth_id = auth.uid()
      )
    )
  );
-- Aucune policy INSERT/UPDATE/DELETE pour authenticated : toute écriture passe par RPC
-- (author_type/author_label/seq fixés côté serveur, jamais par le client).

-- Supabase accorde par défaut arwdDxtm (toutes les commandes DML) à anon/authenticated/
-- service_role sur toute nouvelle table (default privileges du rôle postgres sur public) —
-- REVOKE ALL explicite sur les TROIS avant de regranter précisément, exactement le même
-- correctif que celui déjà appliqué sur les fonctions de cette Phase 2 (sql/83, sql/84).
-- Sans ce REVOKE explicite sur `authenticated`, la table aurait conservé INSERT/UPDATE/DELETE
-- directs pour authenticated malgré le "GRANT SELECT" ci-dessous (un GRANT n'annule jamais un
-- privilège déjà accordé ailleurs) — violant entièrement la doctrine append-only/RPC-only de
-- cette table. Trouvé et corrigé pendant les tests.
REVOKE ALL ON public.support_ticket_replies FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.support_ticket_replies TO authenticated;
GRANT INSERT, UPDATE ON public.support_ticket_replies TO service_role;
-- authenticated n'a que SELECT (filtré par RLS) : les RPC SECURITY DEFINER ci-dessous
-- effectuent les écritures en tant que owner (postgres, qui bypasse les grants par nature),
-- jamais besoin d'un grant INSERT/UPDATE direct à authenticated (qui permettrait de
-- contourner la fixation serveur des champs author_type/author_label/seq).

-- ----------------------------------------------------------------------------
-- Moindre privilège : ce module Support est réservé à super_admin ET support_agent,
-- jamais billing_admin (qui reste un platform_admin valide mais hors périmètre Support).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_support_staff()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_platform_admin() AND public.platform_admin_role() IN ('super_admin', 'support_agent');
$function$;

REVOKE ALL ON FUNCTION public._is_support_staff() FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- admin_list_support_tickets — liste filtrable/triable/paginée.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_support_tickets(
  p_status text DEFAULT NULL,
  p_priority text DEFAULT NULL,
  p_assigned_to text DEFAULT NULL,
  p_hotel_id uuid DEFAULT NULL,
  p_module text DEFAULT NULL,
  p_risk_score text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  id uuid, hotel_id uuid, hotel_name text, ticket_number text, module text, feature text,
  problem_type text, description text, priority text, status text, assigned_to text,
  risk_score text, classification text, user_email text, created_at timestamptz,
  updated_at timestamptz, reply_count bigint, total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    st.id, st.hotel_id, h.name, st.ticket_number, st.module, st.feature, st.problem_type,
    st.description, st.priority, st.status, st.assigned_to, st.risk_score, st.classification,
    st.user_email, st.created_at, st.updated_at,
    (SELECT count(*) FROM public.support_ticket_replies r WHERE r.ticket_id = st.id) AS reply_count,
    count(*) OVER() AS total_count
  FROM public.support_tickets st
  JOIN public.hotels h ON h.id = st.hotel_id
  WHERE (p_status IS NULL OR st.status = p_status)
    AND (p_priority IS NULL OR st.priority = p_priority)
    AND (p_assigned_to IS NULL OR st.assigned_to = p_assigned_to)
    AND (p_hotel_id IS NULL OR st.hotel_id = p_hotel_id)
    AND (p_module IS NULL OR st.module = p_module)
    AND (p_risk_score IS NULL OR st.risk_score = p_risk_score)
    AND (p_search IS NULL OR p_search = '' OR
         st.description ILIKE '%' || p_search || '%' OR
         st.ticket_number ILIKE '%' || p_search || '%' OR
         h.name ILIKE '%' || p_search || '%')
  ORDER BY
    CASE st.priority WHEN 'bloquant' THEN 0 WHEN 'eleve' THEN 1 WHEN 'moyen' THEN 2 ELSE 3 END,
    st.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0) OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_support_tickets(text, text, text, uuid, text, text, text, integer, integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_support_tickets(text, text, text, uuid, text, text, text, integer, integer) TO authenticated;

-- ----------------------------------------------------------------------------
-- admin_get_support_ticket_detail — ticket complet + fil de réponses (toutes,
-- y compris notes internes et réponses masquées : vue admin intégrale).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_support_ticket_detail(p_ticket_id uuid)
RETURNS TABLE(
  id uuid, hotel_id uuid, hotel_name text, ticket_number text, module text, feature text,
  problem_type text, description text, steps jsonb, expected_result text, actual_result text,
  priority text, status text, assigned_to text, risk_score text, classification text,
  claude_response text, diagnostic_details jsonb, user_email text, user_role text,
  created_at timestamptz, updated_at timestamptz, replies jsonb
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    st.id, st.hotel_id, h.name, st.ticket_number, st.module, st.feature, st.problem_type,
    st.description, st.steps, st.expected_result, st.actual_result, st.priority, st.status,
    st.assigned_to, st.risk_score, st.classification, st.claude_response, st.diagnostic_details,
    st.user_email, st.user_role, st.created_at, st.updated_at,
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', r.id, 'seq', r.seq, 'author_type', r.author_type, 'author_label', r.author_label,
        'body', r.body, 'is_internal_note', r.is_internal_note, 'corrects_reply_id', r.corrects_reply_id,
        'hidden_at', r.hidden_at, 'hidden_by', r.hidden_by, 'hidden_reason', r.hidden_reason,
        'created_at', r.created_at
      ) ORDER BY r.seq)
      FROM public.support_ticket_replies r WHERE r.ticket_id = st.id
    ), '[]'::jsonb) AS replies
  FROM public.support_tickets st
  JOIN public.hotels h ON h.id = st.hotel_id
  WHERE st.id = p_ticket_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_get_support_ticket_detail(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_support_ticket_detail(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- admin_update_support_ticket — statut/priorité/assignation, notifie sur
-- changement de statut réel (jamais sur un no-op).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_update_support_ticket(
  p_ticket_id uuid,
  p_status text DEFAULT NULL,
  p_priority text DEFAULT NULL,
  p_assigned_to text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_old_status text;
  v_new_status text;
  v_ticket_number text;
  v_recipient_email text;
  v_updated_at timestamptz;
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;

  SELECT status INTO v_old_status FROM public.support_tickets WHERE id = p_ticket_id;
  IF v_old_status IS NULL THEN
    RAISE EXCEPTION 'TICKET_INTROUVABLE' USING errcode = 'P0002';
  END IF;

  UPDATE public.support_tickets SET
    status = coalesce(p_status, status),
    priority = coalesce(p_priority, priority),
    assigned_to = CASE WHEN p_assigned_to IS NOT NULL THEN nullif(trim(p_assigned_to), '') ELSE assigned_to END,
    updated_at = now()
  WHERE id = p_ticket_id
  RETURNING status, ticket_number, updated_at, coalesce(nullif(trim(user_email), ''), (
    SELECT coalesce(nullif(trim(h.billing_email), ''), nullif(trim(h.email), ''))
    FROM public.hotels h WHERE h.id = support_tickets.hotel_id
  )) INTO v_new_status, v_ticket_number, v_updated_at, v_recipient_email;

  PERFORM public._platform_log(
    'support_ticket.update', 'support_ticket', p_ticket_id::text, NULL, NULL,
    jsonb_build_object('old_status', v_old_status, 'new_status', v_new_status, 'priority', p_priority, 'assigned_to', p_assigned_to)
  );

  IF p_status IS NOT NULL AND p_status <> v_old_status AND v_recipient_email IS NOT NULL THEN
    INSERT INTO public.platform_notifications (category, reference_type, reference_id, dedupe_key, recipient_email, template, template_payload)
    VALUES (
      'support_ticket_update', 'support_ticket', p_ticket_id,
      'support:' || p_ticket_id::text || ':status:' || v_new_status || ':' || extract(epoch FROM v_updated_at)::text,
      v_recipient_email, 'ticket_status_changed',
      jsonb_build_object('ticket_number', coalesce(v_ticket_number, p_ticket_id::text), 'new_status', v_new_status)
    )
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_update_support_ticket(uuid, text, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_support_ticket(uuid, text, text, text) TO authenticated;

-- ----------------------------------------------------------------------------
-- admin_reply_support_ticket — insère dans support_ticket_replies, notifie si
-- réponse publique (jamais pour une note interne).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_reply_support_ticket(
  p_ticket_id uuid,
  p_body text,
  p_is_internal_note boolean DEFAULT false,
  p_corrects_reply_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_reply_id uuid;
  v_admin_email text;
  v_ticket_number text;
  v_recipient_email text;
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.support_tickets WHERE id = p_ticket_id) THEN
    RAISE EXCEPTION 'TICKET_INTROUVABLE' USING errcode = 'P0002';
  END IF;

  SELECT email INTO v_admin_email FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  INSERT INTO public.support_ticket_replies
    (ticket_id, author_type, author_user_id, author_label, body, is_internal_note, corrects_reply_id)
  VALUES
    (p_ticket_id, 'super_admin', auth.uid(), coalesce(v_admin_email, 'Super Admin'), p_body, coalesce(p_is_internal_note, false), p_corrects_reply_id)
  RETURNING id INTO v_reply_id;

  PERFORM public._platform_log(
    'support_ticket_reply.create', 'support_ticket_reply', v_reply_id::text, NULL, NULL,
    jsonb_build_object('ticket_id', p_ticket_id, 'is_internal_note', p_is_internal_note)
  );

  IF NOT coalesce(p_is_internal_note, false) THEN
    SELECT st.ticket_number, coalesce(nullif(trim(st.user_email), ''), coalesce(nullif(trim(h.billing_email), ''), nullif(trim(h.email), '')))
      INTO v_ticket_number, v_recipient_email
    FROM public.support_tickets st JOIN public.hotels h ON h.id = st.hotel_id
    WHERE st.id = p_ticket_id;

    IF v_recipient_email IS NOT NULL THEN
      INSERT INTO public.platform_notifications (category, reference_type, reference_id, dedupe_key, recipient_email, template, template_payload)
      VALUES (
        'support_ticket_update', 'support_ticket_reply', v_reply_id,
        'support:' || p_ticket_id::text || ':reply:' || v_reply_id::text,
        v_recipient_email, 'ticket_new_reply',
        jsonb_build_object('ticket_number', coalesce(v_ticket_number, p_ticket_id::text))
      )
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
  END IF;

  RETURN v_reply_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_reply_support_ticket(uuid, text, boolean, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_reply_support_ticket(uuid, text, boolean, uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- Masquage administratif audité — jamais une notification (silencieux côté hôtel).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hide_support_ticket_reply(p_reply_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'MOTIF_REQUIS : le masquage d''une réponse nécessite un motif' USING errcode = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.support_ticket_replies WHERE id = p_reply_id) THEN
    RAISE EXCEPTION 'REPONSE_INTROUVABLE' USING errcode = 'P0002';
  END IF;

  UPDATE public.support_ticket_replies
  SET hidden_at = now(), hidden_by = auth.uid(), hidden_reason = trim(p_reason)
  WHERE id = p_reply_id AND hidden_at IS NULL;

  PERFORM public._platform_log('support_ticket_reply.hide', 'support_ticket_reply', p_reply_id::text, NULL, NULL, jsonb_build_object('reason', p_reason));
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_unhide_support_ticket_reply(p_reply_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.support_ticket_replies WHERE id = p_reply_id) THEN
    RAISE EXCEPTION 'REPONSE_INTROUVABLE' USING errcode = 'P0002';
  END IF;

  UPDATE public.support_ticket_replies
  SET hidden_at = NULL, hidden_by = NULL, hidden_reason = NULL
  WHERE id = p_reply_id AND hidden_at IS NOT NULL;

  PERFORM public._platform_log('support_ticket_reply.unhide', 'support_ticket_reply', p_reply_id::text, NULL, NULL, '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_hide_support_ticket_reply(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_hide_support_ticket_reply(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_unhide_support_ticket_reply(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_unhide_support_ticket_reply(uuid) TO authenticated;
