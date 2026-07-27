-- 62_group_planning_repos_visibility.sql
-- ============================================================================
-- Correctif : les collaborateurs en Repos n'apparaissaient jamais dans le
-- Planning Groupe.
--
-- Cause racine
-- ------------
-- La RPC group_planning(p_service, p_from, p_to) construisait `cells`
-- (branche titulaires) à partir de :
--   FROM staff_planning sp JOIN employees e ON e.id = sp.employee_id
-- Or, dans Flowtym, un salarié en Repos n'a AUCUNE ligne staff_planning pour
-- ce jour — convention confirmée côté frontend (index.html:saveChanges) :
--   if(status===''){ if(committed.has(k)) dels.push({hotel_id, employee_id, day}); }
-- (statut vide = suppression de la ligne, pas insertion d'une ligne « repos »).
--
-- Conséquence : la requête ne renvoyait donc JAMAIS ces salariés — ils
-- n'apparaissaient ni dans la grille du Planning Groupe, ni dans les
-- suggestions, ni comme mobilisables.
--
-- Correctif
-- ---------
-- La branche titulaires part maintenant de l'ensemble des employés actifs
-- du (hôtel, service) — CROSS JOIN generate_series(p_from, p_to) pour
-- couvrir chaque jour de la période — puis LEFT JOIN staff_planning pour
-- récupérer le statut du jour. Absence de ligne → status='' (Repos),
-- exactement comme le fait déjà le rendu du planning établissement
-- (index.html:render(), qui part de `staff` et non de `planningRows`).
--
-- La branche extras (is_extra=true, activations employee_extra_activations)
-- N'EST PAS modifiée : elle reste basée sur un INNER JOIN staff_planning,
-- car elle représente une activation déjà existante et ne doit afficher
-- l'extra dans l'hôtel d'accueil que les jours où il y est réellement
-- planifié (comportement inchangé, hors périmètre de ce correctif).
--
-- Filtre de périmètre (conservé à l'identique) :
--   coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END) <> 'parti'
-- Reproduit exactement la convention BE.listEmployees (index.html:852) :
--   {...e, status: e.status || (e.active ? 'actif' : 'parti')}
-- Les salariés désactivés/sortis restent exclus. Aucun changement sur le
-- filtrage par hôtel/groupe/accès RLS (pl_my_hotels()).
--
-- Migration destructive ? NON — CREATE OR REPLACE uniquement.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.group_planning(p_service text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id IN (SELECT public.pl_my_hotels()) AND group_id IS NOT NULL LIMIT 1;
  IF v_gid IS NULL THEN RETURN jsonb_build_object('group_id',null,'hotels','[]'::jsonb,'services','[]'::jsonb,'cells','[]'::jsonb,'requirements','[]'::jsonb); END IF;
  RETURN jsonb_build_object(
    'group_id', v_gid,
    'hotels', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'hotel_code',hotel_code) ORDER BY name),'[]'::jsonb)
               FROM hotels WHERE group_id=v_gid AND active AND id IN (SELECT public.pl_my_hotels())),
    'services', (SELECT coalesce(jsonb_agg(DISTINCT name),'[]'::jsonb) FROM staff_departments
                 WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND id IN (SELECT public.pl_my_hotels()))),
    'cells', (SELECT coalesce(jsonb_agg(c),'[]'::jsonb) FROM (
        -- Titulaires : TOUS les employés actifs du (hôtel, service), pour
        -- chaque jour de la période. LEFT JOIN staff_planning : l'absence de
        -- ligne = Repos (status='').
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
        -- Extras (activations existantes) : comportement INCHANGÉ.
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
