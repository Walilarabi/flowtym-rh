-- =============================================================================
-- 64_pointage_remediation_log.sql
-- Table d'audit des remédiations manuelles sur staff_clockings.
--
-- Contexte : lors du déploiement du module Pointage v2, l'index unique partiel
-- staff_clockings_one_open_per_employee (migration 63) a révélé des pointages
-- ouverts orphelins (pré-existants à la garantie « au plus 1 ouvert par
-- salarié »). Chaque correction manuelle doit :
--   • conserver la ligne originale complète (jsonb)
--   • tracer le type de remédiation et son motif
--   • horodater et identifier l'auteur
-- Ce fichier crée la table et sa RLS.
--
-- Rejouable (IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.staff_clockings_remediation_log (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  clocking_id         uuid        NOT NULL,
  hotel_id            uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id         uuid        REFERENCES public.employees(id) ON DELETE SET NULL,
  original_row        jsonb       NOT NULL,
  remediation_type    text        NOT NULL
    CHECK (remediation_type IN (
      'orphan_open_shift_close_zero',   -- clock_out_ts ≈ clock_in_ts
      'orphan_open_shift_chain',        -- clock_out chaîné sur clock_in suivant
      'manual_close',                   -- fermeture manuelle par un manager
      'delete_duplicate',               -- suppression d'un doublon strict
      'other'
    )),
  remediation_reason  text        NOT NULL,
  remediated_at       timestamptz NOT NULL DEFAULT now(),
  remediated_by       uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  remediated_by_email text
);

CREATE INDEX IF NOT EXISTS idx_scr_clocking     ON public.staff_clockings_remediation_log(clocking_id);
CREATE INDEX IF NOT EXISTS idx_scr_hotel_time   ON public.staff_clockings_remediation_log(hotel_id, remediated_at DESC);
CREATE INDEX IF NOT EXISTS idx_scr_employee     ON public.staff_clockings_remediation_log(employee_id) WHERE employee_id IS NOT NULL;

ALTER TABLE public.staff_clockings_remediation_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_clockings_remediation_log_isolation ON public.staff_clockings_remediation_log;
CREATE POLICY staff_clockings_remediation_log_isolation ON public.staff_clockings_remediation_log
  FOR SELECT USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT ON public.staff_clockings_remediation_log TO authenticated;

COMMENT ON TABLE public.staff_clockings_remediation_log IS
  'Journal des remédiations manuelles sur staff_clockings. Conserve la ligne complète avant modification (original_row) + motif + auteur. Alimenté par des transactions atomiques, jamais par les clients (aucun droit INSERT/UPDATE/DELETE).';
