-- 76_super_admin_phase2f_lot5_dashboard_audit_settings_supervision.sql
-- Super Admin portal (/admin) — Lot 5 : Dashboard, Audit, Paramètres, Supervision.
-- Contient également les correctifs des réserves du Lot 4 (traitées ici, comme autorisé par le
-- CTO : "pendant le Lot 5 ou la préparation RC"), sans bloquer le développement du Lot 5.
--
-- ============================================================================
-- PARTIE 0 — RÉSERVES LOT 4
-- ============================================================================
--
-- Réserve 1 (inventaire exact des fonctions) : traitée hors SQL, dans le dossier RC1
-- (docs/RC1_super_admin_portal.md), via une requête aclexplode/pg_proc automatisable — pas de
-- rapport intermédiaire séparé.
--
-- Réserve 2 (sémantique de paid_at) — redéfinition explicite :
--   paid_at représente désormais UNIQUEMENT un règlement financier réel : la première fois où
--   la somme des paiements 'recorded' atteint amount_ttc BRUT (jamais réduit par un avoir).
--   Un avoir qui ramène le solde net à zéro NE remplit PAS paid_at à lui seul (il n'a fait
--   circuler aucun argent réel) — cette distinction est exactement ce que demandait le CTO.
--   La garde anti-surpaiement continue, elle, de respecter les avoirs (on ne peut pas payer plus
--   que ce qui reste réellement dû après avoir) — deux règles différentes, pour deux questions
--   différentes ("combien reste dû" vs "l'intégralité de la facture a-t-elle été réglée en cash").
--   Nouveau helper interne _recompute_invoice_paid_at(uuid) centralise le calcul (idempotent,
--   et capable de RE-vider paid_at si un renversement de paiement fait redescendre paid_amount
--   sous amount_ttc) — appelé après toute mutation de paid_amount (enregistrement, confirmation,
--   renversement). Nouvelle RPC admin_reverse_platform_payment pour invalider un paiement déjà
--   confirmé (chèque impayé, virement rejeté...) — absente du Lot 4, c'est le vrai trou qui
--   empêchait de tester "l'annulation d'un paiement recalcule paid_at". admin_update_platform_
--   payment_status devient idempotent : reconfirmer un paiement déjà 'recorded' est un no-op
--   silencieux plutôt qu'une exception.
--
-- Réserve 3 (statut documentaire vs état financier) : le statut de facture (proforma/issued/
--   cancelled) ne représente et ne représentera jamais un état de paiement. Les deux RPC de
--   lecture (admin_list_platform_invoices, admin_get_platform_invoice_detail) exposent
--   désormais un champ SÉPARÉ et calculé à la lecture, financial_state, à 5 valeurs : unpaid /
--   partially_paid / paid / overdue / fully_credited. Jamais stocké (toujours recalculé),
--   jamais confondu avec le statut documentaire.
--
-- Réserve 4 (annulation de facture) : déjà vrai pour la suppression physique (aucune, statut
--   'cancelled' uniquement), la non-réutilisation de numéro (séquence monotone
--   platform_invoice_sequences, jamais réinitialisée), le motif obligatoire, la conservation de
--   l'historique (platform_logs). Corrigé ici : le garde-fou ne vérifiait que paid_amount > 0 ;
--   il vérifie désormais AUSSI la présence d'un avoir émis (une facture partiellement créditée
--   ne doit pas non plus pouvoir être annulée silencieusement — la correction se fait par avoir
--   complémentaire, jamais par annulation rétroactive d'un document déjà partiellement soldé).
--
-- Réserve 5 (PDF) : traitée côté frontend uniquement (libellé "Imprimer / enregistrer en PDF"
--   au lieu de "Export PDF") — la dette technique (rendu déterministe, PDF immuable, duplicata
--   identique, stockage, numéro définitif, empreinte) est documentée dans le dossier RC1, pas
--   construite ici (le CTO a explicitness demandé de ne pas construire de moteur documentaire
--   externe à ce stade).

