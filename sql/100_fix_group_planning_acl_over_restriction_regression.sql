-- sql/100_fix_group_planning_acl_over_restriction_regression.sql
-- P0 — RÉGRESSION FONCTIONNELLE introduite par sql/98/99 : l'onglet « Groupe » a disparu pour
-- la quasi-totalité des comptes réels (y compris des comptes Direction légitimes de Folkestone
-- Opéra, groupe BOUDAA HOTELS), alors que la correction de la fuite inter-groupes ne devait
-- JAMAIS supprimer l'accès au Planning Groupe pour les comptes de leur PROPRE groupe.
--
-- CAUSE EXACTE (prouvée en production, pas supposée) : group_planning(), group_requirements_list()
-- et group_travel_times() combinaient DEUX filtres différents :
--   1. group_id = (groupe de l'hôtel ACTIF, via get_user_hotel_id())   -- correct, introduit par sql/98
--   2. id IN (SELECT public.pl_my_hotels())                            -- préexistant, conservé par erreur
-- pl_my_hotels() ne renvoie que les hôtels pour lesquels l'utilisateur a une ligne EXPLICITE
-- dans `user_hotels` (ACL multi-hôtels). Or la majorité des comptes réels (recensé en production :
-- 5 des 14 comptes de ce dépôt de test, et plusieurs comptes Direction de Folkestone Opéra même
-- après filtrage) n'ont AUCUNE ligne `user_hotels` : leur accès repose entièrement sur
-- `users.hotel_id` (colonne historique), déjà résolu correctement par get_user_hotel_id() via son
-- fallback (c). Pour ces comptes, pl_my_hotels() est TOUJOURS vide, donc l'intersection avec le
-- filtre groupe renvoyait une liste d'hôtels VIDE — group_id correct, mais hotels:[] — ce qui fait
-- échouer la condition d'éligibilité côté frontend (gpCheckEligible : hs.length>=2) et masque
-- l'onglet Groupe entièrement, y compris pour des comptes 100% légitimes de leur propre groupe.
--
-- Preuve directe (lecture seule, avant correctif, compte réel Direction de Folkestone Opéra,
-- actif_hotel=Folkestone, groupe=BOUDAA HOTELS, 0 ligne user_hotels) :
--   group_planning() -> {"group_id":"48b8f8b6-...","hotels":[],...}   (groupe correct, hotels VIDE)
-- Après ce correctif (même compte) :
--   group_planning() -> {"group_id":"48b8f8b6-...","hotels":[Folkestone,Grand Hotel du Havre,
--                         Vendome opera,Washington Opera]}  -- ses 4 hôtels BOUDAA, aucun hôtel
--                         du groupe REDOUAN (Arty Paris/Au Royal Mad/Le Home Latin/Le Montclair
--                         Montmartre), vérifié par requête directe sur `hotels`.
--
-- CORRECTIF : retire l'intersection pl_my_hotels() de ces 3 fonctions. Le périmètre de sécurité
-- reste intégralement le group_id de l'hôtel ACTIF (get_user_hotel_id()) — strictement le même
-- périmètre déjà utilisé sans aucun filtre pl_my_hotels() additionnel par org_get() et
-- group_staff_directory() (jamais concernées par cette régression, cf. sql/98), donc CE N'EST
-- PAS UNE RÉOUVERTURE DE LA FUITE : aucun hôtel hors du groupe de l'hôtel actif n'est ni n'a
-- jamais été exposé par ce correctif. pl_my_hotels() reste la source de vérité, inchangée, pour
-- la famille group_move_* (propositions de renfort, qui exigent un accès EXPLICITE aux hôtels
-- origine ET destination — périmètre volontairement plus strict, non concerné par ce bug) et pour
-- les RPC d'écriture hôtel/groupe (hotel_group_*, org_*), qui ne sont pas non plus concernées ici.

BEGIN;

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
               FROM hotels WHERE group_id=v_gid AND active),
    'services', (SELECT coalesce(jsonb_agg(DISTINCT name),'[]'::jsonb) FROM staff_departments
                 WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid)),
    'cells', (SELECT coalesce(jsonb_agg(c),'[]'::jsonb) FROM (
        SELECT jsonb_build_object('hotel_id',e.hotel_id,'employee_id',e.id,'name',e.first_name||' '||e.last_name,
               'role',e.role,'is_extra',false,'origin_hotel_id',e.hotel_id,'day',gd.day::date,
               'status',coalesce(sp.status,''),
               'emp_status',coalesce(e.status, CASE WHEN e.active THEN 'actif' ELSE 'parti' END),
               'service',p_service,'shift_label',sp.shift_label) AS c
        FROM employees e
        CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gd(day)
        LEFT JOIN staff_planning sp ON sp.employee_id=e.id AND sp.hotel_id=e.hotel_id AND sp.day=gd.day::date
        WHERE e.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active)
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
        WHERE act.active AND act.hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid AND active)
      ) sub),
    'requirements', (SELECT coalesce(jsonb_agg(jsonb_build_object('hotel_id',hotel_id,'weekday',weekday,'shift',shift,'required',required_count)),'[]'::jsonb)
                     FROM group_staffing_requirements
                     WHERE service_name=p_service AND hotel_id IN (SELECT id FROM hotels WHERE group_id=v_gid))
  );
END $function$;

CREATE OR REPLACE FUNCTION public.group_requirements_list()
 RETURNS TABLE(hotel_id uuid, service_name text, weekday integer, required_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT hotel_id, service_name, weekday, required_count
  FROM group_staffing_requirements
  WHERE hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;

CREATE OR REPLACE FUNCTION public.group_travel_times()
 RETURNS TABLE(from_hotel_id uuid, to_hotel_id uuid, duration_min integer, safety_margin_min integer, transport_type text, valid_from date, valid_to date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT from_hotel_id, to_hotel_id, duration_min, safety_margin_min, transport_type, valid_from, valid_to
  FROM hotel_travel_times
  WHERE from_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()))
    AND to_hotel_id IN (SELECT id FROM hotels WHERE group_id = (SELECT group_id FROM hotels WHERE id = public.get_user_hotel_id()));
$function$;

COMMIT;

-- Note de suivi — permission frontend « Réception » (hors périmètre SQL de ce correctif) :
-- la matrice DEFAULT_PERMISSIONS (index.html) ne comporte, pour le rôle reception, AUCUNE entrée
-- group_planning (donc canDo('group_planning','view') vaut false par défaut), et aucune ligne
-- hotel_role_permissions ne l'accorde à Folkestone Opéra. Cet état est IDENTIQUE avant et après
-- toute intervention de cet incident (index.html n'a jamais été modifié) : si l'onglet Groupe doit
-- être visible pour le rôle Réception, c'est une décision de droits métier distincte de cette
-- régression, à valider explicitement avant toute modification de DEFAULT_PERMISSIONS ou création
-- d'une ligne hotel_role_permissions.
