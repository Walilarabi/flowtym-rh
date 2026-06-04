-- 18_medical.sql
-- Medical module: medical_visits
-- Idempotent: IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS

-- ─── medical_visits ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.medical_visits (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id     uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  visit_type      text        NOT NULL
                              CHECK (visit_type IN ('embauche','periodique','reprise')),
  visit_date      date        NOT NULL,
  next_visit_date date,
  doctor          text,
  clinic          text,
  aptitude        text        NOT NULL DEFAULT 'apte'
                              CHECK (aptitude IN ('apte','apte_amenagement','inapte')),
  notes           text,
  document_path   text,
  created_by      uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_medical_visits_hotel_employee
  ON public.medical_visits (hotel_id, employee_id);

CREATE INDEX IF NOT EXISTS idx_medical_visits_hotel_next_visit
  ON public.medical_visits (hotel_id, next_visit_date);

ALTER TABLE public.medical_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS medical_visits_tenant ON public.medical_visits;
CREATE POLICY medical_visits_tenant ON public.medical_visits
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.medical_visits TO authenticated;

DROP TRIGGER IF EXISTS trg_medical_visits_updated_at ON public.medical_visits;
CREATE TRIGGER trg_medical_visits_updated_at
  BEFORE UPDATE ON public.medical_visits
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
