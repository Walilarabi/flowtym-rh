-- 74_super_admin_phase2d_lot3b_users_frontend_support.sql
-- Super Admin portal (/admin) — Lot 3 (suite) : support backend pour l'écran Utilisateurs.
--
-- Complète sql/73 (garde-fous + ACL) avec ce qui manquait pour construire une vraie liste et
-- une vraie fiche utilisateur sans jamais exposer auth.users directement au frontend :
--   1. admin_list_user_access() enrichie (même nom, signature 0-arg inchangée mais TYPE DE
--      RETOUR élargi -> DROP+CREATE requis, comme admin_revoke_hotel dans sql/73) :
--        - inclut désormais les Super Admins n'ayant AUCUNE ligne public.users (cas prévu et
--          documenté dans sql/73 : admin_grant_platform_admin ne crée jamais de ligne users).
--          Sans ce correctif, un tel compte resterait invisible dans "Utilisateurs" alors que
--          le cahier des charges exige un filtre "Super Admin" dans cette même liste.
--        - ajoute : groupes accessibles (dérivés des hôtels, aucune nouvelle table — cf. arbitrage
--          groupe de sql/73), rôle plateforme, date de dernière modification, et les signaux
--          bruts d'invitation (email_confirmed_at / invited_at, lus depuis auth.users, jamais
--          exposés bruts : uniquement via cette RPC SECURITY DEFINER) permettant au frontend de
--          calculer un statut "invitation en attente" sans jamais interroger auth.users lui-même.
--   2. admin_get_user_detail(p_user_id) : agrège les 5 sections de la fiche (identité, accès
--      hôtel avec auteur/date d'octroi, accès groupe dérivé, rôle plateforme, historique). Une
--      seule RPC, un seul aller-retour réseau, pour une fiche cohérente à instant donné.
--   3. admin_set_hotel_role (Phase 1) journalise désormais dans platform_logs — c'était le seul
--      RPC de gestion d'accès qui ne le faisait pas encore, ce qui aurait laissé un trou dans la
--      section Historique de la fiche pour les changements de rôle.
--
-- Aucune nouvelle table. Aucune donnée existante modifiée. auth.users n'est lu que depuis des
-- fonctions SECURITY DEFINER déjà existantes dans ce module (même schéma d'accès que
-- admin_list_unlinked_auth_users, Phase 1) — jamais accessible directement à authenticated/anon.

-- ============================================================================
-- 1. admin_list_user_access() — DROP + recreate (type de retour élargi)
-- ============================================================================
DROP FUNCTION IF EXISTS public.admin_list_user_access();

CREATE OR REPLACE FUNCTION public.admin_list_user_access()
RETURNS TABLE(
  user_id uuid, auth_id uuid, email text, full_name text, global_role admin_user_role,
  is_active boolean, last_login_at timestamptz, created_at timestamptz, updated_at timestamptz,
  hotels jsonb, group_names jsonb,
  is_super_admin boolean, platform_role text, is_platform_only boolean,
  email_confirmed_at timestamptz, invited_at timestamptz
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT
    u.id, u.auth_id, u.email, u.full_name, u.role, u.is_active,
    u.last_login_at, u.created_at, u.updated_at,
    COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'hotel_id',   uh.hotel_id,
                 'hotel_name', h.name,
                 'role',       uh.role,
                 'is_default', uh.is_default,
                 'granted_at', uh.granted_at,
                 'app_ids',    COALESCE((
                                 SELECT jsonb_agg(uaa.app_id)
                                 FROM public.user_app_access uaa
                                 WHERE uaa.user_id = u.id AND uaa.hotel_id = uh.hotel_id
                               ), '[]'::jsonb)
               )
               ORDER BY uh.is_default DESC, h.name)
      FROM public.user_hotels uh
      JOIN public.hotels h ON h.id = uh.hotel_id
      WHERE uh.user_id = u.id
    ), '[]'::jsonb) AS hotels,
    COALESCE((
      SELECT jsonb_agg(DISTINCT hg.name)
      FROM public.user_hotels uh2
      JOIN public.hotels h2 ON h2.id = uh2.hotel_id
      JOIN public.hotel_groups hg ON hg.id = h2.group_id
      WHERE uh2.user_id = u.id
    ), '[]'::jsonb) AS group_names,
    coalesce(pa.role = 'super_admin' AND pa.is_active, false) AS is_super_admin,
    CASE WHEN pa.is_active THEN pa.role ELSE NULL END AS platform_role,
    false AS is_platform_only,
    au.email_confirmed_at, au.invited_at
  FROM public.users u
  LEFT JOIN public.platform_admins pa ON pa.auth_id = u.auth_id
  LEFT JOIN auth.users au ON au.id = u.auth_id
  WHERE public.is_platform_admin()

  UNION ALL

  -- Super Admins sans aucune ligne public.users (cas prévu par admin_grant_platform_admin).
  SELECT
    NULL::uuid AS user_id, pa.auth_id, pa.email, pa.full_name, NULL::admin_user_role,
    true AS is_active, au.last_sign_in_at, pa.created_at, pa.updated_at,
    '[]'::jsonb, '[]'::jsonb,
    coalesce(pa.role = 'super_admin' AND pa.is_active, false),
    CASE WHEN pa.is_active THEN pa.role ELSE NULL END,
    true AS is_platform_only,
    au.email_confirmed_at, au.invited_at
  FROM public.platform_admins pa
  LEFT JOIN auth.users au ON au.id = pa.auth_id
  WHERE public.is_platform_admin()
    AND NOT EXISTS (SELECT 1 FROM public.users u2 WHERE u2.auth_id = pa.auth_id)

  ORDER BY 4 NULLS LAST, 3;
