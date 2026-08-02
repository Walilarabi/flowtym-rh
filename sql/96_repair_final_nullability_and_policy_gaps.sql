-- ============================================================================
-- sql/96_repair_final_nullability_and_policy_gaps.sql
-- Régularisation — 3 derniers écarts détectés par la 2e passe de
-- vérification structurelle après sql/95 (2026-08-02) : deux nullabilités
-- non alignées sur production (probablement héritées du rejeu pur lui-même,
-- non introduites par sql/95, découvertes seulement à cette passe) et un
-- WITH CHECK manquant sur une policy déjà recréée par sql/91/92.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================
DO $repair_final_gaps$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='hotels' AND column_name='created_at' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.hotels ALTER COLUMN created_at DROP NOT NULL';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rooms' AND column_name='hotel_id' AND is_nullable='NO') THEN
    EXECUTE 'ALTER TABLE public.rooms ALTER COLUMN hotel_id DROP NOT NULL';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='lighthouse_imports' AND policyname='lighthouse_imports_no_modify' AND with_check IS NULL) THEN
    EXECUTE 'DROP POLICY lighthouse_imports_no_modify ON public.lighthouse_imports';
    EXECUTE $pol$CREATE POLICY lighthouse_imports_no_modify ON public.lighthouse_imports FOR UPDATE USING (false) WITH CHECK (false)$pol$;
  END IF;

  RAISE NOTICE '[final gaps] hotels.created_at, rooms.hotel_id nullabilité + lighthouse_imports_no_modify with_check alignés sur production.';
END
$repair_final_gaps$;
