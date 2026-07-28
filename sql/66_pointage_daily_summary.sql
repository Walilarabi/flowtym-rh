-- =============================================================================
-- 66_pointage_daily_summary.sql
-- Refonte de la page Pointage RH : calcul serveur du retard matin, du
-- rattrapage soir et du solde du jour (écart planifié / réel), pour éviter
-- tout calcul lourd côté frontend et garantir la cohérence avec les futurs
-- calculs de paie (exigence explicite de la refonte).
--
-- Documente également en migration versionnée une table déjà présente en
-- production mais jamais créée par une migration `sql/` (drift de schéma) :
-- `department_schedules`, utilisée par l'écran Paramètres › Horaires
-- (index.html, BE.listSchedules/updateSchedule) et par `employees.schedule_id`.
-- CREATE TABLE IF NOT EXISTS est un no-op sur la prod existante (mêmes types
-- vérifiés via information_schema : id uuid, hotel_id uuid, department_id
-- uuid, name text, default_start_time text, default_end_time text,
-- break_minutes int, hours_per_day numeric, cp_days_per_month numeric,
-- sort_order int, created_at timestamptz), et rend cette table disponible
-- en CI (sql/tests/pointage_minimal_schema.sql ne la connaissait pas).
--
-- Rejouable (IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

-- ── 0. Colonnes défensives ───────────────────────────────────────────────────
-- Ces colonnes existent déjà sur la prod réelle (migrations 01 et 24) mais
-- pas dans le schéma minimal utilisé par la CI pointage (qui ne rejoue pas
-- toutes les migrations RH) : ADD COLUMN IF NOT EXISTS est un no-op sur prod,
-- et rend cette migration self-sufficient — même principe que sql/63 pour
-- les colonnes d'audit de staff_clockings.
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS role text,
  ADD COLUMN IF NOT EXISTS department text;

ALTER TABLE public.staff_planning
  ADD COLUMN IF NOT EXISTS shift_start time,
  ADD COLUMN IF NOT EXISTS shift_end   time;

-- ── 1. Documentation du schéma existant (drift) ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.department_schedules (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id           uuid        NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  -- Pas de FK vers staff_departments : cette table n'est pas une dépendance
  -- de ce module (uniquement default_start_time/default_end_time via
  -- employees.schedule_id nous intéressent ici), et n'existe pas dans le
  -- schéma minimal CI. Éviter une FK inutile évite un couplage superflu.
  department_id      uuid,
  name               text        NOT NULL,
  default_start_time text,
  default_end_time   text,
  break_minutes      int         DEFAULT 0,
  hours_per_day       numeric,
  cp_days_per_month  numeric     DEFAULT 2.5,
  sort_order         int         DEFAULT 10,
  created_at         timestamptz DEFAULT now()
);

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS schedule_id uuid REFERENCES public.department_schedules(id) ON DELETE SET NULL;

-- RLS : même isolation multi-hôtel que le reste du module RH (défensif — la
-- table existe déjà en prod, potentiellement sans RLS explicite).
ALTER TABLE public.department_schedules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS department_schedules_isolation ON public.department_schedules;
CREATE POLICY department_schedules_isolation ON public.department_schedules
  FOR ALL
  USING      (hotel_id IN (SELECT public.pl_my_hotels()))
  WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()));

-- ── 2. Delta minute-de-la-journée robuste au passage minuit ─────────────────
-- Compare deux `time` (heure locale, indépendante de la date civile) et
-- renvoie l'écart en minutes normalisé dans [-720, +720] : un service de nuit
-- (ex. prévu 23:50, réel 00:10) ne doit jamais être lu comme "-23h40" mais
-- comme "+20 min de retard".
CREATE OR REPLACE FUNCTION public.pl_pointage_time_delta_minutes(p_planned time, p_real time)
RETURNS int
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE WHEN p_planned IS NULL OR p_real IS NULL THEN NULL ELSE
    ROUND(EXTRACT(EPOCH FROM (
      (p_real - p_planned) - CASE
        WHEN (p_real - p_planned) > interval '12 hours'  THEN interval '24 hours'
        WHEN (p_real - p_planned) < interval '-12 hours' THEN interval '-24 hours'
        ELSE interval '0'
      END
    )) / 60)::int
  END
