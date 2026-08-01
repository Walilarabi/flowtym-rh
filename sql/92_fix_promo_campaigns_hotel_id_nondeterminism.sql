-- 92_fix_promo_campaigns_hotel_id_nondeterminism.sql
-- ============================================================================
-- Corrige une migration NON DÉTERMINISTE qui casse le rejeu de branche.
--
-- Migration fautive : 20260528161639_security_phase1 (section "1. promo_campaigns").
--
-- Cause racine démontrée : le backfill de promo_campaigns.hotel_id (ajoutée
-- avec une contrainte FK vers public.hotels(id)) utilisait un UUID
-- littéral, réel identifiant d'un hôtel de production :
--
--   UPDATE public.promo_campaigns
--     SET hotel_id = '02b9eb0e-89ef-45de-ba8e-20d4b41c500c'
--     WHERE hotel_id IS NULL;
--
-- Sur production, cet hôtel existe : la contrainte FK est satisfaite. Sur un
-- rejeu de branche Supabase (Branching 2.0, with_data:false — public.hotels
-- part totalement vide), cet UUID ne correspond à aucune ligne :
--   ERROR: insert or update on table "promo_campaigns" violates foreign key
--   constraint "promo_campaigns_hotel_id_fkey"
-- → migration non déterministe : son succès dépend d'un ID de production
--   figé en dur, jamais garanti par le mécanisme de rejeu.
--
-- Correction appliquée (root cause, pas contournement) : résolution
-- dynamique du premier hôtel disponible (`SELECT id FROM hotels LIMIT 1`)
-- au lieu du littéral figé. Si aucun hôtel n'existe (rejeu vierge sans
-- seed), le backfill et le `SET NOT NULL` qui en dépend sont sautés
-- silencieusement — les 10 lignes de démo de promo_campaigns restent avec
-- hotel_id NULL, ce qui est valide (colonne nullable tant que le SET NOT
-- NULL n'a pas été exécuté) et ne bloque aucune migration ultérieure connue
-- à ce jour.
--
-- Application : édition EN PLACE du texte déjà stocké dans
-- supabase_migrations.schema_migrations pour la version 20260528161639 —
-- pas un apply_migration standard (qui ajouterait une nouvelle ligne
-- d'historique timestampée "maintenant", inutile pour corriger le rejeu).
-- Sans impact sur la production : cette migration a déjà été exécutée en
-- production (le vrai hôtel '02b9eb0e-...' porte déjà les 10 campagnes de
-- démo) ; éditer le texte stocké ne rejoue rien contre la production, ça ne
-- change que le comportement des FUTURS rejeux de branche.
-- ============================================================================

ALTER TABLE public.promo_campaigns
  ADD COLUMN IF NOT EXISTS hotel_id uuid
    REFERENCES public.hotels(id) ON DELETE CASCADE;

DO $repair$
DECLARE v_hotel_id uuid;
BEGIN
  SELECT id INTO v_hotel_id FROM public.hotels LIMIT 1;
  IF v_hotel_id IS NOT NULL THEN
    UPDATE public.promo_campaigns
      SET hotel_id = v_hotel_id
      WHERE hotel_id IS NULL;

    ALTER TABLE public.promo_campaigns
      ALTER COLUMN hotel_id SET NOT NULL;
  END IF;
END $repair$;
