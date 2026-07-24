-- ============================================================================
-- 55_security_hardening.sql — LOT C : zéro ERROR sécurité (advisors Supabase).
--
--  1. `v_staff_day_flags` : passait en SECURITY DEFINER (contourne la RLS de
--     l'appelant) => unique ERROR sécurité. Recréée en `security_invoker=on`
--     (respecte la RLS de l'utilisateur courant). Vue d'agrégation simple.
--  2. `search_path` mutable (WARN sécurité) sur les fonctions du moteur
--     déplacement : figé explicitement.
--
-- NON appliqué en production. Testé sur cluster local.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_staff_day_flags
WITH (security_invoker = on) AS
  SELECT employee_id, day,
    count(*) AS segment_count,
    count(*) > 0 AS is_segmented,
    count(DISTINCT hotel_id) > 1 AS has_multiple_hotels,
    count(DISTINCT status) > 1 AS has_multiple_statuses,
    true AS derived_from_segments
  FROM public.staff_planning_segments
  GROUP BY employee_id, day;

-- search_path figé (empêche le détournement via un schéma injecté).
ALTER FUNCTION public.trg_staff_planning_move_guard() SET search_path = public, pg_temp;
ALTER FUNCTION public._gmp_subtract(integer, integer, int4range[]) SET search_path = pg_catalog, pg_temp;
