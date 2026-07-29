-- 73_super_admin_phase2d_lot3_users_access.sql
-- Super Admin portal (/admin) — Lot 3 : Utilisateurs et Accès.
--
-- Constat d'audit (avant modification) — trois notions distinctes, jamais confondues ici :
--   1. public.users        : identité employé, UN SEUL hôtel "domicile" (UNIQUE(auth_id),
--      hotel_id NOT NULL) — c'est le profil RH, pas le mécanisme d'accès multi-hôtel.
--   2. public.user_hotels  : accès/rôle PAR hôtel (PK user_id+hotel_id) — table déjà présente,
--      déjà exploitée par admin_grant_hotel/admin_revoke_hotel/admin_set_hotel_role/
--      admin_list_user_access (celle-ci agrège déjà hôtels+rôle+apps par utilisateur en JSON).
--   3. public.user_app_access : accès PAR application PAR hôtel — troisième niveau, déjà géré
--      par admin_set_app_access et par admin_grant_hotel (qui active les apps disponibles).
--   4. public.platform_admins : rôle plateforme (super_admin/billing_admin/support_agent),
--      totalement indépendant des trois précédents — un Super Admin n'a pas besoin d'une ligne
--      public.users ni user_hotels pour administrer la plateforme.
--   5. public.user_invitations : invitations HÔTEL (pas plateforme), déjà avec statut PENDING.
--
-- Le modèle multi-hôtel demandé (un utilisateur actif peut perdre l'accès à un hôtel en
-- conservant les autres) existe DÉJÀ via user_hotels — aucune restructuration nécessaire.
--
-- Edge Functions déjà en production, inspectées avant toute action :
--   - invite-user (v25) : invite/relie un utilisateur à UN hôtel donné, mais l'autorisation
--     n'accepte que l'appelant ayant déjà un rôle direction/admin_hotel SUR CET HÔTEL — un
--     Super Admin sans user_hotels sur un hôtel neuf en serait rejeté (c'est précisément le
--     trou signalé au Lot 2). Corrigé ci-après par un patch minimal (ajout d'un accès Super
--     Admin en plus du chemin existant, sans dupliquer la logique d'invitation/idempotence
--     déjà correcte : détection utilisateur existant, magic link vs invitation réelle,
--     rh_grant_hotel_access, audit hr_document_audit_logs).
--   - invite-platform-admin (v10) : déjà un mécanisme correct et complet d'invitation/promotion
--     Super Admin (vérifie platform_admins.role='super_admin' de l'appelant, gère utilisateur
--     existant vs nouveau) — réutilisé tel quel pour "inviter un nouveau Super Admin jamais vu".
--     Pour un utilisateur EXISTANT (déjà dans auth.users via son emploi), pas besoin de
--     ré-inviter par e-mail : admin_grant_platform_admin ci-dessous suffit.
--   - invite-hotel-primary-contact (v9) : conflate création d'hôtel + invitation + abonnement
--     app-level (hotel_app_subscriptions, mécanisme antérieur à hotel_subscriptions du Lot 0) —
--     NON réutilisée pour la création d'hôtel (redondante avec admin_create_hotel_with_subscription
--     du Lot 2, qui utilise le modèle d'abonnement actuel) ; laissée intacte, hors périmètre.
--
-- Découverte faite pendant la validation (test du garde-fou "dernier admin_hotel") : le trigger
-- historique trg_grant_superadmin_on_new_hotel (AFTER INSERT ON hotels) accorde automatiquement
-- un accès 'direction' au Super Admin réel le plus ancien (le premier platform_admins.role=
-- super_admin actif possédant une ligne public.users) sur TOUT nouvel hôtel. Comportement
-- préexistant, intentionnel (bootstrap d'accès), inchangé ici — documenté pour expliquer
-- pourquoi le garde-fou "dernier administrateur" de admin_revoke_hotel ne se déclenche
-- quasiment jamais sur un hôtel neuf en conditions réelles (il y a presque toujours ce second
-- accès automatique) : le garde-fou reste correct et utile pour les hôtels plus anciens ou dans
-- les cas où ce trigger n'a pas trouvé de correspondance.
--
-- ÉCART DE SÉCURITÉ DÉCOUVERT (même famille que Lots 0-2) : admin_grant_hotel, admin_revoke_hotel,
-- admin_set_hotel_role, admin_list_user_access, admin_set_app_access, admin_set_user_status,
-- admin_list_unlinked_auth_users (RPC frontend) et _admin_sync_user_default_role (helper interne)
-- étaient toutes restées ouvertes à anon/service_role depuis la Phase 1. Corrigé ci-dessous.

-- ============================================================================
-- 1. Garde-fous ajoutés à admin_grant_hotel (même signature, pas de nouvel overload)
-- ============================================================================
-- Empêche : (a) l'attribution d'un accès à un hôtel archivé ; (b) l'attribution d'un accès à
-- un utilisateur désactivé (incompatible avec son statut de compte).
CREATE OR REPLACE FUNCTION public.admin_grant_hotel(p_user_id uuid, p_hotel_id uuid, p_role admin_user_role)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor        uuid;
  v_has_default  boolean;
  v_hotel_status text;
  v_user_active  boolean;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT status INTO v_hotel_status FROM public.hotels WHERE id = p_hotel_id;
  IF v_hotel_status IS NULL THEN
    RAISE EXCEPTION 'Hôtel introuvable : %', p_hotel_id USING errcode = 'P0002';
  END IF;
  IF v_hotel_status = 'archived' THEN
    RAISE EXCEPTION 'Impossible d''attribuer un accès à un hôtel archivé' USING errcode = '22023';
  END IF;

  SELECT is_active INTO v_user_active FROM public.users WHERE id = p_user_id;
  IF v_user_active IS NULL THEN
    RAISE EXCEPTION 'Utilisateur introuvable : %', p_user_id USING errcode = 'P0002';
  END IF;
  IF NOT v_user_active THEN
    RAISE EXCEPTION 'Impossible d''attribuer un accès à un utilisateur désactivé' USING errcode = '22023';
  END IF;

  SELECT id INTO v_actor FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  SELECT EXISTS (SELECT 1 FROM public.user_hotels WHERE user_id = p_user_id AND is_default)
    INTO v_has_default;

  INSERT INTO public.user_hotels (user_id, hotel_id, role, is_default, granted_by)
  VALUES (p_user_id, p_hotel_id, p_role, NOT v_has_default, v_actor)
  ON CONFLICT (user_id, hotel_id) DO UPDATE
    SET role = EXCLUDED.role;

  INSERT INTO public.user_app_access (user_id, hotel_id, app_id, granted_by)
  SELECT p_user_id, p_hotel_id, pa.id, v_actor
  FROM public.platform_apps pa
  WHERE pa.is_available
  ON CONFLICT (user_id, hotel_id, app_id) DO NOTHING;

  PERFORM public._admin_sync_user_default_role(p_user_id);

  PERFORM public._platform_log('user.grant_hotel', 'user_hotels', p_user_id::text, p_hotel_id, NULL,
    jsonb_build_object('hotel_id', p_hotel_id, 'role', p_role));
END;
$function$;

-- ============================================================================
-- 2. admin_revoke_hotel — ajout d'un remplacement optionnel + garde dernier admin
-- ============================================================================
-- Nouveau paramètre optionnel (compatible arrière autrement) : si le retrait laisserait
-- l'hôtel sans aucun administrateur (direction/admin_hotel) actif, l'opération est refusée
-- SAUF si un remplaçant est fourni — auquel cas il est promu admin_hotel dans la même
-- transaction, avant le retrait. Jamais de suppression silencieuse du dernier admin.
DROP FUNCTION IF EXISTS public.admin_revoke_hotel(uuid, uuid);

CREATE OR REPLACE FUNCTION public.admin_revoke_hotel(
  p_user_id uuid, p_hotel_id uuid, p_replacement_user_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_was_default   boolean;
  v_next_hotel    uuid;
  v_role          admin_user_role;
  v_other_admins  int;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT role, is_default INTO v_role, v_was_default
  FROM public.user_hotels WHERE user_id = p_user_id AND hotel_id = p_hotel_id;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Accès hôtel introuvable pour cet utilisateur' USING errcode = 'P0002';
  END IF;

  IF v_role IN ('direction', 'admin_hotel') THEN
    SELECT count(*) INTO v_other_admins
    FROM public.user_hotels
    WHERE hotel_id = p_hotel_id AND user_id <> p_user_id AND role IN ('direction', 'admin_hotel');
    IF v_other_admins = 0 THEN
      IF p_replacement_user_id IS NULL THEN
        RAISE EXCEPTION
          'Ce retrait laisserait l''hôtel sans administrateur (direction/admin_hotel) — fournissez un remplaçant'
          USING errcode = '22023';
      END IF;
      IF p_replacement_user_id = p_user_id THEN
        RAISE EXCEPTION 'Le remplaçant ne peut pas être l''utilisateur retiré' USING errcode = '22023';
      END IF;
      PERFORM public.admin_grant_hotel(p_replacement_user_id, p_hotel_id, 'admin_hotel');
    END IF;
  END IF;

  DELETE FROM public.user_app_access WHERE user_id = p_user_id AND hotel_id = p_hotel_id;
  DELETE FROM public.user_active_hotel WHERE user_id = p_user_id AND hotel_id = p_hotel_id;
  DELETE FROM public.user_hotels WHERE user_id = p_user_id AND hotel_id = p_hotel_id;

  IF COALESCE(v_was_default, false) THEN
    SELECT hotel_id INTO v_next_hotel
    FROM public.user_hotels WHERE user_id = p_user_id
    ORDER BY granted_at LIMIT 1;
    IF v_next_hotel IS NOT NULL THEN
      UPDATE public.user_hotels SET is_default = true
      WHERE user_id = p_user_id AND hotel_id = v_next_hotel;
    END IF;
  END IF;

  PERFORM public._admin_sync_user_default_role(p_user_id);

  PERFORM public._platform_log('user.revoke_hotel', 'user_hotels', p_user_id::text, p_hotel_id, NULL,
    jsonb_build_object('hotel_id', p_hotel_id, 'replacement_user_id', p_replacement_user_id));
END;
$function$;

-- ============================================================================
-- 3. Rôle plateforme pour un utilisateur DÉJÀ existant (auth.users déjà présent)
-- ============================================================================
-- Distinct de l'Edge Function invite-platform-admin (réservée à une personne jamais vue de
-- auth.users, qui doit recevoir un e-mail réel). Ici, l'auth_id existe déjà (employé Flowtym
-- RH classique) : simple upsert local, aucune API Admin Auth nécessaire.
CREATE OR REPLACE FUNCTION public.admin_grant_platform_admin(
  p_auth_id uuid, p_role text DEFAULT 'super_admin', p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row     public.platform_admins;
  v_email   text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_role NOT IN ('super_admin', 'billing_admin', 'support_agent') THEN
    RAISE EXCEPTION 'Rôle plateforme invalide : %', p_role USING errcode = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_auth_id) THEN
    RAISE EXCEPTION 'Compte introuvable dans auth.users : %', p_auth_id USING errcode = 'P0002';
  END IF;

  SELECT email INTO v_email FROM public.users WHERE auth_id = p_auth_id;
  IF v_email IS NULL THEN
    SELECT email INTO v_email FROM auth.users WHERE id = p_auth_id;
  END IF;

  INSERT INTO public.platform_admins (auth_id, email, role, is_active)
  VALUES (p_auth_id, coalesce(v_email, 'inconnu@flowtym.local'), p_role, true)
  ON CONFLICT (auth_id) DO UPDATE SET role = EXCLUDED.role, is_active = true
  RETURNING * INTO v_row;

  PERFORM public._platform_log('platform_admin.grant', 'platform_admin', p_auth_id::text, NULL, NULL,
    jsonb_build_object('role', p_role, 'reason', p_reason));

  RETURN to_jsonb(v_row);
