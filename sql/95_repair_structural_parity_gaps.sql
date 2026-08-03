-- ============================================================================
-- sql/95_repair_structural_parity_gaps.sql
-- Régularisation — clôture des 10 écarts résiduels détectés par la
-- comparaison structurelle automatisée (32/42 tables conformes, 10
-- divergentes) exécutée le 2026-08-02 sur la branche régularisée par
-- sql/91-94, plus 6 corrections de GRANT EXECUTE sur des fonctions support.
--
-- Chaque écart ci-dessous a été vérifié objet par objet contre la production
-- (hzrzkvdebaadditvbqis) le 2026-08-02 — aucune correction par recopie
-- aveugle : texte exact extrait via pg_get_triggerdef/pg_get_functiondef/
-- pg_views.definition/col_description/pg_get_expr, jamais reformulé.
--
-- RÉVISION 2026-08-02 : la section B (hotels) ne DROP plus aucune colonne.
-- room_count/user_count/updated_at sont conservées et marquées legacy —
-- le mandat exige un audit du dépôt PMS (inaccessible depuis ce dépôt)
-- avant tout retrait de colonne, "l'absence de référence dans flowtym-rh
-- ne suffit pas". Conséquence assumée et documentée : la branche
-- régularisée diverge désormais de production sur ces 3 colonnes
-- spécifiques (divergence expliquée, pas silencieuse) tant que ce retrait
-- n'est pas fait dans une migration ultérieure dédiée.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A) audit_logs — commentaire de colonne : sql/91 avait paraphrasé au lieu de
--    recopier le texte exact de production.
-- ----------------------------------------------------------------------------
COMMENT ON COLUMN public.audit_logs.actor_label IS 'Étiquette humainement lisible de l''acteur quand actor_user_id est NULL (ex: "Cron", "Service Role", "Anonymous").';

-- ----------------------------------------------------------------------------
-- B) hotels — RÉVISÉ 2026-08-02 : aucun DROP COLUMN (mandat : le PMS vit
--    dans un dépôt séparé inaccessible, "l'absence de référence dans
--    flowtym-rh ne suffit pas"). room_count/user_count/updated_at sont
--    conservées et marquées legacy/dépréciées au lieu d'être retirées.
--    Le reste : correction de la nullabilité de status, ajout du trigger
--    manquant, retrait des 3 policies legacy remplacées en production par
--    les policies _admin/_own (un retrait de policy ne touche aucune
--    donnée), correction du rôle de hotels_select, et correction des 7
--    commentaires Lighthouse (recopiés mot pour mot depuis production, y
--    compris celui de lighthouse_subscription_id totalement absent du
--    rejeu).
-- ----------------------------------------------------------------------------
DO $repair_hotels$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='hotels' AND tg.tgname='set_updated_at') THEN
    EXECUTE 'DROP TRIGGER set_updated_at ON public.hotels';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='hotels' AND column_name='room_count') THEN
    EXECUTE $c$COMMENT ON COLUMN public.hotels.room_count IS 'LEGACY (colonne du baseline pristine, absente de production) — conservée sans retrait : aucune preuve d''absence de lecture côté dépôt PMS (hors périmètre de cet audit). Ne pas utiliser pour du nouveau code. Retrait différé à une migration ultérieure après audit PMS complet.'$c$;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='hotels' AND column_name='user_count') THEN
    EXECUTE $c$COMMENT ON COLUMN public.hotels.user_count IS 'LEGACY (colonne du baseline pristine, absente de production) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='hotels' AND column_name='updated_at') THEN
    EXECUTE $c$COMMENT ON COLUMN public.hotels.updated_at IS 'LEGACY (colonne du baseline pristine, absente de production ; trigger de rafraîchissement automatique retiré) — conservée sans retrait, valeur figée à sa dernière mise à jour. Audit PMS requis avant suppression.'$c$;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='hotels' AND column_name='status' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.hotels ALTER COLUMN status DROP NOT NULL';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='hotels' AND tg.tgname='trg_grant_superadmin_on_new_hotel') THEN
    EXECUTE 'CREATE TRIGGER trg_grant_superadmin_on_new_hotel AFTER INSERT ON public.hotels FOR EACH ROW EXECUTE FUNCTION grant_superadmin_on_new_hotel()';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='hotels' AND policyname='hotels_delete') THEN
    EXECUTE 'DROP POLICY hotels_delete ON public.hotels';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='hotels' AND policyname='hotels_insert') THEN
    EXECUTE 'DROP POLICY hotels_insert ON public.hotels';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='hotels' AND policyname='hotels_update') THEN
    EXECUTE 'DROP POLICY hotels_update ON public.hotels';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='hotels' AND policyname='hotels_select' AND roles <> ARRAY['authenticated']::name[]) THEN
    EXECUTE 'ALTER POLICY hotels_select ON public.hotels TO authenticated';
  END IF;

  RAISE NOTICE '[hotels] parité structurelle terminée (colonnes legacy, nullabilité, trigger, policies, rôle).';
