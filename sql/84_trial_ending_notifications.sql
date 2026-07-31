-- ============================================================================
-- sql/84_trial_ending_notifications.sql
-- Lot 4 — Notifications de fin de période d'essai J-7/J-3/J-1 (ADR-012 §3.3)
--
-- Dépend de Lot 2 (platform_notifications, sql/82).
--
-- Doctrine centrale (P0) : preview et exécution interrogent EXACTEMENT la même
-- requête. Concrètement : les deux RPC publiques ne font qu'itérer sur le même
-- helper interne _trial_ending_notification_candidates() — aucune logique
-- d'éligibilité n'est jamais dupliquée entre les deux.
--
-- Paliers : J-7, J-3, J-1 avant hotel_subscriptions.trial_ends_at, uniquement
-- pour les abonnements status='trial'. Un abonnement activé, suspendu, expiré
-- ou annulé (status <> 'trial') sort naturellement du prédicat.
--
-- Idempotence : dedupe_key = 'trial:<subscription_id>:<threshold_days>:<trial_ends_at
-- normalisé en date civile Europe/Paris>', UNIQUE sur platform_notifications.dedupe_key
-- (sql/82). Pas de renvoi après envoi réussi.
--
-- Écart assumé et documenté par rapport au format initial d'ADR-012 §3.3
-- ('trial:<subscription_id>:<threshold_days>', sans la date) : ce format initial
-- identifiait un PALIER PAR ABONNEMENT, jamais un cycle d'échéance réel — une
-- prolongation ou un raccourcissement de l'essai (hotel_subscriptions.trial_ends_at
-- modifié après un premier envoi) ne redonnait alors jamais lieu à un nouveau
-- J-7/J-3/J-1 pour la nouvelle date, ce qui contredit l'attente métier réelle
-- (revue de stabilisation CTO, item 10). La date d'échéance est intégrée à la clé,
-- normalisée sur le même calcul de jour civil Europe/Paris que days_remaining
-- ci-dessous (jamais un format de date différent, pour ne jamais diverger de la
-- fenêtre d'éligibilité elle-même) : un changement de trial_ends_at fait donc
-- naturellement réapparaître les paliers non encore notifiés pour la NOUVELLE
-- échéance, sans jamais renvoyer un palier déjà notifié pour une échéance
-- identique. La doctrine ADR-012 §3.3 doit être mise à jour en conséquence
-- (voir ADR-012 canonique, §9 — revue de stabilisation).
--
-- Déclenchement manuel uniquement — aucun cron. Le prédicat n'exige pas un
-- palier exact au jour près (days_remaining = threshold) mais days_remaining
-- <= threshold ET >= 0 : en l'absence de cron, un admin peut exécuter le
-- traitement plusieurs jours après qu'un palier a été franchi (ex. un
-- week-end) — le palier reste dû tant qu'il n'a pas été notifié. Décision
-- documentée : si plusieurs paliers sont franchis et non notifiés au moment
-- de l'exécution (ex. J-7 et J-3 le même jour), chacun génère sa propre
-- notification (paliers distincts, sémantique distincte), jamais fusionnés
-- silencieusement.
--
-- Comportement si la date d'essai change : la date d'échéance (normalisée en
-- jour civil Europe/Paris) fait partie de la clé d'idempotence — voir plus
-- haut. Une prolongation ou un raccourcissement de trial_ends_at change donc
-- le cycle identifié par la clé : les paliers déjà notifiés pour l'ANCIENNE
-- échéance restent des lignes historiques intactes (jamais supprimées, jamais
-- réutilisées), et les paliers dus pour la NOUVELLE échéance redeviennent
-- éligibles normalement — y compris un palier dont le NUMÉRO DE JOURS est
-- identique (ex. J-7 avant et après prolongation) mais dont la date réelle a
-- changé : la clé les distingue correctement, aucune confusion possible.
--
-- Fuseau : comparaison de dates calendaires en Europe/Paris (jour civil),
-- stockage strictement en UTC (timestamptz, comme le reste du schéma).
--
-- Destinataire : coalesce(hotels.billing_email, hotels.email) — même
-- convention que le module Facturation existant (admin.html, fiche facture).
-- Si aucun des deux n'est renseigné, le palier est signalé (preview) ou
-- ignoré et comptabilisé (run) plutôt que d'échouer silencieusement ou
-- d'envoyer à une adresse invalide.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._trial_ending_notification_candidates()
RETURNS TABLE(
  subscription_id uuid,
  hotel_id uuid,
  hotel_name text,
  trial_ends_at timestamptz,
  threshold_days integer,
  days_remaining integer,
  recipient_email text,
  dedupe_key text,
  already_sent boolean,
  notification_status text
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    hs.id AS subscription_id,
    h.id AS hotel_id,
    h.name AS hotel_name,
    hs.trial_ends_at,
    t.threshold_days,
    (((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date) - ((now() AT TIME ZONE 'Europe/Paris')::date))::integer AS days_remaining,
    coalesce(nullif(trim(h.billing_email), ''), nullif(trim(h.email), '')) AS recipient_email,
    'trial:' || hs.id::text || ':' || t.threshold_days::text || ':' || to_char((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date, 'YYYY-MM-DD') AS dedupe_key,
    EXISTS(
      SELECT 1 FROM public.platform_notifications pn
      WHERE pn.dedupe_key = 'trial:' || hs.id::text || ':' || t.threshold_days::text || ':' || to_char((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date, 'YYYY-MM-DD')
    ) AS already_sent,
    (
      SELECT pn.status FROM public.platform_notifications pn
      WHERE pn.dedupe_key = 'trial:' || hs.id::text || ':' || t.threshold_days::text || ':' || to_char((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date, 'YYYY-MM-DD')
    ) AS notification_status
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  CROSS JOIN (VALUES (7), (3), (1)) AS t(threshold_days)
  WHERE hs.status = 'trial'
    AND hs.trial_ends_at IS NOT NULL
    AND (((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date) - ((now() AT TIME ZONE 'Europe/Paris')::date)) <= t.threshold_days
    AND (((hs.trial_ends_at AT TIME ZONE 'Europe/Paris')::date) - ((now() AT TIME ZONE 'Europe/Paris')::date)) >= 0
  ORDER BY h.name, t.threshold_days DESC;
$function$;

-- Supabase accorde EXECUTE à anon/authenticated/service_role par défaut à la création d'une
-- fonction (default privileges du rôle postgres sur le schéma public) — révoqué explicitement
-- ici, exactement comme le fait sql/76 pour chaque RPC admin_* existante (ex.
-- admin_platform_alerts), et comme _platform_log : ce helper interne ne doit être appelable
-- que via les deux RPC publiques ci-dessous, jamais directement, même par authenticated.
REVOKE ALL ON FUNCTION public._trial_ending_notification_candidates() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_preview_trial_ending_notifications()
RETURNS TABLE(
  subscription_id uuid, hotel_id uuid, hotel_name text, trial_ends_at timestamptz,
  threshold_days integer, days_remaining integer, recipient_email text, dedupe_key text,
  already_sent boolean, would_send boolean, skip_reason text
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    c.subscription_id, c.hotel_id, c.hotel_name, c.trial_ends_at, c.threshold_days, c.days_remaining,
    c.recipient_email, c.dedupe_key, c.already_sent,
    (NOT c.already_sent AND c.recipient_email IS NOT NULL) AS would_send,
    CASE
      WHEN c.already_sent THEN 'Déjà envoyé (statut : ' || coalesce(c.notification_status, '?') || ')'
      WHEN c.recipient_email IS NULL THEN 'Aucun e-mail de contact (billing_email / email absents sur la fiche hôtel)'
      ELSE NULL
    END AS skip_reason
  FROM public._trial_ending_notification_candidates() c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_run_trial_ending_notifications()
RETURNS TABLE(sent_count integer, skipped_already_sent integer, skipped_no_email integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sent integer := 0;
  v_skipped_sent integer := 0;
  v_skipped_email integer := 0;
  v_rows integer;
  r record;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  FOR r IN SELECT * FROM public._trial_ending_notification_candidates() LOOP
    IF r.recipient_email IS NULL THEN
      v_skipped_email := v_skipped_email + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.platform_notifications
      (category, reference_type, reference_id, dedupe_key, recipient_email, template, template_payload)
    VALUES (
      'trial_ending', 'hotel_subscription', r.subscription_id, r.dedupe_key, r.recipient_email,
      'trial_ending_soon',
      jsonb_build_object(
        'hotel_name', r.hotel_name,
        'days_remaining', r.days_remaining,
        'trial_ends_at', to_char(r.trial_ends_at AT TIME ZONE 'Europe/Paris', 'DD/MM/YYYY')
      )
    )
    ON CONFLICT (dedupe_key) DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows = 1 THEN
      v_sent := v_sent + 1;
    ELSE
      -- Déjà envoyé (par un run précédent, ou par un appel concurrent gagnant la course
      -- ON CONFLICT DO NOTHING pendant cette même boucle) — jamais compté comme un échec.
      v_skipped_sent := v_skipped_sent + 1;
    END IF;
  END LOOP;

  PERFORM public._platform_log(
    'trial_ending_notifications.manual_trigger', 'system', 'manual', NULL, NULL,
    jsonb_build_object('sent', v_sent, 'skipped_already_sent', v_skipped_sent, 'skipped_no_email', v_skipped_email)
  );

  RETURN QUERY SELECT v_sent, v_skipped_sent, v_skipped_email;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_preview_trial_ending_notifications() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_preview_trial_ending_notifications() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_run_trial_ending_notifications() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_run_trial_ending_notifications() TO authenticated;
