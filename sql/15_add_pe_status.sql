-- =============================================================================
-- 15_add_pe_status.sql
-- Ajoute le statut PE (Présence Extra) dans la contrainte staff_planning
-- Rejouable : DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'staff_planning' AND column_name = 'status'
  ) THEN
    ALTER TABLE public.staff_planning
      DROP CONSTRAINT IF EXISTS staff_planning_status_check;

    ALTER TABLE public.staff_planning
      ADD CONSTRAINT staff_planning_status_check
        CHECK (status IN (
          'P','PE','CP','RTT','MAL','MAT','CSS','AE','F',
          'PAT','ABS','REC','FORM'
        ));
  END IF;
END $$;