END
$repair_hotels$;

COMMENT ON COLUMN public.hotels.lighthouse_api_token IS 'Lighthouse v3 API token (X-Oi-Authorization header). MUST be encrypted at app level.';
COMMENT ON COLUMN public.hotels.lighthouse_competitor_set_id IS 'Optional Lighthouse compset id; NULL = use default.';
COMMENT ON COLUMN public.hotels.lighthouse_enabled IS 'Hotel is included in Lighthouse contract. Set per-hotel admin-side.';
COMMENT ON COLUMN public.hotels.lighthouse_last_sync_at IS 'Timestamp of the last successful Lighthouse sync.';
COMMENT ON COLUMN public.hotels.lighthouse_otas IS 'Array of OTAs to fetch for this hotel.';
COMMENT ON COLUMN public.hotels.lighthouse_plan_tier IS 'Subscribed Lighthouse plan: none | rate_insight_api_only (25€/mo) | rate_insight_premium (62.40€/mo, 10 competitors + market demand)';
COMMENT ON COLUMN public.hotels.lighthouse_subscription_id IS 'Lighthouse subscriptionId used in /v3/rates queries.';

-- ----------------------------------------------------------------------------
-- C) invoices / payments — précision numérique. sql/92 avait renoncé face à 3
--    vues dépendantes ; ce fichier les recrée à l'identique (texte exact de
--    production) autour de l'ALTER, au lieu de laisser la dette.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_fin02_payments;
DROP VIEW IF EXISTS public.v_fec_entries;
DROP VIEW IF EXISTS public.financial_timeline;

-- invoices.balance est une colonne générée stockée dépendant de total_ttc
-- (découvert à l'exécution : bloque l'ALTER COLUMN TYPE comme les 3 vues
-- ci-dessus). Retirée puis recréée à l'identique (même expression, même
-- type) autour de l'ALTER — jamais silencieusement laissée de côté.
DO $drop_invoices_balance$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.invoices'::regclass AND attname='balance' AND attgenerated='s') THEN
    EXECUTE 'ALTER TABLE public.invoices DROP COLUMN balance';
  END IF;
END
$drop_invoices_balance$;

ALTER TABLE public.invoices
  ALTER COLUMN total_ht TYPE numeric(12,2),
  ALTER COLUMN total_tva TYPE numeric(12,2),
  ALTER COLUMN total_ttc TYPE numeric(12,2);

ALTER TABLE public.payments
  ALTER COLUMN amount TYPE numeric(12,2);

DO $readd_invoices_balance$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.invoices'::regclass AND attname='balance' AND NOT attisdropped) THEN
    EXECUTE $g$ALTER TABLE public.invoices ADD COLUMN balance numeric GENERATED ALWAYS AS (COALESCE(total_ttc, (0)::numeric) - COALESCE(paid_amount, (0)::numeric)) STORED$g$;
  END IF;
