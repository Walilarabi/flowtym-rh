-- ============================================================================
-- sql/86_support_ticket_attachments.sql
-- Lot 5 — PR-07 : Portail hôtel Support + pièces jointes (ADR-012 §3.5.5/§3.5.8)
--
-- Dépend de sql/80/81 (support_tickets, corrigé), sql/85 (support_ticket_replies).
--
-- Ajoute :
--   1) public._can_access_support_ticket(ticket_id) — autorisation centralisée
--      (admin, ou hotel_user de l'hôtel du ticket), appelée par les Edge
--      Functions ET par la RPC de réponse hôtel — jamais dupliquée.
--   2) public.hotel_reply_support_ticket(...) — réponse hôtel, author_type
--      fixé côté serveur (jamais confiance dans le client).
--   3) public.support_ticket_attachments + support_ticket_attachment_access_log.
--   4) Bucket Storage privé 'support-ticket-attachments' — AUCUNE policy
--      storage.objects pour anon/authenticated : tout accès passe par les 3
--      Edge Functions dédiées (service_role uniquement), jamais un accès
--      direct client au bucket.
--   5) public.list_support_ticket_attachments(ticket_id) — métadonnées
--      uniquement (jamais le contenu du fichier), pour admin et hotel_user
--      autorisés via _can_access_support_ticket.
--
-- Statuts antivirus honnêtes (ADR-012 §3.5.8, correction round 5) : aucun
-- fournisseur choisi dans ce lot. 'clean' n'est JAMAIS atteint automatiquement
-- — transition réservée à un futur scanner réel. Conséquence assumée et
-- documentée : aucune pièce jointe n'est téléchargeable en pratique tant
-- qu'aucun scanner n'est câblé (la lecture exige status='clean').
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) _can_access_support_ticket — logique d'autorisation unique, réutilisée
--    par hotel_reply_support_ticket ET par les 3 Edge Functions (via un appel
--    RPC service_role, cf. documentation des Edge Functions).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._can_access_support_ticket(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_platform_admin() OR EXISTS (
    SELECT 1 FROM public.support_tickets st
    JOIN public.user_hotels uh ON uh.hotel_id = st.hotel_id
    JOIN public.users u ON u.id = uh.user_id
    WHERE st.id = p_ticket_id AND u.auth_id = auth.uid()
  );
$function$;

REVOKE ALL ON FUNCTION public._can_access_support_ticket(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public._can_access_support_ticket(uuid) TO authenticated;
-- authenticated a EXECUTE ici (contrairement aux autres helpers internes de cette Phase 2) :
-- cette fonction sert de garde d'autorisation appelée directement par le client avant un
-- upload (cf. frontend), elle ne fait QUE répondre vrai/faux sur une autorisation déjà
-- déterminée par RLS/rôle — aucune fuite de données, contrairement à _platform_log ou
-- _is_support_staff qui exécutent des actions ou renvoient des informations privilégiées.

-- ----------------------------------------------------------------------------
-- 2) hotel_reply_support_ticket — réponse côté hôtel, jamais de note interne
--    (is_internal_note toujours false : un hotel_user ne peut jamais créer de
--    note interne, contrainte déjà imposée par le CHECK de la table).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hotel_reply_support_ticket(
  p_ticket_id uuid,
  p_body text,
  p_corrects_reply_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_reply_id uuid;
  v_user_label text;
  v_ticket_number text;
BEGIN
  IF NOT public._can_access_support_ticket(p_ticket_id) THEN
    RAISE EXCEPTION 'Accès refusé : ce ticket n''appartient pas à votre hôtel' USING errcode = '42501';
  END IF;
  IF public.is_platform_admin() THEN
    RAISE EXCEPTION 'Un Super Admin doit utiliser admin_reply_support_ticket, pas hotel_reply_support_ticket' USING errcode = '42501';
  END IF;
  IF p_body IS NULL OR trim(p_body) = '' THEN
    RAISE EXCEPTION 'REPONSE_VIDE' USING errcode = '22023';
  END IF;

  SELECT coalesce(nullif(trim(u.full_name), ''), u.email) INTO v_user_label
  FROM public.users u WHERE u.auth_id = auth.uid();

  INSERT INTO public.support_ticket_replies
    (ticket_id, author_type, author_user_id, author_label, body, is_internal_note, corrects_reply_id)
  VALUES
    (p_ticket_id, 'hotel_user', auth.uid(), coalesce(v_user_label, 'Utilisateur hôtel'), p_body, false, p_corrects_reply_id)
  RETURNING id INTO v_reply_id;

  PERFORM public._platform_log(
    'support_ticket_reply.create_hotel', 'support_ticket_reply', v_reply_id::text, NULL, NULL,
    jsonb_build_object('ticket_id', p_ticket_id)
  );

  -- Notifie le staff Support (pas de destinataire unique évident côté plateforme dans ce
  -- round — les futurs agents assignés recevront cette notification une fois Lot 5A doté
  -- d'une adresse d'équipe Support ; point ouvert, documenté, non bloquant pour ce lot qui
  -- porte sur le portail hôtel, pas sur le routage des notifications internes).
  RETURN v_reply_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.hotel_reply_support_ticket(uuid, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.hotel_reply_support_ticket(uuid, text, uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- 3) support_ticket_attachments — métadonnées uniquement, jamais le contenu.
--
-- Doctrine trois états (remplace CREATE TABLE IF NOT EXISTS, qui masquerait
-- silencieusement toute divergence de schéma sur un replay) : absent →
-- création complète ; présent et conforme (colonnes, contraintes avec
-- prédicat exact, index, commentaire, propriétaire) → no-op ; présent et
-- divergent → RAISE EXCEPTION, aucune correction automatique.
-- ----------------------------------------------------------------------------
DO $support_ticket_attachments_table$
DECLARE
  v_table_exists boolean;
  v_col_count int;
  v_owner text;
  v_comment text;
  v_missing_constraints text[];
  v_c text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = 'support_ticket_attachments' AND relkind = 'r'
  ) INTO v_table_exists;

  IF NOT v_table_exists THEN
    RAISE NOTICE '[support_ticket_attachments] absente — création complète (table, index, commentaire).';

    EXECUTE $ddl$
      CREATE TABLE public.support_ticket_attachments (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        ticket_id uuid NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
        reply_id uuid REFERENCES public.support_ticket_replies(id) ON DELETE CASCADE,
        storage_bucket text NOT NULL DEFAULT 'support-ticket-attachments',
        storage_path text NOT NULL,
        original_filename text NOT NULL,
        mime_type text NOT NULL CHECK (mime_type IN (
          'application/pdf','image/jpeg','image/png','image/heic','image/webp','image/gif',
          'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        )),
        size_bytes bigint NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760),
        status text NOT NULL DEFAULT 'pending_upload' CHECK (status IN ('pending_upload','uploaded','scan_pending','clean','quarantined','rejected')),
        uploaded_by uuid NOT NULL REFERENCES auth.users(id),
        created_at timestamptz NOT NULL DEFAULT now(),
        confirmed_at timestamptz,
        deleted_at timestamptz,
        deleted_by uuid REFERENCES auth.users(id),
        deletion_reason text,
        CONSTRAINT support_ticket_attachments_pkey PRIMARY KEY (id),
        CONSTRAINT support_ticket_attachments_storage_path_key UNIQUE (storage_path),
        CONSTRAINT support_ticket_attachments_deleted_by_check CHECK ((deleted_at IS NULL) = (deleted_by IS NULL)),
        CONSTRAINT support_ticket_attachments_deletion_reason_check CHECK ((deleted_at IS NULL) = (deletion_reason IS NULL))
      )
    $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_support_ticket_attachments_ticket ON public.support_ticket_attachments USING btree (ticket_id) $ddl$;

    EXECUTE $ddl$ COMMENT ON TABLE public.support_ticket_attachments IS 'Lot 5 PR-07 (ADR-012 §3.5.8) — métadonnées de pièces jointes Support. storage_path généré exclusivement côté serveur (jamais dérivé du nom de fichier client). status=clean atteignable uniquement par un scan antivirus réel (aucun câblé dans ce round) — tant qu''aucun scanner n''existe, aucune pièce jointe n''est donc téléchargeable, limitation assumée et documentée (voir ADR-012 §7). Suppression logique via deleted_at/deleted_by/deletion_reason (admin_delete_support_ticket_attachment), jamais de DELETE physique.' $ddl$;

    RAISE NOTICE '[support_ticket_attachments] création terminée.';
  ELSE
    SELECT count(*) INTO v_col_count FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'support_ticket_attachments';
    IF v_col_count <> 15 THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : % colonne(s) trouvée(s), 15 attendues. Aucune correction automatique.', v_col_count;
    END IF;

    FOREACH v_c IN ARRAY ARRAY[
      'support_ticket_attachments_pkey',
      'support_ticket_attachments_storage_path_key',
      'support_ticket_attachments_ticket_id_fkey',
      'support_ticket_attachments_reply_id_fkey',
      'support_ticket_attachments_uploaded_by_fkey',
      'support_ticket_attachments_deleted_by_fkey',
      'support_ticket_attachments_mime_type_check',
      'support_ticket_attachments_size_bytes_check',
      'support_ticket_attachments_status_check',
      'support_ticket_attachments_deleted_by_check',
      'support_ticket_attachments_deletion_reason_check'
    ] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = v_c) THEN
        v_missing_constraints := coalesce(v_missing_constraints, '{}') || v_c;
      END IF;
    END LOOP;
    IF v_missing_constraints IS NOT NULL THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : contrainte(s) manquante(s) : %. Aucune correction automatique.', v_missing_constraints;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = 'support_ticket_attachments_mime_type_check'
        AND pg_get_constraintdef(oid) = 'CHECK ((mime_type = ANY (ARRAY[''application/pdf''::text, ''image/jpeg''::text, ''image/png''::text, ''image/heic''::text, ''image/webp''::text, ''image/gif''::text, ''application/msword''::text, ''application/vnd.openxmlformats-officedocument.wordprocessingml.document''::text])))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : prédicat mime_type_check différent. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = 'support_ticket_attachments_size_bytes_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((size_bytes > 0) AND (size_bytes <= 10485760)))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : prédicat size_bytes_check différent. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = 'support_ticket_attachments_status_check'
        AND pg_get_constraintdef(oid) = 'CHECK ((status = ANY (ARRAY[''pending_upload''::text, ''uploaded''::text, ''scan_pending''::text, ''clean''::text, ''quarantined''::text, ''rejected''::text])))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : prédicat status_check différent. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = 'support_ticket_attachments_deleted_by_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((deleted_at IS NULL) = (deleted_by IS NULL)))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : prédicat deleted_by_check différent. Aucune correction automatique.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachments'::regclass AND conname = 'support_ticket_attachments_deletion_reason_check'
        AND pg_get_constraintdef(oid) = 'CHECK (((deleted_at IS NULL) = (deletion_reason IS NULL)))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : prédicat deletion_reason_check différent. Aucune correction automatique.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'support_ticket_attachments'
        AND indexname = 'idx_support_ticket_attachments_ticket' AND indexdef ILIKE '%USING btree (ticket_id)%'
    ) THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : index idx_support_ticket_attachments_ticket absent ou différent. Aucune correction automatique.';
    END IF;

    SELECT obj_description('public.support_ticket_attachments'::regclass, 'pg_class') INTO v_comment;
    IF v_comment IS NULL OR v_comment = '' THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : commentaire de table absent. Aucune correction automatique.';
    END IF;

    SELECT pg_get_userbyid(relowner) INTO v_owner FROM pg_class WHERE oid = 'public.support_ticket_attachments'::regclass;
    IF v_owner IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION '[support_ticket_attachments] DIVERGENT : propriétaire = % (rôle applicatif). Aucune correction automatique.', v_owner;
    END IF;

    RAISE NOTICE '[support_ticket_attachments] déjà présente et conforme — aucune action sur le schéma.';
  END IF;
