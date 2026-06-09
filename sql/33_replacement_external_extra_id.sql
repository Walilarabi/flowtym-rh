-- Migration 33: ajout external_extra_id sur replacement_assignments
ALTER TABLE replacement_assignments
  ADD COLUMN IF NOT EXISTS external_extra_id uuid REFERENCES external_extras(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_repl_assign_ext_extra 
  ON replacement_assignments(external_extra_id) 
  WHERE external_extra_id IS NOT NULL;
