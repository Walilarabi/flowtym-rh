-- 91_fix_flowday_housekeeping_seed_nondeterminism.sql
-- ============================================================================
-- Corrige une migration NON DÉTERMINISTE qui casse le rejeu de branche.
--
-- Migration fautive : 20260514145911_flowday_housekeeping_maintenance
-- (migration originale du dépôt, PAS un objet hors bande — le schéma qu'elle
-- crée, public.hk_staff/hk_tasks/hk_checklists/.../maintenance_tickets, est
-- bien tracké depuis le début).
--
-- Cause racine démontrée : son bloc final (section 7, "Seed staff + checklist
-- pour l'hôtel demo") résout v_hotel_id ainsi :
--   1. SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1
--   2. si NULL, fallback SELECT id FROM public.hotels LIMIT 1
-- puis insère 5 lignes dans public.hk_staff avec hotel_id = v_hotel_id (colonne
-- NOT NULL). Sur production, ce fallback trouvait toujours un hôtel existant.
-- Sur un rejeu de branche Supabase (Branching 2.0, with_data:false — la base
-- part vierge, SANS les données de production), (1) auth.uid() est NULL hors
-- contexte de session, et (2) public.hotels est vide. v_hotel_id reste donc
-- NULL et l'INSERT viole la contrainte NOT NULL sur hk_staff.hotel_id :
--   ERROR: null value in column "hotel_id" of relation "hk_staff" violates
--   not-null constraint
-- → migration non déterministe : son succès dépend de données runtime
--   (au moins un hôtel existant) que le mécanisme de rejeu ne fournit jamais.
--
-- Correction appliquée (root cause, pas contournement) : le bloc de seed est
-- une commodité de démo, pas une exigence de schéma — il est maintenant gardé
-- par `IF v_hotel_id IS NOT NULL THEN ... END IF`, donc il se saute
-- silencieusement quand aucun hôtel n'existe, au lieu de faire échouer tout le
-- rejeu. Le texte ci-dessous est la version corrigée du statement complet de
-- 20260514145911.
--
-- Application : PAS un apply_migration standard (qui ajouterait une NOUVELLE
-- ligne d'historique timestampée "maintenant", ce qui ne changerait rien pour
-- le rejeu). C'est une édition EN PLACE du texte déjà stocké dans
-- supabase_migrations.schema_migrations pour la version 20260514145911 :
--
--   UPDATE supabase_migrations.schema_migrations
--   SET statements = ARRAY[$tag$ ... texte corrigé ci-dessous ... $tag$]
--   WHERE version = '20260514145911';
--
-- Sans impact sur la production : cette migration a déjà été exécutée en
-- production (les 5 hk_staff de démo existent déjà, sur le vrai hôtel résolu
-- à l'époque) ; éditer le texte stocké ne rejoue rien contre la production,
-- ça ne change que le comportement des FUTURS rejeux de branche.
-- ============================================================================

-- 1. Colonne housekeeping sur rooms
ALTER TABLE public.rooms
  ADD COLUMN IF NOT EXISTS housekeeping_status text NOT NULL DEFAULT 'clean'
    CHECK (housekeeping_status IN ('clean','dirty','cleaning','inspected','out_of_order')),
  ADD COLUMN IF NOT EXISTS housekeeping_priority int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_cleaned_at timestamptz,
  ADD COLUMN IF NOT EXISTS assigned_to uuid;

-- 2. Staff housekeeping
CREATE TABLE IF NOT EXISTS public.hk_staff (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id    uuid NOT NULL,
  first_name  text NOT NULL,
  last_name   text NOT NULL,
  role        text NOT NULL DEFAULT 'housekeeper'
              CHECK (role IN ('housekeeper','supervisor','inspector')),
  status      text NOT NULL DEFAULT 'active'
              CHECK (status IN ('active','inactive','on_leave')),
  color       text NOT NULL DEFAULT '#8B5CF6',
  phone       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.hk_staff ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hk_staff_rls ON public.hk_staff;
CREATE POLICY hk_staff_rls ON public.hk_staff
  FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- 3. Tâches housekeeping
CREATE TABLE IF NOT EXISTS public.hk_tasks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid NOT NULL,
  room_id      uuid REFERENCES public.rooms(id) ON DELETE CASCADE,
  room_number  text NOT NULL,
  task_type    text NOT NULL DEFAULT 'cleaning'
               CHECK (task_type IN ('cleaning','inspection','turndown','deep_clean','checkout')),
  status       text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','in_progress','done','validated','skipped')),
  priority     text NOT NULL DEFAULT 'normal'
               CHECK (priority IN ('low','normal','high','urgent')),
  assigned_to  uuid REFERENCES public.hk_staff(id) ON DELETE SET NULL,
  notes        text,
  started_at   timestamptz,
  completed_at timestamptz,
  validated_at timestamptz,
  validated_by uuid,
  scheduled_for date NOT NULL DEFAULT CURRENT_DATE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hk_tasks_hotel_date ON public.hk_tasks(hotel_id, scheduled_for DESC);
CREATE INDEX IF NOT EXISTS idx_hk_tasks_status ON public.hk_tasks(hotel_id, status);

ALTER TABLE public.hk_tasks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hk_tasks_rls ON public.hk_tasks;
CREATE POLICY hk_tasks_rls ON public.hk_tasks
  FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- 4. Checklists
CREATE TABLE IF NOT EXISTS public.hk_checklists (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id    uuid NOT NULL,
  name        text NOT NULL,
  task_type   text NOT NULL DEFAULT 'cleaning',
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hk_checklist_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid NOT NULL,
  checklist_id uuid NOT NULL REFERENCES public.hk_checklists(id) ON DELETE CASCADE,
  label        text NOT NULL,
  order_index  int NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.hk_task_checks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid NOT NULL,
  task_id      uuid NOT NULL REFERENCES public.hk_tasks(id) ON DELETE CASCADE,
  item_id      uuid NOT NULL REFERENCES public.hk_checklist_items(id) ON DELETE CASCADE,
  checked      boolean NOT NULL DEFAULT false,
  checked_at   timestamptz,
  checked_by   uuid
);

ALTER TABLE public.hk_checklists ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hk_checklists_rls ON public.hk_checklists;
CREATE POLICY hk_checklists_rls ON public.hk_checklists FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

ALTER TABLE public.hk_checklist_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hk_checklist_items_rls ON public.hk_checklist_items;
CREATE POLICY hk_checklist_items_rls ON public.hk_checklist_items FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

ALTER TABLE public.hk_task_checks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hk_task_checks_rls ON public.hk_task_checks;
CREATE POLICY hk_task_checks_rls ON public.hk_task_checks FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- 5. Tickets maintenance
CREATE TABLE IF NOT EXISTS public.maintenance_tickets (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id     uuid NOT NULL,
  room_id      uuid REFERENCES public.rooms(id) ON DELETE SET NULL,
  room_number  text,
  title        text NOT NULL,
  description  text,
  category     text NOT NULL DEFAULT 'general'
               CHECK (category IN ('plumbing','electrical','hvac','furniture','equipment','cleaning','safety','general')),
  priority     text NOT NULL DEFAULT 'normal'
               CHECK (priority IN ('low','normal','high','urgent','critical')),
  status       text NOT NULL DEFAULT 'open'
               CHECK (status IN ('open','in_progress','pending_parts','resolved','closed','cancelled')),
  assigned_to  uuid REFERENCES public.hk_staff(id) ON DELETE SET NULL,
  reported_by  uuid,
  resolved_at  timestamptz,
  estimated_cost numeric(10,2),
  actual_cost    numeric(10,2),
  photos       jsonb DEFAULT '[]',
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_maint_hotel_status ON public.maintenance_tickets(hotel_id, status);
CREATE INDEX IF NOT EXISTS idx_maint_room ON public.maintenance_tickets(room_id);

ALTER TABLE public.maintenance_tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS maint_rls ON public.maintenance_tickets;
CREATE POLICY maint_rls ON public.maintenance_tickets
  FOR ALL TO authenticated
  USING (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
  WITH CHECK (hotel_id = (SELECT hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- 6. Trigger updated_at
CREATE OR REPLACE FUNCTION app.set_updated_at_flowday()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_hk_tasks_updated ON public.hk_tasks;
CREATE TRIGGER trg_hk_tasks_updated BEFORE UPDATE ON public.hk_tasks
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at_flowday();

DROP TRIGGER IF EXISTS trg_maint_updated ON public.maintenance_tickets;
CREATE TRIGGER trg_maint_updated BEFORE UPDATE ON public.maintenance_tickets
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at_flowday();

-- 7. Seed staff + checklist pour l'hôtel demo
-- Correction rejeu : v_hotel_id est NULL sur un environnement vierge
-- (auth.uid() absent hors session, et public.hotels vide tant qu'aucune
-- donnée n'a été insérée — la branche est with_data:false). Le seed est
-- une commodité de démo, pas une exigence de schéma : on le saute
-- silencieusement plutôt que de violer la contrainte NOT NULL sur
-- hk_staff.hotel_id.
DO $$
DECLARE v_hotel_id uuid;
BEGIN
  SELECT hotel_id INTO v_hotel_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1;
  IF v_hotel_id IS NULL THEN SELECT id INTO v_hotel_id FROM public.hotels LIMIT 1; END IF;

  IF v_hotel_id IS NOT NULL THEN
    -- Staff housekeeping
    INSERT INTO public.hk_staff (hotel_id, first_name, last_name, role, color) VALUES
      (v_hotel_id, 'Marie',   'Dupont',  'housekeeper', '#8B5CF6'),
      (v_hotel_id, 'Sophie',  'Martin',  'housekeeper', '#3B82F6'),
      (v_hotel_id, 'Fatima',  'Benali',  'housekeeper', '#10B981'),
      (v_hotel_id, 'Isabelle','Morel',   'supervisor',  '#F59E0B'),
      (v_hotel_id, 'Marc',    'Bernard', 'inspector',   '#EF4444')
    ON CONFLICT DO NOTHING;

    -- Checklist par défaut
    WITH cl AS (
      INSERT INTO public.hk_checklists (hotel_id, name, task_type, is_default)
      VALUES (v_hotel_id, 'Ménage standard', 'cleaning', true)
      ON CONFLICT DO NOTHING
      RETURNING id
    )
    INSERT INTO public.hk_checklist_items (hotel_id, checklist_id, label, order_index)
    SELECT v_hotel_id, cl.id, label, idx FROM cl,
    (VALUES
      (0, 'Retirer le linge sale'),
      (1, 'Dépoussiérer les surfaces'),
      (2, 'Nettoyer salle de bain'),
      (3, 'Passer l''aspirateur'),
      (4, 'Faire le(s) lit(s)'),
      (5, 'Renouveler les serviettes'),
      (6, 'Réapprovisionner les produits'),
      (7, 'Vider les poubelles'),
      (8, 'Contrôle visuel final')
    ) AS items(idx, label)
    ON CONFLICT DO NOTHING;
  END IF;

  RAISE NOTICE 'Flowday DB prête — hotel_id: %', v_hotel_id;
END $$;

SELECT 'Flowday DB OK' as status;
