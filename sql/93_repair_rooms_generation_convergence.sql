-- ============================================================================
-- sql/93_repair_rooms_generation_convergence.sql
-- Régularisation — convergence de génération de public.rooms vers la forme
-- réellement servie par production (ADR-012 §9, audit de dérive du
-- 2026-08-02)
--
-- Contexte : `00001_initial_schema` (baseline squashée, trackée) définit
-- `rooms` avec room_number/room_type/room_category/view_type/bathroom_type/
-- capacity/equipment/dotation/status(enum room_status)/client_badge/
-- cleaning_status/... — vérifié par lecture directe du texte de 00001. La
-- table réellement servie par production a été intégralement redéfinie hors
-- bande : colonnes renommées (room_number→number, room_category→category,
-- room_size→surface_m2, capacity→max_occupancy), statut repassé en texte
-- simple, colonnes ménage/enum retirées, nouvelles colonnes ajoutées
-- (base_price, amenities, notes). C'est un script SQL hors dépôt de grande
-- ampleur, pas un hotfix ciblé.
--
-- Cible retenue : la forme de PRODUCTION — vérifiée le 2026-08-02 comme
-- étant celle réellement utilisée par les triggers/fonctions PMS live
-- (`trg_fn_reservation_checkout_housekeeping`, `trg_fn_reservation_room_
-- availability_guard`, `trg_fn_maintenance_ticket_room_block` — tous
-- lisent/écrivent number/status/housekeeping_status) et par les 62 lignes
-- réelles de production (number="101" etc., type="Simple"/"Double",
-- category, base_price, status texte "occupied"/"to_clean"/"available").
--
-- Preuve « zéro référence » pour chaque colonne retirée ci-dessous (condition
-- posée par le mandat : aucun DROP sans preuve) : recherche exhaustive sur
-- (a) tout le dépôt applicatif (public/*.html, sql/*.sql, supabase/
-- functions/**), (b) le corps de TOUTES les fonctions/triggers vivants de
-- production (pg_proc.prosrc) — confirmée à 0 occurrence pour room_number,
-- room_type, room_category, view_type, bathroom_type, room_size, capacity,
-- equipment, dotation, client_badge, vip_instructions, cleaning_status,
-- cleaning_assignee, cleaning_started_at, cleaning_completed_at,
-- breakfast_included, cleanliness_status, eta_arrival, booking_source,
-- npd_status, updated_at (colonne rooms.updated_at spécifiquement — les
-- occurrences de "updated_at" sur d'autres tables ne comptent pas). Les
-- 6 types enum orphelins (room_status, client_badge, cleaning_status,
-- booking_source, room_npd_status, room_cleanliness_status) restent en
-- place (CREATE TYPE non exécuté ici, déjà présents et inoffensifs) —
-- décision volontairement non tranchée, cf. rapport joint.
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
  -- uniquement, jamais destructif : ne fait que copier une valeur).
  IF v_has_legacy THEN
    EXECUTE 'UPDATE public.rooms SET number = room_number WHERE number IS NULL AND room_number IS NOT NULL';
  END IF;

  EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN number SET NOT NULL';

  -- C) status : enum room_status -> text, défaut ''available''.
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='status' AND udt_name <> 'text') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN status DROP DEFAULT';
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN status TYPE text USING status::text';
    EXECUTE $d$ALTER TABLE public.rooms ALTER COLUMN status SET DEFAULT 'available'$d$;
  END IF;

  -- D) Contrainte d'unicité cible (hotel_id, number) — la contrainte legacy
  -- (hotel_id, room_number) est retirée avec la colonne room_number
  -- ci-dessous (CASCADE), inutile de la droper séparément ici.
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

  -- F) Trigger cible : audit générique (trg_audit_rooms), retire le trigger
  -- générique de baseline (set_updated_at) devenu sans objet puisque la
  -- colonne rooms.updated_at elle-même est retirée en section H (preuve de
  -- zéro référence ci-dessus).
  IF EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='rooms' AND tg.tgname='set_updated_at') THEN
    EXECUTE 'DROP TRIGGER set_updated_at ON public.rooms';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='rooms' AND tg.tgname='trg_audit_rooms') THEN
    EXECUTE 'CREATE TRIGGER trg_audit_rooms AFTER INSERT OR DELETE OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn(''room'')';
  END IF;

  -- G) Policies cibles : rooms_select reste inchangée (qual identique des
  -- deux côtés, confirmé par audit). rooms_insert/update/delete (baseline)
  -- retirées au profit de rooms_modify (production).
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

  -- H) Retrait des colonnes de l'ancienne génération — preuve de zéro
  -- référence documentée en en-tête de fichier. CASCADE retire
  -- automatiquement les objets dépendants encore présents (contrainte
  -- rooms_hotel_id_room_number_key et son index, rooms_cleaning_assignee_
  -- fkey, rooms_assigned_to_fkey — cette dernière absente de production,
  -- cf. rapport : « ne PAS ajouter cette FK, la cible ne la contraint pas »).
  IF v_has_legacy THEN
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS room_number CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS room_type CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS room_category CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS view_type CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS bathroom_type CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS room_size CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS capacity CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS equipment CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS dotation CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS client_badge CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS vip_instructions CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS cleaning_status CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS cleaning_assignee CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS cleaning_started_at CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS cleaning_completed_at CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS breakfast_included CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS cleanliness_status CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS eta_arrival CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS booking_source CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS npd_status CASCADE';
    EXECUTE 'ALTER TABLE public.rooms DROP COLUMN IF EXISTS updated_at CASCADE';
    -- assigned_to est CONSERVÉE (colonne commune aux deux générations) ;
    -- seule sa FK legacy (absente en production) est retirée par le CASCADE
    -- de cleaning_assignee ci-dessus si elle y était rattachée par erreur —
    -- vérification explicite au cas où elle serait indépendante :
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.rooms'::regclass AND conname='rooms_assigned_to_fkey') THEN
      EXECUTE 'ALTER TABLE public.rooms DROP CONSTRAINT rooms_assigned_to_fkey';
    END IF;
  END IF;

  RAISE NOTICE '[rooms] convergence de génération terminée (ajouts, statut, contraintes, index, trigger, policies, retraits justifiés).';
END
$converge_rooms$;