$function$;

-- ============================================================================
-- 2. admin_get_user_detail(p_user_id) — fiche 5 sections en un seul appel
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_get_user_detail(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user     public.users;
  v_identity jsonb;
  v_hotels   jsonb;
  v_groups   jsonb;
  v_platform jsonb;
  v_history  jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = p_user_id;
  IF v_user.id IS NULL THEN
    RAISE EXCEPTION 'Utilisateur introuvable' USING errcode = 'P0002';
  END IF;

  -- A. Identité
  SELECT jsonb_build_object(
    'user_id', v_user.id, 'auth_id', v_user.auth_id, 'email', v_user.email, 'full_name', v_user.full_name,
    'is_active', v_user.is_active, 'created_at', v_user.created_at, 'updated_at', v_user.updated_at,
    'last_login_at', v_user.last_login_at,
    'email_confirmed_at', au.email_confirmed_at, 'invited_at', au.invited_at, 'accepted_at', au.confirmed_at
  ) INTO v_identity
  FROM auth.users au WHERE au.id = v_user.auth_id;
  IF v_identity IS NULL THEN
    v_identity := jsonb_build_object(
      'user_id', v_user.id, 'auth_id', v_user.auth_id, 'email', v_user.email, 'full_name', v_user.full_name,
      'is_active', v_user.is_active, 'created_at', v_user.created_at, 'updated_at', v_user.updated_at,
      'last_login_at', v_user.last_login_at,
      'email_confirmed_at', null, 'invited_at', null, 'accepted_at', null
    );
  END IF;

  -- B. Accès hôtels (rôle, statut d'octroi, date, auteur)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'hotel_id', h.id, 'hotel_name', h.name, 'hotel_status', h.status, 'group_name', hg.name,
      'role', uh.role, 'is_default', uh.is_default, 'granted_at', uh.granted_at,
      'granted_by_name', gb.full_name, 'granted_by_email', gb.email
    ) ORDER BY uh.is_default DESC, h.name), '[]'::jsonb)
  INTO v_hotels
  FROM public.user_hotels uh
  JOIN public.hotels h ON h.id = uh.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  LEFT JOIN public.users gb ON gb.id = uh.granted_by
  WHERE uh.user_id = p_user_id;

  -- C. Accès groupe — dérivé des hôtels (pas de table de rattachement groupe distincte, cf.
  -- arbitrage documenté dans sql/73). "Hôtels hérités" = ceux du groupe déjà couverts.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'group_id', g.group_id, 'group_name', hg.name,
      'accessible_hotel_count', cnt.accessible, 'total_hotel_count', cnt.total
    )), '[]'::jsonb)
  INTO v_groups
  FROM (
    SELECT DISTINCT h.group_id
    FROM public.user_hotels uh JOIN public.hotels h ON h.id = uh.hotel_id
    WHERE uh.user_id = p_user_id AND h.group_id IS NOT NULL
  ) g
  JOIN public.hotel_groups hg ON hg.id = g.group_id
  JOIN LATERAL (
    SELECT
      count(*) FILTER (WHERE EXISTS(
        SELECT 1 FROM public.user_hotels uh3 WHERE uh3.user_id = p_user_id AND uh3.hotel_id = h3.id
      )) AS accessible,
      count(*) AS total
    FROM public.hotels h3 WHERE h3.group_id = hg.id
  ) cnt ON true;

  -- D. Rôle plateforme
  SELECT jsonb_build_object('role', pa.role, 'is_active', pa.is_active,
    'created_at', pa.created_at, 'updated_at', pa.updated_at)
  INTO v_platform
  FROM public.platform_admins pa WHERE pa.auth_id = v_user.auth_id;

  -- E. Historique — actions ciblant CET utilisateur (platform_logs, entity_id = son id
  -- applicatif OU son auth_id pour les actions plateforme) + invitations reçues d'un admin
  -- hôtel (hr_document_audit_logs, appariées par e-mail car ce flux journalise l'ACTEUR, pas
  -- la cible).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'action', x.action, 'created_at', x.created_at, 'admin_email', x.admin_email, 'payload', x.payload
    ) ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_history
  FROM (
    SELECT action, created_at, admin_email, payload FROM public.platform_logs
    WHERE entity_id = p_user_id::text AND entity IN ('user', 'user_hotels')
    UNION ALL
    SELECT action, created_at, admin_email, payload FROM public.platform_logs
    WHERE entity = 'platform_admin' AND entity_id = v_user.auth_id::text
    UNION ALL
    SELECT action, created_at, actor_email, details FROM public.hr_document_audit_logs
    WHERE action = 'invite_user' AND details->>'email' = v_user.email
    ORDER BY created_at DESC
    LIMIT 200
  ) x;

  RETURN jsonb_build_object(
    'identity', v_identity, 'hotel_access', v_hotels, 'group_access', v_groups,
    'platform_role', v_platform, 'history', v_history
  );