END
$support_ticket_attachments_table$;

ALTER TABLE public.support_ticket_attachments ENABLE ROW LEVEL SECURITY;
-- Aucune policy pour anon/authenticated : toute lecture/écriture passe par les Edge Functions
-- (service_role) ou par la RPC list_support_ticket_attachments ci-dessous (SECURITY DEFINER).
DROP POLICY IF EXISTS platform_admin_full_attachments ON public.support_ticket_attachments;
CREATE POLICY platform_admin_full_attachments ON public.support_ticket_attachments
  FOR ALL USING (public.is_platform_admin()) WITH CHECK (public.is_platform_admin());

REVOKE ALL ON public.support_ticket_attachments FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.support_ticket_attachments TO service_role;

-- ----------------------------------------------------------------------------
-- 4) Journal des accès et suppressions — écrit exclusivement par les Edge
--    Functions (service_role), aucun accès authenticated direct.
--    Même doctrine trois états que support_ticket_attachments ci-dessus.
-- ----------------------------------------------------------------------------
DO $support_ticket_attachment_access_log_table$
DECLARE
  v_table_exists boolean;
  v_col_count int;
  v_owner text;
  v_missing_constraints text[];
  v_c text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = 'support_ticket_attachment_access_log' AND relkind = 'r'
  ) INTO v_table_exists;

  IF NOT v_table_exists THEN
    RAISE NOTICE '[support_ticket_attachment_access_log] absente — création complète (table, index).';

    EXECUTE $ddl$
      CREATE TABLE public.support_ticket_attachment_access_log (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        attachment_id uuid NOT NULL REFERENCES public.support_ticket_attachments(id) ON DELETE CASCADE,
        ticket_id uuid NOT NULL,
        user_id uuid NOT NULL REFERENCES auth.users(id),
        action text NOT NULL CHECK (action IN ('download_url_issued','soft_deleted')),
        ip_address inet,
        user_agent text,
        occurred_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT support_ticket_attachment_access_log_pkey PRIMARY KEY (id)
      )
    $ddl$;

    EXECUTE $ddl$ CREATE INDEX idx_support_ticket_attachment_access_log_attachment ON public.support_ticket_attachment_access_log USING btree (attachment_id) $ddl$;

    RAISE NOTICE '[support_ticket_attachment_access_log] création terminée.';
  ELSE
    SELECT count(*) INTO v_col_count FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'support_ticket_attachment_access_log';
    IF v_col_count <> 8 THEN
      RAISE EXCEPTION '[support_ticket_attachment_access_log] DIVERGENT : % colonne(s) trouvée(s), 8 attendues. Aucune correction automatique.', v_col_count;
    END IF;

    FOREACH v_c IN ARRAY ARRAY[
      'support_ticket_attachment_access_log_pkey',
      'support_ticket_attachment_access_log_attachment_id_fkey',
      'support_ticket_attachment_access_log_user_id_fkey',
      'support_ticket_attachment_access_log_action_check'
    ] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachment_access_log'::regclass AND conname = v_c) THEN
        v_missing_constraints := coalesce(v_missing_constraints, '{}') || v_c;
      END IF;
    END LOOP;
    IF v_missing_constraints IS NOT NULL THEN
      RAISE EXCEPTION '[support_ticket_attachment_access_log] DIVERGENT : contrainte(s) manquante(s) : %. Aucune correction automatique.', v_missing_constraints;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.support_ticket_attachment_access_log'::regclass AND conname = 'support_ticket_attachment_access_log_action_check'
        AND pg_get_constraintdef(oid) = 'CHECK ((action = ANY (ARRAY[''download_url_issued''::text, ''soft_deleted''::text])))')
    THEN
      RAISE EXCEPTION '[support_ticket_attachment_access_log] DIVERGENT : prédicat action_check différent. Aucune correction automatique.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'support_ticket_attachment_access_log'
        AND indexname = 'idx_support_ticket_attachment_access_log_attachment' AND indexdef ILIKE '%USING btree (attachment_id)%'
    ) THEN
      RAISE EXCEPTION '[support_ticket_attachment_access_log] DIVERGENT : index absent ou différent. Aucune correction automatique.';
    END IF;

    SELECT pg_get_userbyid(relowner) INTO v_owner FROM pg_class WHERE oid = 'public.support_ticket_attachment_access_log'::regclass;
    IF v_owner IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION '[support_ticket_attachment_access_log] DIVERGENT : propriétaire = % (rôle applicatif). Aucune correction automatique.', v_owner;
    END IF;

    RAISE NOTICE '[support_ticket_attachment_access_log] déjà présente et conforme — aucune action sur le schéma.';
  END IF;
