-- =============================================================================
-- 13_absence_module.sql
-- Module absences : types, demandes, soldes, historique d'approbation
-- Rejouable : IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO NOTHING
-- NOTE : ce fichier a été recréé car la migration originale n°13 était absente
--        de l'historique Git (la numérotation sautait de 12 à 14).
-- =============================================================================

-- ── 1. Types d'absence ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.absence_types (
  code          text        PRIMARY KEY,
  label         text        NOT NULL,
  color_bg      text        NOT NULL DEFAULT '#E5E7EB',
  color_fg      text        NOT NULL DEFAULT '#374151',
  planning_code text,           -- code planning associé (CP, RTT, MAL…)
  debit_balance boolean     NOT NULL DEFAULT false,
  balance_type  text,           -- 'CP' | 'RTT' | null
  active        boolean     NOT NULL DEFAULT true,
  sort_order    integer     NOT NULL DEFAULT 0
);

INSERT INTO public.absence_types (code,label,color_bg,color_fg,planning_code,debit_balance,balance_type,sort_order)
VALUES
  ('CP',   'Congé payé',            '#C6EFCE','#0F5132','CP',   true, 'CP',  1),
  ('RTT',  'RTT',                   '#BDD7EE','#1F4E78','RTT',  true, 'RTT', 2),
  ('MAL',  'Maladie',               '#FFC7CE','#9C0006','MAL',  false, null,  3),
  ('MAT',  'Maternité / Paternité', '#E1D5F0','#5B2A86','MAT',  false, null,  4),
  ('CSS',  'Congé sans solde',      '#D9D9D9','#3F3F3F','CSS',  false, null,  5),
  ('AE',   'Accident du travail',   '#FFE699','#7F6000','AE',   false, null,  6),
  ('PAT',  'Paternité',             '#E8E0F5','#4A2080','PAT',  false, null,  7),
  ('ABS',  'Absence injustifiée',   '#FFD9D9','#7B0000','ABS',  false, null,  8),
  ('REC',  'Récupération',          '#D4F0FC','#0C4A6E','REC',  false, null,  9),
  ('FORM', 'Formation',             '#FEF3C7','#92400E','FORM', false, null, 10)
ON CONFLICT (code) DO NOTHING;

-- ── 2. Demandes d'absence ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.absence_requests (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  type_code    text        NOT NULL REFERENCES public.absence_types(code),
  start_date   date        NOT NULL,
  end_date     date        NOT NULL,
  days_count   numeric(6,2),
  status       text        NOT NULL DEFAULT 'submitted'
                           CHECK (status IN ('submitted','pending','approved','rejected','cancelled')),
  comment      text,
  created_by   uuid        REFERENCES public.users(id),
  updated_by   uuid        REFERENCES public.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_absence_requests_hotel   ON public.absence_requests(hotel_id);
CREATE INDEX IF NOT EXISTS idx_absence_requests_emp     ON public.absence_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_absence_requests_status  ON public.absence_requests(status);

ALTER TABLE public.absence_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "absence_requests_hotel" ON public.absence_requests;
CREATE POLICY "absence_requests_hotel" ON public.absence_requests
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

-- ── 3. Historique d'approbation ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.absence_approval_history (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  request_id   uuid        NOT NULL REFERENCES public.absence_requests(id) ON DELETE CASCADE,
  employee_id  uuid        REFERENCES public.employees(id),
  action       text        NOT NULL CHECK (action IN ('submit','approve','reject','cancel')),
  actor_user_id uuid       REFERENCES public.users(id),
  actor_email  text,
  comment      text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.absence_approval_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "absence_approval_history_hotel" ON public.absence_approval_history;
CREATE POLICY "absence_approval_history_hotel" ON public.absence_approval_history
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

-- ── 4. Soldes CP / RTT ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.absence_balances (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  year         integer     NOT NULL,
  balance_type text        NOT NULL CHECK (balance_type IN ('CP','RTT')),
  acquired     numeric(6,2) NOT NULL DEFAULT 0,
  taken        numeric(6,2) NOT NULL DEFAULT 0,
  remaining    numeric(6,2) GENERATED ALWAYS AS (acquired - taken) STORED,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hotel_id, employee_id, year, balance_type)
);

ALTER TABLE public.absence_balances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "absence_balances_hotel" ON public.absence_balances;
CREATE POLICY "absence_balances_hotel" ON public.absence_balances
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

-- ── 5. Mouvements de solde ───────────────────────────────────────────────────
-- Nom réel de la table dans la base : absence_balance_movements
-- Colonnes calées sur le schéma existant (type_code, year au lieu de balance_type)

CREATE TABLE IF NOT EXISTS public.absence_balance_movements (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id  uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  type_code    text        NOT NULL,   -- code du type d'absence (CP, RTT…)
  year         integer     NOT NULL,
  delta        numeric(6,2) NOT NULL,  -- positif = crédit, négatif = débit
  reason       text,
  request_id   uuid        REFERENCES public.absence_requests(id),
  created_by   uuid        REFERENCES public.users(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.absence_balance_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "absence_balance_movements_hotel" ON public.absence_balance_movements;
CREATE POLICY "absence_balance_movements_hotel" ON public.absence_balance_movements
  USING (hotel_id IN (SELECT public.pl_my_hotels()));