$$;
COMMENT ON FUNCTION public.pl_pointage_time_delta_minutes(time, time) IS
  'Écart en minutes entre une heure planifiée et une heure réelle, normalisé pour rester correct sur un service traversant minuit. Positif = après le planifié, négatif = avant.';

-- ── 3. Résumé pointage par salarié × jour, sur une plage de dates ───────────
-- Un seul appel couvre : le tableau du jour affiché, les KPI, l'export PDF
-- et le cumul "Total retard (mois)" — la RPC est appelée une fois pour tout
-- le mois affiché, le frontend filtre/agrège sans recalcul métier.
--
-- Salariés inclus pour un jour donné (UNION, un employé peut apparaître par
-- l'un ou l'autre critère) :
--   (a) planifiés à cet hôtel ce jour (staff_planning.status IN ('P','PE'))
--   (b) ayant pointé à cet hôtel ce jour (staff_clockings.hotel_id), même
--       sans plan local — couvre les extras / salariés en renfort inter-
--       hôtel (cf. module Pointage v2, employee_can_clock_at).
--
-- Heure planifiée : shift_start/shift_end du jour (staff_planning) sinon
-- l'horaire par défaut du salarié (department_schedules via
-- employees.schedule_id) — NULL si aucune des deux sources n'existe.
--
-- Heure réelle : premier clock_in / dernier clock_out du jour à cet hôtel
-- (plusieurs vacations dans la journée sont agrégées en une seule ligne
-- arrivée/départ, cohérent avec le nouveau tableau). Session encore ouverte
-- ⇒ real_out NULL, rattrapage_soir/solde_jour NULL (non calculables tant que
-- le salarié n'a pas pointé sa sortie).
--
-- Formules (identiques à la logique pure JS testée dans
-- tests/lib/pointageDailyLogic.js, à garder synchronisée) :
--   arrival_delta   = real_in_local  - planned_in     (minutes, + = en retard)
--   departure_delta = real_out_local - planned_out    (minutes, + = reste plus tard)
--   retard_matin      = GREATEST(0,  arrival_delta)
--   rattrapage_soir    = GREATEST(0,  departure_delta)
--   solde_jour        = arrival_delta - departure_delta
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
  -- Garde-fou : une page mensuelle reste bornée (évite un abus p_from/p_to).
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
       AND sp.status IN ('P','PE')
  ),
  clocked_days AS (
    SELECT DISTINCT sc.employee_id, sc.day
      FROM public.staff_clockings sc
     WHERE sc.hotel_id = p_hotel
       AND sc.day BETWEEN p_from AND p_to
  ),
  -- Références qualifiées obligatoires : "employee_id" et "day" sont aussi
  -- des paramètres OUT de la fonction (RETURNS TABLE) — une référence de
  -- colonne non qualifiée identique au nom d'un paramètre OUT est ambiguë
  -- pour PL/pgSQL, y compris dans un CTE imbriqué (piège classique).
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
  -- Résolution des heures planifiées/réelles, une seule fois par ligne.
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
    -- GREATEST() ignore les NULL en PostgreSQL (GREATEST(0,NULL)=0) : garde
    -- explicite indispensable pour préserver "—" côté UI quand la donnée
    -- source (plan ou pointage) est absente, au lieu d'afficher 0 à tort.
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
  'Résumé pointage (planifié vs réel, retard matin, rattrapage soir, solde du jour) par salarié pour chaque jour d''une plage. Isolation multi-hôtel via pl_my_hotels(). Utilisée par la page Pointage RH (tableau, KPI, export PDF, cumul mensuel).';
