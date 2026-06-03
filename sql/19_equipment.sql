-- 19_equipment.sql
-- Equipment module: equipment_items
-- Idempotent: IF NOT EXISTS, ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS

-- ─── equipment_items ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.equipment_items (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id           uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id        uuid        NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  item_type          text        NOT NULL
                                 CHECK (item_type IN ('badge','cle','uniforme','telephone','ordinateur','tablette','vehicule','autre')),
  item_code          text,
  description        text,
  given_date         date        NOT NULL,
  returned_date      date,
  condition_given    text        NOT NULL DEFAULT 'bon'
                                 CHECK (condition_given IN ('neuf','bon','usage')),
  condition_returned text        CHECK (condition_returned IN ('neuf','bon','usage','abime','perdu')),
  notes              text,
  created_by         uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_equipment_items_hotel_employee
  ON public.equipment_items (hotel_id, employee_id);

CREATE INDEX IF NOT EXISTS idx_equipment_items_hotel_type
  ON public.equipment_items (hotel_id, item_type);

ALTER TABLE public.equipment_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS equipment_items_tenant ON public.equipment_items;
CREATE POLICY equipment_items_tenant ON public.equipment_items
  FOR ALL
  USING (hotel_id IN (SELECT public.pl_my_hotels()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.equipment_items TO authenticated;

DROP TRIGGER IF EXISTS trg_equipment_items_updated_at ON public.equipment_items;
CREATE TRIGGER trg_equipment_items_updated_at
  BEFORE UPDATE ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION pl_touch_updated_at();