END
$support_ticket_attachment_access_log_table$;

ALTER TABLE public.support_ticket_attachment_access_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_admin_read_attachment_access_log ON public.support_ticket_attachment_access_log;
CREATE POLICY platform_admin_read_attachment_access_log ON public.support_ticket_attachment_access_log
  FOR SELECT USING (public.is_platform_admin());

REVOKE ALL ON public.support_ticket_attachment_access_log FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.support_ticket_attachment_access_log TO service_role;

-- ----------------------------------------------------------------------------
-- 5) Bucket Storage privé — aucune policy storage.objects pour anon/authenticated.
-- ----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'support-ticket-attachments', 'support-ticket-attachments', false, 10485760,
  ARRAY[
    'application/pdf','image/jpeg','image/png','image/heic','image/webp','image/gif',
    'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
-- public = false est explicitement forcé dans le DO UPDATE (pas seulement à la création) :
-- un état antérieur incohérent (bucket déjà présent avec public=true, par ex. suite d'un essai
-- manuel) ne doit jamais pouvoir survivre à cette migration — la confidentialité de ce bucket
-- ne dépend d'aucun état préexistant.
-- Volontairement AUCUNE policy storage.objects créée pour ce bucket (ni anon, ni
-- authenticated) : seul service_role (les 3 Edge Functions) y accède. Choix délibérément
-- plus strict que le filtrage par préfixe utilisé par portal-documents (ADR-012 §3.5.8) —
-- un seul point de contrôle (Edge Functions) plutôt que deux surfaces (RLS Storage + RLS
-- table) à maintenir en cohérence.

-- ----------------------------------------------------------------------------
-- 6) list_support_ticket_attachments — métadonnées uniquement (jamais le
--    contenu ni une URL). Le téléchargement réel passe exclusivement par
--    l'Edge Function support-ticket-attachment-download-url.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_support_ticket_attachments(p_ticket_id uuid)
RETURNS TABLE(
  id uuid, original_filename text, mime_type text, size_bytes bigint, status text,
  uploaded_by uuid, created_at timestamptz, confirmed_at timestamptz, deleted_at timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public._can_access_support_ticket(p_ticket_id) THEN
    RAISE EXCEPTION 'Accès refusé' USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT a.id, a.original_filename, a.mime_type, a.size_bytes, a.status, a.uploaded_by,
    a.created_at, a.confirmed_at, a.deleted_at
  FROM public.support_ticket_attachments a
  WHERE a.ticket_id = p_ticket_id AND a.deleted_at IS NULL
  ORDER BY a.created_at;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_support_ticket_attachments(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_support_ticket_attachments(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- 7) admin_delete_support_ticket_attachment — suppression logique (jamais physique),
--    réservée au staff Support (_is_support_staff, sql/85). Motif obligatoire, journalisé
--    dans support_ticket_attachment_access_log (action='soft_deleted'). Le fichier reste en
--    Storage (aucun appel storage.remove ici) : seule sa visibilité applicative disparaît
--    (list_support_ticket_attachments filtre déjà deleted_at IS NULL) — cohérent avec le
--    fait qu'aucune commande DELETE physique n'existe nulle part sur ce domaine (ADR-012,
--    doctrine déjà appliquée à support_ticket_replies : correction/masquage, jamais de perte).
--
-- Périmètre assumé de ce lot : seul le staff Support peut supprimer logiquement une pièce
-- jointe, à tout moment. Un auto-retrait par l'uploader hôtel dans une fenêtre de 15 minutes
-- (envisagé par ADR-012 §3.5.8 v1) n'est PAS livré ici — l'upload hôtel lui-même est mis en
-- pause côté frontend (cf. support-portal.html, stratégie A : aucun scanner antivirus câblé,
-- un fichier téléversé ne devient jamais consultable) ; une fenêtre d'auto-retrait n'aurait
-- aucune utilité tant que l'upload reste désactivé. À construire quand l'upload sera réactivé.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_support_ticket_attachment(p_attachment_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ticket_id uuid;
  v_already_deleted timestamptz;
BEGIN
  IF NOT public._is_support_staff() THEN
    RAISE EXCEPTION 'Accès refusé : réservé aux agents Support et Super Admin' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RAISE EXCEPTION 'MOTIF_REQUIS : la suppression d''une pièce jointe nécessite un motif' USING errcode = '22023';
  END IF;

  SELECT ticket_id, deleted_at INTO v_ticket_id, v_already_deleted
  FROM public.support_ticket_attachments WHERE id = p_attachment_id;
  IF v_ticket_id IS NULL THEN
    RAISE EXCEPTION 'PIECE_JOINTE_INTROUVABLE' USING errcode = 'P0002';
  END IF;
  IF v_already_deleted IS NOT NULL THEN
    RAISE EXCEPTION 'DEJA_SUPPRIMEE : cette pièce jointe est déjà masquée' USING errcode = '22023';
  END IF;

  UPDATE public.support_ticket_attachments
  SET deleted_at = now(), deleted_by = auth.uid(), deletion_reason = trim(p_reason)
  WHERE id = p_attachment_id AND deleted_at IS NULL;

  INSERT INTO public.support_ticket_attachment_access_log (attachment_id, ticket_id, user_id, action)
  VALUES (p_attachment_id, v_ticket_id, auth.uid(), 'soft_deleted');

  PERFORM public._platform_log(
    'support_ticket_attachment.delete', 'support_ticket_attachment', p_attachment_id::text, NULL, NULL,
    jsonb_build_object('ticket_id', v_ticket_id, 'reason', p_reason)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_delete_support_ticket_attachment(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_support_ticket_attachment(uuid, text) TO authenticated;
