-- ============================================================================
-- sql/93_repair_rooms_generation_convergence.sql
-- Régularisation — convergence ADDITIVE de public.rooms vers la forme
-- réellement servie par production (ADR-012 §9, audit de dérive du
-- 2026-08-02 ; révisé le 2026-08-02 suite à l'arbitrage explicite du
-- mandat : aucun DROP COLUMN sans audit du dépôt PMS, inaccessible depuis
-- ce dépôt).
--
-- Contexte : `00001_initial_schema` (baseline squashée, trackée) définit
-- `rooms` avec room_number/room_type/room_category/view_type/bathroom_type/
-- capacity/equipment/dotation/status(enum room_status)/client_badge/
-- cleaning_status/... — vérifié par lecture directe du texte de 00001. La
-- table réellement servie par production a été intégralement redéfinie hors
-- bande : colonnes renommées (room_number→number, room_category→category,
-- room_size→surface_m2, capacity→max_occupancy), statut repassé en texte
-- simple, colonnes ménage/enum absentes côté production, nouvelles colonnes
-- ajoutées (base_price, amenities, notes).
--
-- Cible retenue pour les colonnes ADDITIVES : la forme de PRODUCTION —
-- vérifiée le 2026-08-02 comme étant celle réellement utilisée par les
-- triggers/fonctions PMS live (`trg_fn_reservation_checkout_housekeeping`,
-- `trg_fn_reservation_room_availability_guard`,
-- `trg_fn_maintenance_ticket_room_block` — tous lisent/écrivent
-- number/status/housekeeping_status) et par les 62 lignes réelles de
-- production.
--
-- RÉVISION 2026-08-02 — colonnes de l'ancienne génération (room_number,
-- room_type, room_category, view_type, bathroom_type, room_size, capacity,
-- equipment, dotation, client_badge, vip_instructions, cleaning_status,
-- cleaning_assignee, cleaning_started_at, cleaning_completed_at,
-- breakfast_included, cleanliness_status, eta_arrival, booking_source,
-- npd_status, updated_at) : la version précédente de ce fichier les
-- DROPpait sur preuve de « zéro référence dans ce dépôt + corps des
-- fonctions de production ». Cette preuve est jugée insuffisante par le
-- mandat : le PMS orienté client (réservations, housekeeping, OTA) vit dans
-- un dépôt séparé non accessible depuis cette session, et « l'absence de
-- référence dans flowtym-rh ne suffit pas ». Aucun DROP COLUMN n'est donc
-- exécuté ici. Les 21 colonnes legacy sont CONSERVÉES intégralement (aucune
-- perte de données, aucun DROP), uniquement marquées comme dépréciées via
-- COMMENT ON COLUMN — le retrait effectif est différé à une migration
-- ultérieure, après audit complet du dépôt PMS (cf. rapport joint : preuve
-- de dépendance requise = code de ce dépôt + code PMS + Edge Functions +
-- vues/fonctions SQL + exports/rapports, pour chacune).
--
-- Trois-états : le bloc détecte l'état « génération pristine » (room_number
-- présent, number absent) vs « déjà convergé » (number présent) vs un état
-- partiel inattendu (RAISE EXCEPTION, aucune correction automatique).
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration. À
-- appliquer sur une branche fraîchement rejouée AVANT toute insertion de
-- données (fixtures QA ou autres) dans rooms.
-- ============================================================================

