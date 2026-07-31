-- ============================================================================
-- sql/89_super_admin_license_usage_single_source_of_truth.sql
-- Réconciliation Lot 3 / Lot 6 — source unique de calcul quota/consommation
-- de licences (ADR-012 §3.2/§6)
--
-- Dépend de sql/83 (Lot 3 — admin_list_license_usage, admin_platform_alerts
-- avec le type 'license_quota_exceeded') ET de sql/87 (Lot 6 —
-- admin_platform_statistics, _hotel_health_subscores, _hotel_license_usage_
-- rows). Doit être appliqué APRÈS ces deux migrations, quel que soit l'ordre
-- de fusion effectif entre elles.
--
-- Constat (documenté dans les deux fichiers d'origine) : le calcul quota vs
-- consommation (rooms.active, user_hotels/users.is_active, hotel_subscriptions.
-- snapshot_limits, seuil 90%) était dupliqué à l'identique dans QUATRE
-- endroits, écrits sur des branches indépendantes qui ne pouvaient pas
-- s'appeler entre elles au moment de leur rédaction :
--   1) admin_list_license_usage()          (sql/83, Lot 3 — écran Licences)
--   2) admin_platform_alerts()             (sql/83, Lot 3 — alerte
--                                           license_quota_exceeded)
--   3) admin_platform_statistics()         (sql/87, Lot 6 — via l'ancien
--                                           _hotel_license_usage_rows())
--   4) _hotel_health_subscores()           (sql/87, Lot 6 — sous-score
--                                           licences, via le même ancien
--                                           helper)
--
-- Cette migration :
--   A. Crée public._hotel_license_usage_snapshot() — l'unique source de
--      calcul (quota, consommation, pourcentage, statut par dimension,
--      date de fraîcheur). Jamais exécutable directement par anon/
--      authenticated/service_role (aucun GRANT EXECUTE émis).
--   B. Redéfinit (CREATE OR REPLACE, signature strictement inchangée) les
--      quatre consommateurs pour qu'ils lisent tous ce même helper, sans
--      aucune divergence de logique possible entre eux.
--   C. Supprime l'ancien helper dupliqué _hotel_license_usage_rows() (Lot 6),
--      devenu inutile.
--
-- CREATE OR REPLACE FUNCTION est par construction idempotent (remplace
-- atomiquement la définition) : pas de doctrine trois états nécessaire ici,
-- aucun objet de production existant n'est rétro-versionné (uniquement des
-- fonctions, jamais des tables). Pas de BEGIN/COMMIT/ROLLBACK. SQL pur,
-- compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A) Source unique — reprend exactement le corps de admin_list_license_usage()
--    (sql/83), sans le contrôle is_platform_admin() (délégué à l'appelant :
--    ce helper n'est jamais exposé directement).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._hotel_license_usage_snapshot()
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
  WHERE hs.status IN ('trial', 'active');
END;
$function$;

-- Helper strictement interne : aucun GRANT EXECUTE, y compris pour service_role
-- (contrairement aux tables Storage/notifications, il n'y a ici aucun besoin d'un
-- accès service_role — seuls les 4 RPC SECURITY DEFINER ci-dessous l'appellent, en
-- tant que propriétaire de la fonction, qui bypasse les grants par construction).
REVOKE ALL ON FUNCTION public._hotel_license_usage_snapshot() FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- B.1) admin_list_license_usage() — délègue entièrement au helper.
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
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public._hotel_license_usage_snapshot() ORDER BY hotel_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_license_usage() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_license_usage() TO authenticated;

-- ----------------------------------------------------------------------------
-- B.2) admin_platform_alerts() — corps identique à sql/83, seule la branche
--      license_quota_exceeded change de source (helper au lieu de recalcul).
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
  -- Lot 3 (ADR-012 §3.2) : quota de licence dépassé (mesure seule, aucun blocage).
  -- Source unique : _hotel_license_usage_snapshot(), jamais recalculé ici.
  SELECT 'license_quota_exceeded', 'medium',
    'Quota ' || dim.label || ' dépassé pour ' || s.hotel_name || ' (' || dim.used || '/' || dim.quota || ')',
    'hotel_subscription', s.subscription_id::text, s.hotel_name, s.hotel_id, s.hotel_name, s.group_id, s.group_name
  FROM public._hotel_license_usage_snapshot() s
  CROSS JOIN LATERAL (
    VALUES
      ('chambres', s.rooms_used, s.rooms_quota, s.rooms_status),
      ('utilisateurs', s.users_used, s.users_quota, s.users_status)
  ) AS dim(label, used, quota, status)
  WHERE dim.status = 'exceeded';
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_platform_alerts() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_platform_alerts() TO authenticated;

