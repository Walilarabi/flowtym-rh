-- ============================================================================
-- sql/87_super_admin_lot6_statistics_health_score.sql
-- Lot 6 — Statistiques Super Admin + score de santé client/hôtel (ADR-012 §6)
--
-- Strictement séparé de la supervision technique de la plateforme
-- (admin_supervision_status, sql/76) : ce lot ne mesure QUE des signaux
-- métier/client (adoption, activité, licences, support, paiement, rétention),
-- jamais l'état de la base/du déploiement.
--
-- Ajoute :
--   1) public.admin_platform_statistics() — statistiques agrégées (hôtels,
--      utilisateurs, licences, support, MRR/ARR, activité récente).
--   2) public._hotel_health_subscores(hotel_id) — calcul interne des 6
--      sous-scores d'un hôtel (jamais appelable directement par un rôle
--      autre que le propriétaire de la fonction).
--   3) public.admin_hotel_health_scores() — expose le détail par hôtel
--      (jamais une seule note globale sans explication).
--
-- Doctrine anti-fabrication (respectée strictement, vérifiée sur données
-- réelles de production avant écriture de ce fichier) :
--   - MRR/ARR : calculé sur hotel_subscriptions.snapshot_price_net_ht (seule
--     source contractuelle fiable — platform_invoices est VIDE en production
--     au moment de ce lot, vérifié par COUNT(*) = 0). 9 abonnements 'trial'/
--     'active' sur 10 ont un prix figé ; le seul NULL (Folkestone, cas déjà
--     tranché en Phase 2A) est explicitement exclu et compté à part, jamais
--     traité comme 0€. Les 4 abonnements 'active' ont un prix figé à 0€ —
--     ce n'est PAS une donnée manquante, c'est l'arrangement Legacy Pilot
--     réel (ADR-010) : le MRR calculé aujourd'hui est donc réellement 0€,
--     affiché comme tel avec l'explication, jamais masqué.
--   - Conversion essai -> abonnement payant : NON affichée. Vérifié sur
--     hotel_subscription_events (event_type réels : 'created', 'trial_extended',
--     'regularized_legacy') qu'AUCUN événement de conversion organique
--     n'existe à ce jour — les 4 abonnements 'active' proviennent tous d'une
--     régularisation Legacy Pilot (Phase 2A), jamais d'un vrai passage
--     essai->payant. Afficher un taux ici fabriquerait une performance
--     commerciale inexistante. Champ renvoyé avec available=false et motif
--     explicite plutôt qu'un taux (ex. 0% ou 67%) trompeur.
--   - Support : sur 0 ticket réel en production au moment de ce lot (Lot 5
--     vient d'être livré) — les compteurs sont correctement à 0, jamais simulés.
--   - Score de santé "paiement" : platform_invoices vide -> available=false
--     pour tous les hôtels aujourd'hui, exclu du composite (jamais neutralisé
--     à une valeur par défaut). Redevient automatiquement disponible dès que
--     de vraies factures existent (logique jamais codée en dur sur "false").
--
-- Licences (sous-score) : redérive volontairement la même logique quota/
-- consommation que public.admin_list_license_usage() (Lot 3, sql/83) plutôt
-- que d'appeler cette RPC directement — les deux migrations évoluent sur des
-- branches encore indépendantes à ce stade de la Phase 2 ; la duplication
-- (même source de calcul : rooms.active, user_hotels/users.is_active,
-- snapshot_limits) est documentée ici et devra être supprimée au profit d'un
-- helper commun lors de la fusion finale des lots (voir ADR-012).
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) admin_platform_statistics() — vue d'ensemble chiffrée, jamais fabriquée.
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
    -- "Essai" est un statut commercial (hotel_subscriptions.status), jamais une 5e valeur de
    -- hotels.status (doctrine ADR-010 déjà établie en Phase 2A) — recompté séparément ici.
    'trial_subscriptions', (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'trial')
  ) INTO v_hotels
  FROM public.hotels h;

  SELECT jsonb_build_object(
    'total', count(*),
    'active', count(*) FILTER (WHERE u.is_active)
  ) INTO v_users
  FROM public.users u;

  -- Conversion essai -> payant : voir en-tête de fichier. Non fabriquée.
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
  FROM public._hotel_license_usage_rows();

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

  -- MRR/ARR : voir en-tête de fichier pour la justification complète.
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
-- Helper interne partagé : lignes quota/consommation par abonnement, même
-- calcul que admin_list_license_usage() (Lot 3) — voir en-tête de fichier.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._hotel_license_usage_rows()
RETURNS TABLE(hotel_id uuid, rooms_status text, users_status text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_threshold_pct numeric := 90;
BEGIN
  RETURN QUERY
  SELECT
    h.id,
    CASE
      WHEN hs.snapshot_limits IS NULL OR (hs.snapshot_limits->>'max_rooms') IS NULL THEN 'unavailable'
      WHEN ru.rooms_used > (hs.snapshot_limits->>'max_rooms')::integer THEN 'exceeded'
      WHEN (hs.snapshot_limits->>'max_rooms')::integer > 0
           AND ru.rooms_used >= v_threshold_pct / 100.0 * (hs.snapshot_limits->>'max_rooms')::integer THEN 'approaching'
      ELSE 'ok'
    END,
    CASE
      WHEN hs.snapshot_limits IS NULL OR (hs.snapshot_limits->>'max_users') IS NULL THEN 'unavailable'
      WHEN uu.users_used > (hs.snapshot_limits->>'max_users')::integer THEN 'exceeded'
      WHEN (hs.snapshot_limits->>'max_users')::integer > 0
           AND uu.users_used >= v_threshold_pct / 100.0 * (hs.snapshot_limits->>'max_users')::integer THEN 'approaching'
      ELSE 'ok'
    END
  FROM public.hotel_subscriptions hs
  JOIN public.hotels h ON h.id = hs.hotel_id
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS rooms_used FROM public.rooms r WHERE r.hotel_id = h.id AND r.active
  ) ru ON true
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT uh.user_id)::integer AS users_used
    FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id
    WHERE uh.hotel_id = h.id AND u.is_active
  ) uu ON true
  WHERE hs.status IN ('trial', 'active');