END
$readd_invoices_balance$;

CREATE VIEW public.financial_timeline AS
 SELECT 'invoice'::text AS event_type,
    invoices.id AS entity_id,
    invoices.hotel_id,
    invoices.reservation_id,
    invoices.invoice_number AS reference,
    invoices.status,
    invoices.total_ttc AS amount,
    'EUR'::text AS currency,
    COALESCE(invoices.issued_at, invoices.created_at) AS event_at,
    invoices.notes AS description
   FROM invoices
  WHERE ((invoices.hotel_id = get_user_hotel_id()) OR is_platform_admin())
UNION ALL
 SELECT 'payment'::text AS event_type,
    payments.id AS entity_id,
    payments.hotel_id,
    payments.reservation_id,
    COALESCE(payments.reference, (payments.id)::text) AS reference,
    payments.status,
    payments.amount,
    payments.currency,
    COALESCE(payments.collected_at, payments.created_at) AS event_at,
    NULL::text AS description
   FROM payments
  WHERE ((payments.hotel_id = get_user_hotel_id()) OR is_platform_admin())
UNION ALL
 SELECT 'credit_note'::text AS event_type,
    credit_notes.id AS entity_id,
    credit_notes.hotel_id,
    credit_notes.reservation_id,
    credit_notes.credit_note_number AS reference,
    credit_notes.status,
    (- credit_notes.total_ttc) AS amount,
    'EUR'::text AS currency,
    COALESCE(credit_notes.issued_at, credit_notes.created_at) AS event_at,
    credit_notes.reason AS description
   FROM credit_notes
  WHERE ((credit_notes.hotel_id = get_user_hotel_id()) OR is_platform_admin())
UNION ALL
 SELECT 'deposit'::text AS event_type,
    deposits.id AS entity_id,
    deposits.hotel_id,
    deposits.reservation_id,
    (deposits.id)::text AS reference,
    deposits.status,
    deposits.amount,
    deposits.currency,
    deposits.created_at AS event_at,
    deposits.notes AS description
   FROM deposits
  WHERE ((deposits.hotel_id = get_user_hotel_id()) OR is_platform_admin());

