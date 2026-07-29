-- 75_super_admin_phase2e_lot4_billing.sql
-- Super Admin portal (/admin) — Lot 4 : Facturation (facturation PLATEFORME, jamais la
-- facturation hôtel/client final).
--
-- Constat d'audit (avant modification) — deux systèmes de facturation totalement distincts
-- existent déjà, jamais confondus ici :
--   1. invoices / payments / credit_notes / einvoice_submissions / einvoice_events /
--      pdp_exchange_logs / fec_exports : facturation de l'HÔTEL à SES CLIENTS (voyageurs),
--      liée à reservation_id/guest_*, pilotée par le module Checkout (skill flowtym-checkout).
--      Hors périmètre Lot 4 — non touché.
--   2. platform_invoices / platform_contracts : facturation de FLOWTYM à SES CLIENTS (les
--      hôtels), pour leur abonnement à la plateforme. C'est le seul périmètre du Lot 4.
--      Constatées vides (0 ligne) et sans aucune RPC — confirmé dès la Phase 1.
--
-- ÉCART DE SÉCURITÉ DÉCOUVERT (plus grave que les précédents lots) : platform_invoices et
-- platform_contracts ont une policy RLS correcte (is_platform_admin()) mais le rôle anon
-- possédait en plus, au niveau TABLE, les privilèges INSERT/UPDATE/DELETE/SELECT (défaut de
-- privilèges Supabase sur les tables neuves, jamais nettoyé). La RLS bloque bien anon en
-- pratique (auth.uid() est NULL pour ce rôle, is_platform_admin() renvoie donc false), mais la
-- doctrine de ce projet (Lots 0/2/3) est de ne jamais compter uniquement sur la RLS : on
-- retire explicitement tout privilège de mutation à anon/service_role au niveau table,
-- exactement comme sql/69 l'a fait pour hotel_groups/audit_logs/invoices/payments.
--
-- Réutilisé tel quel (aucune duplication) :
--   - hotel_subscriptions : billing_cycle, next_billing_date, snapshot_price_net_ht déjà présents
--     — une facture plateforme référence un abonnement (subscription_id), elle ne recopie pas
--     son modèle de tarification.
--   - admin_suspend_subscription / admin_reactivate_subscription (Lot 1) : "abonnement suspendu
--     pour impayé" n'est PAS un nouveau statut — c'est le statut 'suspended' existant, avec un
--     motif normalisé (préfixe 'IMPAYÉ') posé par le nouveau admin_suspend_subscription_for_nonpayment,
--     détectable ensuite dans hotel_subscription_events.reason pour le tableau de bord.
--   - hotels.company/address/siret/tva_number/email : identité légale déjà présente, réutilisée
--     comme coordonnées de facturation par défaut. Seul ajout : billing_email (peut différer de
--     l'email opérationnel — ex. service comptable).
--
-- Décisions de modélisation explicites :
--   - Facture / Avoir / Paiement sont TROIS objets distincts, jamais fusionnés : platform_invoices,
--     platform_credit_notes (nouvelle table, miroir de credit_notes hôtel), platform_payments
--     (nouvelle table, miroir de payments hôtel). Un avoir ne modifie jamais amount_ttc/paid_amount
--     de la facture d'origine — le solde affiché (RPC de lecture) est calculé à la volée :
--     amount_ttc - paid_amount - somme des avoirs émis liés.
--   - Statuts facture : proforma / issued / cancelled (jamais "payée" comme statut — le paiement
--     est un fait distinct, dérivé de paid_amount vs amount_ttc). Annulation interdite si
--     paid_amount > 0 (utiliser un avoir, jamais annuler une facture déjà réglée).
--   - Export PDF : rendu navigateur (window.print() côté frontend, aucune librairie, aucun
--     service externe) — pdf_url reste réservé pour un futur stockage réel (Stripe/Chorus Pro...).
--   - Préparation e-invoicing plateforme : pas de nouvelle colonne/table spéculative ajoutée sans
--     usage immédiat (aucune fonctionnalité ne les lirait) — le modèle est déjà compatible
--     (bill_to_vat, hotels.siret/tva_number) et l'écran affiche un module "Phase 2" explicite,
--     même convention que les autres stubs déjà en place (Abonnements/Facturation hôtel restaient
--     déjà marqués ainsi avant ce lot).

-- ============================================================================
-- 1. Colonnes additionnelles
-- ============================================================================
ALTER TABLE public.hotels ADD COLUMN IF NOT EXISTS billing_email text;

ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS subscription_id uuid REFERENCES public.hotel_subscriptions(id);
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS paid_amount numeric NOT NULL DEFAULT 0;
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS issued_at timestamptz;
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS bill_to_name text;
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS bill_to_address text;
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS bill_to_vat text;
ALTER TABLE public.platform_invoices ADD COLUMN IF NOT EXISTS bill_to_email text;
ALTER TABLE public.platform_invoices ALTER COLUMN status SET DEFAULT 'proforma';
-- Table vide (0 ligne, confirmé) : aucune donnée existante à migrer avant la contrainte.
ALTER TABLE public.platform_invoices DROP CONSTRAINT IF EXISTS platform_invoices_status_check;
ALTER TABLE public.platform_invoices ADD CONSTRAINT platform_invoices_status_check
  CHECK (status IN ('proforma', 'issued', 'cancelled'));

-- ============================================================================
-- 2. Nouvelles tables : paiements et avoirs plateforme (jamais fusionnés avec la facture)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.platform_payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id    uuid NOT NULL REFERENCES public.platform_invoices(id),
  hotel_id      uuid NOT NULL REFERENCES public.hotels(id),
  amount        numeric NOT NULL CHECK (amount > 0),
  currency      text NOT NULL DEFAULT 'EUR',
  method        text NOT NULL DEFAULT 'bank_transfer'
                  CHECK (method IN ('bank_transfer', 'card', 'sepa', 'check', 'cash', 'other')),
  status        text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'pending', 'failed')),
  reference     text,
  notes         text,
  recorded_by   uuid REFERENCES public.platform_admins(id),
  payment_date  timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_platform_payments_invoice ON public.platform_payments(invoice_id);