END;
$function$;

-- Désactive un rôle plateforme (jamais de suppression physique de la ligne platform_admins —
-- conserve l'historique de qui a été admin plateforme). Refuse de désactiver le DERNIER
-- super_admin actif : la plateforme ne doit jamais se retrouver sans administrateur.
CREATE OR REPLACE FUNCTION public.admin_revoke_platform_admin(p_auth_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row          public.platform_admins;
  v_target_role  text;
  v_other_active int;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif est obligatoire' USING errcode = '22023';
  END IF;

  SELECT role INTO v_target_role FROM public.platform_admins WHERE auth_id = p_auth_id AND is_active = true;
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Administrateur plateforme actif introuvable' USING errcode = 'P0002';
  END IF;

  IF v_target_role = 'super_admin' THEN
    SELECT count(*) INTO v_other_active
    FROM public.platform_admins WHERE auth_id <> p_auth_id AND role = 'super_admin' AND is_active = true;
    IF v_other_active = 0 THEN
      RAISE EXCEPTION 'Impossible de retirer le dernier Super Admin actif de la plateforme' USING errcode = '22023';
    END IF;
  END IF;

  UPDATE public.platform_admins SET is_active = false WHERE auth_id = p_auth_id RETURNING * INTO v_row;

  PERFORM public._platform_log('platform_admin.revoke', 'platform_admin', p_auth_id::text, NULL, NULL,
    jsonb_build_object('previous_role', v_target_role, 'reason', p_reason));

  RETURN to_jsonb(v_row);
END;
$function$;

-- ============================================================================
-- 3bis. Affectation/retrait en masse sur un GROUPE hôtelier
-- ============================================================================
-- Aucune table de rattachement utilisateur<->groupe n'existe (audit confirmé) — inventer une
-- table persistante distincte pour ce lot serait une évolution de modèle non demandée. Ces deux
-- RPC sont un raccourci d'affectation en masse sur les hôtels ACTUELS du groupe, entièrement
-- porté par user_hotels (aucune nouvelle table). Limite assumée et documentée dans le frontend :
-- un hôtel qui rejoindrait le groupe PLUS TARD n'hérite pas rétroactivement de cet accès — il
-- faudrait relancer l'affectation ou rattacher l'hôtel individuellement.
CREATE OR REPLACE FUNCTION public.admin_grant_hotel_group_access(
  p_user_id uuid, p_group_id uuid, p_role admin_user_role
) RETURNS TABLE(hotel_id uuid, hotel_name text, granted boolean, error_detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_hotel record;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  FOR v_hotel IN SELECT id, name FROM public.hotels WHERE group_id = p_group_id LOOP
    BEGIN
      PERFORM public.admin_grant_hotel(p_user_id, v_hotel.id, p_role);
      hotel_id := v_hotel.id; hotel_name := v_hotel.name; granted := true; error_detail := NULL;
    EXCEPTION WHEN OTHERS THEN
      hotel_id := v_hotel.id; hotel_name := v_hotel.name; granted := false; error_detail := SQLERRM;
    END;
    RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_revoke_hotel_group_access(p_user_id uuid, p_group_id uuid)
RETURNS TABLE(hotel_id uuid, hotel_name text, revoked boolean, error_detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_hotel record;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  FOR v_hotel IN SELECT h.id, h.name FROM public.hotels h
                 WHERE h.group_id = p_group_id AND EXISTS (
                   SELECT 1 FROM public.user_hotels uh WHERE uh.user_id = p_user_id AND uh.hotel_id = h.id
                 ) LOOP
    BEGIN
      PERFORM public.admin_revoke_hotel(p_user_id, v_hotel.id);
      hotel_id := v_hotel.id; hotel_name := v_hotel.name; revoked := true; error_detail := NULL;
    EXCEPTION WHEN OTHERS THEN
      hotel_id := v_hotel.id; hotel_name := v_hotel.name; revoked := false; error_detail := SQLERRM;
    END;
    RETURN NEXT;
  END LOOP;
END;
$function$;

-- ============================================================================
-- 4. ACL — REVOKE PUBLIC/anon/service_role explicite (retrofix Phase 1 + nouvelles RPC)
-- ============================================================================
REVOKE ALL ON FUNCTION public.admin_grant_hotel(uuid, uuid, admin_user_role) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_grant_hotel(uuid, uuid, admin_user_role) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_revoke_hotel(uuid, uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_hotel(uuid, uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_hotel_role(uuid, uuid, admin_user_role) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_hotel_role(uuid, uuid, admin_user_role) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_user_access() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_user_access() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_app_access(uuid, uuid, uuid, boolean) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_app_access(uuid, uuid, uuid, boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_user_status(uuid, boolean) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_user_status(uuid, boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_unlinked_auth_users() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_unlinked_auth_users() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_grant_platform_admin(uuid, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_grant_platform_admin(uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_revoke_platform_admin(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_platform_admin(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_grant_hotel_group_access(uuid, uuid, admin_user_role) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_grant_hotel_group_access(uuid, uuid, admin_user_role) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_revoke_hotel_group_access(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_hotel_group_access(uuid, uuid) TO authenticated;

-- Helper interne (catégorie 2) : jamais de GRANT client, sur aucun rôle.
REVOKE ALL ON FUNCTION public._admin_sync_user_default_role(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- Fin de migration. Aucune donnée existante modifiée (les nouveaux contrôles ne bloquent que
-- les cas qu'ils ciblent explicitement — hôtel archivé, utilisateur désactivé, dernier admin).
-- Aucune API Admin Auth appelée depuis SQL. Le patch de invite-user (Edge Function) est déployé
-- séparément (pas du SQL, cf. rapport).
