-- 79_super_admin_p0_trial_app_access_coherence.sql
-- P0 — Sécurisation du traitement des essais expirés (prévisualisation).
--
-- Historique de ce fichier : sa première version synchronisait hotel_subscriptions et
-- hotel_app_subscriptions dans admin_extend_trial() et ajoutait admin_sync_app_trial_dates()
-- pour régulariser Folkestone. Décision CTO (étude de dépréciation, cf. ADR-011
-- "Plan de dépréciation de hotel_app_subscriptions") : hotel_app_subscriptions est un
-- composant legacy en fin de vie, dont la dépréciation est désormais planifiée séparément.
-- Plus aucune logique métier ne doit être ajoutée sur cette table dans l'intervalle — la
-- synchronisation aurait été un mécanisme transitoire de plus à retirer lors de la
-- dépréciation, pour un bénéfice déjà nul aujourd'hui (hotel_app_subscriptions n'est
-- consultée par aucune policy RLS, vue, trigger ni code applicatif réel — cf. ADR-011 §1).
-- Cette version ne touche donc plus du tout hotel_app_subscriptions, ni en lecture ni en
-- écriture : admin_extend_trial() reste strictement inchangée (sql/70), et
-- admin_sync_app_trial_dates() n'est pas créée.
--
-- Ce qui reste, strictement indépendant de hotel_app_subscriptions :
--   admin_preview_expired_trials_processing() — nouvelle RPC strictement en lecture seule
--   (aucun INSERT/UPDATE/DELETE/log), qui prévisualise l'effet de "Traiter les essais
--   expirés" sur les abonnements principaux (hotel_subscriptions) avant confirmation.
--
-- Portée résiduelle assumée : process_expired_subscription_trials() (sql/70, inchangée)
-- continue de traiter aussi hotel_app_subscriptions sous le capot — cette prévisualisation ne
-- couvre donc que l'abonnement principal, pas ce second effet legacy. Combler cet écart
-- reviendrait à ajouter une dépendance métier de plus à une table en cours de dépréciation ;
-- l'écart disparaîtra de lui-même une fois le moteur legacy retiré (cf. ADR-011), sans qu'il
-- soit nécessaire d'y toucher ici.

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

-- Fin de migration. Aucune donnée existante modifiée. Aucune écriture ni lecture ajoutée sur
-- hotel_app_subscriptions. Aucun job pg_cron créé ni activé.
