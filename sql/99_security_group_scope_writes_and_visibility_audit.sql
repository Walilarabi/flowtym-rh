-- sql/99_security_group_scope_writes_and_visibility_audit.sql
-- P0 SECURITY — suite du ré-audit exhaustif exigé sur TOUTES les RPC de Planning Groupe
-- après sql/98 (bascule org_get/group_planning/group_staff_directory/group_requirements_list/
-- group_travel_times sur get_user_hotel_id()). Ce ré-audit systématique (nom, contrôle d'accès,
-- filtre groupe, filtre hôtel pour chaque RPC) a révélé que le même défaut, et un défaut distinct
-- de filtrage totalement absent, subsistaient ailleurs. Aucun des deux n'explique le symptôme
-- initialement rapporté (déjà fermé par sql/98) ; ce sont des trouvailles du ré-audit demandé.
--
-- 1) org_create_hotel / org_detach_hotel / org_set_hotel_status / org_update_hotel résolvaient
--    encore le "groupe courant" via le même scan non déterministe que sql/98 a corrigé ailleurs :
--      SELECT group_id INTO v_gid FROM hotels WHERE id IN (SELECT pl_my_hotels())
--        AND group_id IS NOT NULL LIMIT 1;
--    Pour un utilisateur multi-groupe légitime, ceci pouvait faire agir ces 4 RPC d'écriture
--    (créer/détacher/suspendre/renommer un hôtel) sur un groupe différent de celui réellement actif
--    (get_user_hotel_id()), au lieu d'échouer proprement ou d'agir sur le bon groupe. Corrigé en
--    réutilisant la même source de vérité que sql/98 : get_user_hotel_id().
--
-- 2) org_provision() cumulait le même défaut ET un bug plus grave : pour tout hôtel accessible à
--    l'appelant (pl_my_hotels(), donc potentiellement à travers PLUSIEURS groupes réels) et
--    dépourvu de hotel_code, la boucle forçait purement et simplement
--      UPDATE hotels SET hotel_code=v_code, group_id=v_gid WHERE id=r.id
--    -- un ECRASEMENT INCONDITIONNEL du group_id existant de cet hôtel, même s'il appartenait déjà
--    à un AUTRE groupe réel. Un utilisateur (ex. compte support/plateforme) ayant accès à des
--    hôtels de plusieurs groupes aurait pu, en déclenchant org_provision() (appelée automatiquement
--    par org_create_hotel quand aucun groupe n'existe encore, et directement par le frontend
--    — BE.orgProvision()), fusionner silencieusement un hôtel d'un groupe réel dans un autre.
--    Corrigé : (a) v_gid résolu via get_user_hotel_id() comme ci-dessus ; (b) la boucle ne touche
--    plus que les hôtels SANS groupe (group_id IS NULL) et n'écrase plus jamais un group_id
--    existant (COALESCE(group_id, v_gid) au lieu d'une affectation directe).
--
-- 3) group_move_visibility_audit() (utilisée par group_move_visibility_backfill(), toutes deux
--    exécutables par `anon` en production — vérifié par introspection des GRANT réels, aucune
--    hypothèse) ne filtrait par AUCUN critère de groupe ni d'hôtel : elle renvoyait TOUTES les
--    propositions de déplacement "applied" de TOUTE la base, tous groupes confondus, à N'IMPORTE
--    QUEL appelant y compris non authentifié. group_move_visibility_backfill(false) exécute en plus
--    des ECRITURES (_gmp_ensure_visibility) pour chacune de ces propositions. C'est une fuite de
--    données inter-groupes directe et un vecteur d'écriture non authentifiée sur les données de
--    TOUS les groupes. Corrigé : ajout du même filtre pl_my_hotels() que toutes les fonctions
--    sœurs (group_move_proposals_list, group_move_reservations, group_move_open_for_employee,
--    group_move_timeline) et retrait du droit d'exécution à `anon` sur les deux fonctions, par
--    cohérence avec toutes les autres RPC group_move_* d'écriture/lecture sensible.
--
-- 4) group_move_workflow_get(p_group) acceptait un group_id ARBITRAIRE fourni par l'appelant sans
--    aucune vérification d'appartenance (contrairement à group_move_workflow_set(p_group,...) qui,
--    elle, vérifie déjà correctement l'appartenance). Un appelant authentifié pouvait donc lire la
--    configuration du workflow d'approbation (libellés, types d'approbateurs) d'un groupe auquel il
--    n'a aucun accès. Corrigé en ajoutant exactement le même contrôle que group_move_workflow_set.

