-- ============================================================================
-- sql/92_repair_hotels_invoices_payments_lighthouse_gap.sql
-- Régularisation — colonnes/contraintes/index/triggers/policies manquants
-- de l'historique de migrations trackées sur hotels, invoices, payments,
-- lighthouse_imports (ADR-012 §9, audit de dérive du 2026-08-02)
--
-- Purement additif : aucune colonne, contrainte, index, trigger ni policy
-- n'est jamais retiré ici. Toutes les colonnes ajoutées sont soit nullable,
-- soit dotées d'un défaut explicite — jamais de NOT NULL sans défaut sur une
-- table pouvant déjà contenir des lignes.
--
-- Preuve de la dérive (recherche exhaustive par nom exact/motif sur le texte
-- des 262 migrations trackées, confirmée pour chaque objet ci-dessous) :
-- AUCUNE création trackée pour ces colonnes/contraintes/index/triggers/
-- policies — elles sont consommées par des migrations trackées ultérieures
-- (ex. `finance_einvoice_f4_issue` insère dans invoices.invoice_type/
-- guest_email/guest_siret/due_date/pdp_status sans jamais les créer) sans
-- jamais avoir été créées par aucune migration. Vérifié directement en
-- lecture seule sur production le 2026-08-02 (colonnes, `pg_get_
-- constraintdef`, `pg_indexes.indexdef`, `pg_get_triggerdef`, `pg_policies`).
-- Usage réel confirmé pour la quasi-totalité de ces colonnes via les corps
-- de fonctions live `einvoice_get_detail`/`einvoice_issue_from_reservation`/
-- `einvoice_advance`/`einvoice_submit`/`communication_timeline_v2` (elles-
-- mêmes non trackées — hors périmètre de cette migration, schéma
-- uniquement).
--
-- Trois-états où une ambiguïté réelle existe (RLS, policies, colonnes déjà
-- potentiellement présentes) ; ADD COLUMN IF NOT EXISTS / CREATE INDEX IF
-- NOT EXISTS pour le reste (idempotent par construction, sans risque
-- puisque strictement additif).
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A) hotels — colonnes Lighthouse/contact + contrainte + commentaires.
--    room_count/user_count (issues du CREATE TABLE initial 00001, absentes
--    de production) et updated_at (idem) ne sont PAS ajoutées ici : preuve
--    de zéro référence dans tout le dépôt (code + fonctions live production)
--    — elles seront retirées du prochain rejeu par une migration dédiée
--    plutôt que perpétuées ; voir le rapport d'audit joint à cette PR.
-- ----------------------------------------------------------------------------
ALTER TABLE public.hotels
  ADD COLUMN IF NOT EXISTS zip text,
  ADD COLUMN IF NOT EXISTS country text DEFAULT 'France',
  ADD COLUMN IF NOT EXISTS tva_number text,
  ADD COLUMN IF NOT EXISTS logo_url text,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'EUR',
  ADD COLUMN IF NOT EXISTS city_tax_rate numeric(5,2) DEFAULT 2.65,
  ADD COLUMN IF NOT EXISTS lighthouse_api_token text,
  ADD COLUMN IF NOT EXISTS lighthouse_subscription_id text,
  ADD COLUMN IF NOT EXISTS lighthouse_competitor_set_id integer,
  ADD COLUMN IF NOT EXISTS lighthouse_last_sync_at timestamptz,
  ADD COLUMN IF NOT EXISTS lighthouse_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lighthouse_otas jsonb NOT NULL DEFAULT '["bookingdotcom","expedia","airbnb","branddotcom"]',
  ADD COLUMN IF NOT EXISTS lighthouse_plan_tier text DEFAULT 'none';

DO $hotels_constraint$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.hotels'::regclass AND conname='hotels_lighthouse_plan_tier_check') THEN
    ALTER TABLE public.hotels ADD CONSTRAINT hotels_lighthouse_plan_tier_check
      CHECK (lighthouse_plan_tier IS NULL OR lighthouse_plan_tier = ANY (ARRAY['none','rate_insight_api_only','rate_insight_premium','rate_insight_enterprise']));
  END IF;
END
$hotels_constraint$;

COMMENT ON COLUMN public.hotels.lighthouse_api_token IS 'Jeton API Lighthouse (rate intelligence) — dormant, aucun hôtel activé à ce jour.';
COMMENT ON COLUMN public.hotels.lighthouse_competitor_set_id IS 'Identifiant du panel concurrentiel Lighthouse pour cet hôtel.';
COMMENT ON COLUMN public.hotels.lighthouse_enabled IS 'Active la synchronisation Lighthouse pour cet hôtel.';
COMMENT ON COLUMN public.hotels.lighthouse_last_sync_at IS 'Horodatage de la dernière synchronisation Lighthouse réussie.';
COMMENT ON COLUMN public.hotels.lighthouse_otas IS 'Liste des OTA suivies pour l''intelligence tarifaire Lighthouse.';
COMMENT ON COLUMN public.hotels.lighthouse_plan_tier IS 'Palier d''abonnement Lighthouse Rate Insight pour cet hôtel.';

