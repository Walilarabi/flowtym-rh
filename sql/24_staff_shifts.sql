-- =============================================================================
-- 24_staff_shifts.sql
-- Ajout des horaires (shifts) directement dans staff_planning.
--
-- Architecture choisie : Option B — colonnes dans la table existante.
-- Rationale : le shift est une propriété de la journée planifiée, pas une
-- entité indépendante. Aucune jointure applicative sur (hotel_id, employee_id, day).
-- L'intégrité est garantie par CHECK sur la même ligne.
--
-- Rejouable : ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.
-- Rollback : ALTER TABLE public.staff_planning DROP COLUMN IF EXISTS shift_label, ...
-- =============================================================================

-- ── 1. Colonnes shift ─────────────────────────────────────────────────────────

ALTER TABLE public.staff_planning
  ADD COLUMN IF NOT EXISTS shift_label text,
  ADD COLUMN IF NOT EXISTS shift_start time,
  ADD COLUMN IF NOT EXISTS shift_end   time,
  ADD COLUMN IF NOT EXISTS break_minutes integer NOT NULL DEFAULT 0;

-- ── 2. Contrainte d'intégrité : shift uniquement si présent ──────────────────
-- Un congé, un RTT, un repos ne peuvent pas porter un shift horaire.

ALTER TABLE public.staff_planning
  DROP CONSTRAINT IF EXISTS chk_shift_only_when_present;

ALTER TABLE public.staff_planning
  ADD CONSTRAINT chk_shift_only_when_present
    CHECK (
      shift_label IS NULL
      OR (status = 'P' AND shift_label IN ('M','S','N','J','PD','C','custom'))
    );

-- ── 3. Contrainte : si shift_start ou shift_end renseignés, les deux doivent l'être
ALTER TABLE public.staff_planning
  DROP CONSTRAINT IF EXISTS chk_shift_times_both_or_none;

ALTER TABLE public.staff_planning
  ADD CONSTRAINT chk_shift_times_both_or_none
    CHECK (
      (shift_start IS NULL AND shift_end IS NULL)
      OR (shift_start IS NOT NULL AND shift_end IS NOT NULL)
    );

-- ── 4. Index couverture : requête "combien d'employés shift M le jour J dans l'hôtel H"
-- Utilisé par computeCoverage() et la vue de couverture.
CREATE INDEX IF NOT EXISTS idx_planning_shift_lookup
  ON public.staff_planning(hotel_id, day, shift_label)
  WHERE shift_label IS NOT NULL;

-- ── 5. Commentaires colonnes
COMMENT ON COLUMN public.staff_planning.shift_label IS
  'Code shift : M=Matin, S=Soir, N=Nuit, J=Journée, PD=Petit-déjeuner, C=Coupure, custom=horaire libre. NULL si status != P.';
COMMENT ON COLUMN public.staff_planning.shift_start IS
  'Heure de début du shift (ex: 06:00). NULL pour les codes standard (M/S/N/J/PD/C) dont les horaires sont définis côté applicatif.';
COMMENT ON COLUMN public.staff_planning.shift_end IS
  'Heure de fin du shift. NULL pour les codes standard.';
COMMENT ON COLUMN public.staff_planning.break_minutes IS
  'Durée de pause en minutes (déduite du temps de travail effectif). Défaut : 0.';
