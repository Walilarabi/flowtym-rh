-- 72_super_admin_phase2c_lot2_hotels_groups.sql
-- Super Admin portal (/admin) — Lot 2 : Hôtels et Groupes, finalisation.
--
-- Constat d'audit (avant modification) :
--   - hotels/hotel_groups : RLS déjà correcte (platform_admin_all sur hotel_groups,
--     hotels_insert_admin/hotels_delete_admin/platform_admin_read_hotels sur hotels — Phase 1).
--   - hotels_status_check : draft/active/suspended/archived — 4 valeurs, déjà distinctes du
--     statut d'abonnement (aucune confusion à corriger, décision Phase 1 déjà correcte).
--   - hotels_group_id_fkey : ON DELETE SET NULL — un hôtel n'est jamais supprimé si son groupe
--     l'est ; sans objet ici car admin_delete_group ne fait de toute façon jamais de DELETE.
--   - admin_delete_group : DÉJÀ un archivage logique (UPDATE status='archived'), refuse déjà
--     si des hôtels sont rattachés (GROUPE_NON_VIDE). Aucune suppression physique constatée —
--     le point 6 de la demande CTO ("si admin_delete_group supprime encore physiquement...")
--     ne s'applique pas : vérifié par lecture du corps de fonction, pas supposé.
--   - admin_update_hotel_full : transfert de groupe DÉJÀ atomique (UPDATE unique avec CASE sur
--     group_id), DÉJÀ auditée distinctement (group.attach_hotel / group.detach_hotel).
--   - Manquant : aucune RPC de restauration pour un groupe archivé (admin_restore_group absente).
--   - Manquant : aucune RPC atomique combinant création d'hôtel + abonnement (le frontend Phase 1
--     ne crée qu'un hôtel nu ; un abonnement doit être ajouté dans un second appel séparé —
--     risque d'état partiel si le second appel échoue, exactement le écueil signalé au point 3
--     de la demande CTO).
--   - ÉCART DE SÉCURITÉ DÉCOUVERT (inventaire ACL avant modification) : les 9 RPC hôtels/groupes
--     de la Phase 1 (admin_create_hotel, admin_update_hotel, admin_update_hotel_full,
--     admin_set_hotel_status, admin_create_group, admin_update_group, admin_delete_group,
--     admin_attach_hotel_to_group, admin_detach_hotel_from_group) n'ont JAMAIS reçu le
--     traitement REVOKE FROM PUBLIC/anon/service_role appliqué au Lot 0/1 — elles prédatent
--     cette doctrine. Vérifié : public_exec=true, anon_exec=true, service_role_exec=true sur les
--     9. Chacune reste gardée en interne par is_platform_admin(), donc aucune exploitation
--     démontrée, mais c'est le même écart que celui corrigé au Lot 0 (445363d) — corrigé ici par
--     la même méthode (REVOKE explicite par signature), sans toucher aux ALTER DEFAULT
--     PRIVILEGES du schéma (même décision qu'au Lot 1 : risque de régression non maîtrisé sur
--     les fonctions non liées à ce lot).

-- ============================================================================
-- 1. Restauration d'un groupe archivé (manquant, symétrique à admin_delete_group)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_restore_group(p_group uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  UPDATE public.hotel_groups SET status = 'active' WHERE id = p_group RETURNING name INTO v_name;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'GROUPE_INTROUVABLE';
  END IF;

  PERFORM public._platform_log('group.restore', 'hotel_group', p_group::text, NULL, v_name, '{}'::jsonb);

  RETURN (SELECT to_jsonb(g) FROM public.hotel_groups g WHERE g.id = p_group);
END;
$function$;

