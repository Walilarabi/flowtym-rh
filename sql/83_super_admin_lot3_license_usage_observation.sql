-- ============================================================================
-- sql/83_super_admin_lot3_license_usage_observation.sql
-- Lot 3 — Licences en observation seule (ADR-012 §3.2)
--
-- Couche de MESURE et d'ALERTE uniquement. Aucun blocage fonctionnel, aucune
-- fonctionnalité hôtel désactivée automatiquement, aucune nouvelle table.
-- Ne touche jamais hotel_app_subscriptions (accès binaire par module, objet
-- distinct qui reste hors périmètre de ce lot).
--
-- Ajoute :
--   1) public.admin_list_license_usage() — consommation réelle vs quota
--      souscrit (snapshot_limits), par abonnement hôtel actif ou en essai.
--   2) Un type d'alerte supplémentaire 'license_quota_exceeded' dans
--      public.admin_platform_alerts() (CREATE OR REPLACE, fonction déjà
--      existante depuis sql/76).
--
-- CREATE OR REPLACE FUNCTION est par construction idempotent (remplace
-- atomiquement la définition, qu'elle soit absente ou déjà présente) : pas de
-- pattern trois-états à la sql/80 nécessaire ici, seule une création/mise à
-- jour additive de fonctions est en jeu (aucun objet de production existant
-- n'est rétro-versionné). Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, sans
-- méta-commande client — compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) admin_list_license_usage()
--
-- Source de calcul par dimension :
--   - rooms_used  : count(*) FROM public.rooms WHERE hotel_id = h.id AND active
--   - users_used  : count(DISTINCT uh.user_id) via public.user_hotels join
--                   public.users.is_active (même méthode que admin_list_user_access
--                   pour la notion d'« utilisateur actif rattaché à un hôtel »)
--   - quota       : hotel_subscriptions.snapshot_limits->>'max_rooms' /
--                   ->>'max_users' (photo figée au moment de la souscription,
--                   jamais recalculée a posteriori — cohérent avec la doctrine
--                   snapshot déjà en place pour le prix)
--
-- Statut par dimension (seuil d'alerte 90%, choix prudent documenté ADR-012,
-- non définitif — cf. §19 de l'instruction CTO, ne bloque pas la livraison) :
--   'unavailable'  quota IS NULL (legacy-pilot, ou abonnement sans plan choisi)
--   'exceeded'     used > quota
--   'approaching'  used >= 90% * quota (et used <= quota)
--   'ok'           sinon
--
-- date de fraîcheur exposée : snapshot_effective_at (date à laquelle ce quota
-- a été figé) + computed_at (horodatage du calcul de la consommation, toujours
-- "maintenant" car recalculé à la volée, jamais stocké — même doctrine que
-- admin_platform_overview_kpis).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_license_usage()
RETURNS TABLE(
  subscription_id uuid,
  hotel_id uuid,
  hotel_name text,
  group_id uuid,
  group_name text,
  subscription_status text,
  plan_slug text,
  plan_name text,
  snapshot_effective_at timestamptz,
  computed_at timestamptz,
  rooms_quota integer,
  rooms_used integer,
  rooms_pct numeric,
  rooms_status text,
  users_quota integer,
  users_used integer,
  users_pct numeric,
  users_status text
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_threshold_pct numeric := 90;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    hs.id AS subscription_id,
    h.id AS hotel_id,
    h.name AS hotel_name,
    h.group_id,
    hg.name AS group_name,
    hs.status AS subscription_status,
    hs.snapshot_plan_slug AS plan_slug,
    sp.name AS plan_name,
    hs.snapshot_effective_at,
    now() AS computed_at,
    (hs.snapshot_limits->>'max_rooms')::integer AS rooms_quota,
    ru.rooms_used,
    CASE WHEN (hs.snapshot_limits->>'max_rooms')::integer > 0
      THEN round(100.0 * ru.rooms_used / (hs.snapshot_limits->>'max_rooms')::integer, 1)
      ELSE NULL END AS rooms_pct,
    CASE
      WHEN hs.snapshot_limits IS NULL OR (hs.snapshot_limits->>'max_rooms') IS NULL THEN 'unavailable'
      WHEN ru.rooms_used > (hs.snapshot_limits->>'max_rooms')::integer THEN 'exceeded'
      WHEN (hs.snapshot_limits->>'max_rooms')::integer > 0
           AND ru.rooms_used >= v_threshold_pct / 100.0 * (hs.snapshot_limits->>'max_rooms')::integer THEN 'approaching'
      ELSE 'ok'
    END AS rooms_status,
    (hs.snapshot_limits->>'max_users')::integer AS users_quota,
    uu.users_used,
    CASE WHEN (hs.snapshot_limits->>'max_users')::integer > 0
      THEN round(100.0 * uu.users_used / (hs.snapshot_limits->>'max_users')::integer, 1)
      ELSE NULL END AS users_pct,
    CASE
      WHEN hs.snapshot_limits IS NULL OR (hs.snapshot_limits->>'max_users') IS NULL THEN 'unavailable'
      WHEN uu.users_used > (hs.snapshot_limits->>'max_users')::integer THEN 'exceeded'
      WHEN (hs.snapshot_limits->>'max_users')::integer > 0
           AND uu.users_used >= v_threshold_pct / 100.0 * (hs.snapshot_limits->>'max_users')::integer THEN 'approaching'
      ELSE 'ok'
    END AS users_status
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  LEFT JOIN public.subscription_plans sp ON sp.id = hs.plan_id
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS rooms_used
    FROM public.rooms r WHERE r.hotel_id = h.id AND r.active
  ) ru ON true
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT uh.user_id)::integer AS users_used
    FROM public.user_hotels uh
    JOIN public.users u ON u.id = uh.user_id
    WHERE uh.hotel_id = h.id AND u.is_active
  ) uu ON true
  WHERE hs.status IN ('trial', 'active')
  ORDER BY h.name;
END;
$function$;

-- Supabase accorde EXECUTE à anon/authenticated/service_role par défaut à la création d'une
-- fonction (default privileges du rôle postgres sur le schéma public) — révoqué explicitement
-- ici, exactement comme le fait sql/76 pour chaque RPC admin_* existante. Sans cette ligne,
-- anon aurait un accès EXECUTE au niveau grant (bloqué en pratique par le contrôle
-- is_platform_admin() interne à la fonction, mais sans la défense en profondeur attendue).
REVOKE ALL ON FUNCTION public.admin_list_license_usage() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_license_usage() TO authenticated;

-- ----------------------------------------------------------------------------
-- 2) admin_platform_alerts() — ajout du type 'license_quota_exceeded'
--
-- Redéfinition complète (CREATE OR REPLACE) reprenant à l'identique le corps
-- existant de sql/76, avec un seul UNION ALL supplémentaire à la fin. Même
-- prédicat de dépassement que admin_list_license_usage() ci-dessus (quota non
-- nul ET consommation strictement supérieure au quota), pour ne jamais
-- diverger entre l'écran de détail et la liste d'alertes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_platform_alerts()
 RETURNS TABLE(alert_type text, severity text, message text, entity_type text, entity_id text, entity_label text, hotel_id uuid, hotel_name text, group_id uuid, group_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  RETURN QUERY
  -- Essais expirant sous 7 jours
  SELECT 'trial_ending_soon', 'medium',
    'Essai se terminant le ' || to_char(hs.trial_ends_at, 'DD/MM/YYYY') || ' pour ' || h.name,
    'hotel_subscription', hs.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotel_subscriptions hs JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE hs.status = 'trial' AND hs.trial_ends_at IS NOT NULL
    AND hs.trial_ends_at BETWEEN now() AND now() + interval '7 days'

  UNION ALL
  -- Factures échues non réglées
  SELECT 'invoice_overdue', 'high',
    'Facture ' || coalesce(pi.number, '(proforma)') || ' en retard pour ' || h.name,
    'platform_invoice', pi.id::text, coalesce(pi.number, '(proforma)'), h.id, h.name, h.group_id, hg.name
  FROM public.platform_invoices pi
  JOIN public.hotels h ON h.id = pi.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  LEFT JOIN LATERAL (SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
    WHERE invoice_id = pi.id AND status = 'issued') cn ON true
  WHERE pi.status = 'issued' AND pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
    AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0

  UNION ALL
  -- Hôtel actif sans administrateur
  SELECT 'hotel_without_admin', 'high', 'Aucun administrateur actif pour ' || h.name,
    'hotel', h.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotels h LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE h.status = 'active' AND NOT EXISTS (
    SELECT 1 FROM public.user_hotels uh WHERE uh.hotel_id = h.id AND uh.role IN ('direction', 'admin_hotel')
  )

  UNION ALL
  -- Invitation non acceptée depuis plus de 14 jours
  SELECT 'invitation_stale', 'medium', 'Invitation de ' || u.email || ' toujours en attente depuis plus de 14 jours',
    'user', u.id::text, u.email, u.hotel_id, h.name, h.group_id, hg.name
  FROM public.users u
  JOIN auth.users au ON au.id = u.auth_id
  LEFT JOIN public.hotels h ON h.id = u.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE au.email_confirmed_at IS NULL AND au.invited_at IS NOT NULL AND au.invited_at < now() - interval '14 days'

  UNION ALL
  -- Abonnement suspendu
  SELECT 'subscription_suspended', 'high', 'Abonnement suspendu pour ' || h.name,
    'hotel_subscription', hs.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotel_subscriptions hs JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE hs.status = 'suspended'

  UNION ALL
  -- Abonnement sans plan du tout
  SELECT 'subscription_no_plan', 'medium', 'Abonnement sans plan associé pour ' || h.name,
    'hotel_subscription', hs.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotel_subscriptions hs JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE hs.status IN ('trial', 'active') AND hs.plan_id IS NULL

  UNION ALL
  -- Plan archivé encore attribué
  SELECT 'archived_plan_assigned', 'medium', 'Plan archivé (' || sp.name || ') toujours attribué à ' || h.name,
    'hotel_subscription', hs.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  JOIN public.subscription_plans sp ON sp.id = hs.plan_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE hs.status IN ('trial', 'active') AND sp.archived_at IS NOT NULL

  UNION ALL
  -- Hôtel actif sans aucun abonnement
  SELECT 'hotel_active_no_subscription', 'high', 'Hôtel actif sans abonnement : ' || h.name,
    'hotel', h.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotels h LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE h.status = 'active' AND NOT EXISTS (SELECT 1 FROM public.hotel_subscriptions hs WHERE hs.hotel_id = h.id)

  UNION ALL
  -- Utilisateur désactivé ayant encore des accès actifs
  SELECT 'deactivated_user_with_access', 'low', 'Utilisateur désactivé ' || u.email || ' possède encore des accès hôtel actifs',
    'user', u.id::text, u.email, u.hotel_id, h.name, h.group_id, hg.name
  FROM public.users u
  LEFT JOIN public.hotels h ON h.id = u.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE NOT u.is_active AND EXISTS (SELECT 1 FROM public.user_hotels uh WHERE uh.user_id = u.id)

  UNION ALL
  -- Lot 3 (ADR-012 §3.2) : quota de licence dépassé (mesure seule, aucun blocage)
  SELECT 'license_quota_exceeded', 'medium',
    'Quota ' || dim.label || ' dépassé pour ' || h.name || ' (' || dim.used || '/' || dim.quota || ')',
    'hotel_subscription', hs.id::text, h.name, h.id, h.name, h.group_id, hg.name
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  CROSS JOIN LATERAL (
    SELECT count(*)::integer AS rooms_used FROM public.rooms r WHERE r.hotel_id = h.id AND r.active
  ) ru
  CROSS JOIN LATERAL (
    SELECT count(DISTINCT uh.user_id)::integer AS users_used
    FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id
    WHERE uh.hotel_id = h.id AND u.is_active
  ) uu
  CROSS JOIN LATERAL (
    VALUES
      ('chambres', ru.rooms_used, (hs.snapshot_limits->>'max_rooms')::integer),
      ('utilisateurs', uu.users_used, (hs.snapshot_limits->>'max_users')::integer)
  ) AS dim(label, used, quota)
  WHERE hs.status IN ('trial', 'active')
    AND dim.quota IS NOT NULL AND dim.used > dim.quota;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_platform_alerts() TO authenticated;