BEGIN;

CREATE OR REPLACE FUNCTION public.org_create_hotel(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid; v_new uuid; v_code text; v_pubuser uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN v_gid := public.org_provision(); END IF;
  v_code := upper(trim(coalesce(p->>'hotel_code','')));
  IF v_code='' THEN RAISE EXCEPTION 'CODE_VIDE'; END IF;
  IF EXISTS(SELECT 1 FROM hotels WHERE upper(hotel_code)=v_code) THEN RAISE EXCEPTION 'CODE_EXISTANT'; END IF;
  IF coalesce(trim(p->>'name'),'')='' THEN RAISE EXCEPTION 'NOM_VIDE'; END IF;
  INSERT INTO hotels(name,address,city,country,phone,email,currency,timezone,hotel_code,group_id,active,status)
    VALUES(trim(p->>'name'),nullif(p->>'address',''),nullif(p->>'city',''),nullif(p->>'country',''),nullif(p->>'phone',''),nullif(p->>'email',''),
           coalesce(nullif(p->>'currency',''),'EUR'),coalesce(nullif(p->>'timezone',''),'Europe/Paris'),v_code,v_gid,true,'active')
    RETURNING id INTO v_new;
  SELECT id INTO v_pubuser FROM users WHERE auth_id=auth.uid() LIMIT 1;
  IF v_pubuser IS NOT NULL THEN
    INSERT INTO user_hotels(user_id,hotel_id,is_default) VALUES(v_pubuser,v_new,false) ON CONFLICT (user_id,hotel_id) DO NOTHING;
  END IF;
  RETURN public.org_get();
END $function$;

CREATE OR REPLACE FUNCTION public.org_detach_hotel(p_hotel uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL OR NOT EXISTS(SELECT 1 FROM hotels WHERE id=p_hotel AND group_id=v_gid) THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;
  UPDATE hotels SET group_id=NULL WHERE id=p_hotel;
  RETURN public.org_get();
END $function$;

CREATE OR REPLACE FUNCTION public.org_provision()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid; r record; v_base text; v_code text; v_n int;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL THEN INSERT INTO hotel_groups(name) VALUES (NULL) RETURNING id INTO v_gid; END IF;
  FOR r IN SELECT id, name, hotel_code FROM hotels
           WHERE id IN (SELECT public.pl_my_hotels()) AND group_id IS NULL LOOP
    IF r.hotel_code IS NULL THEN
      v_base := coalesce((SELECT upper(string_agg(left(w,1),'')) FROM (
                  SELECT w FROM unnest(regexp_split_to_array(regexp_replace(coalesce(r.name,''),'[^A-Za-z ]','','g'),'\s+')) AS w
                  WHERE w<>'' LIMIT 2) t),'');
      IF length(v_base)<2 THEN v_base := upper(left(regexp_replace(coalesce(r.name,'HT'),'[^A-Za-z]','','g')||'HT',2)); END IF;
      v_n := 1;
      LOOP
        v_code := v_base || lpad(v_n::text,3,'0');
        EXIT WHEN NOT EXISTS(SELECT 1 FROM hotels WHERE upper(hotel_code)=v_code);
        v_n := v_n + 1;
      END LOOP;
      UPDATE hotels SET hotel_code=v_code, group_id=COALESCE(group_id, v_gid) WHERE id=r.id;
    ELSE
      UPDATE hotels SET group_id=COALESCE(group_id,v_gid) WHERE id=r.id;
    END IF;
  END LOOP;
  RETURN v_gid;
END $function$;

CREATE OR REPLACE FUNCTION public.org_set_hotel_status(p_hotel uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL OR NOT EXISTS(SELECT 1 FROM hotels WHERE id=p_hotel AND group_id=v_gid) THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;
  IF p_status NOT IN ('active','suspended') THEN RAISE EXCEPTION 'STATUT_INVALIDE'; END IF;
  UPDATE hotels SET status=p_status, active=(p_status='active') WHERE id=p_hotel;
  RETURN public.org_get();
END $function$;

CREATE OR REPLACE FUNCTION public.org_update_hotel(p_hotel uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_gid uuid;
BEGIN
  SELECT group_id INTO v_gid FROM hotels WHERE id = public.get_user_hotel_id();
  IF v_gid IS NULL OR NOT EXISTS(SELECT 1 FROM hotels WHERE id=p_hotel AND group_id=v_gid) THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;
  UPDATE hotels SET
    name=coalesce(nullif(trim(p->>'name'),''),name),
    address=coalesce(p->>'address',address), city=coalesce(p->>'city',city), country=coalesce(p->>'country',country),
    phone=coalesce(p->>'phone',phone), email=coalesce(p->>'email',email),
    currency=coalesce(nullif(p->>'currency',''),currency), timezone=coalesce(nullif(p->>'timezone',''),timezone)
  WHERE id=p_hotel;
  RETURN public.org_get();
END $function$;

CREATE OR REPLACE FUNCTION public.group_move_visibility_audit()
 RETURNS TABLE(proposal_id uuid, employee_id uuid, from_hotel_id uuid, to_hotel_id uuid, to_service text, period_from date, period_to date, applied_at timestamp with time zone, missing_assignment boolean, missing_activations text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH applied AS (
    SELECT p.id, p.employee_id, p.from_hotel_id, p.to_hotel_id, p.to_service,
           p.period_from, p.period_to, p.applied_at, p.slots
    FROM group_move_proposals p
    WHERE p.status = 'applied'
      AND p.from_hotel_id IN (SELECT public.pl_my_hotels())
      AND p.to_hotel_id IN (SELECT public.pl_my_hotels())
  ),
  slots_months AS (
    SELECT a.id AS proposal_id, a.employee_id, a.from_hotel_id, a.to_hotel_id, a.to_service,
           a.period_from, a.period_to, a.applied_at,
           extract(year FROM (s->>'date')::date)::int AS y,
           extract(month FROM (s->>'date')::date)::int AS m
    FROM applied a
    LEFT JOIN jsonb_array_elements(a.slots) s ON true
  ),
  agg AS (
    SELECT sm.proposal_id, sm.employee_id, sm.from_hotel_id, sm.to_hotel_id, sm.to_service,
           sm.period_from, sm.period_to, sm.applied_at,
           NOT EXISTS (
             SELECT 1 FROM employee_hotel_assignments h
             WHERE h.employee_id = sm.employee_id AND h.target_hotel_id = sm.to_hotel_id AND h.active = true
           ) AS missing_assignment,
           array_agg(DISTINCT sm.y::text || '-' || lpad(sm.m::text, 2, '0'))
             FILTER (
               WHERE sm.y IS NOT NULL AND NOT EXISTS (
                 SELECT 1 FROM employee_extra_activations ea
                 WHERE ea.employee_id = sm.employee_id AND ea.hotel_id = sm.to_hotel_id
                   AND ea.year = sm.y AND ea.month = sm.m AND ea.active = true
               )
             ) AS missing_activations
    FROM slots_months sm
    GROUP BY sm.proposal_id, sm.employee_id, sm.from_hotel_id, sm.to_hotel_id, sm.to_service,
             sm.period_from, sm.period_to, sm.applied_at
  )
  SELECT proposal_id, employee_id, from_hotel_id, to_hotel_id, to_service,
         period_from, period_to, applied_at,
         missing_assignment,
         coalesce(missing_activations, ARRAY[]::text[]) AS missing_activations
  FROM agg
  WHERE missing_assignment OR coalesce(array_length(missing_activations, 1), 0) > 0
  ORDER BY applied_at DESC NULLS LAST;
$function$;

-- Ces deux fonctions portaient encore le GRANT PUBLIC par défaut de Postgres (jamais retiré à
-- leur création, contrairement à toutes les autres RPC group_move_* qui le révoquent). REVOKE
-- ... FROM anon seul est insuffisant tant que le GRANT PUBLIC subsiste (anon en hérite) : il faut
-- révoquer PUBLIC puis regranter explicitement aux seuls rôles réellement nécessaires.
REVOKE EXECUTE ON FUNCTION public.group_move_visibility_audit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.group_move_visibility_backfill(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_move_visibility_audit() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.group_move_visibility_backfill(boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.group_move_workflow_get(p_group uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  IF p_group NOT IN (SELECT group_id FROM hotels WHERE id IN (SELECT public.pl_my_hotels())) THEN
    RAISE EXCEPTION 'Accès refusé à ce groupe';
  END IF;
  SELECT steps INTO v FROM group_move_workflows WHERE group_id=p_group;
  IF v IS NULL THEN
    -- Défaut : validation par le directeur de l'hôtel de destination.
    v := jsonb_build_array(jsonb_build_object('key','dest_director','label','Directeur hôtel destination','approver_type','dest_director','hotel_scope','dest'));
  END IF;
  RETURN v;
END $function$;

COMMIT;