CREATE VIEW public.v_fec_entries AS
 WITH payment_account_map AS (
         SELECT 'CB'::text AS method,
            '512100'::text AS compte_num,
            'Banque - CB'::text AS compte_lib
        UNION ALL
         SELECT 'CARD'::text AS text,
            '512100'::text AS text,
            'Banque - CB'::text AS text
        UNION ALL
         SELECT 'CARTE BANCAIRE'::text AS text,
            '512100'::text AS text,
            'Banque - CB'::text AS text
        UNION ALL
         SELECT 'CARTE'::text AS text,
            '512100'::text AS text,
            'Banque - CB'::text AS text
        UNION ALL
         SELECT 'VIREMENT'::text AS text,
            '512000'::text AS text,
            'Banque - Virement'::text AS text
        UNION ALL
         SELECT 'TRANSFER'::text AS text,
            '512000'::text AS text,
            'Banque - Virement'::text AS text
        UNION ALL
         SELECT 'WIRE'::text AS text,
            '512000'::text AS text,
            'Banque - Virement'::text AS text
        UNION ALL
         SELECT 'CHEQUE'::text AS text,
            '512110'::text AS text,
            'Banque - Chèque'::text AS text
        UNION ALL
         SELECT 'CHÈQUE'::text AS text,
            '512110'::text AS text,
            'Banque - Chèque'::text AS text
        UNION ALL
         SELECT 'CHECK'::text AS text,
            '512110'::text AS text,
            'Banque - Chèque'::text AS text
        UNION ALL
         SELECT 'ESPECES'::text AS text,
            '530000'::text AS text,
            'Caisse - Espèces'::text AS text
        UNION ALL
         SELECT 'ESPÈCES'::text AS text,
            '530000'::text AS text,
            'Caisse - Espèces'::text AS text
        UNION ALL
         SELECT 'CASH'::text AS text,
            '530000'::text AS text,
            'Caisse - Espèces'::text AS text
        UNION ALL
         SELECT 'OTA'::text AS text,
            '512200'::text AS text,
            'Banque - Payout OTA'::text AS text
        UNION ALL
         SELECT 'PAYPAL'::text AS text,
            '512300'::text AS text,
            'Banque - PayPal'::text AS text
        UNION ALL
         SELECT 'STRIPE'::text AS text,
            '512300'::text AS text,
            'Banque - Stripe'::text AS text
        UNION ALL
         SELECT 'PMS'::text AS text,
            '512300'::text AS text,
            'Banque - PMS'::text AS text
        ), inv AS (
         SELECT i.id AS src_id,
            i.hotel_id,
            'VE'::text AS journal_code,
            'Journal des Ventes'::text AS journal_lib,
            i.invoice_number AS piece_ref,
            COALESCE(i.issue_date, (i.created_at)::date) AS ecr_date,
            COALESCE(i.issue_date, (i.created_at)::date) AS piece_date,
            COALESCE(NULLIF(i.guest_name, ''::text), 'Client divers'::text) AS guest_name,
            COALESCE(i.total_ht, (0)::numeric) AS ht,
            COALESCE(i.total_tva, (0)::numeric) AS tva,
            COALESCE(i.total_ttc, (0)::numeric) AS ttc,
            ((('Facture '::text || i.invoice_number) || ' - '::text) || COALESCE(i.guest_name, 'Client'::text)) AS ecr_lib,
            i.reservation_id,
            COALESCE(i.created_at, now()) AS valid_date
           FROM invoices i
          WHERE (COALESCE(i.status, 'draft'::text) <> 'cancelled'::text)
        ), inv_lines AS (
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '411000'::text AS compte_num,
            'Clients'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            inv.ttc AS debit,
            (0)::numeric AS credit,
            inv.ecr_lib,
            1 AS sub_order
           FROM inv
        UNION ALL
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '707000'::text AS compte_num,
            'Ventes - Hébergement'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            (0)::numeric AS debit,
            inv.ht AS credit,
            inv.ecr_lib,
            2
           FROM inv
          WHERE (inv.ht > (0)::numeric)
        UNION ALL
         SELECT inv.hotel_id,
            inv.src_id,
            inv.journal_code,
            inv.journal_lib,
            inv.piece_ref,
            inv.ecr_date,
            inv.piece_date,
            inv.valid_date,
            '445710'::text AS compte_num,
            'TVA collectée'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            (0)::numeric AS debit,
            inv.tva AS credit,
            inv.ecr_lib,
            3
           FROM inv
          WHERE (inv.tva > (0)::numeric)
        ), pay AS (
         SELECT p.id AS src_id,
            p.hotel_id,
            'BQ'::text AS journal_code,
            'Journal de Banque'::text AS journal_lib,
            COALESCE(p.reference, p.transaction_id, (p.id)::text) AS piece_ref,
            COALESCE((p.payment_date)::date, (p.created_at)::date) AS ecr_date,
            COALESCE((p.payment_date)::date, (p.created_at)::date) AS piece_date,
            COALESCE(p.amount, (0)::numeric) AS ttc,
            upper(COALESCE(p.payment_method, 'CB'::text)) AS method,
            ((('Encaissement '::text || COALESCE(p.payment_method, 'CB'::text)) || ' - '::text) || COALESCE(p.reference, (p.id)::text)) AS ecr_lib,
            COALESCE(p.created_at, now()) AS valid_date
           FROM payments p
          WHERE (COALESCE(p.status, 'completed'::text) <> 'cancelled'::text)
        ), pay_lines AS (
         SELECT py.hotel_id,
            py.src_id,
            py.journal_code,
            py.journal_lib,
            py.piece_ref,
            py.ecr_date,
            py.piece_date,
            py.valid_date,
            COALESCE(m.compte_num, '512000'::text) AS compte_num,
            COALESCE(m.compte_lib, 'Banque - Autre'::text) AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            py.ttc AS debit,
            (0)::numeric AS credit,
            py.ecr_lib,
            1 AS sub_order
           FROM (pay py
             LEFT JOIN payment_account_map m ON ((m.method = py.method)))
        UNION ALL
         SELECT py.hotel_id,
            py.src_id,
            py.journal_code,
            py.journal_lib,
            py.piece_ref,
            py.ecr_date,
            py.piece_date,
            py.valid_date,
            '411000'::text AS compte_num,
            'Clients'::text AS compte_lib,
            NULL::text AS compaux_num,
            NULL::text AS compaux_lib,
            (0)::numeric AS debit,
            py.ttc AS credit,
            py.ecr_lib,
            2
           FROM pay py
        ), all_lines AS (
         SELECT inv_lines.hotel_id,
            inv_lines.src_id,
            inv_lines.journal_code,
            inv_lines.journal_lib,
            inv_lines.piece_ref,
            inv_lines.ecr_date,
            inv_lines.piece_date,
            inv_lines.valid_date,
            inv_lines.compte_num,
            inv_lines.compte_lib,
            inv_lines.compaux_num,
            inv_lines.compaux_lib,
            inv_lines.debit,
            inv_lines.credit,
            inv_lines.ecr_lib,
            inv_lines.sub_order
           FROM inv_lines
        UNION ALL
         SELECT pay_lines.hotel_id,
            pay_lines.src_id,
            pay_lines.journal_code,
            pay_lines.journal_lib,
            pay_lines.piece_ref,
            pay_lines.ecr_date,
            pay_lines.piece_date,
            pay_lines.valid_date,
            pay_lines.compte_num,
            pay_lines.compte_lib,
            pay_lines.compaux_num,
            pay_lines.compaux_lib,
            pay_lines.debit,
            pay_lines.credit,
            pay_lines.ecr_lib,
            pay_lines.sub_order
           FROM pay_lines
        ), numbered AS (
         SELECT all_lines.hotel_id,
            all_lines.journal_code,
            all_lines.journal_lib,
            dense_rank() OVER (PARTITION BY all_lines.hotel_id, all_lines.journal_code, (date_part('year'::text, all_lines.ecr_date)) ORDER BY all_lines.ecr_date, all_lines.src_id) AS ecr_num,
            all_lines.ecr_date,
            all_lines.compte_num,
            all_lines.compte_lib,
            all_lines.compaux_num,
            all_lines.compaux_lib,
            all_lines.piece_ref,
            all_lines.piece_date,
            all_lines.ecr_lib,
            all_lines.debit,
            all_lines.credit,
            all_lines.valid_date,
            all_lines.src_id,
            all_lines.sub_order
           FROM all_lines
        )
 SELECT hotel_id,
    journal_code AS "JournalCode",
    journal_lib AS "JournalLib",
    ((journal_code || to_char((ecr_date)::timestamp with time zone, 'YYYY'::text)) || lpad((ecr_num)::text, 6, '0'::text)) AS "EcritureNum",
    to_char((ecr_date)::timestamp with time zone, 'YYYYMMDD'::text) AS "EcritureDate",
    compte_num AS "CompteNum",
    compte_lib AS "CompteLib",
    COALESCE(compaux_num, ''::text) AS "CompAuxNum",
    COALESCE(compaux_lib, ''::text) AS "CompAuxLib",
    piece_ref AS "PieceRef",
    to_char((piece_date)::timestamp with time zone, 'YYYYMMDD'::text) AS "PieceDate",
    ecr_lib AS "EcritureLib",
    to_char(debit, 'FM999999990D00'::text) AS "Debit",
    to_char(credit, 'FM999999990D00'::text) AS "Credit",
    ''::text AS "EcritureLet",
    ''::text AS "DateLet",
    to_char(valid_date, 'YYYYMMDD'::text) AS "ValidDate",
    ''::text AS "Montantdevise",
    ''::text AS "Idevise",
    src_id,
    sub_order,
    ecr_num
   FROM numbered;

