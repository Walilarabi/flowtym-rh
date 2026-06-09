-- Migration 32: ajout des colonnes ignored_at / ignored_by sur replacement_assignments
-- et ajout du statut 'ignored' à l'enum si elle existe

ALTER TABLE replacement_assignments
  ADD COLUMN IF NOT EXISTS ignored_at timestamptz,
  ADD COLUMN IF NOT EXISTS ignored_by text;

-- Si le statut est stocké comme text (pas enum), rien à faire.
-- Si c'est un enum, ajouter la valeur :
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    WHERE t.typname LIKE '%replacement%status%'
  ) THEN
    ALTER TYPE replacement_status ADD VALUE IF NOT EXISTS 'ignored';
  END IF;
END$$;