END;
$function$;

REVOKE ALL ON FUNCTION public._hotel_license_usage_rows() FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2) _hotel_health_subscores(hotel_id) — les 6 sous-scores, chacun avec
--    définition/source/période/pondération/fraîcheur/disponibilité. Jamais un
--    score par défaut quand la donnée manque : available=false, valeur NULL.
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
  -- Abonnement le plus récent (statut quelconque) : sert de référence pour licences/rétention.
  SELECT * INTO v_sub FROM public.hotel_subscriptions WHERE hotel_id = p_hotel_id ORDER BY created_at DESC LIMIT 1;

  -- ---- Adoption : apps du plan/add-ons actifs réellement utilisées par >=1 utilisateur actif.
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

  -- ---- Activité : % d'utilisateurs actifs de l'hôtel connectés (auth réel) sous 30 jours.
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

  -- ---- Licences : pire des deux dimensions (chambres/utilisateurs), même méthode que sql/83.
  SELECT rooms_status, users_status INTO v_rooms_status, v_users_status
  FROM public._hotel_license_usage_rows() WHERE hotel_id = p_hotel_id;
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
      -- Les deux dimensions sont 'unavailable' (snapshot_limits sans quota chiffré, ex. Legacy Pilot).
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

  -- ---- Support : nécessite un historique réel (>= 1 ticket) pour être significatif.
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

  -- ---- Paiement : disponible seulement si des factures réelles existent pour cet hôtel.
  SELECT EXISTS(SELECT 1 FROM public.platform_invoices WHERE hotel_id = p_hotel_id) INTO v_has_invoice;
  IF NOT v_has_invoice THEN
    v_payment := jsonb_build_object('available', false,
      'reason', 'Aucune facture plateforme enregistrée pour cet hôtel à ce jour (platform_invoices vide en production) — exclu du score composite, jamais neutralisé à une valeur par défaut.',
      'definition', 'Part des factures émises payées à échéance sur les 6 derniers mois.',
      'source', 'platform_invoices', 'weight', 10);
    v_excluded := v_excluded || '"payment"'::jsonb;
  ELSE
    -- Redevient automatiquement calculable dès que de vraies factures existent (non atteint en Phase 2).
    SELECT jsonb_build_object('available', true,
      'value', round(100.0 * count(*) FILTER (WHERE status = 'paid' AND (due_date IS NULL OR paid_at <= due_date + interval '1 day'))
                     / greatest(count(*) FILTER (WHERE status IN ('paid', 'issued')), 1), 1),
      'definition', 'Part des factures émises payées à échéance (+1 jour de tolérance) sur les 6 derniers mois.',
      'source', 'platform_invoices', 'period', '6 derniers mois', 'weight', 10)
    INTO v_payment
    FROM public.platform_invoices WHERE hotel_id = p_hotel_id AND created_at > now() - interval '6 months';
  END IF;

  -- ---- Rétention : ancienneté sans annulation, sur l'abonnement le plus récent.
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

  -- ---- Composite : moyenne pondérée des SEULS sous-scores disponibles, poids renormalisés.
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
-- 3) admin_hotel_health_scores() — expose le détail complet par hôtel.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hotel_health_scores()
RETURNS TABLE(hotel_id uuid, hotel_name text, scores jsonb)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT h.id, h.name, public._hotel_health_subscores(h.id)
  FROM public.hotels h
  WHERE h.status <> 'archived'
  ORDER BY h.name;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_hotel_health_scores() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_hotel_health_scores() TO authenticated;
