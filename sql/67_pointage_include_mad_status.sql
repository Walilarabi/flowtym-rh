-- =============================================================================
-- 67_pointage_include_mad_status.sql
-- Hotfix production : le statut 'MAD' (Mise à disposition — salarié d'un
-- autre hôtel prêté pour la journée) était absent du filtre de
-- pointage_range_summary() (sql/66). Résultat : un salarié en MAD à un
-- hôtel n'apparaissait JAMAIS dans le menu Pointage de cet hôtel, alors
-- qu'il y travaille réellement et doit y pointer.
--
-- Cas réel signalé : Karima OULSAADA (Grand Hôtel du Havre) mise à
-- disposition de Folkestone opera le 2026-07-28 (staff_planning.status =
-- 'MAD' à Folkestone) — absente du menu Pointage de Folkestone.
--
-- CREATE OR REPLACE : rejouable, aucune donnée modifiée. sql/66 mis à jour
-- en parallèle pour qu'une reconstruction from-scratch (62→66) obtienne
-- directement la version corrigée — même principe que sql/63 consolidé par
-- sql/65.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.pointage_range_summary(
  p_hotel uuid, p_from date, p_to date
) RETURNS TABLE (
  employee_id          uuid,
  first_name           text,
  last_name            text,
  role                 text,
  department           text,
  day                  date,
  planning_status      text,
  is_extra             boolean,
  planned_in           time,
  planned_out          time,
  real_in              timestamptz,
  real_out             timestamptz,
  is_open              boolean,
  retard_matin_min     int,
  rattrapage_soir_min  int,
  solde_jour_min       int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_hotel IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'BAD_INPUT' USING ERRCODE = '22023';
  END IF;
  IF p_hotel NOT IN (SELECT public.pl_my_hotels()) THEN
    RAISE EXCEPTION 'NOT_ALLOWED' USING ERRCODE = '42501';
  END IF;
  IF p_to - p_from > 92 THEN
    RAISE EXCEPTION 'RANGE_TOO_WIDE' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH tz AS (
    SELECT COALESCE(h.timezone, 'Europe/Paris') AS zone FROM public.hotels h WHERE h.id = p_hotel
  ),
  planned AS (
    SELECT sp.employee_id, sp.day, sp.status, sp.shift_start, sp.shift_end
      FROM public.staff_planning sp
     WHERE sp.hotel_id = p_hotel
       AND sp.day BETWEEN p_from AND p_to
       AND sp.status IN ('P','PE','MAD')
  ),
  clocked_days AS (
    SELECT DISTINCT sc.employee_id, sc.day
      FROM public.staff_clockings sc
     WHERE sc.hotel_id = p_hotel
       AND sc.day BETWEEN p_from AND p_to
  ),
  scope AS (
    SELECT planned.employee_id, planned.day FROM planned
    UNION
    SELECT clocked_days.employee_id, clocked_days.day FROM clocked_days
  ),
  agg_clock AS (
    SELECT sc.employee_id, sc.day,
           MIN(sc.clock_in_ts)               AS real_in,
           bool_or(sc.clock_out_ts IS NULL)  AS has_open,
           MAX(sc.clock_out_ts)              AS last_clock_out
      FROM public.staff_clockings sc
     WHERE sc.hotel_id = p_hotel AND sc.day BETWEEN p_from AND p_to
     GROUP BY sc.employee_id, sc.day
  ),
  resolved AS (
    SELECT
      e.id AS employee_id, e.first_name, e.last_name, e.role, e.department,
      s.day,
      p.status AS planning_status,
      (e.hotel_id <> p_hotel) AS is_extra,
      COALESCE(
        p.shift_start,
        CASE WHEN ds.default_start_time ~ '^\d{2}:\d{2}' THEN ds.default_start_time::time END
      ) AS planned_in,
      COALESCE(
        p.shift_end,
        CASE WHEN ds.default_end_time ~ '^\d{2}:\d{2}' THEN ds.default_end_time::time END
      ) AS planned_out,
      ac.real_in,
      CASE WHEN COALESCE(ac.has_open,false) THEN NULL ELSE ac.last_clock_out END AS real_out,
      COALESCE(ac.has_open, false) AS is_open,
      (SELECT zone FROM tz) AS hotel_tz
    FROM scope s
    JOIN public.employees e ON e.id = s.employee_id AND e.active = true
    LEFT JOIN planned p                      ON p.employee_id = s.employee_id AND p.day = s.day
    LEFT JOIN public.department_schedules ds ON ds.id = e.schedule_id
    LEFT JOIN agg_clock ac                   ON ac.employee_id = s.employee_id AND ac.day = s.day
  ),
  scored AS (
    SELECT
      r.*,
      public.pl_pointage_time_delta_minutes(r.planned_in,  (r.real_in  AT TIME ZONE r.hotel_tz)::time) AS arrival_delta,
      CASE WHEN r.real_out IS NULL THEN NULL
           ELSE public.pl_pointage_time_delta_minutes(r.planned_out, (r.real_out AT TIME ZONE r.hotel_tz)::time)
      END AS departure_delta
    FROM resolved r
  )
  SELECT
    sc.employee_id, sc.first_name, sc.last_name, sc.role, sc.department,
    sc.day, sc.planning_status, sc.is_extra,
    sc.planned_in, sc.planned_out, sc.real_in, sc.real_out, sc.is_open,
    CASE WHEN sc.arrival_delta   IS NULL THEN NULL ELSE GREATEST(0, sc.arrival_delta)   END AS retard_matin_min,
    CASE WHEN sc.departure_delta IS NULL THEN NULL ELSE GREATEST(0, sc.departure_delta) END AS rattrapage_soir_min,
    CASE WHEN sc.arrival_delta IS NULL OR sc.departure_delta IS NULL THEN NULL
         ELSE sc.arrival_delta - sc.departure_delta
    END AS solde_jour_min
  FROM scored sc
  ORDER BY sc.day, sc.last_name, sc.first_name;
END;
$$;

REVOKE ALL ON FUNCTION public.pointage_range_summary(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pointage_range_summary(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION public.pointage_range_summary(uuid, date, date) IS
  'Résumé pointage (planifié vs réel, retard matin, rattrapage soir, solde du jour) par salarié pour chaque jour d''une plage. Isolation multi-hôtel via pl_my_hotels(). Statuts de présence physique inclus : P, PE, MAD. Utilisée par la page Pointage RH (tableau, KPI, export PDF, cumul mensuel).';