CREATE VIEW public.v_fin02_payments AS
 SELECT payment_method,
    count(*) AS nb_transactions,
    sum(amount) AS total_amount,
    round(((sum(amount) * 100.0) / NULLIF(sum(sum(amount)) OVER (), (0)::numeric)), 1) AS share_pct
   FROM payments
  WHERE (status = 'completed'::text)
  GROUP BY payment_method
  ORDER BY (sum(amount)) DESC;

-- ----------------------------------------------------------------------------
-- D) lighthouse_imports — duration_seconds est une colonne GÉNÉRÉE STOCKÉE en
--    production (attgenerated='s'), pas un DEFAULT (impossible : référence
--    d'autres colonnes de la même ligne). sql/92 avait correctement identifié
--    l'impossibilité d'un DEFAULT classique mais n'était pas allé jusqu'à la
--    vraie mécanique (GENERATED). Conversion sûre : la colonne est
--    actuellement simple/nullable et jamais alimentée directement par le code
--    applicatif (elle est dérivée, jamais un champ de formulaire) — un
--    DROP+ADD ne perd donc aucune donnée légitime. Corrige aussi les 2
--    policies.
-- ----------------------------------------------------------------------------
DO $repair_lighthouse_imports_gen$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute WHERE attrelid='public.lighthouse_imports'::regclass AND attname='duration_seconds' AND attgenerated='s'
  ) THEN
    EXECUTE 'ALTER TABLE public.lighthouse_imports DROP COLUMN IF EXISTS duration_seconds';
    EXECUTE $g$ALTER TABLE public.lighthouse_imports ADD COLUMN duration_seconds numeric GENERATED ALWAYS AS (CASE WHEN (processed_at IS NULL) THEN NULL::numeric ELSE EXTRACT(epoch FROM (processed_at - uploaded_at)) END) STORED$g$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_no_modify' AND with_check IS NULL) THEN
    EXECUTE 'DROP POLICY lighthouse_imports_no_modify ON public.lighthouse_imports';
    EXECUTE $pol$CREATE POLICY lighthouse_imports_no_modify ON public.lighthouse_imports FOR UPDATE USING (false)$pol$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_select' AND roles <> ARRAY['public']::name[]) THEN
    EXECUTE 'ALTER POLICY lighthouse_imports_select ON public.lighthouse_imports TO public';
  END IF;

  RAISE NOTICE '[lighthouse_imports] colonne générée + policies alignées sur production.';
