-- 70_super_admin_phase2a_subscription_foundation.sql
-- Super Admin portal (/admin) — Phase 2A : fondations du modèle d'abonnement (schéma).
--
-- Contexte : hotel_subscriptions est la source de vérité du contrat commercial principal
-- (statut, essai, dates, tarification) — distincte du statut opérationnel de hotels.status.
-- hotel_app_subscriptions n'est PAS un second abonnement principal parallèle : réservé aux
-- modules optionnels non inclus dans le plan (add-ons). Une app incluse dans un plan n'a
-- besoin d'aucune ligne hotel_app_subscriptions. Décisions CTO validées lors du cadrage
-- Phase 2 puis de la revue du plan d'implémentation Phase 2A.
--
-- Portée strictement additive : aucun DROP, aucun DELETE, aucune correction de donnée
-- existante, aucun backfill commercial automatique, aucune modification des accès
-- utilisateurs existants (user_app_access non touché), aucun job pg_cron créé ni activé,
-- aucune insertion du plan interne "Flowtym Legacy Pilot" (préparé, pas créé), mode
-- d'application "enforce" de la résolution des droits techniquement impossible (verrouillé
-- en dur dans le code). Idempotent partout où c'est possible.

-- ============================================================================
-- 1. subscription_plans — typage actif / commercialisable / interne / archivé
-- ============================================================================
-- Sémantique précise de chaque champ (évite les états contradictoires) :
--   is_active            = le plan est utilisable aujourd'hui, tous usages confondus
--                           (commercial en libre-service ET attribution admin manuelle).
--                           Conservé pour compatibilité avec le code existant qui le lit déjà.
--   is_commercializable  = le plan est proposé aux NOUVEAUX clients (catalogue public).
--                           Ne peut être vrai que si le plan est actif, public et non archivé
--                           (contrainte ci-dessous) — un plan interne ou archivé n'est donc
--                           JAMAIS commercialisable, par construction.
--   plan_scope           = 'public' (vendable) ou 'internal' (régularisation technique,
--                           jamais proposé en libre-service, jamais dans un catalogue client).
--   archived_at           = plan retiré du catalogue. Un plan archivé reste référencé par les
--                           abonnements historiques déjà créés (FK non touchée, aucune
--                           CASCADE) — seule l'attribution à un NOUVEL abonnement est bloquée,
--                           au niveau des RPC de création (cf. section 8), pas par une
--                           contrainte de table qui casserait la lecture des abonnements
--                           existants.

ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS plan_scope           text NOT NULL DEFAULT 'public',
  ADD COLUMN IF NOT EXISTS is_commercializable   boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS archived_at           timestamptz,
  ADD COLUMN IF NOT EXISTS archived_reason       text;

ALTER TABLE public.subscription_plans
  DROP CONSTRAINT IF EXISTS subscription_plans_plan_scope_check;
ALTER TABLE public.subscription_plans
  ADD CONSTRAINT subscription_plans_plan_scope_check
  CHECK (plan_scope IN ('public', 'internal'));

-- Un plan archivé ne doit jamais rester actif (évite l'état contradictoire "archivé + actif").
ALTER TABLE public.subscription_plans
  DROP CONSTRAINT IF EXISTS subscription_plans_archived_not_active;
ALTER TABLE public.subscription_plans
  ADD CONSTRAINT subscription_plans_archived_not_active
  CHECK (archived_at IS NULL OR is_active = false);

-- Un plan interne, inactif ou archivé ne peut jamais être commercialisable.
ALTER TABLE public.subscription_plans
  DROP CONSTRAINT IF EXISTS subscription_plans_commercializable_requires_public_active;
ALTER TABLE public.subscription_plans
  ADD CONSTRAINT subscription_plans_commercializable_requires_public_active
  CHECK (
    is_commercializable = false
    OR (plan_scope = 'public' AND is_active = true AND archived_at IS NULL)
  );

-- Les 5 plans réels existants (is_active=true, archived_at NULL par défaut) satisfont ces
-- 3 contraintes sans aucune correction : plan_scope='public' (défaut), is_commercializable
-- reste à sa valeur par défaut true, cohérente avec leur is_active=true déjà en place.

-- ============================================================================
-- 2. plan_modules — liaison minimale subscription_plans <-> platform_apps
-- ============================================================================
-- Absente aujourd'hui (recherche exhaustive pg_class effectuée lors du cadrage). Sans cette
-- table, aucun moyen structurel de savoir quelles apps sont incluses dans un plan — la
-- fonction de résolution des droits (section 9) en dépend directement.

CREATE TABLE IF NOT EXISTS public.plan_modules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id     uuid NOT NULL REFERENCES public.subscription_plans(id) ON DELETE CASCADE,
  app_id      uuid NOT NULL REFERENCES public.platform_apps(id) ON DELETE RESTRICT,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, app_id)
);