END;
$function$;

-- ============================================================================
-- 3. admin_set_hotel_role — ajoute la journalisation manquante (trou d'historique)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_set_hotel_role(p_user_id uuid, p_hotel_id uuid, p_role admin_user_role)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_before admin_user_role;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT role INTO v_before FROM public.user_hotels WHERE user_id = p_user_id AND hotel_id = p_hotel_id;

  UPDATE public.user_hotels SET role = p_role
  WHERE user_id = p_user_id AND hotel_id = p_hotel_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Accès hôtel introuvable pour cet utilisateur' USING errcode = 'P0002';
  END IF;

  PERFORM public._admin_sync_user_default_role(p_user_id);

  PERFORM public._platform_log('user.change_role', 'user_hotels', p_user_id::text, p_hotel_id, NULL,
    jsonb_build_object('hotel_id', p_hotel_id, 'before_role', v_before, 'after_role', p_role));
END;
$function$;

-- ============================================================================
-- 4. ACL
-- ============================================================================
REVOKE ALL ON FUNCTION public.admin_list_user_access() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_user_access() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_get_user_detail(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_user_detail(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_hotel_role(uuid, uuid, admin_user_role) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_hotel_role(uuid, uuid, admin_user_role) TO authenticated;

-- Fin de migration. Lecture seule d'auth.users, uniquement via SECURITY DEFINER déjà admin-gated
-- (is_platform_admin() vérifié en tout premier dans chaque fonction) — jamais de GRANT direct sur
-- auth.users, jamais de vue exposée dessus.