END
$repair_lighthouse_imports_gen$;

-- ----------------------------------------------------------------------------
-- E) rooms — nullabilité/défaut de floor/status/created_at, index
--    idx_rooms_floor résiduel du rejeu pur absent de production, rôle de
--    rooms_select.
-- ----------------------------------------------------------------------------
DO $repair_rooms_parity$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='floor' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN floor DROP NOT NULL';
  END IF;
  EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN floor SET DEFAULT 1';

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='status' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN status DROP NOT NULL';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='created_at' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN created_at DROP NOT NULL';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='rooms' AND indexname='idx_rooms_floor') THEN
    EXECUTE 'DROP INDEX public.idx_rooms_floor';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rooms' AND policyname='rooms_select' AND roles <> ARRAY['authenticated']::name[]) THEN
    EXECUTE 'ALTER POLICY rooms_select ON public.rooms TO authenticated';
  END IF;

  RAISE NOTICE '[rooms] parité structurelle terminée.';
END
$repair_rooms_parity$;

-- ----------------------------------------------------------------------------
-- F) user_active_hotel / user_hotels — texte de commentaire exact.
-- ----------------------------------------------------------------------------
COMMENT ON TABLE public.user_active_hotel IS 'Stocke l''hôtel actif (sélectionné par le sélecteur UI) pour chaque utilisateur. Un seul hôtel actif à la fois par user.';
COMMENT ON TABLE public.user_hotels IS 'Multi-tenant access: une row par (user, hotel) auquel l''utilisateur a accès. is_default = l''hôtel sélectionné par défaut au login.';

