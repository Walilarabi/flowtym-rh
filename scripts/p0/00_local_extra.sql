-- Supplément local : objets présents en base live mais absents du schéma local de
-- base (staff_departments + helpers segment-hours), requis par la migration 54.
CREATE TABLE IF NOT EXISTS public.staff_departments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  name text NOT NULL,
  sort_order int DEFAULT 0);

CREATE OR REPLACE FUNCTION public.staff_segment_hours(p_emp uuid, p_day date)
 RETURNS TABLE(hotel_id uuid, minutes integer, hours numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT hotel_id, sum(seg_end_min - seg_start_min)::int AS minutes,
         round(sum(seg_end_min - seg_start_min)/60.0, 2) AS hours
  FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day
  GROUP BY hotel_id;
$function$;

CREATE OR REPLACE FUNCTION public.staff_day_hours(p_emp uuid, p_day date, p_default_hpd numeric DEFAULT 7)
 RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v numeric;
BEGIN
  SELECT round(sum(seg_end_min - seg_start_min)/60.0, 2) INTO v FROM staff_planning_segments WHERE employee_id=p_emp AND day=p_day;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT coalesce(hours,
           CASE WHEN shift_start IS NOT NULL AND shift_end IS NOT NULL
                THEN round((extract(epoch FROM shift_end)-extract(epoch FROM shift_start))/3600.0,2)
                ELSE p_default_hpd END)
    INTO v FROM staff_planning
    WHERE employee_id=p_emp AND day=p_day AND status IN ('P','PE')
    ORDER BY updated_at DESC LIMIT 1;
  RETURN coalesce(v, 0);
END $function$;
