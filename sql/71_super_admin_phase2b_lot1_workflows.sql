-- 71_super_admin_phase2b_lot1_workflows.sql
-- Super Admin portal (/admin) — Lot 1 : RPC manquantes pour le module Abonnements/Applications.
--
-- Contexte : le Lot 0 (70_super_admin_phase2a_subscription_foundation.sql) a livré le modèle
-- et 17 RPC de cycle de vie/résolution des droits, mais aucune RPC de changement de plan ni
-- de gestion du catalogue des offres. Ce lot ajoute strictement ces deux manques, avec la
-- même doctrine ACL que le Lot 0 (corrigée post-application le 445363d) : chaque RPC frontend
-- reçoit REVOKE ALL FROM PUBLIC, anon, service_role puis GRANT EXECUTE TO authenticated
-- uniquement, garde interne is_platform_admin() en première ligne, audit atomique dans la
-- même transaction que la mutation.
--
-- Portée strictement additive : aucun DROP, aucun DELETE, aucune donnée modifiée, aucun
-- changement de modèle hors ce qui est explicitement listé ci-dessous, aucun déverrouillage
-- du mode enforce (toujours verrouillé en dur — cf. ADR-010 §1, inchangé par ce lot).

-- ============================================================================
-- 1. Changement de plan — immédiat uniquement (limitation documentée)
-- ============================================================================
-- Limitation assumée : le changement PLANIFIÉ (à la prochaine échéance) exigerait de nouvelles
-- colonnes (scheduled_plan_id, scheduled_plan_change_at) et une logique d'application différée
-- symétrique à process_expired_subscription_trials — une évolution structurante non triviale,
-- hors périmètre de cette RPC. Implémenté ici : changement IMMÉDIAT uniquement, avec
-- re-snapshot tarifaire complet (même logique que admin_create_subscription) et événement
-- d'historique 'plan_changed' (déjà présent dans la contrainte CHECK du Lot 0, aucune
-- modification de contrainte nécessaire).
CREATE OR REPLACE FUNCTION public.admin_change_subscription_plan(
  p_subscription_id           uuid,
  p_new_plan_id               uuid,
  p_reason                    text,
  p_discount_percent          numeric DEFAULT 0,
  p_price_derogation_reason   text DEFAULT NULL
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub             public.hotel_subscriptions;
  v_new_plan        public.subscription_plans;
  v_price_catalog   numeric;
  v_net             numeric;
  v_old_plan_id     uuid;
  v_old_plan_slug   text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif de changement de plan est obligatoire' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  IF v_sub.status NOT IN ('trial', 'active', 'suspended') THEN
    RAISE EXCEPTION 'Le plan ne peut être changé que pour un abonnement en essai, actif ou suspendu'
      USING errcode = '22023';
  END IF;
  IF v_sub.plan_id = p_new_plan_id THEN
    RAISE EXCEPTION 'Le nouveau plan est identique au plan actuel' USING errcode = '22023';
  END IF;
  v_old_plan_id := v_sub.plan_id;
  SELECT slug INTO v_old_plan_slug FROM public.subscription_plans WHERE id = v_old_plan_id;

  SELECT * INTO v_new_plan FROM public.subscription_plans WHERE id = p_new_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_new_plan_id USING errcode = 'P0002';
  END IF;
  IF NOT v_new_plan.is_active OR v_new_plan.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'Ce plan n''est plus attribuable (inactif ou archivé)' USING errcode = '22023';
  END IF;

  v_price_catalog := CASE v_sub.billing_cycle WHEN 'annual' THEN v_new_plan.price_annual ELSE v_new_plan.price_monthly END;
  v_net := round(coalesce(v_price_catalog, 0) * (1 - coalesce(p_discount_percent, 0) / 100.0), 2);
  IF v_net IS DISTINCT FROM v_price_catalog AND p_price_derogation_reason IS NULL THEN
    RAISE EXCEPTION 'Un prix net différent du tarif catalogue exige une justification commerciale'
      USING errcode = '22023';
  END IF;

  UPDATE public.hotel_subscriptions
     SET plan_id = p_new_plan_id,
         snapshot_plan_slug = v_new_plan.slug,
         snapshot_plan_name = v_new_plan.name,
         snapshot_price_catalog_ht = v_price_catalog,
         snapshot_discount_percent = coalesce(p_discount_percent, 0),
         snapshot_price_net_ht = v_net,
         snapshot_price_derogation_reason = p_price_derogation_reason,
         snapshot_limits = jsonb_build_object(
           'max_rooms', v_new_plan.max_rooms, 'max_users', v_new_plan.max_users,
           'max_hotels', v_new_plan.max_hotels, 'modules', v_new_plan.modules
         ),
         snapshot_effective_at = now(),
         updated_at = now()
   WHERE id = p_subscription_id
   RETURNING * INTO v_sub;

  PERFORM public._hotel_subscription_transition(
    p_subscription_id, 'plan_changed', NULL, p_reason, 'platform_admin',
    jsonb_build_object(
      'old_plan_id', v_old_plan_id, 'old_plan_slug', v_old_plan_slug,
      'new_plan_id', p_new_plan_id, 'new_plan_slug', v_new_plan.slug
    )
  );

  RETURN v_sub;
END;
$function$;

-- ============================================================================
-- 2. Catalogue des offres — création/modification/activation/archivage
-- ============================================================================
-- Chaque RPC est un mince wrapper d'écriture directe sur subscription_plans (déjà protégée
-- par la policy RLS platform_admin_all — cf. Lot 0), dont la seule valeur ajoutée est la
-- VALIDATION explicite (erreurs lisibles plutôt qu'une violation de contrainte brute) et
-- l'AUDIT atomique via _platform_log, cohérent avec le reste du portail (aucune mutation
-- admin sans trace). Une écriture directe cliente sur la table serait techniquement possible
-- (RLS le permettrait) mais ne serait jamais auditée — d'où ces RPC.

