-- 79_super_admin_p0_trial_app_access_coherence.sql
-- P0 — Cohérence et sécurisation du traitement des essais.
--
-- Root cause (cf. rapport CTO joint) : admin_extend_trial() ne modifie que
-- hotel_subscriptions.trial_ends_at (le contrat commercial principal). Elle ne touche jamais
-- hotel_app_subscriptions (le mécanisme technique, antérieur à hotel_subscriptions — cf.
-- sql/73 L33-36 — qui gouverne RÉELLEMENT l'accès RH/PMS aujourd'hui via
-- current_user_has_app(), lequel ne consulte QUE hotel_app_subscriptions.status, jamais
-- hotel_subscriptions ni plan_modules). Un abonnement principal prolongé peut donc laisser
-- derrière lui des lignes hotel_app_subscriptions figées sur leur ancienne échéance. Le bouton
-- "Traiter les essais expirés" (admin_run_expired_trials_processing ->
-- process_expired_subscription_trials) expire alors ces lignes dès que leur trial_ends_at est
-- dépassé, même si l'abonnement principal est encore valide — coupant RH/PMS pour un hôtel en
-- règle. Cas réel constaté : Folkestone opera (hotel_subscriptions.trial_ends_at = 2026-08-28,
-- trial_extensions_count = 1 ; hotel_app_subscriptions RH et PMS toujours à 2026-07-05, jamais
-- synchronisées lors de cette prolongation).
--
-- Portée de cette migration (strictement le P0, aucun autre Quick Win) :
--   1. admin_extend_trial() synchronise désormais, dans la MÊME transaction, toute ligne
--      hotel_app_subscriptions de l'hôtel encore en status='trial' vers la nouvelle échéance.
--      Retour enrichi (nombre et liste des apps synchronisées) au lieu du seul enregistrement
--      hotel_subscriptions.
--   2. admin_sync_app_trial_dates() — nouvelle RPC dédiée, générale (pas un hack Folkestone) —
--      régularise, hôtel par hôtel, toute ligne hotel_app_subscriptions en essai dont la date
--      diverge de celle de l'abonnement principal. Idempotente (ne touche que les lignes
--      réellement divergentes), auditée (avant/après conservés dans
--      hotel_subscription_events.metadata_before/after), sans aucun UPDATE manuel direct.
--      C'est le chemin de régularisation de Folkestone : admin_extend_trial() ne peut plus être
--      rappelée pour Folkestone (trial_extensions_count=1, plafond max_trial_extensions=1 déjà
--      atteint) — la régularisation d'une divergence historique n'est de toute façon pas une
--      nouvelle prolongation commerciale, elle mérite sa propre RPC et son propre event_type.
--   3. admin_preview_expired_trials_processing() — nouvelle RPC strictement en lecture seule
--      (aucun INSERT/UPDATE/DELETE/log), pour prévisualiser l'effet exact de "Traiter les
--      essais expirés" avant confirmation, ligne par ligne (hôtel, app, statut, échéance, jours
--      de retard, effet théorique, anomalies — dont "main_subscription_still_valid", le signal
--      qui aurait permis de repérer Folkestone avant le clic).
--
-- Non modifié dans ce lot (portée volontairement exclue, cf. rapport CTO "risques résiduels") :
--   process_expired_subscription_trials() elle-même (déjà correcte : elle n'expire que ce qui
--   est réellement passé, sans lien de cause avec ce bug), admin_convert_trial_to_active() et
--   les autres transitions de cycle de vie (risque de divergence symétrique documenté, non
--   traité ici — hors périmètre P0 explicitement borné par le CTO à admin_extend_trial), aucun
--   job pg_cron créé/activé, aucun UPDATE de masse, aucune donnée existante modifiée par cette
--   migration (la régularisation de Folkestone est un APPEL RPC séparé, après validation CTO,
--   jamais exécuté par ce fichier).

