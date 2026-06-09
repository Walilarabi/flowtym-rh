-- Migration 36 : Statut collaborateur 3 états (actif, pause, parti)
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'actif'
  CHECK (status IN ('actif', 'pause', 'parti'));

-- Migrer les données existantes
UPDATE employees SET status = 'parti' WHERE active = false AND status = 'actif';
