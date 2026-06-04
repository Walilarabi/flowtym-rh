-- 16_recruitment.sql
-- Recruitment module: job_postings, candidates, candidate_notes
-- Idempotent: IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS

-- ─── job_postings ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.job_postings (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id      uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  title         text        NOT NULL,
  department_id uuid        REFERENCES public.staff_departments(id) ON DELETE SET NULL,
  contract_type text,
  location      text,
  description   text,
  status        text        NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open', 'closed', 'draft')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_postings_hotel_status
  ON public.job_postings (hotel_id, status);

ALTER TABLE public.job_postings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS job_postings_tenant ON public.job_postings;
CREATE POLICY job_postings_tenant ON public.job_postings
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.job_postings TO authenticated;

DROP TRIGGER IF EXISTS trg_job_postings_updated_at ON public.job_postings;
CREATE TRIGGER trg_job_postings_updated_at
  BEFORE UPDATE ON public.job_postings
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();

-- ─── candidates ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.candidates (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  job_posting_id  uuid        REFERENCES public.job_postings(id) ON DELETE SET NULL,
  first_name      text,
  last_name       text,
  email           text,
  phone           text,
  stage           text        NOT NULL DEFAULT 'nouveau'
                              CHECK (stage IN ('nouveau','preselection','entretien','offre','embauche','refuse')),
  notes           text,
  cv_path         text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_candidates_hotel_stage
  ON public.candidates (hotel_id, stage);

ALTER TABLE public.candidates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS candidates_tenant ON public.candidates;
CREATE POLICY candidates_tenant ON public.candidates
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.candidates TO authenticated;

DROP TRIGGER IF EXISTS trg_candidates_updated_at ON public.candidates;
CREATE TRIGGER trg_candidates_updated_at
  BEFORE UPDATE ON public.candidates
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();

-- ─── candidate_notes ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.candidate_notes (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id       uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  candidate_id   uuid        NOT NULL REFERENCES public.candidates(id) ON DELETE CASCADE,
  author_user_id uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  content        text        NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_candidate_notes_candidate
  ON public.candidate_notes (candidate_id);

ALTER TABLE public.candidate_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS candidate_notes_tenant ON public.candidate_notes;
CREATE POLICY candidate_notes_tenant ON public.candidate_notes
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.candidate_notes TO authenticated;