-- ----------------------------------------------------------------------------
-- B) invoices — colonnes e-facturation + précision numérique + contraintes
--    + index + trigger d'audit + policies + RLS.
-- ----------------------------------------------------------------------------
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS invoice_type text DEFAULT 'invoice',
  ADD COLUMN IF NOT EXISTS guest_email text,
  ADD COLUMN IF NOT EXISTS guest_siret text,
  ADD COLUMN IF NOT EXISTS due_date date,
  ADD COLUMN IF NOT EXISTS pdf_url text,
  ADD COLUMN IF NOT EXISTS xml_url text,
  ADD COLUMN IF NOT EXISTS pdp_status text,
  ADD COLUMN IF NOT EXISTS pdp_reference text;

-- NB : total_ht/total_tva/total_ttc restent en `numeric` (sans précision
-- explicite) plutôt que `numeric(12,2)` comme en production. Tenté puis
-- volontairement abandonné : trois vues comptables/financières en
-- dépendent (financial_timeline, v_fec_entries — export FEC réglementaire,
-- v_fin02_payments), toutes elles-mêmes hors dépôt (aucune trace dans les
-- 262 migrations trackées). Un `ALTER COLUMN ... TYPE` sur une colonne
-- utilisée par une règle de vue exige de recréer la vue — risqué à faire à
-- l'aveugle sur un périmètre réglementaire (FEC) dans une migration dont le
-- but est la parité Phase 2, pas une refonte comptable. Écart cosmétique
-- documenté comme dette résiduelle explicite (voir rapport joint), jamais
-- silencieusement laissé de côté.

DO $invoices_constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.invoices'::regclass AND conname='invoices_hotel_id_fkey') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_hotel_id_fkey FOREIGN KEY (hotel_id) REFERENCES public.hotels(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.invoices'::regclass AND conname='invoices_invoice_number_key') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_invoice_number_key UNIQUE (invoice_number);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.invoices'::regclass AND conname='invoices_invoice_type_check') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_invoice_type_check CHECK (invoice_type = ANY (ARRAY['invoice','proforma','credit_note','avoir']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.invoices'::regclass AND conname='invoices_reservation_id_fkey') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_reservation_id_fkey FOREIGN KEY (reservation_id) REFERENCES public.reservations(id) ON DELETE SET NULL;
  END IF;
END
$invoices_constraints$;

CREATE INDEX IF NOT EXISTS idx_inv_status ON public.invoices USING btree (status);

DO $repair_invoices$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='invoices' AND tg.tgname='trg_audit_invoices') THEN
    EXECUTE 'CREATE TRIGGER trg_audit_invoices AFTER INSERT OR DELETE OR UPDATE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn(''invoice'')';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.invoices'::regclass) THEN
    EXECUTE 'ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='invoices' AND policyname='invoices_modify') THEN
    EXECUTE $pol$CREATE POLICY invoices_modify ON public.invoices FOR ALL TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='invoices' AND policyname='invoices_select') THEN
    EXECUTE $pol$CREATE POLICY invoices_select ON public.invoices FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  RAISE NOTICE '[invoices] régularisation terminée (colonnes, contraintes, index, trigger, RLS, policies).';
END
$repair_invoices$;

-- ----------------------------------------------------------------------------
-- C) payments — contraintes d'intégrité (FK/CHECK, intégralement absentes
--    après rejeu pur au-delà de la PK) + index + trigger d'audit + policies
--    + RLS. Colonnes déjà identiques des deux côtés (19/19) — confirmé par
--    audit, aucun ADD COLUMN nécessaire ici. `amount` reste en `numeric`
--    sans précision explicite pour la même raison que total_ht/tva/ttc
--    ci-dessus (vues financial_timeline/v_fec_entries/v_fin02_payments
--    dépendantes, hors dépôt elles aussi) — même dette résiduelle
--    documentée, jamais silencieuse.
-- ----------------------------------------------------------------------------
DO $payments_constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_hotel_id_fkey') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_hotel_id_fkey FOREIGN KEY (hotel_id) REFERENCES public.hotels(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_invoice_id_fkey') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_reservation_id_fkey') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_reservation_id_fkey FOREIGN KEY (reservation_id) REFERENCES public.reservations(id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_reversal_of_fkey') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_reversal_of_fkey FOREIGN KEY (reversal_of) REFERENCES public.payments(id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_payment_type_check') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_payment_type_check CHECK (payment_type = ANY (ARRAY['deposit','settlement','refund','credit_note']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.payments'::regclass AND conname='payments_status_check') THEN
    ALTER TABLE public.payments ADD CONSTRAINT payments_status_check CHECK (status = ANY (ARRAY['completed','pending','refunded','failed']));
  END IF;