-- ============================================================================
-- 2. Création atomique hôtel + abonnement (évite l'état partiel signalé point 3)
-- ============================================================================
-- Une seule RPC = une seule transaction PL/pgSQL : si la création de l'abonnement échoue
-- (plan introuvable/inactif, prix dérogatoire non justifié…), l'INSERT de l'hôtel est annulé
-- avec elle — jamais d'hôtel orphelin sans abonnement suite à une erreur intermédiaire.
-- Réutilise admin_create_subscription (Lot 0) pour la logique de snapshot tarifaire plutôt que
-- de la dupliquer — appelée depuis un contexte déjà authentifié admin, le contrôle interne
-- is_platform_admin() de la fonction appelée repasse (auth.uid() est préservé à travers l'appel
-- imbriqué SECURITY DEFINER).
--
-- Limitation assumée et documentée (pas de fausse fonctionnalité) : le "premier administrateur"
-- (prénom/nom/e-mail) ne peut pas être créé comme compte utilisateur actif ici — public.users
-- exige un auth_id existant (NOT NULL, FK vers auth.users), et l'envoi d'une invitation e-mail
-- réelle passe par l'API Admin Auth de Supabase (service_role), qui ne doit jamais être invoquée
-- depuis le client (clé sensible). Cette RPC se contente donc de consigner l'intention (e-mail/
-- nom fournis) dans l'audit ; la création du compte utilisateur réel est un geste manuel depuis
-- Utilisateurs une fois la personne connue de auth.users — l'automatisation complète de
-- l'invitation est explicitement hors périmètre de ce lot (nécessiterait une Edge Function
-- dédiée détenant le service_role, non construite ici).
CREATE OR REPLACE FUNCTION public.admin_create_hotel_with_subscription(
  p_hotel                 jsonb,
  p_plan_id               uuid,
  p_subscription_status   text DEFAULT 'trial',
  p_first_admin_email     text DEFAULT NULL,
  p_first_admin_name      text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_new_hotel  uuid;
  v_code       text;
  v_name       text := trim(coalesce(p_hotel->>'name',''));
  v_sub        public.hotel_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'NOM_VIDE';
  END IF;
  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'Un plan est obligatoire pour créer un hôtel avec abonnement' USING errcode = '22023';
  END IF;

  v_code := upper(trim(coalesce(p_hotel->>'hotel_code','')));
  IF v_code <> '' AND EXISTS(SELECT 1 FROM public.hotels WHERE upper(hotel_code)=v_code) THEN
    RAISE EXCEPTION 'CODE_EXISTANT';
  END IF;
  IF v_code = '' THEN
    v_code := public._generate_hotel_code(v_name);
  END IF;

  INSERT INTO public.hotels (
    name, address, city, zip, country, phone, email, website, siret, tva_number,
    company, stars, total_rooms, currency, timezone, hotel_code, group_id,
    status, active
  ) VALUES (
    v_name, nullif(p_hotel->>'address',''), nullif(p_hotel->>'city',''), nullif(p_hotel->>'zip',''),
    coalesce(nullif(p_hotel->>'country',''),'France'), nullif(p_hotel->>'phone',''), nullif(p_hotel->>'email',''),
    nullif(p_hotel->>'website',''), nullif(p_hotel->>'siret',''), nullif(p_hotel->>'tva_number',''),
    nullif(p_hotel->>'company',''), nullif(p_hotel->>'stars','')::int, nullif(p_hotel->>'total_rooms','')::int,
    coalesce(nullif(p_hotel->>'currency',''),'EUR'), coalesce(nullif(p_hotel->>'timezone',''),'Europe/Paris'),
    v_code, nullif(p_hotel->>'group_id','')::uuid,
    'active', true
  ) RETURNING id INTO v_new_hotel;

  -- Abonnement : réutilise la RPC existante (mêmes contrôles plan actif/non archivé, snapshot
  -- tarifaire) — une exception ici annule aussi l'INSERT hôtel ci-dessus (même transaction).
  v_sub := public.admin_create_subscription(v_new_hotel, p_plan_id, 'monthly', 0, NULL, coalesce(p_subscription_status,'trial'));

  PERFORM public._platform_log('hotel.create_with_subscription', 'hotel', v_new_hotel::text, v_new_hotel, v_name,
    jsonb_build_object(
      'plan_id', p_plan_id, 'subscription_id', v_sub.id, 'subscription_status', v_sub.status,
      'first_admin_email', p_first_admin_email, 'first_admin_name', p_first_admin_name,
      'first_admin_account_created', false
    ));

  RETURN jsonb_build_object(
    'hotel', (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = v_new_hotel),
    'subscription', to_jsonb(v_sub)
  );
END;
$function$;

-- ============================================================================
-- 3. ACL — correction de l'écart hérité de la Phase 1 (9 RPC) + les 2 nouvelles
-- ============================================================================
REVOKE ALL ON FUNCTION public.admin_create_hotel(jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_hotel(jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_hotel(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_hotel(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_hotel_full(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_hotel_full(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_hotel_status(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_hotel_status(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_create_group(jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_group(jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_group(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_group(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_delete_group(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_group(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_attach_hotel_to_group(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_attach_hotel_to_group(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_detach_hotel_from_group(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_detach_hotel_from_group(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_restore_group(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_restore_group(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_create_hotel_with_subscription(jsonb, uuid, text, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_hotel_with_subscription(jsonb, uuid, text, text, text) TO authenticated;

-- Fin de migration. Aucune donnée existante modifiée. Aucune fonction rendue moins permissive
-- pour authenticated (seul PUBLIC/anon/service_role perdent un accès qu'aucun frontend légitime
-- n'utilisait). admin_delete_group reste un archivage logique, inchangé dans son comportement.