-- ============================================================================
-- 1. hotel_subscription_events — nouveau type d'événement pour la régularisation (additif)
-- ============================================================================
ALTER TABLE public.hotel_subscription_events
  DROP CONSTRAINT IF EXISTS hotel_subscription_events_event_type_check;
ALTER TABLE public.hotel_subscription_events
  ADD CONSTRAINT hotel_subscription_events_event_type_check CHECK (event_type IN (
    'created', 'trial_started', 'trial_extended', 'trial_converted',
    'activated', 'suspended', 'reactivated', 'renewed',
    'cancelled_immediate', 'cancellation_scheduled', 'cancellation_reverted',
    'expired_automatic', 'plan_changed', 'price_snapshot_updated',
    'regularized_legacy', 'migrated_to_commercial_plan',
    'app_trial_synced'
  ));

-- ============================================================================
-- 2. admin_extend_trial — synchronisation atomique des accès applicatifs en essai
-- ============================================================================
-- Le type de retour change (ajout du détail de synchronisation) : DROP requis, CREATE OR
-- REPLACE seul ne permet pas de changer le type de retour d'une fonction existante.
DROP FUNCTION IF EXISTS public.admin_extend_trial(uuid, timestamptz, text);

CREATE FUNCTION public.admin_extend_trial(
  p_subscription_id     uuid,
  p_new_trial_ends_at   timestamptz,
  p_reason              text
) RETURNS TABLE(
  subscription       public.hotel_subscriptions,
  old_trial_ends_at  timestamptz,
  new_trial_ends_at  timestamptz,
  synced_app_count   integer,
  synced_apps        text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub        public.hotel_subscriptions;
  v_max_ext    integer;
  v_old_ends   timestamptz;
  v_synced     text[];
  v_count      integer;
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

  v_old_ends := v_sub.trial_ends_at;

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

  -- Synchronisation atomique, même transaction. Portée volontaire : TOUTE ligne
  -- hotel_app_subscriptions de cet hôtel en status='trial', sans filtrer par plan_modules —
  -- current_user_has_app() (l'accès réel RH/PMS) ne consulte que ce statut, jamais
  -- l'appartenance au plan ; filtrer par plan laisserait une app hors-plan (ex. PMS sur un plan
  -- qui ne l'inclut pas) divergente et exposée au même bug que Folkestone. Une ligne déjà
  -- 'expired' n'est jamais ressuscitée ; une ligne déjà 'active' suit son propre cycle de vie
  -- payant, indépendant de l'essai principal — ni l'une ni l'autre n'est touchée ici.
  WITH synced AS (
    UPDATE public.hotel_app_subscriptions has
       SET trial_ends_at = p_new_trial_ends_at, updated_at = now()
     WHERE has.hotel_id = v_sub.hotel_id AND has.status = 'trial'
     RETURNING has.app_id
  )
  SELECT coalesce(array_agg(pa.code ORDER BY pa.code), ARRAY[]::text[]), count(*)::int
    INTO v_synced, v_count
  FROM synced JOIN public.platform_apps pa ON pa.id = synced.app_id;

  PERFORM public._hotel_subscription_transition(
    p_subscription_id, 'trial_extended', NULL, p_reason, 'platform_admin',
    jsonb_build_object(
      'old_trial_ends_at', v_old_ends, 'new_trial_ends_at', p_new_trial_ends_at,
      'synced_app_count', coalesce(v_count, 0), 'synced_apps', to_jsonb(coalesce(v_synced, ARRAY[]::text[]))
    )
  );

  PERFORM public._platform_log(
    'subscription.extend_trial', 'hotel_subscription', p_subscription_id::text, v_sub.hotel_id, NULL,
    jsonb_build_object(
      'old_trial_ends_at', v_old_ends, 'new_trial_ends_at', p_new_trial_ends_at,
      'synced_app_count', coalesce(v_count, 0), 'synced_apps', coalesce(v_synced, ARRAY[]::text[])
    )
  );

  RETURN QUERY SELECT v_sub, v_old_ends, p_new_trial_ends_at, coalesce(v_count, 0), coalesce(v_synced, ARRAY[]::text[]);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_extend_trial(uuid, timestamptz, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_extend_trial(uuid, timestamptz, text) TO authenticated;

-- ============================================================================
-- 3. admin_sync_app_trial_dates — régularisation générale, traçable, jamais un hack Folkestone
-- ============================================================================
-- Cible : hotel_app_subscriptions en status='trial' dont trial_ends_at diverge de
-- hotel_subscriptions.trial_ends_at pour le même hôtel — quelle qu'en soit la cause historique
-- (bug corrigé en section 2, saisie manuelle antérieure, mécanisme legacy jamais synchronisé).
-- Idempotente : ne sélectionne et ne modifie que les lignes réellement divergentes ; un second
-- appel sans nouvelle divergence renvoie synced_app_count=0 sans erreur ni écriture inutile.
-- Ne modifie qu'UN hôtel (celui de p_subscription_id) — jamais d'UPDATE portant sur plusieurs
-- hôtels à la fois.
CREATE OR REPLACE FUNCTION public.admin_sync_app_trial_dates(
  p_subscription_id  uuid,
  p_reason           text
) RETURNS TABLE(
  hotel_id            uuid,
  target_trial_ends_at timestamptz,
  synced_app_count    integer,
  synced_apps         jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub          public.hotel_subscriptions;
  v_admin_id     uuid;
  v_admin_email  text;
  v_before       jsonb;
  v_after        jsonb;
  v_count        integer;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif de régularisation est obligatoire' USING errcode = '22023';
  END IF;

  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Abonnement introuvable : %', p_subscription_id USING errcode = 'P0002';
  END IF;
  IF v_sub.status <> 'trial' THEN
    RAISE EXCEPTION 'Seul un abonnement en essai peut être régularisé par cette RPC' USING errcode = '22023';
  END IF;
  IF v_sub.trial_ends_at IS NULL THEN
    RAISE EXCEPTION 'L''abonnement principal n''a pas de date de fin d''essai à propager — corrigez-la d''abord via admin_extend_trial'
      USING errcode = '22023';
  END IF;

  -- Diagnostic avant correction, conservé dans l'historique (metadata_before) — jamais perdu.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'app_code', pa.code, 'app_subscription_id', has.id, 'trial_ends_at', has.trial_ends_at
         ) ORDER BY pa.code), '[]'::jsonb)
    INTO v_before
  FROM public.hotel_app_subscriptions has
  JOIN public.platform_apps pa ON pa.id = has.app_id
  WHERE has.hotel_id = v_sub.hotel_id AND has.status = 'trial'
    AND has.trial_ends_at IS DISTINCT FROM v_sub.trial_ends_at;

  WITH synced AS (
    UPDATE public.hotel_app_subscriptions has
       SET trial_ends_at = v_sub.trial_ends_at, updated_at = now()
     WHERE has.hotel_id = v_sub.hotel_id AND has.status = 'trial'
       AND has.trial_ends_at IS DISTINCT FROM v_sub.trial_ends_at
     RETURNING has.app_id, has.id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('app_code', pa.code, 'app_subscription_id', synced.id) ORDER BY pa.code), '[]'::jsonb),
         count(*)::int
    INTO v_after, v_count
  FROM synced JOIN public.platform_apps pa ON pa.id = synced.app_id;

  SELECT id, email INTO v_admin_id, v_admin_email FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  INSERT INTO public.hotel_subscription_events (
    subscription_id, hotel_id, event_type, from_status, to_status,
    actor_type, actor_id, actor_email, reason, metadata_before, metadata_after
  ) VALUES (
    v_sub.id, v_sub.hotel_id, 'app_trial_synced', NULL, NULL,
    'platform_admin', v_admin_id, v_admin_email, p_reason, v_before,
    jsonb_build_object('target_trial_ends_at', v_sub.trial_ends_at, 'synced_apps', v_after, 'synced_app_count', coalesce(v_count, 0))
  );

  PERFORM public._platform_log(
    'subscription.regularize_app_trial_divergence', 'hotel_subscription', p_subscription_id::text, v_sub.hotel_id, NULL,
    jsonb_build_object(
      'reason', p_reason, 'target_trial_ends_at', v_sub.trial_ends_at,
      'before', v_before, 'synced_apps', v_after, 'synced_app_count', coalesce(v_count, 0)
    )
  );

  RETURN QUERY SELECT v_sub.hotel_id, v_sub.trial_ends_at, coalesce(v_count, 0), v_after;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_sync_app_trial_dates(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_sync_app_trial_dates(uuid, text) TO authenticated;

-- ============================================================================
-- 4. admin_preview_expired_trials_processing — prévisualisation stricte, aucune écriture
-- ============================================================================
-- Aucun INSERT/UPDATE/DELETE, aucun appel à _platform_log/_platform_log_system, aucun effet
-- de bord : peut être appelée autant de fois que nécessaire sans modifier la base. Reprend
-- exactement les deux prédicats de process_expired_subscription_trials() (section 10 de
-- sql/70) pour que la prévisualisation corresponde toujours à ce que l'exécution traiterait.
CREATE OR REPLACE FUNCTION public.admin_preview_expired_trials_processing()
RETURNS TABLE(
  entity_type         text,
  hotel_id            uuid,
  hotel_name          text,
  app_code            text,
  entity_id           uuid,
  current_status      text,
  trial_ends_at       timestamptz,
  days_since_expiry   numeric,
  theoretical_effect  text,
  anomaly_causes      text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    'main_subscription'::text,
    hs.hotel_id, h.name, NULL::text, hs.id, hs.status, hs.trial_ends_at,
    round(extract(epoch FROM (now() - hs.trial_ends_at)) / 86400.0, 1),
    format('Abonnement principal de %s → expired (essai dépassé)', h.name)::text,
    ARRAY[]::text[]
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  WHERE hs.status = 'trial' AND hs.trial_ends_at IS NOT NULL AND hs.trial_ends_at < now()

  UNION ALL

  SELECT
    'app_subscription'::text,
    has.hotel_id, h.name, pa.code, has.id, has.status, has.trial_ends_at,
    round(extract(epoch FROM (now() - has.trial_ends_at)) / 86400.0, 1),
    format('Accès %s de %s → expired', pa.code, h.name)::text,
    array_remove(ARRAY[
      CASE WHEN hs2.id IS NULL THEN 'missing_main_subscription' END,
      CASE WHEN hs2.id IS NOT NULL AND hs2.status IN ('trial', 'active')
             AND (hs2.trial_ends_at IS NULL OR hs2.trial_ends_at >= now())
           THEN 'main_subscription_still_valid' END
    ], NULL)
  FROM public.hotel_app_subscriptions has
  JOIN public.hotels h ON h.id = has.hotel_id
  JOIN public.platform_apps pa ON pa.id = has.app_id
  LEFT JOIN public.hotel_subscriptions hs2 ON hs2.hotel_id = has.hotel_id
  WHERE has.status = 'trial' AND has.trial_ends_at IS NOT NULL AND has.trial_ends_at < now()

  ORDER BY 3, 4, 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_preview_expired_trials_processing() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_preview_expired_trials_processing() TO authenticated;

-- Fin de migration. Aucune donnée existante modifiée (aucun UPDATE hors définitions de
-- fonctions/contrainte). Folkestone n'est régularisée par aucune ligne de ce fichier : sa
-- correction est un appel explicite à admin_sync_app_trial_dates(), après application de cette
-- migration et validation CTO, jamais un UPDATE de masse. Aucun job pg_cron créé ni activé.
