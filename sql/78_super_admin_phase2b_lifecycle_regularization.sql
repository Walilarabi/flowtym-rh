-- 78_super_admin_phase2b_lifecycle_regularization.sql
-- Phase 2B (moteur de gestion des abonnements) — préalables de régularisation exigés par
-- l'ADR-010 §1 avant toute activation réelle (mode enforce, cron) du moteur de cycle de vie.
-- Le moteur lui-même (RPC de suspension/renouvellement/résiliation/essai) a été livré et
-- câblé en Lot 1 (sql/71) ; cette migration ferme les 3 conditions encore ouvertes :
--   1. plan_modules peuplé pour les 5 plans commerciaux réels ;
--   2. un plan interne « Legacy Pilot » existe pour régulariser les hôtels historiques
--      sans abonnement (RPC admin_regularize_legacy_subscription, déjà présente depuis la
--      Phase 2A, mais jusqu'ici inutilisable : aucun plan plan_scope='internal' n'existait) ;
--   3. durcissement des deux RPC de création/changement de plan commercial pour qu'elles
--      ne puissent jamais assigner un plan interne (garde manquante, corrigée ici — le plan
--      interne ne doit être atteignable que via admin_regularize_legacy_subscription, qui
--      impose motif + date de revue + justification tarifaire).
-- Décisions CTO du 2026-07-29 : Legacy Pilot pour les 4 hôtels sans abonnement ; RH inclus
-- dans tous les plans, PMS à partir de Flow Core. Le cas Folkestone (trial_ends_at manquant)
-- et la régularisation des 4 hôtels sont exécutés séparément via les RPC de cycle de vie
-- elles-mêmes (admin_extend_trial, admin_regularize_legacy_subscription), pas par cette
-- migration — doctrine Phase 2A : aucune correction de donnée par UPDATE de masse.
-- Aucun cron créé, aucun verrou enforce levé (ADR-010 §1 et §3 restent en vigueur).

-- ============================================================================
-- 1. Catalogue applicatif — plan_modules (vide depuis la Phase 2A)
-- ============================================================================
INSERT INTO public.plan_modules (plan_id, app_id)
SELECT sp.id, pa.id
FROM public.subscription_plans sp
JOIN public.platform_apps pa ON pa.code = 'RH'
WHERE sp.plan_scope = 'public'
ON CONFLICT (plan_id, app_id) DO NOTHING;

INSERT INTO public.plan_modules (plan_id, app_id)
SELECT sp.id, pa.id
FROM public.subscription_plans sp
JOIN public.platform_apps pa ON pa.code = 'PMS'
WHERE sp.plan_scope = 'public' AND sp.slug IN ('flow-core', 'flow-pro', 'flow-elite', 'flow-enterprise')
ON CONFLICT (plan_id, app_id) DO NOTHING;

