-- sql/98_security_group_scope_active_hotel.sql
-- P0 SECURITY — cause racine réelle du symptôme rapporté : un utilisateur connecté sur
-- Folkestone Opéra (groupe BOUDAA HOTELS) voyait les hôtels d'un AUTRE groupe réel (REDOUAN)
-- dans Planning Groupe. sql/97 (fuites group_move_timeline/cancellations/replacements/
-- v_staff_day_flags) ne l'expliquait pas — confirmé par reproduction directe en production.
--
-- Cause racine exacte : org_get(), group_planning(), group_staff_directory(),
-- group_requirements_list() et group_travel_times() résolvaient le "groupe courant" via un
-- scan SANS ORDER BY ni LIMIT déterministe sur TOUS les hôtels accessibles à l'appelant
-- (pl_my_hotels()) :
--   SELECT group_id INTO v_gid FROM hotels WHERE id IN (SELECT pl_my_hotels())
--     AND group_id IS NOT NULL LIMIT 1;
-- Pour un utilisateur ayant un accès légitime (user_hotels) à des hôtels de PLUSIEURS groupes
-- réels — cas confirmé en production (accès multi-groupe direction) — ce LIMIT 1 sans ORDER BY
-- pouvait retourner N'IMPORTE LEQUEL des groupes accessibles, sans aucun rapport avec l'hôtel
-- réellement affiché/sélectionné par l'utilisateur (get_user_hotel_id(), déjà la source de
-- vérité utilisée partout ailleurs — ex. policy hotels_select : id = get_user_hotel_id()).
--
-- Preuve en production (lecture seule, avant correctif) : group_planning() appelé pour le
-- compte réel ayant accès à la fois à BOUDAA HOTELS (dont Folkestone opera) et à un second
-- groupe réel a renvoyé le group_id ET les 4 hôtels de cet AUTRE groupe — jamais Boudaa/
-- Folkestone. Après correctif, le même appel (avec l'hôtel actif substitué à Folkestone pour
-- la preuve) ne renvoie que les 4 hôtels Boudaa.
--
-- Correctif : chaque fonction résout désormais le groupe via l'hôtel ACTIF de l'appelant
-- (get_user_hotel_id()), jamais via un scan arbitraire de tous ses hôtels accessibles. Les
-- filtres ACL existants (id IN pl_my_hotels()) sont conservés en défense en profondeur.

BEGIN;

CREATE OR REPLACE FUNCTION public.org_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid; g record;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null); END IF;
  SELECT * INTO g FROM hotel_groups WHERE id=v_gid;
  RETURN jsonb_build_object(
    'group_id',v_gid,'name',g.name,'status',g.status,'logo_url',g.logo_url,
    'features',coalesce(g.features,'{}'::jsonb),'created_at',g.created_at,
    'members',(SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'name',name,'hotel_code',hotel_code,'city',city,'address',address,'country',country,
        'phone',phone,'email',email,'currency',currency,'timezone',timezone,
        'active',active,'status',coalesce(status,'active')) ORDER BY name),'[]'::jsonb) FROM hotels WHERE group_id=v_gid),
    'counts',jsonb_build_object(
      'hotels',(SELECT count(*) FROM hotels WHERE group_id=v_gid),
      'employees',(SELECT count(*) FROM employees WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid)),
      'users',(SELECT count(DISTINCT user_id) FROM user_hotels WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid))
    ));
END $function$;

