-- 69_super_admin_phase1_security_hardening.sql
-- Hotfix Phase 1 — suite à l'audit d'architecture. Portée strictement limitée aux points
-- validés par le CTO : _platform_log() exploitable, admin_set_user_status() non historisée,
-- durcissement (sans suppression) du trigger grant_superadmin_on_new_hotel, atomicité de
-- l'édition hôtel+groupe, indexation justifiée de platform_logs.
--
-- Aucun DROP de table, aucune suppression de données, additif et idempotent partout où
-- c'est possible (CREATE OR REPLACE FUNCTION, CREATE INDEX IF NOT EXISTS, REVOKE/GRANT
-- rejouables sans erreur).

-- ============================================================================
-- P0 — _platform_log() : fermer l'exécution publique + garde interne
-- ============================================================================
-- Cause racine : fonction SECURITY DEFINER (donc contourne RLS sur platform_logs par
-- conception) créée sans REVOKE explicite. PostgreSQL accorde EXECUTE à PUBLIC par défaut
-- à la création d'une fonction — non compensé ici par une vérification interne, contrairement
-- à toutes les autres RPC admin_* du portail. Résultat : n'importe quel appelant, authentifié
-- ou anonyme, pouvait insérer des entrées arbitraires dans un journal censé être immuable.

CREATE OR REPLACE FUNCTION public._platform_log(
  p_action    text,
  p_entity    text,
  p_entity_id text,
  p_hotel_id  uuid DEFAULT NULL,
  p_hotel_name text DEFAULT NULL,
  p_payload   jsonb DEFAULT '{}'::jsonb,
  p_level     text DEFAULT 'info'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_admin_id    uuid;
  v_admin_email text;
  v_headers     jsonb;
  v_ip          text;
  v_ua          text;
BEGIN
  -- Défense interne : cette fonction ne doit jamais être exécutable en dehors d'un contexte
  -- Super Admin authentifié. Le REVOKE ci-dessous ferme le chemin d'appel direct (défense
  -- primaire) ; cette garde est la défense secondaire si un futur GRANT rouvrait l'accès
  -- par erreur (ex. un `GRANT ALL ON ALL FUNCTIONS` générique lors d'une migration future).
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  -- Identité, IP et user-agent résolus côté serveur — jamais acceptés en paramètre du client.
  SELECT id, email INTO v_admin_id, v_admin_email
  FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  BEGIN
    v_headers := current_setting('request.headers', true)::jsonb;
    v_ip := coalesce(split_part(v_headers->>'x-forwarded-for', ',', 1), v_headers->>'x-real-ip');
    v_ua := v_headers->>'user-agent';
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL; v_ua := NULL;
  END;

  INSERT INTO public.platform_logs
    (admin_id, admin_email, action, entity, entity_id, hotel_id, hotel_name, payload, ip_address, user_agent, level)
  VALUES
    (v_admin_id, v_admin_email, p_action, p_entity, p_entity_id, p_hotel_id, p_hotel_name, coalesce(p_payload,'{}'::jsonb), v_ip, v_ua, p_level);
END;
$function$;

-- Défense primaire : fermer tout chemin d'appel direct. Rejouable sans erreur (REVOKE sur un
-- privilège déjà absent est un no-op en PostgreSQL).
REVOKE ALL ON FUNCTION public._platform_log(text,text,text,uuid,text,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._platform_log(text,text,text,uuid,text,jsonb,text) FROM anon;
REVOKE ALL ON FUNCTION public._platform_log(text,text,text,uuid,text,jsonb,text) FROM authenticated;
REVOKE ALL ON FUNCTION public._platform_log(text,text,text,uuid,text,jsonb,text) FROM service_role;
-- Aucun rôle applicatif n'a besoin d'un accès direct : la fonction n'est appelée qu'en
-- interne (PERFORM) par d'autres fonctions SECURITY DEFINER dont le propriétaire (postgres)
-- contourne intrinsèquement les vérifications de privilège pour ses propres appels internes.

-- ============================================================================
-- P0 — nouvelle variante pour les événements d'origine système (triggers)
-- ============================================================================
-- grant_superadmin_on_new_hotel (voir plus bas) doit journaliser même quand l'utilisateur à
-- l'origine de la création d'hôtel n'est PAS un platform_admin (cas normal du self-service
-- org_create_hotel, utilisé par un directeur d'hôtel gérant son propre groupe). Router ce cas
-- vers _platform_log() casserait ce flux existant, puisque sa garde exige is_platform_admin().
-- _platform_log_system() résout l'acteur depuis public.users (valable pour tout utilisateur
-- authentifié, admin ou non) et n'a, comme _platform_log(), aucun GRANT EXECUTE public — la
-- même défense primaire s'applique, aucun rôle client ne peut l'appeler directement.