CREATE INDEX IF NOT EXISTS idx_platform_payments_hotel ON public.platform_payments(hotel_id);

CREATE TABLE IF NOT EXISTS public.platform_credit_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id   uuid NOT NULL REFERENCES public.platform_invoices(id),
  hotel_id     uuid NOT NULL REFERENCES public.hotels(id),
  number       text NOT NULL UNIQUE,
  amount_ht    numeric NOT NULL,
  tva_amount   numeric NOT NULL DEFAULT 0,
  amount_ttc   numeric NOT NULL,
  currency     text NOT NULL DEFAULT 'EUR',
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'voided')),
  issued_at    timestamptz NOT NULL DEFAULT now(),
  voided_at    timestamptz,
  void_reason  text,
  created_by   uuid REFERENCES public.platform_admins(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_platform_credit_notes_invoice ON public.platform_credit_notes(invoice_id);

ALTER TABLE public.platform_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_credit_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_admin_all ON public.platform_payments;
CREATE POLICY platform_admin_all ON public.platform_payments FOR ALL USING (public.is_platform_admin());
DROP POLICY IF EXISTS platform_admin_all ON public.platform_credit_notes;
CREATE POLICY platform_admin_all ON public.platform_credit_notes FOR ALL USING (public.is_platform_admin());

-- Numérotation (compteur global plateforme par année — distinct de invoice_sequences qui est
-- PAR HÔTEL et sert la facturation client, hors périmètre ici).
CREATE TABLE IF NOT EXISTS public.platform_invoice_sequences (
  year int PRIMARY KEY, last_seq int NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS public.platform_credit_note_sequences (
  year int PRIMARY KEY, last_seq int NOT NULL DEFAULT 0
);
ALTER TABLE public.platform_invoice_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_credit_note_sequences ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS platform_admin_all ON public.platform_invoice_sequences;
CREATE POLICY platform_admin_all ON public.platform_invoice_sequences FOR ALL USING (public.is_platform_admin());
DROP POLICY IF EXISTS platform_admin_all ON public.platform_credit_note_sequences;
CREATE POLICY platform_admin_all ON public.platform_credit_note_sequences FOR ALL USING (public.is_platform_admin());

CREATE OR REPLACE FUNCTION public._next_platform_invoice_number()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
DECLARE v_year int := extract(year FROM now())::int; v_seq int;
BEGIN
  INSERT INTO public.platform_invoice_sequences(year, last_seq) VALUES (v_year, 1)
  ON CONFLICT (year) DO UPDATE SET last_seq = public.platform_invoice_sequences.last_seq + 1
  RETURNING last_seq INTO v_seq;
  RETURN 'FLOW-' || v_year || '-' || lpad(v_seq::text, 6, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public._next_platform_credit_note_number()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
DECLARE v_year int := extract(year FROM now())::int; v_seq int;
BEGIN
  INSERT INTO public.platform_credit_note_sequences(year, last_seq) VALUES (v_year, 1)
  ON CONFLICT (year) DO UPDATE SET last_seq = public.platform_credit_note_sequences.last_seq + 1
  RETURNING last_seq INTO v_seq;
  RETURN 'FLOW-AV-' || v_year || '-' || lpad(v_seq::text, 6, '0');
END;
$function$;

-- ============================================================================
-- 3. Coordonnées de facturation — extension additive de admin_update_hotel_full (Lot 2)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_update_hotel_full(p_hotel uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_before        jsonb;
  v_before_group  uuid;
  v_name          text;
  v_group_provided boolean := (p ? 'group_id');
  v_new_group     uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT to_jsonb(h), h.group_id INTO v_before, v_before_group FROM public.hotels h WHERE h.id = p_hotel;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'HOTEL_INTROUVABLE';
  END IF;

  IF v_group_provided THEN
    v_new_group := nullif(p->>'group_id', '')::uuid;
    IF v_new_group IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.hotel_groups WHERE id = v_new_group) THEN
      RAISE EXCEPTION 'GROUPE_INTROUVABLE';
    END IF;
  END IF;

  UPDATE public.hotels SET
    name          = coalesce(nullif(trim(p->>'name'), ''), name),
    address       = coalesce(p->>'address', address),
    city          = coalesce(p->>'city', city),
    zip           = coalesce(p->>'zip', zip),
    country       = coalesce(p->>'country', country),
    phone         = coalesce(p->>'phone', phone),
    email         = coalesce(p->>'email', email),
    billing_email = coalesce(p->>'billing_email', billing_email),
    website       = coalesce(p->>'website', website),
    siret         = coalesce(p->>'siret', siret),
    tva_number    = coalesce(p->>'tva_number', tva_number),
    company       = coalesce(p->>'company', company),
    stars         = coalesce(nullif(p->>'stars', '')::int, stars),
    total_rooms   = coalesce(nullif(p->>'total_rooms', '')::int, total_rooms),
    currency      = coalesce(nullif(p->>'currency', ''), currency),
    timezone      = coalesce(nullif(p->>'timezone', ''), timezone),
    group_id      = CASE WHEN v_group_provided THEN v_new_group ELSE group_id END
  WHERE id = p_hotel
  RETURNING name INTO v_name;

  PERFORM public._platform_log('hotel.update', 'hotel', p_hotel::text, p_hotel, v_name,
    jsonb_build_object('before', v_before, 'after', p));

  IF v_group_provided AND v_new_group IS DISTINCT FROM v_before_group THEN
    PERFORM public._platform_log(
      CASE WHEN v_new_group IS NULL THEN 'group.detach_hotel' ELSE 'group.attach_hotel' END,
      'hotel', p_hotel::text, p_hotel, v_name,
      jsonb_build_object('previous_group_id', v_before_group, 'new_group_id', v_new_group));
  END IF;

  RETURN (SELECT to_jsonb(h) FROM public.hotels h WHERE h.id = p_hotel);
END;
$function$;

-- ============================================================================
-- 4. Factures plateforme
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_list_platform_invoices()
RETURNS TABLE(
  id uuid, hotel_id uuid, hotel_name text, number text, status text,
  amount_ht numeric, tva_amount numeric, amount_ttc numeric, paid_amount numeric,
  balance numeric, currency text, period_start date, period_end date, due_date date,
  issued_at timestamptz, created_at timestamptz, updated_at timestamptz,
  subscription_id uuid, is_overdue boolean,
  credited_ttc numeric
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
    COALESCE(cn.credited, 0) AS credited_ttc
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

  SELECT jsonb_build_object(
    'invoice', to_jsonb(v_invoice),
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

CREATE OR REPLACE FUNCTION public.admin_create_platform_invoice(
  p_hotel_id uuid, p_subscription_id uuid, p_period_start date, p_period_end date,
  p_amount_ht numeric, p_tva_rate numeric DEFAULT 20, p_due_date date DEFAULT NULL, p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_hotel public.hotels;
  v_id    uuid;
  v_tva   numeric;
  v_ttc   numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_amount_ht IS NULL OR p_amount_ht <= 0 THEN
    RAISE EXCEPTION 'Le montant HT doit être positif' USING errcode = '22023';
  END IF;

  SELECT * INTO v_hotel FROM public.hotels WHERE id = p_hotel_id;
  IF v_hotel.id IS NULL THEN
    RAISE EXCEPTION 'Hôtel introuvable' USING errcode = 'P0002';
  END IF;
  IF p_subscription_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.hotel_subscriptions WHERE id = p_subscription_id AND hotel_id = p_hotel_id
  ) THEN
    RAISE EXCEPTION 'Abonnement introuvable pour cet hôtel' USING errcode = 'P0002';
  END IF;

  v_tva := round(p_amount_ht * coalesce(p_tva_rate, 20) / 100, 2);
  v_ttc := p_amount_ht + v_tva;

  -- Facture créée en 'proforma' : le numéro définitif n'est attribué qu'à l'émission
  -- (admin_issue_platform_invoice) — une proforma n'engage rien et peut être librement annulée.
  INSERT INTO public.platform_invoices (
    hotel_id, number, status, amount_ht, tva_rate, tva_amount, amount_ttc, currency,
    period_start, period_end, due_date, notes, subscription_id,
    bill_to_name, bill_to_address, bill_to_vat, bill_to_email
  ) VALUES (
    p_hotel_id, 'PROFORMA-' || substr(gen_random_uuid()::text, 1, 8), 'proforma',
    p_amount_ht, coalesce(p_tva_rate, 20), v_tva, v_ttc, 'EUR',
    p_period_start, p_period_end, p_due_date, p_notes, p_subscription_id,
    coalesce(v_hotel.company, v_hotel.name), v_hotel.address, v_hotel.tva_number,
    coalesce(v_hotel.billing_email, v_hotel.email)
  ) RETURNING id INTO v_id;

  PERFORM public._platform_log('invoice.create_proforma', 'platform_invoice', v_id::text, p_hotel_id, v_hotel.name,
    jsonb_build_object('amount_ht', p_amount_ht, 'amount_ttc', v_ttc, 'subscription_id', p_subscription_id));

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_issue_platform_invoice(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice public.platform_invoices;
  v_hotel   public.hotels;
  v_number  text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  IF v_invoice.status <> 'proforma' THEN
    RAISE EXCEPTION 'Seule une facture proforma peut être émise' USING errcode = '22023';
  END IF;

  SELECT * INTO v_hotel FROM public.hotels WHERE id = v_invoice.hotel_id;
  v_number := public._next_platform_invoice_number();

  -- Re-snapshot des coordonnées de facturation au moment de l'émission (la proforma pouvait
  -- avoir été créée avant une mise à jour des coordonnées de l'hôtel) : une facture émise est un
  -- document légal figé, jamais recalculé a posteriori.
  UPDATE public.platform_invoices SET
    status = 'issued', number = v_number, issued_at = now(),
    bill_to_name = coalesce(v_hotel.company, v_hotel.name), bill_to_address = v_hotel.address,
    bill_to_vat = v_hotel.tva_number, bill_to_email = coalesce(v_hotel.billing_email, v_hotel.email)
  WHERE id = p_invoice_id;

  PERFORM public._platform_log('invoice.issue', 'platform_invoice', p_invoice_id::text, v_invoice.hotel_id, v_hotel.name,
    jsonb_build_object('number', v_number, 'amount_ttc', v_invoice.amount_ttc));
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_cancel_platform_invoice(p_invoice_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_invoice public.platform_invoices; v_hotel_name text;
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

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_invoice.hotel_id;
  UPDATE public.platform_invoices SET status = 'cancelled' WHERE id = p_invoice_id;

  PERFORM public._platform_log('invoice.cancel', 'platform_invoice', p_invoice_id::text, v_invoice.hotel_id, v_hotel_name,
    jsonb_build_object('reason', p_reason, 'previous_status', v_invoice.status));
END;
$function$;

-- ============================================================================
-- 5. Paiements plateforme
-- ============================================================================
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
    -- paid_at (colonne préexistante, jusqu'ici jamais peuplée) marque le règlement intégral —
    -- posé ici plutôt que laissé inutilisé, cohérent avec le solde calculé à la volée (avoirs inclus).
    UPDATE public.platform_invoices SET
      paid_amount = paid_amount + p_amount,
      paid_at = CASE WHEN (paid_amount + p_amount) >= (amount_ttc - v_credited) THEN now() ELSE paid_at END
    WHERE id = p_invoice_id;
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
DECLARE v_payment public.platform_payments; v_hotel_name text; v_credited numeric;
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
  IF v_payment.status <> 'pending' THEN
    RAISE EXCEPTION 'Seul un paiement en attente peut changer de statut ici' USING errcode = '22023';
  END IF;

  UPDATE public.platform_payments SET status = p_status WHERE id = p_payment_id;
  IF p_status = 'recorded' THEN
    SELECT COALESCE(sum(amount_ttc), 0) INTO v_credited
    FROM public.platform_credit_notes WHERE invoice_id = v_payment.invoice_id AND status = 'issued';
    UPDATE public.platform_invoices SET
      paid_amount = paid_amount + v_payment.amount,
      paid_at = CASE WHEN (paid_amount + v_payment.amount) >= (amount_ttc - v_credited) THEN now() ELSE paid_at END
    WHERE id = v_payment.invoice_id;
  END IF;

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_payment.hotel_id;
  PERFORM public._platform_log('payment.update_status', 'platform_invoice', v_payment.invoice_id::text, v_payment.hotel_id, v_hotel_name,
    jsonb_build_object('payment_id', p_payment_id, 'new_status', p_status));
END;
$function$;

-- ============================================================================
-- 6. Avoirs plateforme
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_create_platform_credit_note(
  p_invoice_id uuid, p_amount_ht numeric, p_tva_amount numeric, p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice public.platform_invoices;
  v_hotel_name text;
  v_actor   uuid;
  v_id      uuid;
  v_number  text;
  v_already_credited numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif est obligatoire pour un avoir' USING errcode = '22023';
  END IF;
  IF p_amount_ht IS NULL OR p_amount_ht <= 0 THEN
    RAISE EXCEPTION 'Le montant HT de l''avoir doit être positif' USING errcode = '22023';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  IF v_invoice.status <> 'issued' THEN
    RAISE EXCEPTION 'Un avoir ne peut être émis que sur une facture émise' USING errcode = '22023';
  END IF;

  SELECT COALESCE(sum(amount_ttc), 0) INTO v_already_credited
  FROM public.platform_credit_notes WHERE invoice_id = p_invoice_id AND status = 'issued';
  IF (v_already_credited + p_amount_ht + coalesce(p_tva_amount, 0)) > v_invoice.amount_ttc THEN
    RAISE EXCEPTION 'Cet avoir dépasserait le montant total de la facture' USING errcode = '22023';
  END IF;

  v_number := public._next_platform_credit_note_number();
  SELECT id INTO v_actor FROM public.platform_admins WHERE auth_id = auth.uid() LIMIT 1;
  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_invoice.hotel_id;

  INSERT INTO public.platform_credit_notes (invoice_id, hotel_id, number, amount_ht, tva_amount, amount_ttc, reason, created_by)
  VALUES (p_invoice_id, v_invoice.hotel_id, v_number, p_amount_ht, coalesce(p_tva_amount, 0),
          p_amount_ht + coalesce(p_tva_amount, 0), p_reason, v_actor)
  RETURNING id INTO v_id;

  PERFORM public._platform_log('credit_note.create', 'platform_invoice', p_invoice_id::text, v_invoice.hotel_id, v_hotel_name,
    jsonb_build_object('credit_note_id', v_id, 'number', v_number, 'amount_ttc', p_amount_ht + coalesce(p_tva_amount, 0), 'reason', p_reason));

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_void_platform_credit_note(p_credit_note_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_cn public.platform_credit_notes; v_hotel_name text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Un motif est obligatoire' USING errcode = '22023';
  END IF;

  SELECT * INTO v_cn FROM public.platform_credit_notes WHERE id = p_credit_note_id;
  IF v_cn.id IS NULL THEN
    RAISE EXCEPTION 'Avoir introuvable' USING errcode = 'P0002';
  END IF;
  IF v_cn.status = 'voided' THEN
    RAISE EXCEPTION 'Cet avoir est déjà annulé' USING errcode = '22023';
  END IF;

  UPDATE public.platform_credit_notes SET status = 'voided', voided_at = now(), void_reason = p_reason
  WHERE id = p_credit_note_id;

  SELECT name INTO v_hotel_name FROM public.hotels WHERE id = v_cn.hotel_id;
  PERFORM public._platform_log('credit_note.void', 'platform_invoice', v_cn.invoice_id::text, v_cn.hotel_id, v_hotel_name,
    jsonb_build_object('credit_note_id', p_credit_note_id, 'reason', p_reason));
END;
$function$;

-- ============================================================================
-- 7. Abonnement suspendu pour impayé — fine couche au-dessus de admin_suspend_subscription (Lot 1)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_suspend_subscription_for_nonpayment(
  p_subscription_id uuid, p_invoice_id uuid, p_reason text DEFAULT NULL
) RETURNS hotel_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_invoice public.platform_invoices; v_number text; v_full_reason text;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT * INTO v_invoice FROM public.platform_invoices WHERE id = p_invoice_id;
  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Facture introuvable' USING errcode = 'P0002';
  END IF;
  IF v_invoice.subscription_id IS DISTINCT FROM p_subscription_id THEN
    RAISE EXCEPTION 'Cette facture n''est pas liée à cet abonnement' USING errcode = '22023';
  END IF;

  v_number := coalesce(v_invoice.number, 'proforma');
  -- Préfixe normalisé 'IMPAYÉ' : c'est ce marqueur, posé uniquement par cette fonction, que le
  -- tableau de bord financier recherche dans hotel_subscription_events.reason pour distinguer
  -- une suspension pour impayé d'une suspension pour toute autre cause.
  v_full_reason := 'IMPAYÉ (facture ' || v_number || ')' || CASE WHEN p_reason IS NOT NULL AND btrim(p_reason) <> ''
    THEN ' : ' || p_reason ELSE '' END;

  RETURN public.admin_suspend_subscription(p_subscription_id, v_full_reason);
END;
$function$;

-- ============================================================================
-- 8. Tableau de bord financier
-- ============================================================================
CREATE OR REPLACE FUNCTION public.platform_billing_dashboard_kpis()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
  END IF;

  SELECT jsonb_build_object(
    'invoices_by_status', (
      SELECT jsonb_object_agg(status, cnt) FROM (
        SELECT status, count(*) AS cnt FROM public.platform_invoices GROUP BY status
      ) s
    ),
    'total_billed_ttc', (SELECT COALESCE(sum(amount_ttc), 0) FROM public.platform_invoices WHERE status = 'issued'),
    'total_collected', (SELECT COALESCE(sum(amount), 0) FROM public.platform_payments WHERE status = 'recorded'),
    'total_credited', (SELECT COALESCE(sum(amount_ttc), 0) FROM public.platform_credit_notes WHERE status = 'issued'),
    'total_overdue', (
      SELECT COALESCE(sum(pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)), 0)
      FROM public.platform_invoices pi
      LEFT JOIN LATERAL (
        SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
        WHERE invoice_id = pi.id AND status = 'issued'
      ) cn ON true
      WHERE pi.status = 'issued' AND pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
        AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0
    ),
    'overdue_invoice_count', (
      SELECT count(*) FROM public.platform_invoices pi
      LEFT JOIN LATERAL (
        SELECT sum(amount_ttc) AS credited FROM public.platform_credit_notes
        WHERE invoice_id = pi.id AND status = 'issued'
      ) cn ON true
      WHERE pi.status = 'issued' AND pi.due_date IS NOT NULL AND pi.due_date < CURRENT_DATE
        AND (pi.amount_ttc - pi.paid_amount - COALESCE(cn.credited, 0)) > 0
    ),
    'subscriptions_suspended_total', (SELECT count(*) FROM public.hotel_subscriptions WHERE status = 'suspended'),
    'subscriptions_suspended_nonpayment', (
      SELECT count(*) FROM public.hotel_subscriptions hs
      WHERE hs.status = 'suspended'
        AND (
          SELECT e.reason FROM public.hotel_subscription_events e
          WHERE e.subscription_id = hs.id AND e.event_type = 'suspended'
          ORDER BY e.created_at DESC LIMIT 1
        ) LIKE 'IMPAYÉ%'
    ),
    'pending_payments_count', (SELECT count(*) FROM public.platform_payments WHERE status = 'pending')
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ============================================================================
-- 9. ACL — retrofix table-level (anon avait tous les privilèges DML) + nouvelles fonctions
-- ============================================================================
REVOKE ALL ON TABLE public.platform_invoices FROM anon, service_role;
REVOKE ALL ON TABLE public.platform_contracts FROM anon, service_role;
REVOKE ALL ON TABLE public.platform_payments FROM anon, service_role;
REVOKE ALL ON TABLE public.platform_credit_notes FROM anon, service_role;
REVOKE ALL ON TABLE public.platform_invoice_sequences FROM anon, authenticated, service_role;
REVOKE ALL ON TABLE public.platform_credit_note_sequences FROM anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_update_hotel_full(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_hotel_full(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_platform_invoices() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_platform_invoices() TO authenticated;

REVOKE ALL ON FUNCTION public.admin_get_platform_invoice_detail(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_platform_invoice_detail(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_create_platform_invoice(uuid, uuid, date, date, numeric, numeric, date, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_platform_invoice(uuid, uuid, date, date, numeric, numeric, date, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_issue_platform_invoice(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_issue_platform_invoice(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_cancel_platform_invoice(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_cancel_platform_invoice(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_record_platform_payment(uuid, numeric, text, text, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_record_platform_payment(uuid, numeric, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_update_platform_payment_status(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_platform_payment_status(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_create_platform_credit_note(uuid, numeric, numeric, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_create_platform_credit_note(uuid, numeric, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_void_platform_credit_note(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_void_platform_credit_note(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_suspend_subscription_for_nonpayment(uuid, uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_suspend_subscription_for_nonpayment(uuid, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.platform_billing_dashboard_kpis() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.platform_billing_dashboard_kpis() TO authenticated;

-- Helpers internes (catégorie 2) : jamais de GRANT client, sur aucun rôle.
REVOKE ALL ON FUNCTION public._next_platform_invoice_number() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._next_platform_credit_note_number() FROM PUBLIC, anon, authenticated, service_role;

-- Fin de migration. Aucune donnée existante perdue (platform_invoices/platform_contracts étaient
-- vides). Aucun service de paiement/e-invoicing réel connecté — modèle prêt à les accueillir
-- (method déjà en checklist bank_transfer/card/sepa/other ; bill_to_vat/siret déjà présents).