DO $converge_rooms$
DECLARE
  v_has_legacy boolean;
  v_has_target boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='room_number')
    INTO v_has_legacy;
  SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='number')
    INTO v_has_target;

  IF v_has_target AND NOT v_has_legacy THEN
    RAISE NOTICE '[rooms] déjà convergé vers la génération production — aucune action.';
    RETURN;
  END IF;

  IF v_has_target AND v_has_legacy THEN
    RAISE NOTICE '[rooms] état intermédiaire détecté (number ET room_number présents) — poursuite pour terminer la convergence (colonnes cibles déjà ajoutées lors d''une exécution précédente partielle).';
  ELSIF NOT v_has_legacy AND NOT v_has_target THEN
    RAISE EXCEPTION '[rooms] état inattendu : ni room_number (génération pristine) ni number (génération cible) présents. Aucune correction automatique — vérifier manuellement.';
  END IF;

  -- A) Colonnes cibles manquantes (ADD COLUMN IF NOT EXISTS : sûr même en
  -- ré-exécution partielle).
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS number text';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS category text';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS surface_m2 numeric(6,1)';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS max_occupancy integer DEFAULT 2';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS base_price numeric(10,2)';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS amenities jsonb DEFAULT ''[]''';
  EXECUTE 'ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS notes text';

  -- B) Backfill number depuis room_number si des lignes existent déjà
  -- (table normalement vide sur un rejeu frais — filet de sécurité
  -- uniquement, jamais destructif : ne fait que copier une valeur, ne
  -- touche pas room_number qui reste intact).
  IF v_has_legacy THEN
    EXECUTE 'UPDATE public.rooms SET number = room_number WHERE number IS NULL AND room_number IS NOT NULL';
  END IF;

  EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN number SET NOT NULL';

  -- C) status : enum room_status -> text, défaut ''available''. Conversion
  -- de type, pas de perte : tout literal enum existant se traduit
  -- exactement en son texte via ::text, aucune valeur ne peut échouer ce
  -- cast (ensemble fini de valeurs enum -> texte total).
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='status' AND udt_name <> 'text') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN status DROP DEFAULT';
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN status TYPE text USING status::text';
    EXECUTE $d$ALTER TABLE public.rooms ALTER COLUMN status SET DEFAULT 'available'$d$;
  END IF;

  -- D) Contrainte d'unicité cible (hotel_id, number) — additive, ne touche
  -- pas à la contrainte legacy (hotel_id, room_number) qui reste en place
  -- puisque room_number n'est plus droppée (cf. révision ci-dessus).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.rooms'::regclass AND conname='rooms_hotel_id_number_key') THEN
    EXECUTE 'ALTER TABLE public.rooms ADD CONSTRAINT rooms_hotel_id_number_key UNIQUE (hotel_id, number)';
  END IF;

  -- E) Index cibles.
  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_rooms_hotel ON public.rooms USING btree (hotel_id)';
  -- idx_rooms_status cible : btree(status) seul (production), remplace la
  -- version pristine btree(hotel_id, status) si elle diffère.
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='rooms' AND indexname='idx_rooms_status' AND indexdef LIKE '%(hotel_id, status)%') THEN
    EXECUTE 'DROP INDEX public.idx_rooms_status';
  END IF;
  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_rooms_status ON public.rooms USING btree (status)';
  EXECUTE $i$CREATE INDEX IF NOT EXISTS idx_rooms_type_code ON public.rooms USING btree (hotel_id, room_type_code) WHERE (room_type_code IS NOT NULL)$i$;

  -- F) Trigger cible : audit générique (trg_audit_rooms) remplace le
  -- trigger générique de baseline (set_updated_at). Ne supprime aucune
  -- donnée : la colonne updated_at elle-même est conservée (cf. révision),
  -- seul le mécanisme qui la rafraîchissait automatiquement à chaque
  -- UPDATE change — sa valeur existante reste lisible, elle cesse
  -- simplement d'être mise à jour (cohérent avec son statut « déprécié »).
  IF EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='rooms' AND tg.tgname='set_updated_at') THEN
    EXECUTE 'DROP TRIGGER set_updated_at ON public.rooms';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='rooms' AND tg.tgname='trg_audit_rooms') THEN
    EXECUTE 'CREATE TRIGGER trg_audit_rooms AFTER INSERT OR DELETE OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn(''room'')';
  END IF;

  -- G) Policies cibles : rooms_select reste inchangée (qual identique des
  -- deux côtés, confirmé par audit). rooms_insert/update (baseline)
  -- retirées au profit de rooms_modify (production) — le retrait d'une
  -- policy ne touche jamais aux données, seulement aux règles d'accès.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rooms' AND policyname='rooms_modify') THEN
    EXECUTE $pol$CREATE POLICY rooms_modify ON public.rooms FOR ALL TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rooms' AND policyname='rooms_insert') THEN
    EXECUTE 'DROP POLICY rooms_insert ON public.rooms';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rooms' AND policyname='rooms_update') THEN
    EXECUTE 'DROP POLICY rooms_update ON public.rooms';
  END IF;
  -- rooms_delete : anomalie non résolue signalée par l'audit — absente de
  -- TOUTE migration trackée (y compris 00001) alors que présente sur le
  -- rejeu, origine indéterminée (mécanisme de provisioning Supabase
  -- Branching hors supabase_migrations, hypothèse non confirmée). Retirée
  -- ici par cohérence avec la cible production (qui ne l'a pas), mais
  -- signalée explicitement plutôt que silencieusement supprimée.
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rooms' AND policyname='rooms_delete') THEN
    RAISE NOTICE '[rooms] policy rooms_delete retirée — absente de production ET absente de tout texte de migration tracké (anomalie non résolue, cf. rapport d''audit joint).';
    EXECUTE 'DROP POLICY rooms_delete ON public.rooms';
  END IF;

  -- H) RÉVISÉ — aucun DROP COLUMN. Les 21 colonnes de l'ancienne génération
  -- sont marquées legacy/dépréciées via commentaire, jamais retirées tant
  -- que l'audit du dépôt PMS n'a pas prouvé l'absence de toute lecture.
  IF v_has_legacy THEN
    EXECUTE $c$COMMENT ON COLUMN public.rooms.room_number IS 'LEGACY (ancienne génération, remplacée par "number") — conservée sans retrait : aucune preuve d''absence de lecture côté dépôt PMS (hors périmètre de cet audit). Ne pas utiliser pour du nouveau code. Retrait différé à une migration ultérieure après audit PMS complet.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.room_type IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.room_category IS 'LEGACY (ancienne génération, remplacée par "category") — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.view_type IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.bathroom_type IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.room_size IS 'LEGACY (ancienne génération, remplacée par "surface_m2") — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.capacity IS 'LEGACY (ancienne génération, remplacée par "max_occupancy") — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.equipment IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.dotation IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.client_badge IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.vip_instructions IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.cleaning_status IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.cleaning_assignee IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.cleaning_started_at IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.cleaning_completed_at IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.breakfast_included IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.cleanliness_status IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.eta_arrival IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.booking_source IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.npd_status IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.rooms.updated_at IS 'LEGACY (ancienne génération, trigger de rafraîchissement automatique retiré au profit de trg_audit_rooms) — conservée sans retrait, valeur figée à sa dernière mise à jour. Audit PMS requis avant suppression.'$c$;
  END IF;

  -- assigned_to est CONSERVÉE (colonne commune aux deux générations, jamais
  -- dépréciée) ; seule sa FK legacy (absente en production) est retirée —
  -- le retrait d'une contrainte FK ne supprime aucune donnée, seulement une
  -- règle de validation.
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.rooms'::regclass AND conname='rooms_assigned_to_fkey') THEN
    EXECUTE 'ALTER TABLE public.rooms DROP CONSTRAINT rooms_assigned_to_fkey';
  END IF;

  RAISE NOTICE '[rooms] convergence additive terminée (ajouts, statut, contraintes, index, trigger, policies) ; colonnes legacy conservées et marquées dépréciées, aucun DROP COLUMN.';
END
$converge_rooms$;