CREATE OR REPLACE FUNCTION public.admin_create_plan(
  p_name                text,
  p_slug                text,
  p_description         text DEFAULT NULL,
  p_price_monthly       numeric DEFAULT 0,
  p_price_annual        numeric DEFAULT 0,
  p_trial_days          integer DEFAULT 14,
  p_max_rooms           integer DEFAULT NULL,
  p_max_users           integer DEFAULT NULL,
  p_max_hotels          integer DEFAULT 1,
  p_plan_scope          text DEFAULT 'public',
  p_is_commercializable boolean DEFAULT true,
  p_sort_order          integer DEFAULT 0
) RETURNS public.subscription_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan public.subscription_plans;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Le nom du plan est obligatoire' USING errcode = '22023';
  END IF;
  IF p_slug IS NULL OR btrim(p_slug) = '' THEN
    RAISE EXCEPTION 'Le slug du plan est obligatoire' USING errcode = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.subscription_plans WHERE slug = p_slug) THEN
    RAISE EXCEPTION 'Ce slug de plan existe déjà : %', p_slug USING errcode = '23505';
  END IF;

  INSERT INTO public.subscription_plans (
    name, slug, description, price_monthly, price_annual, trial_days,
    max_rooms, max_users, max_hotels, plan_scope, is_commercializable, sort_order
  ) VALUES (
    btrim(p_name), btrim(p_slug), p_description, coalesce(p_price_monthly, 0), coalesce(p_price_annual, 0),
    coalesce(p_trial_days, 14), p_max_rooms, p_max_users, coalesce(p_max_hotels, 1),
    coalesce(p_plan_scope, 'public'), coalesce(p_is_commercializable, true), coalesce(p_sort_order, 0)
  ) RETURNING * INTO v_plan;

  PERFORM public._platform_log('plan.create', 'subscription_plan', v_plan.id::text, NULL, NULL,
    jsonb_build_object('slug', v_plan.slug, 'name', v_plan.name));

  RETURN v_plan;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_plan(
  p_plan_id             uuid,
  p_name                text,
  p_description         text DEFAULT NULL,
  p_price_monthly       numeric DEFAULT 0,
  p_price_annual        numeric DEFAULT 0,
  p_trial_days          integer DEFAULT 14,
  p_max_rooms           integer DEFAULT NULL,
  p_max_users           integer DEFAULT NULL,
  p_max_hotels          integer DEFAULT 1,
  p_sort_order          integer DEFAULT 0
) RETURNS public.subscription_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan public.subscription_plans;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Le nom du plan est obligatoire' USING errcode = '22023';
  END IF;

  UPDATE public.subscription_plans
     SET name = btrim(p_name), description = p_description,
         price_monthly = coalesce(p_price_monthly, 0), price_annual = coalesce(p_price_annual, 0),
         trial_days = coalesce(p_trial_days, 14), max_rooms = p_max_rooms, max_users = p_max_users,
         max_hotels = coalesce(p_max_hotels, 1), sort_order = coalesce(p_sort_order, 0),
         updated_at = now()
   WHERE id = p_plan_id
   RETURNING * INTO v_plan;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_plan_id USING errcode = 'P0002';
  END IF;

  PERFORM public._platform_log('plan.update', 'subscription_plan', p_plan_id::text, NULL, NULL,
    jsonb_build_object('slug', v_plan.slug, 'name', v_plan.name));

  RETURN v_plan;
