-- 39_employee_departure_fields.sql
-- Offboarding V1 — motif de départ + dernier jour travaillé.
--
-- Contexte : la fiche collaborateur expose une section « Départ / Offboarding »
-- permettant au RH de préparer la sortie d'un salarié. Deux champs sont ajoutés
-- pour tracer le motif de départ et le dernier jour effectivement travaillé.
--
-- Idempotent : ADD COLUMN IF NOT EXISTS uniquement. Aucune valeur par défaut,
-- aucune contrainte bloquante. Le CHECK accepte NULL → les lignes existantes
-- (motif non renseigné) ne cassent jamais la migration. Entièrement rejouable.

-- ─── Motif de départ ─────────────────────────────────────────────────────────
-- Valeurs autorisées : fin_cdd | demission | licenciement |
--   rupture_conventionnelle | fin_periode_essai | autre. NULL accepté.
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS departure_reason text
    CHECK (departure_reason IS NULL OR departure_reason IN
      ('fin_cdd','demission','licenciement','rupture_conventionnelle','fin_periode_essai','autre'));

COMMENT ON COLUMN public.employees.departure_reason IS
  'Motif de départ : fin_cdd | demission | licenciement | rupture_conventionnelle | fin_periode_essai | autre. NULL si non renseigné.';

-- ─── Dernier jour travaillé ──────────────────────────────────────────────────
-- Peut différer de departure_date (sortie des effectifs / fin de préavis).
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS last_worked_date date;

COMMENT ON COLUMN public.employees.last_worked_date IS
  'Dernier jour effectivement travaillé. Peut différer de departure_date (fin de préavis / sortie des effectifs).';
