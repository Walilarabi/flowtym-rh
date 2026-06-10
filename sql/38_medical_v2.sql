-- 38_medical_v2.sql
-- Visites médicales V1 — colonne status + régularisation du drift schéma.
--
-- Contexte : les colonnes convocation_sent_at, convocation_notes et restrictions
-- existent en production et sont utilisées par le front, mais étaient absentes des
-- fichiers de migration (drift). Cette migration les régularise et ajoute la
-- colonne `status` du workflow de visite.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS uniquement. Aucune contrainte bloquante,
-- aucun backfill destructif, entièrement rejouable.

-- ─── 1. Colonne status (workflow de visite) ──────────────────────────────────
-- Valeurs attendues (non contraintes pour l'instant, validation côté applicatif) :
--   planifiee  → visite programmée, pas encore réalisée
--   realisee   → visite effectuée (valeur par défaut, cohérente avec l'existant)
--   annulee    → visite annulée
ALTER TABLE public.medical_visits
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'realisee';

COMMENT ON COLUMN public.medical_visits.status IS
  'Statut du workflow : planifiee | realisee | annulee. Défaut realisee (cohérent avec les visites existantes saisies après coup).';

-- ─── 2. Régularisation du drift schéma ───────────────────────────────────────
-- Ces 3 colonnes existaient déjà en prod mais pas dans les migrations.
ALTER TABLE public.medical_visits
  ADD COLUMN IF NOT EXISTS convocation_sent_at date,
  ADD COLUMN IF NOT EXISTS convocation_notes   text,
  ADD COLUMN IF NOT EXISTS restrictions        text;

COMMENT ON COLUMN public.medical_visits.convocation_sent_at IS
  'Date d''émission de la convocation PDF (marquée automatiquement à la génération).';
COMMENT ON COLUMN public.medical_visits.convocation_notes IS
  'Notes complémentaires reprises dans la convocation PDF.';
COMMENT ON COLUMN public.medical_visits.restrictions IS
  'Restrictions / aménagements de poste (ex : port de charges limité).';
