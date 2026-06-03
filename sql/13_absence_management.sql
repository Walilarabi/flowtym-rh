-- =============================================================================
-- 13_absence_management.sql
-- Module P3B — Absences / CP-RTT
-- Rejouable : IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. TABLE absence_types (globale, pas de hotel_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS absence_types (
  code               text PRIMARY KEY,
  label              text NOT NULL,
  planning_code      text,
  debit_balance      boolean NOT NULL DEFAULT false,
  balance_type       text CHECK (balance_type IN ('CP','RTT')),
  requires_attachment boolean NOT NULL DEFAULT false,
  sort_order         integer NOT NULL DEFAULT 99,
  color_bg           text NOT NULL DEFAULT '#f1f1f5',
  color_fg           text NOT NULL DEFAULT '#6B7280',
  active             boolean NOT NULL DEFAULT true
);

-- Seed des 10 types
INSERT INTO absence_types (code, label, planning_code, debit_balance, balance_type, requires_attachment, sort_order, color_bg, color_fg) VALUES
  ('CP',    'Congé payé',         'CP',   true,  'CP',  false, 10,  '#C6EFCE', '#0F5132'),
  ('RTT',   'RTT',                'RTT',  true,  'RTT', false, 20,  '#BDD7EE', '#1F4E78'),
  ('MAL',   'Maladie',            'MAL',  false, NULL,  true,  30,  '#FFC7CE', '#9C0006'),
  ('MAT',   'Maternité',          'MAT',  false, NULL,  false, 40,  '#E1D5F0', '#5B2A86'),
  ('PAT',   'Paternité',          'PAT',  false, NULL,  false, 50,  '#E8E0F5', '#4A2080'),
  ('ABS',   'Absence injustifiée','ABS',  false, NULL,  false, 60,  '#FFD9D9', '#7B0000'),
  ('REC',   'Récupération',       'REC',  false, NULL,  false, 70,  '#D4F0FC', '#0C4A6E'),
  ('REPOS', 'Repos compensateur', NULL,   false, NULL,  false, 80,  '#F5F5F5', '#6B7280'),
  ('FORM',  'Formation',          'FORM', false, NULL,  false, 90,  '#FEF3C7', '#92400E'),
  ('AUT',   'Autre',              'AE',   false, NULL,  false, 100, '#FFE699', '#7F6000')
ON CONFLICT (code) DO NOTHING;

-- RLS sur absence_types (lecture pour tout authenticated)
ALTER TABLE absence_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "absence_types_read" ON absence_types;
CREATE POLICY "absence_types_read" ON absence_types
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- 2. TABLE absence_requests
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS absence_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id            uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id         uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  type_code           text NOT NULL REFERENCES absence_types(code),
  start_date          date NOT NULL,
  end_date            date NOT NULL,
  half_day_start      boolean NOT NULL DEFAULT false,
  half_day_start_period text CHECK (half_day_start_period IN ('matin','après-midi')),
  half_day_end        boolean NOT NULL DEFAULT false,
  half_day_end_period text CHECK (half_day_end_period IN ('matin','après-midi')),
  days_count          numeric(5,1) NOT NULL DEFAULT 1.0,
  note                text,
  attachment_path     text,
  status              text NOT NULL DEFAULT 'submitted'
                        CHECK (status IN ('draft','submitted','approved','rejected','cancelled')),
  created_by          uuid REFERENCES users(id),
  updated_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_abs_dates CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_abs_req_hotel_emp    ON absence_requests (hotel_id, employee_id);
CREATE INDEX IF NOT EXISTS idx_abs_req_hotel_status ON absence_requests (hotel_id, status);
CREATE INDEX IF NOT EXISTS idx_abs_req_hotel_dates  ON absence_requests (hotel_id, start_date, end_date);

ALTER TABLE absence_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abs_req_hotel" ON absence_requests;
CREATE POLICY "abs_req_hotel" ON absence_requests
  FOR ALL TO authenticated USING (pl_my_hotels() @> ARRAY[hotel_id]);

-- Trigger updated_at
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_abs_req_upd' AND tgrelid = 'absence_requests'::regclass
  ) THEN
    CREATE TRIGGER trg_abs_req_upd
      BEFORE UPDATE ON absence_requests
      FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. TABLE absence_balances
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS absence_balances (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id    uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  year        integer NOT NULL,
  type_code   text NOT NULL REFERENCES absence_types(code),
  entitled    numeric(5,1) NOT NULL DEFAULT 0,
  taken       numeric(5,1) NOT NULL DEFAULT 0,
  adjusted    numeric(5,1) NOT NULL DEFAULT 0,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hotel_id, employee_id, year, type_code)
);

ALTER TABLE absence_balances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abs_bal_hotel" ON absence_balances;
CREATE POLICY "abs_bal_hotel" ON absence_balances
  FOR ALL TO authenticated USING (pl_my_hotels() @> ARRAY[hotel_id]);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_abs_bal_upd' AND tgrelid = 'absence_balances'::regclass
  ) THEN
    CREATE TRIGGER trg_abs_bal_upd
      BEFORE UPDATE ON absence_balances
      FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. TABLE absence_balance_movements
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS absence_balance_movements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id    uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  type_code   text NOT NULL REFERENCES absence_types(code),
  year        integer NOT NULL,
  delta       numeric(5,1) NOT NULL,   -- positif = crédit, négatif = débit
  reason      text NOT NULL,
  request_id  uuid REFERENCES absence_requests(id) ON DELETE SET NULL,
  created_by  uuid REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE absence_balance_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abs_mov_hotel" ON absence_balance_movements;
CREATE POLICY "abs_mov_hotel" ON absence_balance_movements
  FOR ALL TO authenticated USING (pl_my_hotels() @> ARRAY[hotel_id]);

-- ---------------------------------------------------------------------------
-- 5. TABLE absence_approval_history
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS absence_approval_history (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id      uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  request_id    uuid NOT NULL REFERENCES absence_requests(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  action        text NOT NULL CHECK (action IN ('submit','approve','reject','cancel')),
  actor_user_id uuid REFERENCES users(id),
  actor_email   text,
  comment       text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE absence_approval_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abs_hist_hotel" ON absence_approval_history;
CREATE POLICY "abs_hist_hotel" ON absence_approval_history
  FOR ALL TO authenticated USING (pl_my_hotels() @> ARRAY[hotel_id]);

-- ---------------------------------------------------------------------------
-- 6. Étendre la contrainte CHECK de staff_planning.status
--    pour inclure PAT, ABS, REC, FORM
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  -- On retrouve la contrainte sur status dans staff_planning
  -- et on la remplace par une version étendue
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'staff_planning' AND column_name = 'status'
  ) THEN
    -- Supprimer l'ancienne contrainte si elle existe
    ALTER TABLE staff_planning
      DROP CONSTRAINT IF EXISTS staff_planning_status_check;

    -- Re-créer avec les nouvelles valeurs
    ALTER TABLE staff_planning
      ADD CONSTRAINT staff_planning_status_check
        CHECK (status IN (
          'P','CP','RTT','MAL','MAT','CSS','AE','F',
          'PAT','ABS','REC','FORM'
        ));
  END IF;
END $$;