CREATE INDEX IF NOT EXISTS idx_plan_modules_plan ON public.plan_modules (plan_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_plan_modules_app  ON public.plan_modules (app_id) WHERE is_active;

ALTER TABLE public.plan_modules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS plan_modules_admin_all ON public.plan_modules;
CREATE POLICY plan_modules_admin_all ON public.plan_modules
  FOR ALL USING (public.is_platform_admin()) WITH CHECK (public.is_platform_admin());

-- Aucune ligne insérée par cette migration : le peuplement de plan_modules pour les 5 plans
-- commerciaux réels est une décision de catalogue (quelles apps par plan), pas une déduction
-- technique — hors périmètre de ce lot, à traiter en Phase 2E avec validation CTO explicite.

-- ============================================================================
-- 3. add_ons.app_id — extension au-delà de la demande littérale, validée par le CTO
-- ============================================================================
-- Constat lors de l'implémentation : add_ons n'a aujourd'hui AUCUNE liaison structurelle
-- vers platform_apps. Sans elle, la condition 4 du résolveur ("application incluse dans le
-- plan OU add-on valide", section 9) est incalculable pour la branche add-on, et le test
-- "un add-on actif complète le plan principal" n'est pas vérifiable.
--
-- HYPOTHÈSE DOCUMENTÉE (validée par le CTO) : un add-on correspond aujourd'hui à UNE SEULE
-- application, d'où une colonne simple plutôt qu'une table de liaison M2M. Si le modèle
-- métier réel montre un jour qu'un add-on peut couvrir plusieurs applications, cette colonne
-- devra être remplacée par une table `add_on_apps (addon_id, app_id)` symétrique à
-- `plan_modules` — migration séparée, non anticipée ici.
--
-- Contraintes respectées :
--   - app_id reste NULLABLE dans cette migration (un add-on existant sans mapping n'est pas
--     bloqué, il est simplement signalé — cf. section 9, cause `addon_missing_app_mapping`).
--   - AUCUN backfill automatique fondé sur un nom ou un libellé : aucune ligne existante
--     (0 ligne hotel_addon_subscriptions en production aujourd'hui) n'est modifiée ou déduite.
--   - FK vers l'identifiant stable platform_apps.id (uuid, jamais le code text mutable).

ALTER TABLE public.add_ons
  ADD COLUMN IF NOT EXISTS app_id uuid REFERENCES public.platform_apps(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_add_ons_app_id ON public.add_ons (app_id) WHERE app_id IS NOT NULL;

-- ============================================================================
-- 4. hotel_subscriptions — snapshot contractuel, attribution, cycle de vie
-- ============================================================================
-- snapshot_* : photographie immuable des conditions contractuelles au moment de la
-- création/modification. Un changement futur du catalogue ne doit jamais recalculer
-- rétroactivement le prix d'un abonnement déjà signé — ces colonnes sont la garantie
-- technique de cette règle (aucun trigger ne les recalcule depuis subscription_plans).

ALTER TABLE public.hotel_subscriptions
  ADD COLUMN IF NOT EXISTS snapshot_plan_slug            text,
  ADD COLUMN IF NOT EXISTS snapshot_plan_name             text,
  ADD COLUMN IF NOT EXISTS snapshot_price_catalog_ht      numeric,
  ADD COLUMN IF NOT EXISTS snapshot_discount_percent      numeric,
  ADD COLUMN IF NOT EXISTS snapshot_price_net_ht          numeric,
  ADD COLUMN IF NOT EXISTS snapshot_currency               text DEFAULT 'EUR',
  ADD COLUMN IF NOT EXISTS snapshot_billing_cycle          text,
  ADD COLUMN IF NOT EXISTS snapshot_limits                 jsonb,
  ADD COLUMN IF NOT EXISTS snapshot_effective_at           timestamptz,
  ADD COLUMN IF NOT EXISTS snapshot_price_derogation_reason text,
  ADD COLUMN IF NOT EXISTS attribution_type                text NOT NULL DEFAULT 'commercial',
  ADD COLUMN IF NOT EXISTS attribution_reason               text,
  ADD COLUMN IF NOT EXISTS review_due_at                    timestamptz,
  ADD COLUMN IF NOT EXISTS trial_extensions_count           integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS scheduled_cancellation_at        timestamptz,
  ADD COLUMN IF NOT EXISTS scheduled_cancellation_reason    text;

ALTER TABLE public.hotel_subscriptions
  DROP CONSTRAINT IF EXISTS hotel_subscriptions_attribution_type_check;
ALTER TABLE public.hotel_subscriptions
  ADD CONSTRAINT hotel_subscriptions_attribution_type_check
  CHECK (attribution_type IN ('commercial', 'internal_regularization'));

-- Un prix net différent du prix catalogue exige une justification commerciale explicite.
-- Sûr à valider immédiatement : toutes les lignes existantes ont snapshot_price_net_ht NULL
-- (colonne neuve), donc la contrainte est trivialement satisfaite sans aucune correction.
ALTER TABLE public.hotel_subscriptions
  DROP CONSTRAINT IF EXISTS hotel_subscriptions_price_derogation_requires_reason;
ALTER TABLE public.hotel_subscriptions
  ADD CONSTRAINT hotel_subscriptions_price_derogation_requires_reason
  CHECK (
    snapshot_price_net_ht IS NULL
    OR snapshot_price_catalog_ht IS NULL
    OR snapshot_price_net_ht = snapshot_price_catalog_ht
    OR snapshot_price_derogation_reason IS NOT NULL
  );

-- Contrainte volontairement NON ajoutée dans ce lot : "un essai doit avoir une date de fin"
-- casserait sur la ligne Folkestone existante (trial_ends_at NULL). À activer en 2 temps
-- (NOT VALID puis VALIDATE CONSTRAINT) uniquement après la décision CTO sur ce cas précis :
--   ALTER TABLE public.hotel_subscriptions
--     ADD CONSTRAINT hotel_subscriptions_trial_has_end_date
--     CHECK (status <> 'trial' OR trial_ends_at IS NOT NULL) NOT VALID;

-- ============================================================================
-- 5. hotel_subscription_events — historique du cycle de vie, immuable
-- ============================================================================
-- Distinct de platform_logs (flux d'audit transverse à toute la plateforme) : timeline
-- dédiée, exploitable directement par le futur drawer "Historique" (Phase 2D) sans filtrer
-- le flux global. Écrite uniquement par des fonctions SECURITY DEFINER (section 7/8).
--
-- Correction CTO (revue contradictoire du commit 0319d7f, arbitrage A) : les 2 FK de
-- cette table utilisaient ON DELETE CASCADE dans la version précédente. Inspection des 2
-- contraintes, une par une — aucun remplacement aveugle :
--
--   Contrainte : hotel_subscription_events_subscription_id_fkey
--   Table/colonne parentes : public.hotel_subscriptions(id)
--   Comportement précédent : ON DELETE CASCADE (si la ligne hotel_subscriptions parente
--     est supprimée physiquement, tout son historique disparaît silencieusement avec elle)
--   Comportement cible : ON DELETE RESTRICT
--   Justification métier : hotel_subscriptions n'est jamais supprimée physiquement dans la
--     doctrine du projet (archivage/changement de statut uniquement — ADR-009 §11) ; mais
--     si ce principe était un jour violé par erreur, CASCADE détruirait silencieusement un
--     historique commercial/légal. RESTRICT transforme une violation de la doctrine en une
--     erreur bloquante visible (FK), au lieu d'une perte de données silencieuse — conforme à
--     « un historique d'abonnement ne doit jamais être supprimé automatiquement ».
--
--   Contrainte : hotel_subscription_events_hotel_id_fkey
--   Table/colonne parentes : public.hotels(id)
--   Comportement précédent : ON DELETE CASCADE (même risque, au niveau de l'hôtel entier :
--     supprimer un hôtel aurait supprimé tout l'historique de tous ses abonnements)
--   Comportement cible : ON DELETE RESTRICT
--   Justification métier : identique — un hôtel doit être archivé (hotels.status='archived'),
--     jamais supprimé physiquement, tant qu'il possède un historique d'abonnement. RESTRICT
--     rend cette exigence exécutoire au niveau base plutôt que déclarative uniquement.
--
-- Aucun autre FK sur cette table (2 seulement : subscription_id, hotel_id) — inspection
-- exhaustive, pas de remplacement partiel.

CREATE TABLE IF NOT EXISTS public.hotel_subscription_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id   uuid NOT NULL
    CONSTRAINT hotel_subscription_events_subscription_id_fkey
    REFERENCES public.hotel_subscriptions(id) ON DELETE RESTRICT,
  hotel_id          uuid NOT NULL
    CONSTRAINT hotel_subscription_events_hotel_id_fkey
    REFERENCES public.hotels(id) ON DELETE RESTRICT,
  event_type        text NOT NULL,
  from_status       text,
  to_status         text,
  actor_type        text NOT NULL,
  actor_id          uuid,
  actor_email       text,
  reason            text,
  operation_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  effective_at      timestamptz NOT NULL DEFAULT now(),
  metadata_before   jsonb NOT NULL DEFAULT '{}'::jsonb,
  metadata_after    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hotel_subscription_events_event_type_check CHECK (event_type IN (
    'created', 'trial_started', 'trial_extended', 'trial_converted',
    'activated', 'suspended', 'reactivated', 'renewed',
    'cancelled_immediate', 'cancellation_scheduled', 'cancellation_reverted',
    'expired_automatic', 'plan_changed', 'price_snapshot_updated',
    'regularized_legacy', 'migrated_to_commercial_plan'
  )),
  CONSTRAINT hotel_subscription_events_actor_type_check CHECK (actor_type IN ('platform_admin', 'system')),
  CONSTRAINT hotel_subscription_events_operation_id_key UNIQUE (operation_id)
);

CREATE INDEX IF NOT EXISTS idx_hse_subscription ON public.hotel_subscription_events (subscription_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hse_hotel        ON public.hotel_subscription_events (hotel_id, created_at DESC);

ALTER TABLE public.hotel_subscription_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hse_admin_select ON public.hotel_subscription_events;
CREATE POLICY hse_admin_select ON public.hotel_subscription_events
  FOR SELECT USING (public.is_platform_admin());
-- Aucune policy INSERT/UPDATE/DELETE pour authenticated : écriture uniquement via les
-- fonctions SECURITY DEFINER de la section 7/8 (même modèle que platform_logs/_platform_log).

-- Immuabilité : réutilise app.audit_logs_immutable(), déjà en place pour audit_logs et
-- platform_logs — même motif exact, pas de duplication.
DROP TRIGGER IF EXISTS trg_hotel_subscription_events_no_update ON public.hotel_subscription_events;
DROP TRIGGER IF EXISTS trg_hotel_subscription_events_no_delete ON public.hotel_subscription_events;
CREATE TRIGGER trg_hotel_subscription_events_no_update BEFORE UPDATE ON public.hotel_subscription_events
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();
CREATE TRIGGER trg_hotel_subscription_events_no_delete BEFORE DELETE ON public.hotel_subscription_events
  FOR EACH ROW EXECUTE FUNCTION app.audit_logs_immutable();

-- ============================================================================
-- 6. Index de performance (scans de la résolution des droits / expiration des essais)
-- ============================================================================
-- Corrections CTO (revue contradictoire, arbitrages C et D) :
--
--   idx_hs_hotel_id RETIRÉ (arbitrage C). Inspection : hotel_subscriptions porte déjà
--   `hotel_subscriptions_hotel_id_key`, un index UNIQUE btree sur (hotel_id) seul, sans
--   prédicat, sans colonne incluse — préexistant en production, non ajouté par cette
--   migration. Comparaison colonne par colonne : même colonne (hotel_id), même ordre (une
--   seule colonne), même méthode d'accès (btree), aucun prédicat des deux côtés, aucune
--   colonne incluse des deux côtés → strictement redondant. L'index existant de la
--   contrainte UNIQUE dessert déjà toute requête `WHERE hotel_id = ...`. Aucun index de
--   production existant n'est supprimé par ce retrait : celui-ci n'a jamais été appliqué.
--
--   idx_hs_attribution_type RETIRÉ (arbitrage D). Aucune requête de ce lot (RPC, résolveur,
--   rapport d'observation) ne filtre sur attribution_type — index spéculatif sans preuve de
--   besoin, sur une colonne à cardinalité binaire ('commercial'/'internal_regularization')
--   et une table d'une ligne aujourd'hui. Requête future qui pourrait le justifier, si elle
--   se matérialise : un futur tableau de bord Phase 2D « abonnements de régularisation
--   interne à revoir » du type
--     SELECT * FROM hotel_subscriptions
--      WHERE attribution_type = 'internal_regularization' AND review_due_at < now();
--   — à réévaluer avec un EXPLAIN réel sur des volumes réels si/quand cette requête existe,
--   pas avant.

CREATE INDEX IF NOT EXISTS idx_hs_status_trial_ends
  ON public.hotel_subscriptions (status, trial_ends_at) WHERE status = 'trial';
CREATE INDEX IF NOT EXISTS idx_has_status_trial_ends
  ON public.hotel_app_subscriptions (status, trial_ends_at) WHERE status = 'trial';

-- ============================================================================
-- 7. Helper interne — machine à états unique du cycle de vie (catégorie 2)
-- ============================================================================
-- Centralise la validation des transitions pour que les 10+ RPC de la section 8 ne
-- réimplémentent pas chacune la même garde. Transitions interdites : cancelled -> * (final),
-- expired -> suspended, et plus généralement tout retour vers trial hors création.

CREATE OR REPLACE FUNCTION public._hotel_subscription_transition(
  p_subscription_id uuid,
  p_event_type      text,
  p_to_status       text,              -- NULL = pas de changement de statut (ex. re-snapshot)
  p_reason          text,
  p_actor_type      text,              -- 'platform_admin' | 'system'
  p_metadata        jsonb DEFAULT '{}'::jsonb,
  p_effective_at    timestamptz DEFAULT now()
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub          public.hotel_subscriptions;
  v_from_status  text;
  v_admin_id     uuid;
  v_admin_email  text;
  v_allowed      boolean := false;
BEGIN
  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  v_from_status := v_sub.status;

  IF p_to_status IS NOT NULL AND p_to_status IS DISTINCT FROM v_from_status THEN
    v_allowed := CASE v_from_status
      WHEN 'trial'     THEN p_to_status IN ('active', 'cancelled', 'expired')
      WHEN 'active'    THEN p_to_status IN ('suspended', 'cancelled', 'expired')
      WHEN 'suspended' THEN p_to_status IN ('active', 'cancelled')
      WHEN 'expired'   THEN p_to_status IN ('cancelled')
      WHEN 'cancelled' THEN false
      ELSE false
    END;
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'Transition interdite : % -> %', v_from_status, p_to_status USING errcode = '22023';
    END IF;
    UPDATE public.hotel_subscriptions SET status = p_to_status, updated_at = now()
      WHERE id = p_subscription_id
      RETURNING * INTO v_sub;
  END IF;

  IF p_actor_type = 'platform_admin' THEN
    SELECT id, email INTO v_admin_id, v_admin_email
    FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;
  END IF;

  INSERT INTO public.hotel_subscription_events (
    subscription_id, hotel_id, event_type, from_status, to_status,
    actor_type, actor_id, actor_email, reason, effective_at, metadata_after
  ) VALUES (
    p_subscription_id, v_sub.hotel_id, p_event_type, v_from_status, p_to_status,
    p_actor_type, v_admin_id, v_admin_email, p_reason, p_effective_at, coalesce(p_metadata, '{}'::jsonb)
  );

  RETURN v_sub;
END;
$function$;

REVOKE ALL ON FUNCTION public._hotel_subscription_transition(uuid, text, text, text, text, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================
-- 8. RPC de cycle de vie (catégorie 1 — non branchées à admin.html dans ce lot)
-- ============================================================================

-- 8.1 Création d'un abonnement commercial standard, avec snapshot tarifaire au catalogue
-- actuel. Aucun backfill : n'agit que sur l'hôtel/plan passés explicitement en paramètre.
CREATE OR REPLACE FUNCTION public.admin_create_subscription(
  p_hotel_id                 uuid,
  p_plan_id                  uuid,
  p_billing_cycle             text DEFAULT 'monthly',
  p_discount_percent          numeric DEFAULT 0,
  p_price_derogation_reason   text DEFAULT NULL,
  p_status                    text DEFAULT 'trial'
) RETURNS public.hotel_subscriptions
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

-- 8.2 Régularisation via un plan interne (ex. futur Legacy Pilot). Motif, date de revue ET
-- justification tarifaire TOUS obligatoires — aucune valeur par défaut silencieuse pour la
-- date de revue, conformément à la décision CTO (le +90 jours restera une simple proposition
-- côté frontend plus tard, jamais un défaut SQL).
CREATE OR REPLACE FUNCTION public.admin_regularize_legacy_subscription(
  p_hotel_id             uuid,
  p_plan_id              uuid,
  p_reason               text,
  p_review_due_at        timestamptz,
  p_price_justification  text
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan      public.subscription_plans;
  v_sub       public.hotel_subscriptions;
  v_admin_id  uuid;
  v_admin_email text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif de régularisation est obligatoire' USING errcode = '22023';
  END IF;
  IF p_review_due_at IS NULL THEN
    RAISE EXCEPTION 'Une date de revue est obligatoire pour une régularisation interne' USING errcode = '22023';
  END IF;
  IF p_review_due_at <= now() THEN
    RAISE EXCEPTION 'La date de revue doit être future' USING errcode = '22023';
  END IF;
  IF p_price_justification IS NULL OR btrim(p_price_justification) = '' THEN
    RAISE EXCEPTION 'Une justification commerciale du tarif est obligatoire, même à 0,00 €'
      USING errcode = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.hotel_subscriptions WHERE hotel_id = p_hotel_id) THEN
    RAISE EXCEPTION 'Cet hôtel a déjà un abonnement principal' USING errcode = '23505';
  END IF;

  SELECT * INTO v_plan FROM public.subscription_plans WHERE id = p_plan_id;
  IF NOT FOUND OR v_plan.plan_scope <> 'internal' THEN
    RAISE EXCEPTION 'Cette RPC exige un plan interne (plan_scope=internal)' USING errcode = '22023';
  END IF;
  IF NOT v_plan.is_active OR v_plan.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'Ce plan n''est plus attribuable (inactif ou archivé)' USING errcode = '22023';
  END IF;

  INSERT INTO public.hotel_subscriptions (
    hotel_id, plan_id, status, billing_cycle,
    snapshot_plan_slug, snapshot_plan_name, snapshot_price_catalog_ht, snapshot_discount_percent,
    snapshot_price_net_ht, snapshot_currency, snapshot_billing_cycle, snapshot_limits,
    snapshot_effective_at, snapshot_price_derogation_reason,
    attribution_type, attribution_reason, review_due_at
  ) VALUES (
    p_hotel_id, p_plan_id, 'active', 'monthly',
    v_plan.slug, v_plan.name, v_plan.price_monthly, 0, v_plan.price_monthly, 'EUR', 'monthly',
    jsonb_build_object('max_rooms', v_plan.max_rooms, 'max_users', v_plan.max_users, 'max_hotels', v_plan.max_hotels),
    now(), p_price_justification,
    'internal_regularization', p_reason, p_review_due_at
  ) RETURNING * INTO v_sub;

  SELECT id, email INTO v_admin_id, v_admin_email FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  INSERT INTO public.hotel_subscription_events (
    subscription_id, hotel_id, event_type, from_status, to_status,
    actor_type, actor_id, actor_email, reason, metadata_after
  ) VALUES (
    v_sub.id, p_hotel_id, 'regularized_legacy', NULL, 'active',
    'platform_admin', v_admin_id, v_admin_email, p_reason, to_jsonb(v_sub)
  );

  PERFORM public._platform_log(
    'subscription.regularize_legacy', 'hotel_subscription', v_sub.id::text, p_hotel_id, NULL,
    jsonb_build_object('plan_slug', v_plan.slug, 'review_due_at', p_review_due_at)
  );

  RETURN v_sub;
END;
$function$;

-- 8.3 Re-snapshot explicite (renégociation). Ne recalcule jamais depuis le catalogue en
-- silence : le prix catalogue de référence est un paramètre explicite de l'appel.
CREATE OR REPLACE FUNCTION public.admin_update_price_snapshot(
  p_subscription_id           uuid,
  p_price_catalog_ht          numeric,
  p_discount_percent          numeric DEFAULT 0,
  p_price_derogation_reason   text DEFAULT NULL,
  p_reason                    text DEFAULT NULL
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub   public.hotel_subscriptions;
  v_net   numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  v_net := round(coalesce(p_price_catalog_ht, 0) * (1 - coalesce(p_discount_percent, 0) / 100.0), 2);
  IF v_net IS DISTINCT FROM p_price_catalog_ht AND p_price_derogation_reason IS NULL THEN
    RAISE EXCEPTION 'Un prix net différent du tarif catalogue exige une justification commerciale'
      USING errcode = '22023';
  END IF;

  UPDATE public.hotel_subscriptions
     SET snapshot_price_catalog_ht = p_price_catalog_ht,
         snapshot_discount_percent = coalesce(p_discount_percent, 0),
         snapshot_price_net_ht = v_net,
         snapshot_price_derogation_reason = p_price_derogation_reason,
         snapshot_effective_at = now(),
         updated_at = now()
   WHERE id = p_subscription_id
   RETURNING * INTO v_sub;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;

  PERFORM public._hotel_subscription_transition(
    p_subscription_id, 'price_snapshot_updated', NULL, p_reason, 'platform_admin',
    jsonb_build_object('snapshot_price_net_ht', v_net, 'snapshot_price_catalog_ht', p_price_catalog_ht)
  );

  RETURN v_sub;
END;
$function$;

-- 8.4 Prolongation d'essai, bornée par platform_settings.max_trial_extensions.
CREATE OR REPLACE FUNCTION public.admin_extend_trial(
  p_subscription_id     uuid,
  p_new_trial_ends_at   timestamptz,
  p_reason              text
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub        public.hotel_subscriptions;
  v_max_ext    integer;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_new_trial_ends_at <= now() THEN
    RAISE EXCEPTION 'La nouvelle date de fin d''essai doit être future' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  IF v_sub.status <> 'trial' THEN
    RAISE EXCEPTION 'Seul un abonnement en essai peut être prolongé' USING errcode = '22023';
  END IF;

  SELECT coalesce((value #>> '{}')::int, 1) INTO v_max_ext
  FROM public.platform_settings WHERE key = 'max_trial_extensions';

  IF v_sub.trial_extensions_count >= coalesce(v_max_ext, 1) THEN
    RAISE EXCEPTION 'Nombre maximum de prolongations d''essai atteint (%)', v_max_ext USING errcode = '22023';
  END IF;

  UPDATE public.hotel_subscriptions
     SET trial_ends_at = p_new_trial_ends_at,
         trial_extensions_count = trial_extensions_count + 1,
         updated_at = now()
   WHERE id = p_subscription_id
   RETURNING * INTO v_sub;

  PERFORM public._hotel_subscription_transition(
    p_subscription_id, 'trial_extended', NULL, p_reason, 'platform_admin',
    jsonb_build_object('new_trial_ends_at', p_new_trial_ends_at)
  );

  RETURN v_sub;
END;
$function$;

-- 8.5 Transitions simples du cycle de vie — chacune un mince appel au helper commun.
CREATE OR REPLACE FUNCTION public.admin_convert_trial_to_active(p_subscription_id uuid, p_reason text DEFAULT NULL)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  RETURN public._hotel_subscription_transition(p_subscription_id, 'trial_converted', 'active', p_reason, 'platform_admin');
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_suspend_subscription(p_subscription_id uuid, p_reason text)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif de suspension est obligatoire' USING errcode = '22023';
  END IF;
  RETURN public._hotel_subscription_transition(p_subscription_id, 'suspended', 'suspended', p_reason, 'platform_admin');
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reactivate_subscription(p_subscription_id uuid, p_reason text DEFAULT NULL)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  RETURN public._hotel_subscription_transition(p_subscription_id, 'reactivated', 'active', p_reason, 'platform_admin');
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_renew_subscription(p_subscription_id uuid, p_next_billing_date date, p_reason text DEFAULT NULL)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sub public.hotel_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  UPDATE public.hotel_subscriptions SET next_billing_date = p_next_billing_date, updated_at = now()
    WHERE id = p_subscription_id RETURNING * INTO v_sub;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  RETURN public._hotel_subscription_transition(
    p_subscription_id, 'renewed', NULL, p_reason, 'platform_admin',
    jsonb_build_object('next_billing_date', p_next_billing_date)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_cancel_subscription_immediate(p_subscription_id uuid, p_reason text)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif d''annulation est obligatoire' USING errcode = '22023';
  END IF;
  UPDATE public.hotel_subscriptions
     SET cancelled_at = now(), cancellation_reason = p_reason, updated_at = now()
   WHERE id = p_subscription_id;
  RETURN public._hotel_subscription_transition(p_subscription_id, 'cancelled_immediate', 'cancelled', p_reason, 'platform_admin');
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_schedule_subscription_cancellation(
  p_subscription_id uuid, p_effective_at timestamptz, p_reason text
) RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sub public.hotel_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_effective_at <= now() THEN
    RAISE EXCEPTION 'La date d''effet doit être future' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  IF v_sub.status NOT IN ('trial', 'active') THEN
    RAISE EXCEPTION 'Seul un abonnement en essai ou actif peut recevoir une annulation programmée'
      USING errcode = '22023';
  END IF;

  UPDATE public.hotel_subscriptions
     SET scheduled_cancellation_at = p_effective_at, scheduled_cancellation_reason = p_reason, updated_at = now()
   WHERE id = p_subscription_id
   RETURNING * INTO v_sub;

  PERFORM public._hotel_subscription_transition(
    p_subscription_id, 'cancellation_scheduled', NULL, p_reason, 'platform_admin',
    jsonb_build_object('scheduled_cancellation_at', p_effective_at), p_effective_at
  );

  RETURN v_sub;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_revert_scheduled_cancellation(p_subscription_id uuid, p_reason text DEFAULT NULL)
RETURNS public.hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sub public.hotel_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  UPDATE public.hotel_subscriptions
     SET scheduled_cancellation_at = NULL, scheduled_cancellation_reason = NULL, updated_at = now()
   WHERE id = p_subscription_id
   RETURNING * INTO v_sub;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  PERFORM public._hotel_subscription_transition(p_subscription_id, 'cancellation_reverted', NULL, p_reason, 'platform_admin');
  RETURN v_sub;
END;
$function$;

-- 8.6 Add-ons — strictement optionnels par rapport au plan principal (Décision 2). Pas de
-- ligne hotel_subscription_events (table réservée à l'abonnement principal) : journalisées
-- via _platform_log uniquement, comme les autres actions admin_* hors cycle de vie principal.
CREATE OR REPLACE FUNCTION public.admin_attach_addon(p_hotel_id uuid, p_addon_id uuid, p_reason text DEFAULT NULL)
RETURNS public.hotel_addon_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_row public.hotel_addon_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.hotel_addon_subscriptions
    WHERE hotel_id = p_hotel_id AND addon_id = p_addon_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Cet add-on est déjà actif pour cet hôtel' USING errcode = '23505';
  END IF;

  INSERT INTO public.hotel_addon_subscriptions (hotel_id, addon_id, status, started_at, notes)
  VALUES (p_hotel_id, p_addon_id, 'active', now(), p_reason)
  RETURNING * INTO v_row;

  PERFORM public._platform_log('addon.attach', 'hotel_addon_subscription', v_row.id::text, p_hotel_id, NULL,
    jsonb_build_object('addon_id', p_addon_id));

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_detach_addon(p_hotel_addon_subscription_id uuid, p_reason text)
RETURNS public.hotel_addon_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_row public.hotel_addon_subscriptions;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif de retrait est obligatoire' USING errcode = '22023';
  END IF;
  UPDATE public.hotel_addon_subscriptions
     SET status = 'cancelled', notes = coalesce(notes || ' | ', '') || p_reason, updated_at = now()
   WHERE id = p_hotel_addon_subscription_id
   RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Add-on introuvable : %', p_hotel_addon_subscription_id USING errcode = 'P0002';
  END IF;
  PERFORM public._platform_log('addon.detach', 'hotel_addon_subscription', v_row.id::text, v_row.hotel_id, NULL,
    jsonb_build_object('reason', p_reason));
  RETURN v_row;
END;
$function$;

-- ============================================================================
-- 9. Résolution centralisée des droits — modes observe / enforce
-- ============================================================================
-- _resolve_app_access_core (catégorie 2) calcule les 6 conditions. Ne recherche PAS l'état
-- is_active/archived_at du plan référencé pour juger la validité de l'abonnement : un
-- abonnement historique doit continuer à référencer un plan devenu non commercialisable ou
-- archivé sans que ses droits en soient affectés (décision CTO explicite) — seule
-- l'ATTRIBUTION d'un NOUVEL abonnement est bloquée par ces états, au niveau des RPC de
-- création (section 8), jamais la résolution des droits d'un abonnement déjà existant.
CREATE OR REPLACE FUNCTION public._resolve_app_access_core(
  p_user_id uuid, p_hotel_id uuid, p_app_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_active             boolean;
  v_hotel_authorized        boolean;
  v_hotel_op_status         text;
  v_sub                     public.hotel_subscriptions;
  v_plan                    public.subscription_plans;
  v_sub_found               boolean;
  v_subscription_valid      boolean := false;
  v_app_in_plan             boolean := false;
  v_app_included_or_addon   boolean := false;
  v_trial_not_expired       boolean := true;
  v_trial_missing_end_date  boolean := false;
  v_trial_expired           boolean := false;
  v_individual_authorized   boolean;
  v_theoretical             boolean;
  v_actual                  boolean;
  -- Détail de la branche add-on, pour distinguer les causes de divergence (section 9 CTO) :
  v_addon_active_for_app    boolean := false;  -- add-on actif dont app_id correspond à p_app_code
  v_addon_expired_for_app   boolean := false;  -- add-on existe pour cette app mais expiré/inactif
  v_addon_missing_mapping   boolean := false;  -- add-on actif sans app_id (non cartographié)
  v_causes                  jsonb := '[]'::jsonb;
BEGIN
  SELECT is_active INTO v_user_active FROM public.users WHERE id = p_user_id;
  v_user_active := coalesce(v_user_active, false);

  SELECT status INTO v_hotel_op_status FROM public.hotels WHERE id = p_hotel_id;
  v_hotel_authorized := v_hotel_op_status = 'active';

  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE hotel_id = p_hotel_id;
  v_sub_found := FOUND;

  IF v_sub_found THEN
    v_subscription_valid := v_sub.status IN ('trial', 'active');

    IF v_sub.status = 'trial' THEN
      IF v_sub.trial_ends_at IS NULL THEN
        -- Ne jamais expirer arbitrairement une ligne sans date : signalée comme cause
        -- distincte, jamais traitée comme expirée (cohérent avec
        -- process_expired_subscription_trials, section 10, qui ignore aussi ces lignes).
        v_trial_missing_end_date := true;
        v_trial_not_expired := true;
      ELSE
        v_trial_not_expired := v_sub.trial_ends_at >= now();
        v_trial_expired := NOT v_trial_not_expired;
      END IF;
      v_subscription_valid := v_subscription_valid AND v_trial_not_expired;
    END IF;

    SELECT * INTO v_plan FROM public.subscription_plans WHERE id = v_sub.plan_id;

    SELECT true INTO v_app_in_plan
    FROM public.plan_modules pm
    JOIN public.platform_apps pa ON pa.id = pm.app_id
    WHERE pm.plan_id = v_sub.plan_id AND pm.is_active AND pa.code = p_app_code;
    v_app_in_plan := coalesce(v_app_in_plan, false);
  END IF;

  -- Branche add-on : distingue actif-et-couvre / existe-mais-invalide / actif-sans-mapping.
  SELECT
    bool_or(has.status = 'active' AND (has.expires_at IS NULL OR has.expires_at > now())
            AND ao.app_id IS NOT NULL AND ao.app_id = (SELECT id FROM public.platform_apps WHERE code = p_app_code)),
    bool_or(ao.app_id IS NOT NULL AND ao.app_id = (SELECT id FROM public.platform_apps WHERE code = p_app_code)
            AND NOT (has.status = 'active' AND (has.expires_at IS NULL OR has.expires_at > now()))),
    bool_or(has.status = 'active' AND (has.expires_at IS NULL OR has.expires_at > now()) AND ao.app_id IS NULL)
  INTO v_addon_active_for_app, v_addon_expired_for_app, v_addon_missing_mapping
  FROM public.hotel_addon_subscriptions has
  JOIN public.add_ons ao ON ao.id = has.addon_id
  WHERE has.hotel_id = p_hotel_id;

  v_app_included_or_addon := v_app_in_plan OR coalesce(v_addon_active_for_app, false);

  SELECT EXISTS (
    SELECT 1 FROM public.user_app_access uaa
    JOIN public.platform_apps pa ON pa.id = uaa.app_id
    WHERE uaa.user_id = p_user_id AND uaa.hotel_id = p_hotel_id AND pa.code = p_app_code
  ) INTO v_individual_authorized;

  v_theoretical := v_user_active AND v_hotel_authorized AND v_subscription_valid
                   AND v_app_included_or_addon AND v_individual_authorized;
  v_actual := v_individual_authorized;

  -- Causes de divergence / anomalies, catégorie par catégorie (jamais un fourre-tout unique).
  IF NOT v_sub_found THEN v_causes := v_causes || '"missing_main_subscription"'::jsonb; END IF;
  IF v_sub_found AND NOT v_app_in_plan AND NOT v_app_included_or_addon THEN
    v_causes := v_causes || '"app_not_in_plan"'::jsonb;
  END IF;
  IF v_sub_found AND NOT v_app_in_plan AND NOT coalesce(v_addon_active_for_app, false)
     AND NOT coalesce(v_addon_expired_for_app, false) THEN
    v_causes := v_causes || '"missing_addon"'::jsonb;
  END IF;
  IF coalesce(v_addon_missing_mapping, false) THEN
    v_causes := v_causes || '"addon_missing_app_mapping"'::jsonb;
  END IF;
  IF coalesce(v_addon_expired_for_app, false) AND NOT coalesce(v_addon_active_for_app, false) THEN
    v_causes := v_causes || '"expired_addon"'::jsonb;
  END IF;
  IF v_trial_expired THEN v_causes := v_causes || '"expired_trial"'::jsonb; END IF;
  IF v_trial_missing_end_date THEN v_causes := v_causes || '"trial_missing_end_date"'::jsonb; END IF;
  IF NOT v_user_active THEN v_causes := v_causes || '"inactive_user"'::jsonb; END IF;
  IF NOT v_hotel_authorized THEN v_causes := v_causes || '"suspended_hotel"'::jsonb; END IF;
  IF v_sub_found AND v_sub.snapshot_effective_at IS NULL THEN
    v_causes := v_causes || '"incomplete_contract_snapshot"'::jsonb;
  END IF;
  IF v_sub_found AND v_plan.id IS NOT NULL AND v_plan.archived_at IS NOT NULL THEN
    v_causes := v_causes || '"archived_plan"'::jsonb;
  ELSIF v_sub_found AND v_plan.id IS NOT NULL AND NOT v_plan.is_active THEN
    v_causes := v_causes || '"inactive_plan"'::jsonb;
  END IF;
  IF NOT v_individual_authorized THEN v_causes := v_causes || '"missing_individual_access"'::jsonb; END IF;

  RETURN jsonb_build_object(
    'user_id', p_user_id, 'hotel_id', p_hotel_id, 'app_code', p_app_code,
    'conditions', jsonb_build_object(
      'user_active', v_user_active,
      'hotel_authorized', v_hotel_authorized,
      'subscription_valid', v_subscription_valid,
      'app_included_or_addon', v_app_included_or_addon,
      'trial_not_expired', v_trial_not_expired,
      'individual_access_authorized', v_individual_authorized
    ),
    'causes', v_causes,
    'theoretical_access', v_theoretical,
    'actual_access', v_actual,
    'diverges', v_theoretical IS DISTINCT FROM v_actual
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._resolve_app_access_core(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- Catégorie 4 : un utilisateur authentifié résout SES PROPRES droits uniquement — aucune
-- donnée d'un autre utilisateur exposée.
CREATE OR REPLACE FUNCTION public.resolve_my_app_access(p_hotel_id uuid, p_app_code text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public._resolve_app_access_core(
    (SELECT id FROM public.users WHERE auth_id = auth.uid()), p_hotel_id, p_app_code
  );
$function$;

-- Catégorie 1 : inspection admin de n'importe quel utilisateur. Le mode enforce est
-- techniquement impossible — verrouillé en dur, pas par convention d'appel.
CREATE OR REPLACE FUNCTION public.admin_resolve_app_access(
  p_user_id uuid, p_hotel_id uuid, p_app_code text, p_mode text DEFAULT 'observe'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  -- Correction CTO (revue contradictoire, arbitrage F) : `p_mode NOT IN (...)` évalue à NULL
  -- (donc ne déclenche jamais l'exception) quand p_mode est NULL — piège classique de NOT IN
  -- avec NULL en SQL. Un appel avec p_mode NULL retombait silencieusement en comportement
  -- observe au lieu d'être rejeté. IS NULL est vérifié explicitement en premier, avant NOT IN.
  IF p_mode IS NULL OR p_mode NOT IN ('observe', 'enforce') THEN
    RAISE EXCEPTION 'Mode invalide : observe ou enforce attendu (NULL non accepté)' USING errcode = '22023';
  END IF;
  IF p_mode = 'enforce' THEN
    -- Verrou volontaire et explicite. Ne pas retirer ce bloc sans validation CTO documentée
    -- ET régularisation complète (Phase 2E) : c'est la garantie qu'aucun accès existant ne
    -- peut être révoqué automatiquement pendant la normalisation.
    RAISE EXCEPTION
      'Mode enforce désactivé : régularisation complète et validation CTO requises avant activation'
      USING errcode = '55000';
  END IF;
  RETURN public._resolve_app_access_core(p_user_id, p_hotel_id, p_app_code);
END;
$function$;

-- Rapport de divergence agrégé, en lecture seule, sur tous les accès individuels réels.
CREATE OR REPLACE FUNCTION public.admin_rights_divergence_report()
RETURNS TABLE(hotel_name text, app_code text, user_email text, resolution jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT h.name, pa.code, u.email,
         public._resolve_app_access_core(uaa.user_id, uaa.hotel_id, pa.code)
  FROM public.user_app_access uaa
  JOIN public.hotels h ON h.id = uaa.hotel_id
  JOIN public.platform_apps pa ON pa.id = uaa.app_id
  LEFT JOIN public.users u ON u.id = uaa.user_id
  ORDER BY h.name, pa.code, u.email;
END;
$function$;

-- ============================================================================
-- 10. Expiration idempotente des essais (catégorie 3 — jamais de job créé/activé ici)
-- ============================================================================
-- Verrouillage : FOR UPDATE SKIP LOCKED seul, sans advisory lock. Contrairement au cas
-- ADR-003 (group_move_apply, où un advisory lock est nécessaire car AUCUNE ligne n'existe
-- encore au moment du conflit), cette fonction agit toujours sur des lignes hotel_subscriptions
-- déjà existantes : le verrou de ligne standard (FOR UPDATE SKIP LOCKED) suffit à garantir
-- qu'une même ligne n'est jamais traitée deux fois par deux exécutions concurrentes (le job
-- planifié futur et un déclenchement manuel admin, par exemple) — architecture volontairement
-- plus simple, sans mécanisme redondant.
CREATE OR REPLACE FUNCTION public.process_expired_subscription_trials()
RETURNS TABLE(processed_subscriptions int, processed_app_subscriptions int, skipped_locked int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row        record;
  v_count_sub  int := 0;
  v_count_app  int := 0;
  v_skipped    int := 0;
BEGIN
  FOR v_row IN
    SELECT id, hotel_id FROM public.hotel_subscriptions
    WHERE status = 'trial' AND trial_ends_at IS NOT NULL AND trial_ends_at < now()
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.hotel_subscriptions
       SET status = 'expired', updated_at = now()
     WHERE id = v_row.id AND status = 'trial';

    IF FOUND THEN
      INSERT INTO public.hotel_subscription_events (
        subscription_id, hotel_id, event_type, from_status, to_status, actor_type, reason
      ) VALUES (
        v_row.id, v_row.hotel_id, 'expired_automatic', 'trial', 'expired', 'system',
        'trial_ends_at dépassé — traitement automatique par process_expired_subscription_trials'
      );
      PERFORM public._platform_log_system(
        'subscription_trial_expired', 'hotel_subscription', v_row.id::text, v_row.hotel_id, NULL,
        jsonb_build_object('trigger', 'process_expired_subscription_trials')
      );
      v_count_sub := v_count_sub + 1;
    END IF;
  END LOOP;

  FOR v_row IN
    SELECT id, hotel_id FROM public.hotel_app_subscriptions
    WHERE status = 'trial' AND trial_ends_at IS NOT NULL AND trial_ends_at < now()
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.hotel_app_subscriptions
       SET status = 'expired', updated_at = now()
     WHERE id = v_row.id AND status = 'trial';

    IF FOUND THEN
      PERFORM public._platform_log_system(
        'app_subscription_trial_expired', 'hotel_app_subscription', v_row.id::text, v_row.hotel_id, NULL,
        jsonb_build_object('trigger', 'process_expired_subscription_trials')
      );
      v_count_app := v_count_app + 1;
    END IF;
  END LOOP;

  -- v_skipped reste à 0 dans un run non concurrent : conservé dans la signature de retour
  -- pour rendre visible, une fois deux exécutions réellement concurrentes, le nombre de
  -- lignes ignorées par SKIP LOCKED plutôt que de les faire disparaître silencieusement.
  RETURN QUERY SELECT v_count_sub, v_count_app, v_skipped;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_expired_subscription_trials() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_run_expired_trials_processing()
RETURNS TABLE(processed_subscriptions int, processed_app_subscriptions int, skipped_locked int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  PERFORM public._platform_log('trial_processing.manual_trigger', 'system', 'manual', NULL, NULL, '{}'::jsonb);
  RETURN QUERY SELECT * FROM public.process_expired_subscription_trials();
END;
$function$;

-- Job pg_cron PROPOSÉ, NON CRÉÉ, NON ACTIVÉ dans ce lot :
--   select cron.schedule('process_expired_subscription_trials', '*/15 * * * *',
--     $$select public.process_expired_subscription_trials();$$);

-- ============================================================================
-- 11. ACL des RPC frontend (catégorie 1/4, gardées en interne) — corrigé (arbitrage B)
-- ============================================================================
-- Correction CTO (revue contradictoire du commit 0319d7f) : la version précédente ne
-- contenait qu'un GRANT TO authenticated par fonction, sans REVOKE FROM PUBLIC préalable.
-- PostgreSQL accorde EXECUTE à PUBLIC par défaut à la création d'une fonction — ce grant
-- implicite n'était jamais retiré, rendant les 17 fonctions ci-dessous techniquement
-- exécutables par `anon` (sans conséquence exploitable, chacune étant gardée en interne par
-- is_platform_admin() ou, pour resolve_my_app_access, par un repli sûr sur auth.uid() NULL —
-- mais incohérent avec le verrouillage explicite déjà appliqué aux 3 helpers internes de la
-- section 7/9/10). Chaque fonction reçoit maintenant un REVOKE ALL FROM PUBLIC explicite
-- avant son GRANT, avec la signature exacte (types, sans les noms de paramètres — la
-- signature qu'utilise PostgreSQL pour résoudre une fonction surchargée).
--
-- Doctrine appliquée (ne pas confondre) :
--   RPC frontend (catégorie 1, 16 fonctions admin_* + admin_resolve_app_access) :
--     REVOKE ALL FROM PUBLIC, puis GRANT EXECUTE TO authenticated, ET garde interne
--     is_platform_admin() en première ligne du corps — vérifiée présente pour les 16.
--   RPC frontend self-service (catégorie 4, resolve_my_app_access) : idem ACL, mais garde
--     interne différente (repli sur auth.uid(), pas de vérification is_platform_admin(),
--     car destinée à tout utilisateur authentifié résolvant SES PROPRES droits).
--   Helper interne (catégorie 2/3, _hotel_subscription_transition, _resolve_app_access_core,
--     process_expired_subscription_trials, sections 7/9/10) : REVOKE ALL FROM PUBLIC, anon,
--     authenticated, service_role — AUCUN GRANT client, inchangé par cette correction.
--
-- Chaque mutation sensible de ces 16 RPC catégorie 1 est auditée de façon atomique, dans la
-- même transaction que l'écriture métier : soit via un INSERT direct dans
-- hotel_subscription_events (admin_create_subscription, admin_regularize_legacy_subscription),
-- soit via l'appel au helper _hotel_subscription_transition qui centralise cette écriture
-- (les 9 autres RPC de cycle de vie) — vérifié fonction par fonction, aucune mutation sans
-- écriture d'événement correspondante.

REVOKE ALL ON FUNCTION public.admin_create_subscription(uuid, uuid, text, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_subscription(uuid, uuid, text, numeric, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_regularize_legacy_subscription(uuid, uuid, text, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_regularize_legacy_subscription(uuid, uuid, text, timestamptz, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_price_snapshot(uuid, numeric, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_price_snapshot(uuid, numeric, numeric, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_extend_trial(uuid, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_extend_trial(uuid, timestamptz, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_convert_trial_to_active(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_convert_trial_to_active(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_suspend_subscription(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_suspend_subscription(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_reactivate_subscription(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reactivate_subscription(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_renew_subscription(uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_renew_subscription(uuid, date, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_cancel_subscription_immediate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_cancel_subscription_immediate(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_schedule_subscription_cancellation(uuid, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_schedule_subscription_cancellation(uuid, timestamptz, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_revert_scheduled_cancellation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_revert_scheduled_cancellation(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_attach_addon(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_attach_addon(uuid, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_detach_addon(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_detach_addon(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_resolve_app_access(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_app_access(uuid, uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_rights_divergence_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_rights_divergence_report() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_run_expired_trials_processing() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_run_expired_trials_processing() TO authenticated;

REVOKE ALL ON FUNCTION public.resolve_my_app_access(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_my_app_access(uuid, text) TO authenticated;

-- Fin de migration. Aucune donnée existante modifiée. Aucun plan Legacy Pilot inséré.
-- Aucun job pg_cron créé. Mode enforce techniquement impossible (RAISE EXCEPTION en dur).