-- ============================================================================
-- 2. Plan interne « Legacy Pilot » — condition préalable à admin_regularize_legacy_subscription
-- ============================================================================
INSERT INTO public.subscription_plans (
  name, slug, description, price_monthly, price_annual, max_rooms, max_users, max_hotels,
  modules, features, support_level, is_active, sort_order, tagline, color, trial_days,
  setup_fee, price_per_room, plan_scope, is_commercializable
) VALUES (
  'Legacy Pilot', 'legacy-pilot',
  'Accès interne de régularisation pour un hôtel opérationnel historique sans abonnement commercial. '
  'Attribué exclusivement via admin_regularize_legacy_subscription (motif, date de revue et justification '
  'tarifaire obligatoires) — jamais sélectionnable à la création d''un hôtel ni via un changement de plan '
  'ordinaire.',
  0, 0, NULL, NULL, 1,
  '[]'::jsonb, '[]'::jsonb, 'email', true, 999, 'Régularisation interne — hors catalogue commercial',
  '#94a3b8', 0, 0, 0, 'internal', false
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.plan_modules (plan_id, app_id)
SELECT sp.id, pa.id
FROM public.subscription_plans sp
JOIN public.platform_apps pa ON pa.code = 'RH'
WHERE sp.slug = 'legacy-pilot'
ON CONFLICT (plan_id, app_id) DO NOTHING;

-- ============================================================================
-- 3. Durcissement — un plan interne ne peut être atteint que via la RPC de régularisation
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_create_subscription(
  p_hotel_id uuid, p_plan_id uuid, p_billing_cycle text DEFAULT 'monthly'::text,
  p_discount_percent numeric DEFAULT 0, p_price_derogation_reason text DEFAULT NULL::text,
  p_status text DEFAULT 'trial'::text
)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan            public.subscription_plans;
  v_sub             public.hotel_subscriptions;
  v_price_catalog   numeric;
  v_net             numeric;
  v_admin_id        uuid;
  v_admin_email     text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_status NOT IN ('trial', 'active') THEN
    RAISE EXCEPTION 'Statut initial invalide : trial ou active attendu' USING errcode = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.hotel_subscriptions WHERE hotel_id = p_hotel_id) THEN
    RAISE EXCEPTION 'Cet hôtel a déjà un abonnement principal' USING errcode = '23505';
  END IF;

  SELECT * INTO v_plan FROM public.subscription_plans WHERE id = p_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan introuvable : %', p_plan_id USING errcode = 'P0002';
  END IF;
  IF NOT v_plan.is_active OR v_plan.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'Ce plan n''est plus attribuable (inactif ou archivé)' USING errcode = '22023';
  END IF;
  IF v_plan.plan_scope <> 'public' THEN
    RAISE EXCEPTION 'Cette RPC exige un plan public (plan_scope=public) ; utilisez admin_regularize_legacy_subscription pour un plan interne'
      USING errcode = '22023';
  END IF;

  v_price_catalog := CASE p_billing_cycle WHEN 'annual' THEN v_plan.price_annual ELSE v_plan.price_monthly END;
  v_net := round(coalesce(v_price_catalog, 0) * (1 - coalesce(p_discount_percent, 0) / 100.0), 2);

  IF v_net IS DISTINCT FROM v_price_catalog AND p_price_derogation_reason IS NULL THEN
    RAISE EXCEPTION 'Un prix net différent du tarif catalogue exige une justification commerciale'
      USING errcode = '22023';
  END IF;

  INSERT INTO public.hotel_subscriptions (
    hotel_id, plan_id, status, billing_cycle, trial_ends_at,
    snapshot_plan_slug, snapshot_plan_name, snapshot_price_catalog_ht, snapshot_discount_percent,
    snapshot_price_net_ht, snapshot_currency, snapshot_billing_cycle, snapshot_limits,
    snapshot_effective_at, snapshot_price_derogation_reason, attribution_type
  ) VALUES (
    p_hotel_id, p_plan_id, p_status, p_billing_cycle,
    CASE WHEN p_status = 'trial' THEN now() + make_interval(days => coalesce(v_plan.trial_days, 14)) ELSE NULL END,
    v_plan.slug, v_plan.name, v_price_catalog, coalesce(p_discount_percent, 0),
    v_net, 'EUR', p_billing_cycle,
    jsonb_build_object(
      'max_rooms', v_plan.max_rooms, 'max_users', v_plan.max_users,
      'max_hotels', v_plan.max_hotels, 'modules', v_plan.modules
    ),
    now(), p_price_derogation_reason, 'commercial'
  ) RETURNING * INTO v_sub;

  SELECT id, email INTO v_admin_id, v_admin_email FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  INSERT INTO public.hotel_subscription_events (
    subscription_id, hotel_id, event_type, from_status, to_status,
    actor_type, actor_id, actor_email, reason, metadata_after
  ) VALUES (
    v_sub.id, p_hotel_id, 'created', NULL, v_sub.status,
    'platform_admin', v_admin_id, v_admin_email, 'Création d''abonnement', to_jsonb(v_sub)
  );

  PERFORM public._platform_log(
    'subscription.create', 'hotel_subscription', v_sub.id::text, p_hotel_id, NULL,
    jsonb_build_object('plan_slug', v_plan.slug, 'status', v_sub.status)
  );

  RETURN v_sub;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_change_subscription_plan(
  p_subscription_id uuid, p_new_plan_id uuid, p_reason text,
  p_discount_percent numeric DEFAULT 0, p_price_derogation_reason text DEFAULT NULL::text
)
RETURNS public.hotel_subscriptions
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
  IF v_new_plan.plan_scope <> 'public' THEN
    RAISE EXCEPTION 'Le changement de plan ne peut cibler qu''un plan public (plan_scope=public) ; utilisez admin_regularize_legacy_subscription pour un plan interne'
      USING errcode = '22023';
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

-- Signatures et ACL inchangées (CREATE OR REPLACE sur les mêmes signatures) : les
-- REVOKE/GRANT posés lors du Lot 1 (sql/71) restent en vigueur, aucune re-déclaration
-- nécessaire.

-- Fin de migration. Aucun cron créé. Mode enforce toujours verrouillé en dur
-- (admin_resolve_app_access, cf. ADR-010 §1 — les 3 conditions de levée y sont désormais
-- toutes closes par cette migration + les actions de régularisation exécutées séparément,
-- mais la levée elle-même reste un acte distinct exigeant une validation CTO dédiée, §3).
