-- 79_super_admin_p0_trial_app_access_coherence.sql
-- P0 — Prévisualisation sécurisée du traitement des essais expirés.
--
-- Historique de ce fichier : sa première version synchronisait hotel_subscriptions et
-- hotel_app_subscriptions ; la deuxième retirait cette synchronisation mais laissait le
-- traitement réel (process_expired_subscription_trials, appelée par
-- admin_run_expired_trials_processing) continuer à modifier hotel_app_subscriptions sous le
-- capot, alors que la prévisualisation ne montrait que hotel_subscriptions — un écart entre
-- prévisualisation et exécution jugé inacceptable par le CTO pour une action Super Admin.
--
-- Décision CTO (contrat de la prévisualisation) : prévisualisation manuelle = exécution
-- manuelle = hotel_subscriptions uniquement. Cette version constitue la PREMIÈRE ÉTAPE
-- EFFECTIVE du plan de dépréciation ADR-011 (docs/adr/ADR-011-plan-deprecation-hotel-app-subscriptions.md) :
-- retrait du consommateur interne "portail Super Admin" vis-à-vis de hotel_app_subscriptions,
-- sans toucher à la table elle-même, ni à current_user_has_app(), ni à l'Edge Function
-- invite-hotel-primary-contact (ces retraits restent des phases ultérieures, distinctes).
--
-- Choix retenu : OPTION A (recommandée par le CTO). Une nouvelle fonction métier dédiée,
-- process_expired_hotel_subscription_trials(), reprend EXACTEMENT la logique de la première
-- boucle de process_expired_subscription_trials() (sql/70, section 10) — même prédicat, même
-- verrouillage FOR UPDATE SKIP LOCKED, même écriture d'audit (hotel_subscription_events +
-- _platform_log_system) — mais ne contient plus la seconde boucle sur
-- hotel_app_subscriptions. admin_run_expired_trials_processing() appelle désormais cette
-- nouvelle fonction. L'ancienne process_expired_subscription_trials() (sql/70) N'EST PAS
-- SUPPRIMÉE ni modifiée — elle reste en base, intacte, mais n'a plus aucun appelant : elle
-- n'est plus accessible depuis le portail. Sa suppression éventuelle relève d'une phase
-- ultérieure d'ADR-011, avec sa propre validation CTO.
--
-- Portée strictement additive : aucune donnée existante modifiée, aucune ligne
-- hotel_app_subscriptions touchée par ce fichier, aucune suppression de fonction ni de table.

-- ============================================================================
-- 1. Prévisualisation stricte en lecture seule — inchangée (déjà limitée à hotel_subscriptions)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_preview_expired_trials_processing()
RETURNS TABLE(
  hotel_id            uuid,
  hotel_name          text,
  subscription_id     uuid,
  current_status      text,
  trial_ends_at       timestamptz,
  days_since_expiry   numeric,
  theoretical_effect  text
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
    hs.hotel_id, h.name, hs.id, hs.status, hs.trial_ends_at,
    round(extract(epoch FROM (now() - hs.trial_ends_at)) / 86400.0, 1),
    format('Abonnement principal de %s → expired (essai dépassé)', h.name)::text
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  WHERE hs.status = 'trial' AND hs.trial_ends_at IS NOT NULL AND hs.trial_ends_at < now()
  ORDER BY h.name;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_preview_expired_trials_processing() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_preview_expired_trials_processing() TO authenticated;

-- ============================================================================
-- 2. process_expired_hotel_subscription_trials() — traitement dédié, hotel_subscriptions
--    uniquement. Reprend à l'identique la première boucle de process_expired_subscription_trials
--    (même prédicat que la prévisualisation ci-dessus : status='trial' AND trial_ends_at IS NOT
--    NULL AND trial_ends_at < now() — même table, même statut, même gestion du NULL, même
--    référence temporelle now()). FOR UPDATE SKIP LOCKED seul, comme l'original : ce traitement
--    n'agit que sur des lignes hotel_subscriptions déjà existantes, un verrou de ligne standard
--    suffit (même raisonnement qu'ADR-010 §2, inchangé, transposé à cette fonction plus étroite).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_expired_hotel_subscription_trials()
RETURNS TABLE(processed_subscriptions int, skipped_locked int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row        record;
  v_count_sub  int := 0;
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
        'trial_ends_at dépassé — traitement automatique par process_expired_hotel_subscription_trials'
      );
      PERFORM public._platform_log_system(
        'subscription_trial_expired', 'hotel_subscription', v_row.id::text, v_row.hotel_id, NULL,
        jsonb_build_object('trigger', 'process_expired_hotel_subscription_trials')
      );
      v_count_sub := v_count_sub + 1;
    END IF;
  END LOOP;

  -- v_skipped reste à 0 dans un run non concurrent (même limite assumée que l'original,
  -- ADR-010 §2) : conservé dans la signature de retour pour rendre visible, une fois deux
  -- exécutions réellement concurrentes, le nombre de lignes ignorées par SKIP LOCKED.
  RETURN QUERY SELECT v_count_sub, v_skipped;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_expired_hotel_subscription_trials() FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================
-- 3. admin_run_expired_trials_processing() — appelle désormais le traitement dédié
--    (section 2) au lieu de process_expired_subscription_trials() (sql/70, inchangée, non
--    supprimée, mais n'a plus aucun appelant après cette migration). Type de retour modifié
--    (retrait de processed_app_subscriptions) : DROP requis avant CREATE.
-- ============================================================================
DROP FUNCTION IF EXISTS public.admin_run_expired_trials_processing();

CREATE FUNCTION public.admin_run_expired_trials_processing()
RETURNS TABLE(processed_subscriptions int, skipped_locked int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  PERFORM public._platform_log('trial_processing.manual_trigger', 'system', 'manual', NULL, NULL, '{}'::jsonb);
  RETURN QUERY SELECT * FROM public.process_expired_hotel_subscription_trials();
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_run_expired_trials_processing() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_run_expired_trials_processing() TO authenticated;

-- Fin de migration. hotel_app_subscriptions n'est ni lue ni écrite par aucune fonction
-- accessible depuis le portail après cette migration. process_expired_subscription_trials()
-- (sql/70) reste en base intacte, orpheline (aucun appelant), non supprimée — sa suppression
-- relève d'une phase ultérieure d'ADR-011. Aucun job pg_cron créé ni activé. Aucune ligne
-- historique (dont Folkestone) modifiée par ce fichier.