CREATE OR REPLACE FUNCTION public._platform_log_system(
  p_action    text,
  p_entity    text,
  p_entity_id text,
  p_hotel_id  uuid DEFAULT NULL,
  p_hotel_name text DEFAULT NULL,
  p_payload   jsonb DEFAULT '{}'::jsonb,
  p_level     text DEFAULT 'info'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor_id    uuid;
  v_actor_email text;
  v_headers     jsonb;
  v_ip          text;
  v_ua          text;
BEGIN
  SELECT id, email INTO v_actor_id, v_actor_email
  FROM public.users WHERE auth_id = auth.uid() LIMIT 1;

  BEGIN
    v_headers := current_setting('request.headers', true)::jsonb;
    v_ip := coalesce(split_part(v_headers->>'x-forwarded-for', ',', 1), v_headers->>'x-real-ip');
    v_ua := v_headers->>'user-agent';
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL; v_ua := NULL;
  END;

  INSERT INTO public.platform_logs
    (admin_id, admin_email, action, entity, entity_id, hotel_id, hotel_name, payload, ip_address, user_agent, level)
  VALUES
    (NULL, v_actor_email, p_action, p_entity, p_entity_id, p_hotel_id, p_hotel_name, coalesce(p_payload,'{}'::jsonb), v_ip, v_ua, p_level);
END;
$function$;

REVOKE ALL ON FUNCTION public._platform_log_system(text,text,text,uuid,text,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._platform_log_system(text,text,text,uuid,text,jsonb,text) FROM anon;
REVOKE ALL ON FUNCTION public._platform_log_system(text,text,text,uuid,text,jsonb,text) FROM authenticated;
REVOKE ALL ON FUNCTION public._platform_log_system(text,text,text,uuid,text,jsonb,text) FROM service_role;

-- ============================================================================
-- P0 — audit des autres helpers internes du portail Super Admin
-- ============================================================================
-- Résultat (voir rapport pour le détail complet, 15 fonctions "_"-préfixées inspectées) :
--   - _admin_sync_user_default_role : SECURITY DEFINER, déjà gardée par is_platform_admin()
--     — conforme, aucune modification nécessaire.
--   - _generate_hotel_code : PAS SECURITY DEFINER (SECURITY INVOKER par défaut), aucun
--     contournement RLS possible, aucun effet de bord sensible — conforme, non modifiée.
--   - les 12 autres (_gmp_*, _dunning_*, _pcr_*, _audit_entry_digest, _folio_transfers_immutable,
--     _tva_snapshot_immutable) appartiennent à d'autres modules (planning groupe, relances,
--     pointage, finance) sans lien avec le portail Super Admin — hors périmètre de ce hotfix,
--     non modifiées.
-- Aucune autre fonction ne cumule SECURITY DEFINER + EXECUTE public + absence de garde.

-- ============================================================================
-- P1 — admin_set_user_status() : historisation atomique
-- ============================================================================
-- Cause racine : fonction préexistante réutilisée telle quelle par la vue Utilisateurs,
-- jamais dotée d'un appel de journalisation. Toute suspension/réactivation était silencieuse.

CREATE OR REPLACE FUNCTION public.admin_set_user_status(p_user_id uuid, p_active boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_before     boolean;
  v_email      text;
  v_full_name  text;
  v_hotel_id   uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT is_active, email, full_name INTO v_before, v_email, v_full_name
  FROM public.users WHERE id = p_user_id;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'UTILISATEUR_INTROUVABLE';
  END IF;

  UPDATE public.users SET is_active = p_active, updated_at = now() WHERE id = p_user_id;

  SELECT hotel_id INTO v_hotel_id FROM public.user_hotels WHERE user_id = p_user_id AND is_default LIMIT 1;

  -- Même transaction que l'UPDATE ci-dessus : un échec de _platform_log() (ex. contrainte
  -- violée, désactivation ponctuelle du service) annule automatiquement le changement de
  -- statut — aucune exécution de statut sans trace d'audit correspondante.
  PERFORM public._platform_log(
    CASE WHEN p_active THEN 'user.reactivate' ELSE 'user.suspend' END,
    'user', p_user_id::text, v_hotel_id, v_email,
    jsonb_build_object(
      'target_user_id', p_user_id, 'target_email', v_email, 'target_full_name', v_full_name,
      'before_is_active', v_before, 'after_is_active', p_active
    )
  );
END;
$function$;

-- ============================================================================
-- P1 — grant_superadmin_on_new_hotel : durcissement, PAS de suppression
-- ============================================================================
-- Voir rapport pour l'analyse d'impact complète. Décision retenue (en attente de votre GO
-- pour aller plus loin) : le trigger reste actif — c'est aujourd'hui le seul mécanisme
-- donnant au super admin un accès opérationnel à un hôtel via l'app principale index.html
-- (dont le modèle RLS est entièrement basé sur user_hotels, sans connaissance de
-- platform_admins) — mais chaque déclenchement devient désormais tracé explicitement.
-- Comportement fonctionnel inchangé (même INSERT INTO user_hotels, même condition
-- ON CONFLICT DO NOTHING) : seul l'ajout de la ligne d'audit est nouveau.

CREATE OR REPLACE FUNCTION public.grant_superadmin_on_new_hotel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_superadmin_id    uuid;
  v_superadmin_email text;
BEGIN
  SELECT u.id, u.email INTO v_superadmin_id, v_superadmin_email
    FROM public.users u
    JOIN public.platform_admins pa
      ON pa.auth_id = u.auth_id AND pa.role = 'super_admin' AND pa.is_active = true
   ORDER BY pa.created_at
   LIMIT 1;

  IF v_superadmin_id IS NOT NULL THEN
    INSERT INTO public.user_hotels (user_id, hotel_id, role, is_default)
    VALUES (v_superadmin_id, NEW.id, 'direction', false)
    ON CONFLICT (user_id, hotel_id) DO NOTHING;

    -- _platform_log_system (pas _platform_log) : l'utilisateur à l'origine de l'INSERT sur
    -- hotels peut être un directeur en self-service (org_create_hotel), pas nécessairement
    -- un platform_admin — _platform_log() aurait bloqué ce cas avec le nouveau garde P0.
    PERFORM public._platform_log_system(
      'hotel.auto_grant_superadmin_access', 'user_hotels', v_superadmin_id::text, NEW.id, NEW.name,
      jsonb_build_object(
        'granted_user_id', v_superadmin_id, 'granted_email', v_superadmin_email,
        'role', 'direction', 'source', 'trigger:grant_superadmin_on_new_hotel'
      )
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- ============================================================================
-- P1 — atomicité édition hôtel + groupe : nouvelle RPC transactionnelle unique
-- ============================================================================
-- Remplace, côté frontend, la séquence à deux appels (admin_update_hotel puis
-- admin_attach_hotel_to_group / admin_detach_hotel_from_group) par un seul appel atomique.
-- admin_update_hotel, admin_attach_hotel_to_group et admin_detach_hotel_from_group restent
-- en place inchangées (aucun DROP) : elles continuent de servir la vue Groupes (rattacher/
-- détacher un hôtel indépendamment de toute édition de ses champs).

CREATE OR REPLACE FUNCTION public.admin_update_hotel_full(p_hotel uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_before        jsonb;
  v_before_group  uuid;
  v_name          text;
  v_group_provided boolean := (p ? 'group_id');
  v_new_group     uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT to_jsonb(h), h.group_id INTO v_before, v_before_group FROM public.hotels h WHERE h.id = p_hotel;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  IF v_group_provided THEN
    v_new_group := nullif(p->>'group_id', '')::uuid;
    IF v_new_group IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.hotel_groups WHERE id = v_new_group) THEN
      RAISE EXCEPTION 'GROUPE_INTROUVABLE';
    END IF;
  END IF;

  UPDATE public.hotels SET
    name        = coalesce(nullif(trim(p->>'name'), ''), name),
    address     = coalesce(p->>'address', address),
    city        = coalesce(p->>'city', city),
    zip         = coalesce(p->>'zip', zip),
    country     = coalesce(p->>'country', country),
    phone       = coalesce(p->>'phone', phone),
    email       = coalesce(p->>'email', email),
    website     = coalesce(p->>'website', website),
    siret       = coalesce(p->>'siret', siret),
    tva_number  = coalesce(p->>'tva_number', tva_number),
    company     = coalesce(p->>'company', company),
    stars       = coalesce(nullif(p->>'stars', '')::int, stars),
    total_rooms = coalesce(nullif(p->>'total_rooms', '')::int, total_rooms),
    currency    = coalesce(nullif(p->>'currency', ''), currency),
    timezone    = coalesce(nullif(p->>'timezone', ''), timezone),
    group_id    = CASE WHEN v_group_provided THEN v_new_group ELSE group_id END
  WHERE id = p_hotel
  RETURNING name INTO v_name;

  PERFORM public._platform_log('hotel.update', 'hotel', p_hotel::text, p_hotel, v_name,
    jsonb_build_object('before', v_before, 'after', p));

  IF v_group_provided AND v_new_group IS DISTINCT FROM v_before_group THEN
    PERFORM public._platform_log(
      CASE WHEN v_new_group IS NULL THEN 'group.detach_hotel' ELSE 'group.attach_hotel' END,
      'hotel', p_hotel::text, p_hotel, v_name,
      jsonb_build_object('previous_group_id', v_before_group, 'new_group_id', v_new_group));
  END IF;

  RETURN (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = p_hotel);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_update_hotel_full(uuid, jsonb) TO authenticated;

-- ============================================================================
-- P2 — indexation platform_logs, justifiée par EXPLAIN (voir rapport pour les mesures)
-- ============================================================================
-- Seul index ajouté : il correspond exactement au motif de requête réel de la vue Audit et
-- de la cloche d'activité (ORDER BY created_at DESC LIMIT n). Aucun autre index ajouté sans
-- preuve, conformément à la consigne P2.

CREATE INDEX IF NOT EXISTS idx_platform_logs_created_at ON public.platform_logs (created_at DESC);
