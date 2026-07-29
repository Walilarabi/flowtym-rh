-- 68_group_staff_directory.sql
-- ============================================================================
-- Annuaire de contacts à l'échelle du GROUPE.
--
-- Objectif métier : tout établissement du groupe doit pouvoir joindre directement
-- un collaborateur (téléphone / e-mail) pour la gestion des missions de
-- remplacement et des Extras — modification d'horaires, consigne opérationnelle,
-- changement de service/lieu, urgence.
--
-- Portée : coordonnées PROFESSIONNELLES (tél + e-mail) + identité minimale
-- (nom, rôle, service, hôtel). AUCUNE donnée RH sensible (contrat, rémunération,
-- état civil, documents) n'est exposée par cette fonction.
--
-- Sécurité : SECURITY DEFINER à champs restreints plutôt qu'un élargissement de
-- la RLS sur employees (qui exposerait toute la ligne). Le périmètre est borné au
-- groupe des hôtels de l'appelant (hotels.group_id), ou à tout le parc pour un
-- administrateur plateforme.
--
-- Migration additive, idempotente, non destructive.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.group_staff_directory()
RETURNS TABLE (
  employee_id uuid,
  first_name  text,
  last_name   text,
  role        text,
  department  text,
  hotel_id    uuid,
  hotel_name  text,
  phone       text,
  email       text,
  active      boolean,
  status      text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.id, e.first_name, e.last_name, e.role, e.department,
         e.hotel_id, h.name, e.phone, e.email, e.active, e.status
  FROM public.employees e
  JOIN public.hotels h ON h.id = e.hotel_id
  WHERE public.is_platform_admin()
     OR h.group_id IN (
          SELECT hz.group_id
          FROM public.hotels hz
          WHERE hz.id IN (SELECT public.pl_my_hotels())
            AND hz.group_id IS NOT NULL
        )
  ORDER BY h.name, e.last_name, e.first_name;
$$;

COMMENT ON FUNCTION public.group_staff_directory() IS
  'Annuaire de contacts du groupe : tél/e-mail + identité minimale des collaborateurs des hôtels partageant le group_id de l''appelant (ou tout le parc pour un admin plateforme). Champs restreints — aucune donnée RH sensible.';

REVOKE ALL ON FUNCTION public.group_staff_directory() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_staff_directory() TO authenticated;
