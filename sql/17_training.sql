-- 17_training.sql
-- Training module: training_catalog, employee_trainings
-- Idempotent: IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS

-- ─── training_catalog ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.training_catalog (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id          uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  title             text        NOT NULL,
  description       text,
  category          text,
  frequency_months  int         NOT NULL DEFAULT 12,
  required_for_all  boolean     NOT NULL DEFAULT false,
  active            boolean     NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_training_catalog_hotel
  ON public.training_catalog (hotel_id);

ALTER TABLE public.training_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS training_catalog_tenant ON public.training_catalog;
CREATE POLICY training_catalog_tenant ON public.training_catalog
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.training_catalog TO authenticated;

DROP TRIGGER IF EXISTS trg_training_catalog_updated_at ON public.training_catalog;
CREATE TRIGGER trg_training_catalog_updated_at
  BEFORE UPDATE ON public.training_catalog
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();

-- ─── employee_trainings ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.employee_trainings (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id     uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  training_id     uuid        NOT NULL REFERENCES public.training_catalog(id) ON DELETE CASCADE,
  completed_date  date,
  expiry_date     date,
  document_path   text,
  status          text        NOT NULL DEFAULT 'todo'
                              CHECK (status IN ('todo','done','expired','na')),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hotel_id, employee_id, training_id)
);

CREATE INDEX IF NOT EXISTS idx_employee_trainings_hotel_employee
  ON public.employee_trainings (hotel_id, employee_id);

CREATE INDEX IF NOT EXISTS idx_employee_trainings_hotel_expiry
  ON public.employee_trainings (hotel_id, expiry_date);

ALTER TABLE public.employee_trainings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_trainings_tenant ON public.employee_trainings;
CREATE POLICY employee_trainings_tenant ON public.employee_trainings
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.employee_trainings TO authenticated;

DROP TRIGGER IF EXISTS trg_employee_trainings_updated_at ON public.employee_trainings;
CREATE TRIGGER trg_employee_trainings_updated_at
  BEFORE UPDATE ON public.employee_trainings
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
