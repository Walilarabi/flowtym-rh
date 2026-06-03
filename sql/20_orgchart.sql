-- 20_orgchart.sql
-- Org chart support: add manager_id to employees
-- Idempotent: IF NOT EXISTS

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS manager_id uuid
    REFERENCES public.employees(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_employees_manager
  ON public.employees (manager_id);