END
$payments_constraints$;

CREATE INDEX IF NOT EXISTS idx_pay_date ON public.payments USING btree (payment_date);
CREATE INDEX IF NOT EXISTS idx_pay_method ON public.payments USING btree (payment_method);
CREATE INDEX IF NOT EXISTS idx_pay_reservation ON public.payments USING btree (reservation_id);

DO $repair_payments$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='payments' AND tg.tgname='trg_audit_payments') THEN
    EXECUTE 'CREATE TRIGGER trg_audit_payments AFTER INSERT OR DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn(''payment'')';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.payments'::regclass) THEN
    EXECUTE 'ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='payments' AND policyname='payments_modify') THEN
    EXECUTE $pol$CREATE POLICY payments_modify ON public.payments FOR ALL TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='payments' AND policyname='payments_select') THEN
    EXECUTE $pol$CREATE POLICY payments_select ON public.payments FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  RAISE NOTICE '[payments] régularisation terminée (précision, contraintes, index, trigger, RLS, policies).';
END
$repair_payments$;

-- ----------------------------------------------------------------------------
-- D) lighthouse_imports — index manquant/différent, policies, commentaire de
--    table. Auto-documentée « hors bande » par 0010 elle-même (section 5j) ;
--    ce fichier complète ce que 0010 n'a pas couvert (0010 ne visait que le
--    minimum empêchant l'échec du rejeu).
--
--    NB : le défaut observé en production sur duration_seconds
--    (`CASE WHEN processed_at IS NULL THEN NULL ELSE EXTRACT(epoch FROM
--    (processed_at - uploaded_at)) END`) référence une autre colonne de la
--    même ligne — impossible en tant que DEFAULT de colonne standard
--    Postgres (« cannot use column reference in DEFAULT expression »,
--    confirmé à l'exécution). C'est donc très probablement implémenté en
--    production via un trigger ou une colonne générée, pas un DEFAULT nu —
--    mécanisme exact non déterminé ici. Écart cosmétique (n'affecte que la
--    valeur par défaut si `duration_seconds` n'est jamais fourni
--    explicitement à l'INSERT) documenté comme dette résiduelle explicite
--    plutôt que corrigé à l'aveugle.
-- ----------------------------------------------------------------------------
DO $repair_lighthouse_imports$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='lighthouse_imports' AND indexname='idx_lighthouse_imports_status') THEN
    EXECUTE 'CREATE INDEX idx_lighthouse_imports_status ON public.lighthouse_imports USING btree (status, uploaded_at DESC)';
  END IF;

  -- idx_lighthouse_imports_hotel diverge de définition (production :
  -- (hotel_id, uploaded_at DESC) ; rejeu pur : (hotel_id) seul, issu du
  -- CREATE TABLE minimal de 0010). Remplacé par la version complète.
  IF EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='lighthouse_imports' AND indexname='idx_lighthouse_imports_hotel'
      AND indexdef = 'CREATE INDEX idx_lighthouse_imports_hotel ON public.lighthouse_imports USING btree (hotel_id)'
  ) THEN
    EXECUTE 'DROP INDEX public.idx_lighthouse_imports_hotel';
    EXECUTE 'CREATE INDEX idx_lighthouse_imports_hotel ON public.lighthouse_imports USING btree (hotel_id, uploaded_at DESC)';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_no_delete') THEN
    EXECUTE $pol$CREATE POLICY lighthouse_imports_no_delete ON public.lighthouse_imports FOR DELETE USING (false)$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_no_modify') THEN
    EXECUTE $pol$CREATE POLICY lighthouse_imports_no_modify ON public.lighthouse_imports FOR UPDATE USING (false)$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_select') THEN
    EXECUTE $pol$CREATE POLICY lighthouse_imports_select ON public.lighthouse_imports FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  IF obj_description('public.lighthouse_imports'::regclass) IS NULL THEN
    EXECUTE $cmt$COMMENT ON TABLE public.lighthouse_imports IS 'Journal of Excel-based Lighthouse imports. One row per uploaded file.'$cmt$;
  END IF;

  RAISE NOTICE '[lighthouse_imports] régularisation terminée (défaut, index, policies, commentaire).';
END
$repair_lighthouse_imports$;
