-- =============================================================================
-- 14_planning_sort_order.sql
-- Ajoute planning_sort_order sur employees pour le tri personnalisé dans le planning
-- Rejouable : ADD COLUMN IF NOT EXISTS
-- =============================================================================

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS planning_sort_order integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_employees_hotel_sort
  ON public.employees (hotel_id, planning_sort_order, last_name);