END;
$function$;

-- Active/désactive un plan. Désactiver force is_commercializable=false dans la MÊME
-- transaction (sans quoi la contrainte subscription_plans_commercializable_requires_public_active
-- du Lot 0 rejetterait l'UPDATE) — jamais une correction silencieuse, une conséquence
-- explicite et documentée de la désactivation.
CREATE OR REPLACE FUNCTION public.admin_set_plan_active(
  p_plan_id uuid, p_is_active boolean, p_reason text DEFAULT NULL
) RETURNS public.subscription_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan public.subscription_plans;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  UPDATE public.subscription_plans
     SET is_active = p_is_active,
         is_commercializable = CASE WHEN p_is_active THEN is_commercializable ELSE false END,
         updated_at = now()
   WHERE id = p_plan_id
   RETURNING * INTO v_plan;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_plan_id USING errcode = 'P0002';
  END IF;

  PERFORM public._platform_log(
    CASE WHEN p_is_active THEN 'plan.activate' ELSE 'plan.deactivate' END,
    'subscription_plan', p_plan_id::text, NULL, NULL,
    jsonb_build_object('slug', v_plan.slug, 'reason', p_reason)
  );

  RETURN v_plan;
END;
$function$;

-- Archivage logique : jamais de suppression physique d'un plan (des abonnements historiques
-- peuvent le référencer — FK non touchée, cf. Lot 0 §1). archived_at + is_active=false +
-- is_commercializable=false ensemble, dans la même transaction, pour la même raison que
-- admin_set_plan_active ci-dessus. Un plan désarchivé redevient actif mais reste NON
-- commercialisable par défaut (décision explicite, pas de réattribution automatique du
-- catalogue public sans revue commerciale).
CREATE OR REPLACE FUNCTION public.admin_set_plan_archived(
  p_plan_id uuid, p_archived boolean, p_reason text DEFAULT NULL
) RETURNS public.subscription_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan public.subscription_plans;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_archived AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'Un motif d''archivage est obligatoire' USING errcode = '22023';
  END IF;

  IF p_archived THEN
    UPDATE public.subscription_plans
       SET archived_at = now(), archived_reason = p_reason,
           is_active = false, is_commercializable = false, updated_at = now()
     WHERE id = p_plan_id
     RETURNING * INTO v_plan;
  ELSE
    UPDATE public.subscription_plans
       SET archived_at = NULL, archived_reason = NULL, is_active = true, updated_at = now()
     WHERE id = p_plan_id
     RETURNING * INTO v_plan;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_plan_id USING errcode = 'P0002';
  END IF;

  PERFORM public._platform_log(
    CASE WHEN p_archived THEN 'plan.archive' ELSE 'plan.unarchive' END,
    'subscription_plan', p_plan_id::text, NULL, NULL,
    jsonb_build_object('slug', v_plan.slug, 'reason', p_reason)
  );

  RETURN v_plan;