ALTER TABLE public.platform_payments DROP CONSTRAINT IF EXISTS platform_payments_status_check;
ALTER TABLE public.platform_payments ADD CONSTRAINT platform_payments_status_check
  CHECK (status IN ('recorded', 'pending', 'failed', 'reversed'));
ALTER TABLE public.platform_payments ADD COLUMN IF NOT EXISTS reversed_at timestamptz;
ALTER TABLE public.platform_payments ADD COLUMN IF NOT EXISTS reversal_reason text;

CREATE OR REPLACE FUNCTION public._recompute_invoice_paid_at(p_invoice_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
BEGIN
  UPDATE public.platform_invoices SET
    paid_at = CASE WHEN paid_amount >= amount_ttc THEN COALESCE(paid_at, now()) ELSE NULL END
  WHERE id = p_invoice_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_record_platform_payment(
  p_invoice_id uuid, p_amount numeric, p_method text DEFAULT 'bank_transfer',
  p_reference text DEFAULT NULL, p_status text DEFAULT 'recorded', p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice public.platform_invoices;
  v_hotel_name text;
  v_actor   uuid;
  v_id      uuid;
  v_credited numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Le montant doit être positif' USING errcode = '22023';
  END IF;
  IF p_status NOT IN ('recorded', 'pending') THEN
    RAISE EXCEPTION 'Statut de paiement invalide à la création : %', p_status USING errcode = '22023';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  IF v_invoice.status <> 'issued' THEN
    RAISE EXCEPTION 'Seule une facture émise peut recevoir un paiement' USING errcode = '22023';
  END IF;

  SELECT COALESCE(sum(amount_ttc), 0) INTO v_credited
  FROM public.platform_credit_notes WHERE invoice_id = p_invoice_id AND status = 'issued';

  IF p_status = 'recorded' AND (v_invoice.paid_amount + p_amount) > (v_invoice.amount_ttc - v_credited) THEN
    RAISE EXCEPTION 'Ce paiement dépasserait le solde restant dû (%.2f)', v_invoice.amount_ttc - v_credited - v_invoice.paid_amount
      USING errcode = '22023';
  END IF;

  SELECT id INTO v_actor FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;
  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_invoice.hotel_id;

  INSERT INTO public.platform_payments (invoice_id, hotel_id, amount, method, status, reference, notes, recorded_by)
  VALUES (p_invoice_id, v_invoice.hotel_id, p_amount, coalesce(p_method, 'bank_transfer'), p_status, p_reference, p_notes, v_actor)
  RETURNING id INTO v_id;

  IF p_status = 'recorded' THEN
    UPDATE public.platform_invoices SET paid_amount = paid_amount + p_amount WHERE id = p_invoice_id;
    PERFORM public._recompute_invoice_paid_at(p_invoice_id);
  END IF;

  PERFORM public._platform_log('payment.record', 'platform_invoice', p_invoice_id::text, v_invoice.hotel_id, v_hotel_name,
    jsonb_build_object('payment_id', v_id, 'amount', p_amount, 'method', p_method, 'status', p_status));

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_platform_payment_status(p_payment_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_payment public.platform_payments; v_hotel_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_status NOT IN ('recorded', 'failed') THEN
    RAISE EXCEPTION 'Transition de statut invalide : %', p_status USING errcode = '22023';
  END IF;

  SELECT * INTO v_payment FROM public.platform_payments WHERE id = p_payment_id;
  IF v_payment.id IS NULL THEN
    RAISE EXCEPTION 'Paiement introuvable' USING errcode = 'P0002';
  END IF;

  -- Idempotence : reconfirmer un paiement déjà dans l'état demandé est un no-op silencieux,
  -- jamais une double comptabilisation ni une exception (retry réseau côté frontend, par ex.).
  IF v_payment.status = p_status THEN
    RETURN;
  END IF;

  IF v_payment.status <> 'pending' THEN
    RAISE EXCEPTION 'Seul un paiement en attente peut changer de statut ici' USING errcode = '22023';
  END IF;

  UPDATE public.platform_payments SET status = p_status WHERE id = p_payment_id;
  IF p_status = 'recorded' THEN
    UPDATE public.platform_invoices SET paid_amount = paid_amount + v_payment.amount WHERE id = v_payment.invoice_id;
    PERFORM public._recompute_invoice_paid_at(v_payment.invoice_id);
  END IF;

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_payment.hotel_id;
  PERFORM public._platform_log('payment.update_status', 'platform_invoice', v_payment.invoice_id::text, v_payment.hotel_id, v_hotel_name,
    jsonb_build_object('payment_id', p_payment_id, 'new_status', p_status));
END;
$function$;

-- Nouveau : invalider un paiement déjà confirmé (chèque rejeté, virement annulé...).
CREATE OR REPLACE FUNCTION public.admin_reverse_platform_payment(p_payment_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_payment public.platform_payments; v_hotel_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif est obligatoire pour renverser un paiement' USING errcode = '22023';
  END IF;

  SELECT * INTO v_payment FROM public.platform_payments WHERE id = p_payment_id;
  IF v_payment.id IS NULL THEN
    RAISE EXCEPTION 'Paiement introuvable' USING errcode = 'P0002';
  END IF;
  IF v_payment.status <> 'recorded' THEN
    RAISE EXCEPTION 'Seul un paiement enregistré (confirmé) peut être renversé' USING errcode = '22023';
  END IF;

  UPDATE public.platform_payments SET status = 'reversed', reversed_at = now(), reversal_reason = p_reason
  WHERE id = p_payment_id;
  UPDATE public.platform_invoices SET paid_amount = paid_amount - v_payment.amount WHERE id = v_payment.invoice_id;
  PERFORM public._recompute_invoice_paid_at(v_payment.invoice_id);

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_payment.hotel_id;
  PERFORM public._platform_log('payment.reverse', 'platform_invoice', v_payment.invoice_id::text, v_payment.hotel_id, v_hotel_name,
    jsonb_build_object('payment_id', p_payment_id, 'amount', v_payment.amount, 'reason', p_reason));
END;
$function$;

-- admin_cancel_platform_invoice : ajoute la garde "avoir déjà émis" (réserve 4).
CREATE OR REPLACE FUNCTION public.admin_cancel_platform_invoice(p_invoice_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_invoice public.platform_invoices; v_hotel_name text; v_credited numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif d''annulation est obligatoire' USING errcode = '22023';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  IF v_invoice.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cette facture est déjà annulée' USING errcode = '22023';
  END IF;
  IF v_invoice.paid_amount > 0 THEN
    RAISE EXCEPTION 'Impossible d''annuler une facture déjà réglée — émettez un avoir' USING errcode = '22023';
  END IF;

  SELECT COALESCE(sum(amount_ttc), 0) INTO v_credited
  FROM public.platform_credit_notes WHERE invoice_id = p_invoice_id AND status = 'issued';
  IF v_credited > 0 THEN
    RAISE EXCEPTION 'Impossible d''annuler une facture ayant déjà un avoir émis — corrigez par un avoir complémentaire' USING errcode = '22023';
  END IF;

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_invoice.hotel_id;
  UPDATE public.platform_invoices SET status = 'cancelled' WHERE id = p_invoice_id;

  PERFORM public._platform_log('invoice.cancel', 'platform_invoice', p_invoice_id::text, v_invoice.hotel_id, v_hotel_name,
    jsonb_build_object('reason', p_reason, 'previous_status', v_invoice.status));
END;
$function$;

-- admin_list_platform_invoices / admin_get_platform_invoice_detail : ajoutent financial_state.
-- Type de retour élargi (ligne définie par des paramètres OUT) -> DROP explicite requis, même
-- leçon que admin_revoke_hotel au Lot 3.
DROP FUNCTION IF EXISTS public.admin_list_platform_invoices();

CREATE OR REPLACE FUNCTION public.admin_list_platform_invoices()
RETURNS TABLE(
  id uuid, hotel_id uuid, hotel_name text, number text, status text,
  amount_ht numeric, tva_amount numeric, amount_ttc numeric, paid_amount numeric,
  balance numeric, currency text, period_start date, period_end date, due_date date,
  issued_at timestamptz, created_at timestamptz, updated_at timestamptz,
  subscription_id uuid, is_overdue boolean, credited_ttc numeric, financial_state text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    pi.id, pi.hotel_id, h.name, pi.number, pi.status,
    pi.amount_ht, pi.tva_amount, pi.amount_ttc, pi.paid_amount,
    pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0) AS balance,
    pi.currency, pi.period_start, pi.period_end, pi.due_date,
    pi.issued_at, pi.created_at, pi.updated_at, pi.subscription_id,
    (pi.status = 'issued' AND pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
      AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0) AS is_overdue,
    COALESCE(cn.credited, 0) AS credited_ttc,
    CASE
      WHEN pi.status <> 'issued' THEN NULL
      WHEN pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
        AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0 THEN 'overdue'
      WHEN (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) <= 0
        AND COALESCE(cn.credited, 0) > 0 AND pi.paid_amount < pi.amount_ttc THEN 'fully_credited'
      WHEN (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) <= 0 THEN 'paid'
      WHEN pi.paid_amount > 0 OR COALESCE(cn.credited, 0) > 0 THEN 'partially_paid'
      ELSE 'unpaid'
    END AS financial_state
  FROM public.platform_invoices pi
  JOIN public.hotels h ON h.id = pi.hotel_id
  LEFT JOIN LATERAL (
    SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
    WHERE invoice_id = pi.id AND status = 'issued'
  ) cn ON true
  WHERE public.is_platform_admin()
  ORDER BY pi.created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_platform_invoice_detail(p_invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice public.platform_invoices;
  v_hotel   public.hotels;
  v_credited numeric;
  v_balance numeric;
  v_financial_state text;
  v_result  jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  SELECT * INTO v_hotel FROM public.hotels WHERE id = v_invoice.hotel_id;

  SELECT COALESCE(sum(amount_ttc), 0) INTO v_credited
  FROM public.platform_credit_notes WHERE invoice_id = p_invoice_id AND status = 'issued';
  v_balance := v_invoice.amount_ttc - v_invoice.paid_amount - v_credited;

  v_financial_state := CASE
    WHEN v_invoice.status <> 'issued' THEN NULL
    WHEN v_invoice.due_date IS NOT NULL AND v_invoice.due_date < CURRENT_DATE AND v_balance > 0 THEN 'overdue'
    WHEN v_balance <= 0 AND v_credited > 0 AND v_invoice.paid_amount < v_invoice.amount_ttc THEN 'fully_credited'
    WHEN v_balance <= 0 THEN 'paid'
    WHEN v_invoice.paid_amount > 0 OR v_credited > 0 THEN 'partially_paid'
    ELSE 'unpaid'
  END;

  SELECT jsonb_build_object(
    'invoice', to_jsonb(v_invoice) || jsonb_build_object('financial_state', v_financial_state, 'balance', v_balance, 'credited_ttc', v_credited),
    'hotel', jsonb_build_object('id', v_hotel.id, 'name', v_hotel.name, 'company', v_hotel.company,
      'address', v_hotel.address, 'siret', v_hotel.siret, 'tva_number', v_hotel.tva_number,
      'email', v_hotel.email, 'billing_email', v_hotel.billing_email),
    'subscription', (SELECT to_jsonb(hs) FROM public.hotel_subscriptions hs WHERE hs.id = v_invoice.subscription_id),
    'payments', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.payment_date DESC)
                          FROM public.platform_payments p WHERE p.invoice_id = p_invoice_id), '[]'::jsonb),
    'credit_notes', COALESCE((SELECT jsonb_agg(to_jsonb(cn) ORDER BY cn.created_at DESC)
                              FROM public.platform_credit_notes cn WHERE cn.invoice_id = p_invoice_id), '[]'::jsonb),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                            'action', pl.action, 'created_at', pl.created_at,
                            'admin_email', pl.admin_email, 'payload', pl.payload
                          ) ORDER BY pl.created_at DESC)
                          FROM public.platform_logs pl
                          WHERE pl.entity = 'platform_invoice' AND pl.entity_id = p_invoice_id::text), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ============================================================================
-- PARTIE 1 — Marqueur de schéma (pour la Supervision, réponse mesurable et honnête)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.platform_schema_markers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  migration_name text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.platform_schema_markers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_admin_all ON public.platform_schema_markers;
CREATE POLICY platform_admin_all ON public.platform_schema_markers FOR ALL USING (public.is_platform_admin());
REVOKE ALL ON TABLE public.platform_schema_markers FROM anon, authenticated, service_role;
INSERT INTO public.platform_schema_markers (migration_name)
VALUES ('super_admin_phase2f_lot5_dashboard_audit_settings_supervision');

-- ============================================================================
-- PARTIE 2 — Tableau de bord : vue d'ensemble plateforme (une seule RPC d'agrégation)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_platform_overview_kpis(
  p_period text DEFAULT 'this_month', p_start date DEFAULT NULL, p_end date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start date; v_end date; v_result jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  IF p_start IS NOT NULL AND p_end IS NOT NULL THEN
    v_start := p_start; v_end := p_end;
  ELSIF p_period = 'last_month' THEN
    v_start := (date_trunc('month', now()) - interval '1 month')::date;
    v_end   := (date_trunc('month', now()) - interval '1 day')::date;
  ELSIF p_period = 'quarter' THEN
    v_start := date_trunc('quarter', now())::date;
    v_end   := (date_trunc('quarter', now()) + interval '3 month' - interval '1 day')::date;
  ELSIF p_period = 'year' THEN
    v_start := date_trunc('year', now())::date;
    v_end   := (date_trunc('year', now()) + interval '1 year' - interval '1 day')::date;
  ELSE
    v_start := date_trunc('month', now())::date;
    v_end   := (date_trunc('month', now()) + interval '1 month' - interval '1 day')::date;
  END IF;

  SELECT jsonb_build_object(
    'period', jsonb_build_object('start', v_start, 'end', v_end, 'label', coalesce(p_period, 'custom')),

    'hotels', (SELECT jsonb_build_object(
      'total', count(*), 'active', count(*) FILTER (WHERE status = 'active'),
      'inactive_or_archived', count(*) FILTER (WHERE status IN ('suspended', 'archived', 'draft'))
    ) FROM public.hotels),

    'groups', (SELECT jsonb_build_object('total', count(*)) FROM public.hotel_groups WHERE status <> 'archived'),

    'users', (SELECT jsonb_build_object(
      'total', count(*), 'super_admins', (SELECT count(*) FROM public.platform_admins WHERE role = 'super_admin' AND is_active)
    ) FROM public.users),

    'subscriptions', (SELECT jsonb_build_object(
      'active', count(*) FILTER (WHERE status = 'active'),
      'trial', count(*) FILTER (WHERE status = 'trial'),
      'trial_expiring_7d', count(*) FILTER (WHERE status = 'trial' AND trial_ends_at IS NOT NULL
        AND trial_ends_at BETWEEN now() AND now() + interval '7 days'),
      'suspended', count(*) FILTER (WHERE status = 'suspended'),
      'scheduled_cancellation', count(*) FILTER (WHERE scheduled_cancellation_at IS NOT NULL),
      'plan_incoherent', count(*) FILTER (WHERE status IN ('trial', 'active') AND (
        plan_id IS NULL
        OR EXISTS (SELECT 1 FROM public.subscription_plans sp WHERE sp.id = hotel_subscriptions.plan_id AND sp.archived_at IS NOT NULL)
        OR EXISTS (SELECT 1 FROM public.subscription_plans sp WHERE sp.id = hotel_subscriptions.plan_id AND NOT sp.is_active)
      )),
      'by_plan', (SELECT COALESCE(jsonb_object_agg(coalesce(sp.name, '(sans plan)'), cnt), '{}'::jsonb)
        FROM (SELECT plan_id, count(*) AS cnt FROM public.hotel_subscriptions WHERE status IN ('trial','active') GROUP BY plan_id) s
        LEFT JOIN public.subscription_plans sp ON sp.id = s.plan_id)
    ) FROM public.hotel_subscriptions),

    'apps', (SELECT jsonb_build_object(
      'active', (SELECT count(*) FROM public.platform_apps WHERE is_available),
      'total_access_grants', (SELECT count(*) FROM public.user_app_access),
      'divergence_count', (SELECT count(*) FROM (
        SELECT public._resolve_app_access_core(uaa.user_id, uaa.hotel_id, pa.code) AS r
        FROM public.user_app_access uaa JOIN public.platform_apps pa ON pa.id = uaa.app_id
      ) x WHERE (x.r->>'diverges')::boolean),
      'resolution_errors', (SELECT count(*) FROM (
        SELECT public._resolve_app_access_core(uaa.user_id, uaa.hotel_id, pa.code) AS r
        FROM public.user_app_access uaa JOIN public.platform_apps pa ON pa.id = uaa.app_id
      ) x WHERE (x.r->>'diverges')::boolean AND jsonb_array_length(x.r->'causes') = 0)
    )),

    'billing', (SELECT jsonb_build_object(
      'period_billed_ttc', COALESCE((SELECT sum(amount_ttc) FROM public.platform_invoices
        WHERE status = 'issued' AND issued_at::date BETWEEN v_start AND v_end), 0),
      'period_collected', COALESCE((SELECT sum(amount) FROM public.platform_payments
        WHERE status = 'recorded' AND payment_date::date BETWEEN v_start AND v_end), 0),
      'outstanding_total', COALESCE((SELECT sum(pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0))
        FROM public.platform_invoices pi
        LEFT JOIN LATERAL (SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
          WHERE invoice_id = pi.id AND status = 'issued') cn ON true
        WHERE pi.status = 'issued' AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0), 0),
      'overdue_invoice_count', COALESCE((SELECT count(*) FROM public.platform_invoices pi
        LEFT JOIN LATERAL (SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
          WHERE invoice_id = pi.id AND status = 'issued') cn ON true
        WHERE pi.status = 'issued' AND pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
          AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0), 0),
      'pending_payments', COALESCE((SELECT count(*) FROM public.platform_payments WHERE status = 'pending'), 0),
      'credits_issued_ttc', COALESCE((SELECT sum(amount_ttc) FROM public.platform_credit_notes
        WHERE status = 'issued' AND issued_at::date BETWEEN v_start AND v_end), 0),
      'subscriptions_suspended_nonpayment', COALESCE((SELECT count(*) FROM public.hotel_subscriptions hs
        WHERE hs.status = 'suspended' AND (
          SELECT e.reason FROM public.hotel_subscription_events e
          WHERE e.subscription_id = hs.id AND e.event_type = 'suspended'
          ORDER BY e.created_at DESC LIMIT 1
        ) LIKE 'IMPAYÉ%'), 0)
    )),

    'users_detail', (SELECT jsonb_build_object(
      'active', count(*) FILTER (WHERE u.is_active),
      'deactivated', count(*) FILTER (WHERE NOT u.is_active),
      'pending_invites', count(*) FILTER (WHERE au.email_confirmed_at IS NULL
        AND (au.invited_at IS NULL OR au.invited_at >= now() - interval '14 days')),
      'stale_invites', count(*) FILTER (WHERE au.email_confirmed_at IS NULL
        AND au.invited_at IS NOT NULL AND au.invited_at < now() - interval '14 days'),
      'without_access', count(*) FILTER (WHERE u.is_active AND NOT EXISTS (
        SELECT 1 FROM public.user_hotels uh WHERE uh.user_id = u.id
      )),
      'hotels_without_admin', (SELECT count(*) FROM public.hotels h WHERE h.status = 'active' AND NOT EXISTS (
        SELECT 1 FROM public.user_hotels uh WHERE uh.hotel_id = h.id AND uh.role IN ('direction', 'admin_hotel')
      ))
    ) FROM public.users u LEFT JOIN auth.users au ON au.id = u.auth_id)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ============================================================================
-- PARTIE 3 — Alertes et actions requises (une ligne = une action concrète, jamais décorative)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_platform_alerts()
RETURNS TABLE(
  alert_type text, severity text, message text,
  entity_type text, entity_id text, entity_label text,
  hotel_id uuid, hotel_name text, group_id uuid, group_name text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
  WHERE NOT u.is_active AND EXISTS (SELECT 1 FROM public.user_hotels uh WHERE uh.user_id = u.id);
END;
$function$;

-- ============================================================================
-- PARTIE 4 — Journal d'audit (filtré, paginé, une seule RPC avec total_count en fenêtre)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_list_platform_audit_log(
  p_search text DEFAULT NULL, p_admin_email text DEFAULT NULL, p_hotel_id uuid DEFAULT NULL,
  p_group_id uuid DEFAULT NULL, p_entity text DEFAULT NULL, p_action text DEFAULT NULL,
  p_level text DEFAULT NULL, p_date_from timestamptz DEFAULT NULL, p_date_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS TABLE(
  id uuid, created_at timestamptz, admin_email text, action text, entity text, entity_id text,
  hotel_id uuid, hotel_name text, group_id uuid, group_name text, level text, payload jsonb,
  ip_address text, total_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit <= 0 OR p_limit > 200 THEN
    RAISE EXCEPTION 'Taille de page invalide (1 à 200)' USING errcode = '22023';
  END IF;

  RETURN QUERY
  SELECT pl.id, pl.created_at, pl.admin_email, pl.action, pl.entity, pl.entity_id,
    pl.hotel_id, pl.hotel_name, h.group_id, hg.name, pl.level, pl.payload, pl.ip_address,
    count(*) OVER() AS total_count
  FROM public.platform_logs pl
  LEFT JOIN public.hotels h ON h.id = pl.hotel_id
  LEFT JOIN public.hotel_groups hg ON hg.id = h.group_id
  WHERE (p_admin_email IS NULL OR pl.admin_email ILIKE '%' || p_admin_email || '%')
    AND (p_hotel_id IS NULL OR pl.hotel_id = p_hotel_id)
    AND (p_group_id IS NULL OR h.group_id = p_group_id)
    AND (p_entity IS NULL OR pl.entity = p_entity)
    AND (p_action IS NULL OR pl.action = p_action)
    AND (p_level IS NULL OR pl.level = p_level)
    AND (p_date_from IS NULL OR pl.created_at >= p_date_from)
    AND (p_date_to IS NULL OR pl.created_at <= p_date_to)
    AND (p_search IS NULL OR p_search = '' OR
      pl.action ILIKE '%' || p_search || '%' OR pl.entity ILIKE '%' || p_search || '%' OR
      pl.hotel_name ILIKE '%' || p_search || '%' OR pl.admin_email ILIKE '%' || p_search || '%')
  ORDER BY pl.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$function$;

-- ============================================================================
-- PARTIE 5 — Paramètres plateforme (les 16 clés existantes uniquement, jamais de clé inventée)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_update_platform_setting(p_key text, p_value jsonb, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_before jsonb; v_actor uuid; v_row public.platform_settings;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT value INTO v_before FROM public.platform_settings WHERE key = p_key;
  IF v_before IS NULL AND NOT EXISTS (SELECT 1 FROM public.platform_settings WHERE key = p_key) THEN
    RAISE EXCEPTION 'Paramètre inconnu : %', p_key USING errcode = 'P0002';
  END IF;

  -- Validation par type attendu selon la clé — jamais de paramètre inventé, jamais de valeur
  -- incohérente avec ce que le backend consomme réellement.
  IF p_key IN ('mrr_target', 'arr_target', 'default_tva_rate', 'default_commitment',
               'max_trial_days', 'min_trial_days', 'max_trial_extensions', 'churn_alert_rate', 'trial_duration_days') THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'Le paramètre % doit être un nombre', p_key USING errcode = '22023';
    END IF;
  ELSIF p_key = 'dunning_days_before' THEN
    IF jsonb_typeof(p_value) <> 'array' THEN
      RAISE EXCEPTION 'Le paramètre % doit être un tableau de nombres', p_key USING errcode = '22023';
    END IF;
  ELSIF jsonb_typeof(p_value) <> 'string' THEN
    RAISE EXCEPTION 'Le paramètre % doit être une chaîne de caractères', p_key USING errcode = '22023';
  END IF;

  SELECT id INTO v_actor FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;

  UPDATE public.platform_settings SET value = p_value, updated_by = v_actor, updated_at = now()
  WHERE key = p_key
  RETURNING * INTO v_row;

  PERFORM public._platform_log('setting.update', 'platform_setting', p_key, NULL, NULL,
    jsonb_build_object('key', p_key, 'before', v_before, 'after', p_value, 'reason', p_reason));

  RETURN to_jsonb(v_row);
END;
$function$;

-- ============================================================================
-- PARTIE 6 — Supervision (honnête : "Non supervisé" plutôt qu'un faux badge vert)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_supervision_status()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb; v_marker public.platform_schema_markers;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT * INTO v_marker FROM public.platform_schema_markers ORDER BY applied_at DESC LIMIT 1;

  SELECT jsonb_build_object(
    'database_connected', true,
    'last_migration_name', v_marker.migration_name,
    'last_migration_at', v_marker.applied_at,
    'scheduled_tasks_count', 0,
    'scheduled_tasks_known', true,
    'mutation_error_monitoring_available', false,
    'edge_function_error_monitoring_available', false,
    'webhooks_configured', false
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ============================================================================
-- PARTIE 7 — ACL
-- ============================================================================
REVOKE ALL ON TABLE public.platform_settings FROM anon, service_role;
REVOKE ALL ON TABLE public.platform_logs FROM anon, service_role;

REVOKE ALL ON FUNCTION public.admin_record_platform_payment(uuid, numeric, text, text, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_record_platform_payment(uuid, numeric, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_platform_payment_status(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_platform_payment_status(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_reverse_platform_payment(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_reverse_platform_payment(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_cancel_platform_invoice(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_cancel_platform_invoice(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_platform_invoices() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_platform_invoices() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_get_platform_invoice_detail(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_platform_invoice_detail(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_platform_overview_kpis(text, date, date) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_platform_overview_kpis(text, date, date) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_platform_alerts() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_platform_alerts() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_platform_audit_log(text, text, uuid, uuid, text, text, text, timestamptz, timestamptz, int, int) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_platform_audit_log(text, text, uuid, uuid, text, text, text, timestamptz, timestamptz, int, int) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_platform_setting(text, jsonb, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_platform_setting(text, jsonb, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_supervision_status() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_supervision_status() TO authenticated;

-- Helper interne (catégorie 2) : jamais de GRANT client, sur aucun rôle.
REVOKE ALL ON FUNCTION public._recompute_invoice_paid_at(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================
-- CONSTAT TRANSVERSAL (documenté, PAS corrigé ici — hors périmètre Lot 5)
-- ============================================================================
-- Un balayage transversal (information_schema.role_table_grants) montre que le rôle anon
-- possède INSERT/UPDATE/DELETE au niveau TABLE sur la quasi-totalité du schéma public (plus de
-- 250 tables), pas seulement les tables plateforme déjà retrofixées lots précédents. C'est un
-- paramétrage de privilèges par défaut au niveau du PROJET (probablement `ALTER DEFAULT
-- PRIVILEGES` appliqué une fois, avant ce chantier), sur lequel toute l'application hôtel
-- (index.html) repose déjà — la RLS est la seule ligne de défense réelle pour l'ensemble de ces
-- tables, ce qui est un modèle Supabase standard et défendable, mais SANS la défense en
-- profondeur déjà appliquée aux tables plateforme touchées par ce projet (Lots 0/2/3/4/5).
-- Corriger ce point à l'échelle du schéma entier dépasse largement le mandat du Lot 5 (risque de
-- casser des flux anonymes légitimes existants : portails de signature, auto-check-in, etc.,
-- dont l'usage exact de anon n'a pas été audité ici) — signalé au CTO comme point de décision
-- pour la RC1, non traité dans cette migration.
