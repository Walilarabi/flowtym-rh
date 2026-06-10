-- =============================================================================
-- 27_portal_leave_v2.sql
-- Portail salarié — Soldes CP/RTT v2 (vues avec security_invoker + RLS)
--
-- Sécurité :
--   • WITH (security_invoker = true) → la vue s'exécute avec les droits de
--     l'appelant ; la RLS des tables sous-jacentes est donc réellement appliquée.
--   • Policies _portal_self sur absence_balances et absence_balance_movements :
--     un salarié ne peut lire que ses propres lignes via pl_portal_employee_id().
--   • La vue v1 portal_leave_balances est conservée en base pour compatibilité
--     descendante mais n'est plus utilisée par portal.html.
--
-- Rejouable (CREATE OR REPLACE, DROP POLICY IF EXISTS).
-- =============================================================================

-- ── 1. Vue portal_leave_balances_v2 ──────────────────────────────────────────
CREATE OR REPLACE VIEW public.portal_leave_balances_v2
WITH (security_invoker = true) AS
SELECT
  ab.hotel_id,
  ab.employee_id,
  ab.year,
  ab.type_code,
  ab.entitled,
  ab.taken,
  ab.adjusted,
  (ab.entitled - ab.taken + ab.adjusted) AS remaining
FROM public.absence_balances ab
WHERE ab.type_code IN ('CP', 'RTT');

GRANT SELECT ON public.portal_leave_balances_v2 TO authenticated;

COMMENT ON VIEW public.portal_leave_balances_v2 IS
  'Soldes CP/RTT exposés au portail salarié. security_invoker = true : la RLS de absence_balances s''applique pleinement. Le salarié ne peut lire que ses propres lignes.';

-- ── 2. Vue portal_leave_movements_v2 ─────────────────────────────────────────
CREATE OR REPLACE VIEW public.portal_leave_movements_v2
WITH (security_invoker = true) AS
SELECT
  m.hotel_id,
  m.employee_id,
  m.type_code,
  m.year,
  m.delta,
  m.reason,
  m.created_at
FROM public.absence_balance_movements m
WHERE m.type_code IN ('CP', 'RTT');

-- created_by (uuid interne RH) volontairement exclu : information inutile et potentiellement
-- sensible pour le salarié.

GRANT SELECT ON public.portal_leave_movements_v2 TO authenticated;

COMMENT ON VIEW public.portal_leave_movements_v2 IS
  'Mouvements CP/RTT exposés au portail salarié. security_invoker = true. created_by exclu.';

-- ── 3. Policies RLS portail sur absence_balances ─────────────────────────────
-- Additives aux policies manager existantes (abs_bal_hotel).
-- Un salarié authentifié peut lire uniquement ses propres lignes.

DROP POLICY IF EXISTS "abs_bal_portal_self" ON public.absence_balances;
CREATE POLICY "abs_bal_portal_self" ON public.absence_balances
  FOR SELECT
  USING (employee_id = public.pl_portal_employee_id());

-- ── 4. Policies RLS portail sur absence_balance_movements ────────────────────
DROP POLICY IF EXISTS "abs_mov_portal_self" ON public.absence_balance_movements;
CREATE POLICY "abs_mov_portal_self" ON public.absence_balance_movements
  FOR SELECT
  USING (employee_id = public.pl_portal_employee_id());