END;
$function$;

-- Liaison plan <-> applications incluses (plan_modules, table du Lot 0). Remplace
-- l'ensemble des applications incluses pour un plan en une seule opération atomique
-- (DELETE + INSERT dans la même transaction) plutôt que d'exposer attach/detach unitaires
-- côté client pour cet écran — plus simple à piloter depuis une liste de cases à cocher,
-- et toujours entièrement traçable via _platform_log (avant/après complet).
CREATE OR REPLACE FUNCTION public.admin_set_plan_modules(
  p_plan_id uuid, p_app_ids uuid[]
) RETURNS TABLE(app_id uuid, app_code text, app_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_before jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE id = p_plan_id) THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_plan_id USING errcode = 'P0002';
  END IF;

  SELECT coalesce(jsonb_agg(pm.app_id), '[]'::jsonb) INTO v_before
  FROM public.plan_modules pm WHERE pm.plan_id = p_plan_id;

  DELETE FROM public.plan_modules WHERE plan_id = p_plan_id;
  IF p_app_ids IS NOT NULL AND array_length(p_app_ids, 1) > 0 THEN
    INSERT INTO public.plan_modules (plan_id, app_id)
    SELECT p_plan_id, unnest(p_app_ids);
  END IF;

  PERFORM public._platform_log('plan.set_modules', 'subscription_plan', p_plan_id::text, NULL, NULL,
    jsonb_build_object('before', v_before, 'after', to_jsonb(coalesce(p_app_ids, ARRAY[]::uuid[]))));

  RETURN QUERY
  SELECT pa.id, pa.code, pa.name
  FROM public.plan_modules pm JOIN public.platform_apps pa ON pa.id = pm.app_id
  WHERE pm.plan_id = p_plan_id
  ORDER BY pa.name;
END;
$function$;

-- ============================================================================
-- 3. ACL — REVOKE PUBLIC/anon/service_role explicite, GRANT authenticated seul
-- ============================================================================
-- Doctrine identique au Lot 0 corrigé (445363d) : chaque REVOKE cible PUBLIC, anon ET
-- service_role — pas seulement PUBLIC — pour neutraliser les ALTER DEFAULT PRIVILEGES du
-- schéma public (inventoriés avant ce lot : owners postgres/supabase_admin, non modifiés
-- globalement — correction globale jugée à risque de régression non maîtrisé sur les ~200
-- autres fonctions existantes de la plateforme, hors périmètre de ce lot).

REVOKE ALL ON FUNCTION public.admin_change_subscription_plan(uuid, uuid, text, numeric, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_change_subscription_plan(uuid, uuid, text, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_create_plan(text, text, text, numeric, numeric, integer, integer, integer, integer, text, boolean, integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_plan(text, text, text, numeric, numeric, integer, integer, integer, integer, text, boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_plan(uuid, text, text, numeric, numeric, integer, integer, integer, integer, integer) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_plan(uuid, text, text, numeric, numeric, integer, integer, integer, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_plan_active(uuid, boolean, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_plan_active(uuid, boolean, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_plan_archived(uuid, boolean, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_plan_archived(uuid, boolean, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_plan_modules(uuid, uuid[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_plan_modules(uuid, uuid[]) TO authenticated;

-- Fin de migration. Aucune donnée existante modifiée. Aucun cron créé. Mode enforce
-- toujours verrouillé en dur (inchangé, cf. admin_resolve_app_access, Lot 0).
