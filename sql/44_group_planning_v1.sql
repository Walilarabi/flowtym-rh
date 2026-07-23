-- 44_group_planning_v1.sql
-- Planning Groupe intelligent — V1 LECTURE SEULE (Lot 1 : socle données/droits).
-- Versionne les objets créés pour cette phase (certains ont été appliqués via MCP
-- lors de l'itération ; ce fichier fait foi pour le dépôt).
--
-- Objets couverts :
--   * table group_staffing_requirements (besoins effectif par hôtel/service/jour)
--   * RPC group_planning(service, from, to)   — agrégat lecture seule, scopé RLS
--   * RPC group_requirements_list/set/delete   — configuration des besoins (scopée)
--
-- Sécurité : toutes les lectures/écritures cross-hôtel passent par des fonctions
-- SECURITY DEFINER filtrant par public.pl_my_hotels() (accès effectif de
-- l'utilisateur). L'appartenance au même group_id NE suffit jamais : il faut
-- aussi que l'hôtel soit dans pl_my_hotels(). Colonnes exposées : uniquement
-- des champs sûrs (pas de données RH sensibles).

-- ── Table des besoins (créée en amont ; rappel du schéma) ────────────────────
CREATE TABLE IF NOT EXISTS public.group_staffing_requirements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id       uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  service_name   text NOT NULL,
  weekday        int  NOT NULL CHECK (weekday >= 0 AND weekday <= 6),  -- 0=dimanche
  required_count int  NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hotel_id, service_name, weekday)
);
ALTER TABLE public.group_staffing_requirements ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='group_staffing_requirements' AND policyname='gsr_manager') THEN
    CREATE POLICY gsr_manager ON public.group_staffing_requirements
      FOR ALL USING (hotel_id IN (SELECT public.pl_my_hotels()))
      WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));
  END IF;
END $$;

-- ── RPC agrégée (voir migration group_planning_v1_lot1 pour le corps courant) ──
-- Le corps complet et à jour de group_planning() ainsi que des RPCs
-- group_requirements_list/set/delete est appliqué par la migration
-- `group_planning_v1_lot1`. Il inclut le statut collaborateur (emp_status) et la
-- résolution du service exercé (Extra -> service d'accueil, sinon service principal).