-- ----------------------------------------------------------------------------
-- G) user_invitations — écart le plus sévère : RLS totalement désactivée
--    après rejeu pur (aucune migration trackée ne l'active), 2 index et 2
--    policies manquants. Table absente du périmètre initial de sql/91-94 ;
--    couverte ici pour la première fois.
-- ----------------------------------------------------------------------------
DO $repair_user_invitations$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='user_invitations' AND relkind='r') THEN
    RAISE EXCEPTION '[user_invitations] table absente — hors périmètre attendu de cette migration, arrêt.';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.user_invitations'::regclass) THEN
    EXECUTE 'ALTER TABLE public.user_invitations ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='user_invitations' AND indexname='idx_user_invitations_hotel') THEN
    EXECUTE 'CREATE INDEX idx_user_invitations_hotel ON public.user_invitations USING btree (hotel_id, status)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='user_invitations' AND indexname='idx_user_invitations_token') THEN
    EXECUTE 'CREATE UNIQUE INDEX idx_user_invitations_token ON public.user_invitations USING btree (token)';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_invitations' AND policyname='user_invitations_modify') THEN
    EXECUTE $pol$CREATE POLICY user_invitations_modify ON public.user_invitations FOR ALL TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_invitations' AND policyname='user_invitations_select') THEN
    EXECUTE $pol$CREATE POLICY user_invitations_select ON public.user_invitations FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  RAISE NOTICE '[user_invitations] RLS activée, index et policies restaurés.';
END
$repair_user_invitations$;

-- ----------------------------------------------------------------------------
-- H) users — défaut manquant sur role, 2 index résiduels du rejeu pur absents
--    de production, policy users_self_update manquante, rôle de users_select.
-- ----------------------------------------------------------------------------
DO $repair_users_parity$
BEGIN
  EXECUTE $d$ALTER TABLE public.users ALTER COLUMN role SET DEFAULT 'reception'::admin_user_role$d$;

  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='users' AND indexname='idx_users_email') THEN
    EXECUTE 'DROP INDEX public.idx_users_email';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='users' AND indexname='idx_users_role') THEN
    EXECUTE 'DROP INDEX public.idx_users_role';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_self_update') THEN
    EXECUTE $pol$CREATE POLICY users_self_update ON public.users FOR UPDATE TO authenticated USING (auth_id = auth.uid()) WITH CHECK (auth_id = auth.uid())$pol$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_select' AND roles <> ARRAY['authenticated']::name[]) THEN
    EXECUTE 'ALTER POLICY users_select ON public.users TO authenticated';
  END IF;

  RAISE NOTICE '[users] parité structurelle terminée.';
END
$repair_users_parity$;

-- ----------------------------------------------------------------------------
-- I) Grants EXECUTE — 6 fonctions support dont les GRANT/REVOKE posés par
--    sql/91 divergent de production (3 trop larges, security-relevant pour
--    des fonctions SECURITY DEFINER ; 2 trop étroites). Corps de fonction
--    identiques des deux côtés (vérifié) — seuls les privilèges différent.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.audit_resolve_actor() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.audit_trigger_fn() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_user_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rh_grant_hotel_access(uuid, text, text, uuid, admin_user_role) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.list_user_hotels() TO PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_active_hotel(uuid) TO PUBLIC, anon, service_role;