CREATE OR REPLACE FUNCTION public.group_planning(p_service text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null,'hotels','[]'::jsonb,'services','[]'::jsonb,'cells','[]'::jsonb,'requirements','[]'::jsonb); END IF;
  RETURN jsonb_build_object(
    'group_id', v_gid,
    'hotels', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'hotel_code',hotel_code) ORDER BY name),'[]'::jsonb)
               FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels())),
    'services', (SELECT coalesce(jsonb_agg(DISTINCT name),'[]'::jsonb) FROM staff_departments
                 WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND id IN (SELECT public.pl_my_hotels()))),
    'cells', (SELECT coalesce(jsonb_agg(c),'[]'::jsonb) FROM (
        SELECT jsonb_build_object('hotel_id',e.hotel_id,'employee_id',e.id,'name',e.first_name||' '||e.last_name,
               'role',e.role,'is_extra',false,'origin_hotel_id',e.hotel_id,'day',gd.day::date,
               'status',coalesce(sp.status,''),
               'emp_status',coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END),
               'service',p_service,'shift_label',sp.shift_label) AS c
        FROM employees e
        CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gd(day)
        LEFT JOIN staff_planning sp ON sp.employee_id=e.id AND sp.hotel_id=e.hotel_id AND sp.day=gd.day::date
        WHERE e.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels()))
          AND e.department=p_service
          AND coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END) <> 'parti'
        UNION ALL
        SELECT jsonb_build_object('hotel_id',sp.hotel_id,'employee_id',e.id,'name',e.first_name||' '||e.last_name,
               'role',coalesce(act.host_role,e.role),'is_extra',true,'origin_hotel_id',e.hotel_id,'day',sp.day,'status',sp.status,
               'emp_status',e.status,'service',p_service,'shift_label',sp.shift_label)
        FROM employee_extra_activations act
        JOIN staff_departments d ON d.id=act.host_service_id AND d.name=p_service
        JOIN employees e ON e.id=act.employee_id
        JOIN staff_planning sp ON sp.employee_id=act.employee_id AND sp.hotel_id=act.hotel_id
          AND sp.day BETWEEN p_from AND p_to
          AND extract(year FROM sp.day)::int=act.year AND extract(month FROM sp.day)::int=act.month
        WHERE act.active AND act.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels()))
      ) sub),
    'requirements', (SELECT coalesce(jsonb_agg(jsonb_build_object('hotel_id',hotel_id,'weekday',weekday,'shift',shift,'required',required_count)),'[]'::jsonb)
                     FROM group_staffing_requirements
                     WHERE service_name=p_service AND hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND id IN (SELECT public.pl_my_hotels())))
  );
END $function$;

CREATE OR REPLACE FUNCTION public.group_staff_directory()
 RETURNS TABLE(employee_id uuid, first_name text, last_name text, role text, department text, hotel_id uuid, hotel_name text, phone text, email text, active boolean, status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT e.id, e.first_name, e.last_name, e.role, e.department,
         e.hotel_id, h.name, e.phone, e.email, e.active, e.status
  FROM public.employees e
  JOIN public.hotels h ON h.id = e.hotel_id
  WHERE public.is_platform_admin()
     OR h.group_id = (SELECT group_id FROM public.hotels WHERE id = public.get_user_hotel_id())
  ORDER BY h.name, e.last_name, e.first_name;
$function$;

CREATE OR REPLACE FUNCTION public.group_requirements_list()
 RETURNS TABLE(hotel_id uuid, service_name text, weekday integer, required_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT hotel_id, service_name, weekday, required_count
  FROM group_staffing_requirements
  WHERE hotel_id IN (SELECT public.pl_my_hotels())
    AND hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;

CREATE OR REPLACE FUNCTION public.group_travel_times()
 RETURNS TABLE(from_hotel_id uuid, to_hotel_id uuid, duration_min integer, safety_margin_min integer, transport_type text, valid_from date, valid_to date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT from_hotel_id, to_hotel_id, duration_min, safety_margin_min, transport_type, valid_from, valid_to
  FROM hotel_travel_times
  WHERE from_hotel_id IN (SELECT public.pl_my_hotels()) AND to_hotel_id IN (SELECT public.pl_my_hotels())
    AND from_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()))
    AND to_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;

COMMIT;

-- Note de suivi (hors périmètre de ce correctif, non exploité par le symptôme rapporté) :
-- org_provision() résout aussi son groupe via un scan pl_my_hotels() (LIMIT non déterministe
-- absent, mais boucle sur TOUS les hôtels accessibles) et, si aucun groupe n'existe, y assigne
-- indistinctement tous les hôtels accessibles à l'appelant. Pour un utilisateur multi-groupe
-- dont l'hôtel actif n'a pas encore de groupe, ceci pourrait fusionner à tort des hôtels de
-- groupes prévus différents. Cette fonction n'a été déclenchée par aucun scénario observé ici
-- (les deux groupes réels concernés existent déjà) ; à traiter dans un correctif dédié avant
-- toute campagne d'onboarding multi-groupe.