-- ----------------------------------------------------------------------------
-- B.3) admin_platform_statistics() — corps identique à sql/87, seul le calcul
--      v_license_summary change de source.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_platform_statistics()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_hotels jsonb;
  v_users jsonb;
  v_trial_conversion jsonb;
  v_license_summary jsonb;
  v_support jsonb;
  v_revenue jsonb;
  v_recent_activity jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT jsonb_build_object(
    'total', count(*),
    'active', count(*) FILTER (WHERE h.status = 'active'),
    'suspended', count(*) FILTER (WHERE h.status = 'suspended'),
    'archived', count(*) FILTER (WHERE h.status = 'archived'),
    'draft', count(*) FILTER (WHERE h.status = 'draft'),
    'trial_subscriptions', (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'trial')
  ) INTO v_hotels
  FROM public.hotels h;

  SELECT jsonb_build_object(
    'total', count(*),
    'active', count(*) FILTER (WHERE u.is_active)
  ) INTO v_users
  FROM public.users u;

  v_trial_conversion := jsonb_build_object(
    'available', false,
    'reason', 'Aucun événement de conversion organique essai->payant dans hotel_subscription_events à ce jour (les abonnements actifs proviennent tous d''une régularisation Legacy Pilot, pas d''une conversion réelle) — afficher un taux ici fabriquerait une performance commerciale inexistante.'
  );

  SELECT jsonb_build_object(
    'ok', count(*) FILTER (WHERE rooms_status = 'ok' AND users_status = 'ok'),
    'approaching', count(*) FILTER (WHERE rooms_status = 'approaching' OR users_status = 'approaching'),
    'exceeded', count(*) FILTER (WHERE rooms_status = 'exceeded' OR users_status = 'exceeded'),
    'unavailable', count(*) FILTER (WHERE rooms_status = 'unavailable' AND users_status = 'unavailable')
  ) INTO v_license_summary
  FROM public._hotel_license_usage_snapshot();

  SELECT jsonb_build_object(
    'total', count(*),
    'open', count(*) FILTER (WHERE st.status NOT IN ('resolu', 'ferme')),
    'by_priority', coalesce((SELECT jsonb_object_agg(priority, cnt) FROM (
      SELECT st2.priority, count(*) AS cnt FROM public.support_tickets st2
      WHERE st2.status NOT IN ('resolu', 'ferme') GROUP BY st2.priority
    ) p), '{}'::jsonb),
    'by_module', coalesce((SELECT jsonb_object_agg(module, cnt) FROM (
      SELECT st3.module, count(*) AS cnt FROM public.support_tickets st3
      WHERE st3.status NOT IN ('resolu', 'ferme') GROUP BY st3.module
    ) m), '{}'::jsonb),
    'avg_resolution_hours', (
      SELECT round(avg(extract(epoch FROM (st4.updated_at - st4.created_at)) / 3600.0)::numeric, 1)
      FROM public.support_tickets st4 WHERE st4.status IN ('resolu', 'ferme')
    )
  ) INTO v_support
  FROM public.support_tickets st;

  SELECT jsonb_build_object(
    'available', true,
    'mrr', coalesce(sum(hs.snapshot_price_net_ht) FILTER (WHERE hs.status = 'active'), 0),
    'arr', coalesce(sum(hs.snapshot_price_net_ht) FILTER (WHERE hs.status = 'active'), 0) * 12,
    'currency', 'EUR',
    'active_subscriptions_counted', count(*) FILTER (WHERE hs.status = 'active' AND hs.snapshot_price_net_ht IS NOT NULL),
    'active_subscriptions_excluded_missing_price', count(*) FILTER (WHERE hs.status = 'active' AND hs.snapshot_price_net_ht IS NULL),
    'note', 'MRR calculé uniquement sur les abonnements au statut ''active'' (jamais les essais). Les 4 abonnements actifs de production sont au tarif Legacy Pilot (0 €, régularisation Phase 2A documentée dans ADR-010) — le MRR réel est donc 0 € aujourd''hui, ce n''est pas une donnée manquante.'
  ) INTO v_revenue
  FROM public.hotel_subscriptions hs;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'action', l.action, 'entity', l.entity, 'hotel_name', l.hotel_name,
    'admin_email', l.admin_email, 'created_at', l.created_at
  ) ORDER BY l.created_at DESC), '[]'::jsonb)
  INTO v_recent_activity
  FROM (SELECT * FROM public.platform_logs ORDER BY created_at DESC LIMIT 10) l;

  RETURN jsonb_build_object(
    'hotels', v_hotels, 'users', v_users, 'trial_conversion', v_trial_conversion,
    'licenses', v_license_summary, 'support', v_support, 'revenue', v_revenue,
    'recent_activity', v_recent_activity, 'computed_at', now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_platform_statistics() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_platform_statistics() TO authenticated;

-- ----------------------------------------------------------------------------
-- B.4) _hotel_health_subscores(hotel_id) — corps identique à sql/87, seule la
--      section « Licences » change de source.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._hotel_health_subscores(p_hotel_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub public.hotel_subscriptions;
  v_apps_in_scope int := 0;
  v_apps_adopted int := 0;
  v_active_users int := 0;
  v_active_users_signed_in_30d int := 0;
  v_rooms_status text; v_users_status text;
  v_license_score numeric; v_license_available boolean := true;
  v_open_tickets_count int; v_ticket_penalty numeric := 0;
  v_support_score numeric; v_support_available boolean;
  v_has_invoice boolean;
  v_adoption jsonb; v_activity jsonb; v_licenses jsonb; v_support jsonb; v_payment jsonb; v_retention jsonb;
  v_composite numeric; v_weight_sum numeric := 0; v_weighted_sum numeric := 0;
  v_weights jsonb := '{"adoption":20,"activity":20,"licenses":20,"support":15,"retention":15,"payment":10}'::jsonb;
  v_excluded jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE hotel_id = p_hotel_id ORDER BY created_at DESC LIMIT 1;

  IF v_sub.id IS NOT NULL AND v_sub.status IN ('trial', 'active') THEN
    SELECT count(DISTINCT pa.id) INTO v_apps_in_scope
    FROM public.plan_modules pm JOIN public.platform_apps pa ON pa.id = pm.app_id
    WHERE pm.plan_id = v_sub.plan_id AND pm.is_active;

    SELECT count(DISTINCT pa.id) INTO v_apps_adopted
    FROM public.plan_modules pm
    JOIN public.platform_apps pa ON pa.id = pm.app_id
    JOIN public.user_app_access uaa ON uaa.app_id = pa.id AND uaa.hotel_id = p_hotel_id
    JOIN public.users u ON u.id = uaa.user_id AND u.is_active
    WHERE pm.plan_id = v_sub.plan_id AND pm.is_active;
  END IF;
  IF v_apps_in_scope > 0 THEN
    v_adoption := jsonb_build_object(
      'available', true, 'value', round(100.0 * v_apps_adopted / v_apps_in_scope, 1),
      'definition', 'Part des applications incluses dans le plan souscrit disposant d''au moins un accès individuel actif (user_app_access) à un utilisateur actif de l''hôtel.',
      'source', 'plan_modules, platform_apps, user_app_access, users.is_active',
      'period', 'Instantané (aucun historique d''adoption disponible aujourd''hui)', 'weight', 20
    );
  ELSE
    v_adoption := jsonb_build_object('available', false,
      'reason', 'Aucun abonnement trial/active avec au moins une application incluse dans le plan.',
      'definition', 'Part des applications incluses dans le plan souscrit disposant d''au moins un accès individuel actif.',
      'source', 'plan_modules, platform_apps, user_app_access, users.is_active', 'weight', 20);
  END IF;

  SELECT count(*) INTO v_active_users
  FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id
  WHERE uh.hotel_id = p_hotel_id AND u.is_active;

  SELECT count(*) INTO v_active_users_signed_in_30d
  FROM public.user_hotels uh
  JOIN public.users u ON u.id = uh.user_id
  JOIN auth.users au ON au.id = u.auth_id
  WHERE uh.hotel_id = p_hotel_id AND u.is_active AND au.last_sign_in_at > now() - interval '30 days';

  IF v_active_users > 0 THEN
    v_activity := jsonb_build_object(
      'available', true, 'value', round(100.0 * v_active_users_signed_in_30d / v_active_users, 1),
      'definition', 'Part des utilisateurs actifs de l''hôtel connectés au moins une fois (auth.users.last_sign_in_at) au cours des 30 derniers jours.',
      'source', 'user_hotels, users.is_active, auth.users.last_sign_in_at', 'period', '30 jours glissants', 'weight', 20
    );
  ELSE
    v_activity := jsonb_build_object('available', false,
      'reason', 'Aucun utilisateur actif rattaché à cet hôtel.',
      'definition', 'Part des utilisateurs actifs connectés au cours des 30 derniers jours.',
      'source', 'user_hotels, users.is_active, auth.users.last_sign_in_at', 'weight', 20);
  END IF;

  -- ---- Licences : pire des deux dimensions (chambres/utilisateurs), source unique.
  SELECT rooms_status, users_status INTO v_rooms_status, v_users_status
  FROM public._hotel_license_usage_snapshot() WHERE hotel_id = p_hotel_id;
  IF v_rooms_status IS NULL THEN
    v_licenses := jsonb_build_object('available', false, 'reason', 'Aucun abonnement trial/active pour cet hôtel.',
      'definition', 'Pire des deux statuts de quota (chambres, utilisateurs) vs consommation réelle.',
      'source', 'hotel_subscriptions.snapshot_limits, rooms.active, user_hotels/users.is_active', 'weight', 20);
  ELSE
    v_license_score := least(
      CASE v_rooms_status WHEN 'ok' THEN 100 WHEN 'approaching' THEN 60 WHEN 'exceeded' THEN 10 ELSE NULL END,
      CASE v_users_status WHEN 'ok' THEN 100 WHEN 'approaching' THEN 60 WHEN 'exceeded' THEN 10 ELSE NULL END
    );
    IF v_license_score IS NULL THEN
      v_licenses := jsonb_build_object('available', false, 'reason', 'Quota non chiffré pour cet abonnement (snapshot_limits sans max_rooms/max_users).',
        'definition', 'Pire des deux statuts de quota (chambres, utilisateurs) vs consommation réelle.',
        'source', 'hotel_subscriptions.snapshot_limits, rooms.active, user_hotels/users.is_active', 'weight', 20);
    ELSE
      v_licenses := jsonb_build_object('available', true, 'value', v_license_score,
        'definition', 'Pire des deux statuts de quota (chambres, utilisateurs) vs consommation réelle (100=ok, 60=proche du seuil 90%, 10=dépassé).',
        'source', 'hotel_subscriptions.snapshot_limits, rooms.active, user_hotels/users.is_active',
        'period', 'Instantané (quota figé à la souscription, consommation recalculée à la volée)', 'weight', 20,
        'rooms_status', v_rooms_status, 'users_status', v_users_status);
    END IF;
  END IF;

  SELECT count(*) INTO v_open_tickets_count FROM public.support_tickets WHERE hotel_id = p_hotel_id;
  IF v_open_tickets_count = 0 THEN
    v_support := jsonb_build_object('available', false,
      'reason', 'Aucun ticket Support historisé pour cet hôtel — pas assez d''historique pour un score significatif (fonctionnalité récemment livrée).',
      'definition', '100 moins une pénalité par ticket ouvert selon sa priorité (bloquant -40, élevé -20, moyen -10, faible -5), plancher 0.',
      'source', 'support_tickets', 'weight', 15);
  ELSE
    SELECT coalesce(sum(CASE priority WHEN 'bloquant' THEN 40 WHEN 'eleve' THEN 20 WHEN 'moyen' THEN 10 WHEN 'faible' THEN 5 ELSE 10 END), 0)
      INTO v_ticket_penalty
    FROM public.support_tickets WHERE hotel_id = p_hotel_id AND status NOT IN ('resolu', 'ferme');
    v_support := jsonb_build_object('available', true, 'value', greatest(0, 100 - v_ticket_penalty),
      'definition', '100 moins une pénalité par ticket ouvert selon sa priorité (bloquant -40, élevé -20, moyen -10, faible -5), plancher 0. Pondération provisoire, non définitive (cf. ADR-012).',
      'source', 'support_tickets', 'period', 'Tickets ouverts au moment du calcul', 'weight', 15);
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.platform_invoices WHERE hotel_id = p_hotel_id) INTO v_has_invoice;
  IF NOT v_has_invoice THEN
    v_payment := jsonb_build_object('available', false,
      'reason', 'Aucune facture plateforme enregistrée pour cet hôtel à ce jour (platform_invoices vide en production) — exclu du score composite, jamais neutralisé à une valeur par défaut.',
      'definition', 'Part des factures émises payées à échéance sur les 6 derniers mois.',
      'source', 'platform_invoices', 'weight', 10);
    v_excluded := v_excluded || '"payment"'::jsonb;
  ELSE
    SELECT jsonb_build_object('available', true,
      'value', round(100.0 * count(*) FILTER (WHERE status = 'paid' AND (due_date IS NULL OR paid_at <= due_date + interval '1 day'))
                     / greatest(count(*) FILTER (WHERE status IN ('paid', 'issued')), 1), 1),
      'definition', 'Part des factures émises payées à échéance (+1 jour de tolérance) sur les 6 derniers mois.',
      'source', 'platform_invoices', 'period', '6 derniers mois', 'weight', 10)
    INTO v_payment
    FROM public.platform_invoices WHERE hotel_id = p_hotel_id AND created_at > now() - interval '6 months';
  END IF;

  IF v_sub.id IS NULL THEN
    v_retention := jsonb_build_object('available', false, 'reason', 'Aucun abonnement pour cet hôtel.',
      'definition', 'Ancienneté de l''abonnement sans annulation (0 si annulé, sinon 40 + 1 point par ~3 jours d''ancienneté, plafonné à 100).',
      'source', 'hotel_subscriptions.status, hotel_subscriptions.created_at', 'weight', 15);
  ELSIF v_sub.status = 'cancelled' THEN
    v_retention := jsonb_build_object('available', true, 'value', 0,
      'definition', 'Ancienneté de l''abonnement sans annulation (0 si annulé, sinon 40 + 1 point par ~3 jours d''ancienneté, plafonné à 100).',
      'source', 'hotel_subscriptions.status, hotel_subscriptions.created_at', 'period', 'Depuis la souscription', 'weight', 15);
  ELSE
    v_retention := jsonb_build_object('available', true,
      'value', least(100, 40 + extract(day FROM now() - v_sub.created_at) / 3.0)::int,
      'definition', 'Ancienneté de l''abonnement sans annulation (0 si annulé, sinon 40 + 1 point par ~3 jours d''ancienneté, plafonné à 100). Pondération provisoire (cf. ADR-012).',
      'source', 'hotel_subscriptions.status, hotel_subscriptions.created_at', 'period', 'Depuis la souscription', 'weight', 15);
  END IF;

  IF (v_adoption->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_adoption->>'value')::numeric * (v_weights->>'adoption')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'adoption')::numeric; ELSE v_excluded := v_excluded || '"adoption"'::jsonb; END IF;
  IF (v_activity->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_activity->>'value')::numeric * (v_weights->>'activity')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'activity')::numeric; ELSE v_excluded := v_excluded || '"activity"'::jsonb; END IF;
  IF (v_licenses->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_licenses->>'value')::numeric * (v_weights->>'licenses')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'licenses')::numeric; ELSE v_excluded := v_excluded || '"licenses"'::jsonb; END IF;
  IF (v_support->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_support->>'value')::numeric * (v_weights->>'support')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'support')::numeric; ELSE v_excluded := v_excluded || '"support"'::jsonb; END IF;
  IF (v_payment->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_payment->>'value')::numeric * (v_weights->>'payment')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'payment')::numeric; END IF;
  IF (v_retention->>'available')::boolean THEN v_weighted_sum := v_weighted_sum + (v_retention->>'value')::numeric * (v_weights->>'retention')::numeric; v_weight_sum := v_weight_sum + (v_weights->>'retention')::numeric; ELSE v_excluded := v_excluded || '"retention"'::jsonb; END IF;

  IF v_weight_sum > 0 THEN v_composite := round(v_weighted_sum / v_weight_sum, 1); END IF;

  RETURN jsonb_build_object(
    'adoption', v_adoption, 'activity', v_activity, 'licenses', v_licenses,
    'support', v_support, 'payment', v_payment, 'retention', v_retention,
    'composite', jsonb_build_object(
      'value', v_composite, 'excluded_subscores', v_excluded,
      'weights_provisional', true,
      'note', 'Pondération provisoire (ADR-012, non une vérité métier définitive). Moyenne pondérée des seuls sous-scores disponibles ; les sous-scores exclus (données manquantes) ne sont jamais neutralisés à une valeur par défaut.'
    ),
    'computed_at', now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._hotel_health_subscores(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- C) Suppression de l'ancien helper dupliqué (Lot 6), devenu inutile — plus
--    aucun appelant après B.3/B.4 ci-dessus.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public._hotel_license_usage_rows();
