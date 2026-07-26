-- 57_group_move_apply_visibility.sql
-- ============================================================================
-- Correctif ATOMIQUE : la mission inter-hôtels appliquée doit être visible
-- dans le planning établissement de destination — dans la MÊME transaction
-- que l'écriture staff_planning.
--
-- Cause racine (voir PR #6, commit d'audit) :
--   group_move_apply écrivait bien staff_planning (source de vérité) mais
--   n'alimentait pas la couche de visibilité extra :
--     · employee_hotel_assignments  (autorisation permanente)
--     · employee_extra_activations  (activation mensuelle)
--   Le rendu du planning établissement (index.html:render()) ne montre un
--   collaborateur d'un autre hôtel que via l'intersection de ces deux tables.
--   Sans elles, la ligne staff_planning existait mais restait invisible.
--
-- Correctif :
--   1. Fonction interne _gmp_ensure_visibility(...) — idempotente, réutilise
--      les mêmes conventions d'upsert que le parcours manuel d'ajout d'extra
--      (BE.addHotelAssignment et BE.setExtraActivation côté client).
--   2. group_move_apply l'appelle en fin de traitement, AVANT de marquer
--      la proposition 'applied'. Toute exception (RAISE) déclenche le
--      rollback plpgsql de l'intégralité de la transaction — atomicité
--      garantie : impossible d'avoir une mission écrite sans visibilité,
--      impossible d'avoir une visibilité sans mission, impossible d'avoir
--      une proposition marquée applied sans que les 3 opérations aient
--      réussi ensemble.
--
-- Migration destructive ? NON — les tables cibles et leurs contraintes
-- unique existent déjà en production ; on ajoute UNE fonction interne et on
-- réécrit CREATE OR REPLACE la RPC publique. Les données existantes ne sont
-- pas modifiées par cette migration. Voir la section « données déjà créées »
-- ci-dessous pour l'audit rétroactif.
--
-- Droits requis :
--   · SECURITY DEFINER pour _gmp_ensure_visibility (mêmes garanties d'accès
--     que group_move_apply, qui contient déjà _gmp_can_access).
--   · Aucun GRANT/REVOKE modifié : la RPC publique reste appelable par les
--     mêmes utilisateurs qu'avant (contrôlé par _gmp_can_access).
--
-- Dépendances :
--   · Tables : employee_hotel_assignments, employee_extra_activations,
--     staff_planning, group_move_proposals, group_move_proposal_events,
--     group_move_applications.
--   · Fonctions : _gmp_can_access, _gmp_fingerprint, _gmp_subtract,
--     _gmp_notify, group_move_open_for_employee.
--
-- Prérequis à vérifier avant application (schémas en production) :
--   ✓ employee_hotel_assignments (
--       employee_id uuid, source_hotel_id uuid, target_hotel_id uuid,
--       notes text, authorized_by uuid, active boolean, ...)
--     UNIQUE (employee_id, target_hotel_id)
--   ✓ employee_extra_activations (
--       employee_id uuid, hotel_id uuid, year int, month int,
--       host_service_id uuid, host_role text, active boolean, comment text,
--       ...)
--     UNIQUE (employee_id, hotel_id, year, month)
--
-- Si l'une de ces contraintes UNIQUE n'existe pas exactement sous ce nom,
-- adapter la clause ON CONFLICT ci-dessous AVANT d'appliquer.
-- ============================================================================

-- ── 1. Fonction interne (atomique, idempotente) ─────────────────────────────
CREATE OR REPLACE FUNCTION public._gmp_ensure_visibility(
  p_emp uuid,
  p_from_hotel uuid,
  p_to_hotel uuid,
  p_days date[],
  p_source text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  d date;
  seen text[] := ARRAY[]::text[];
  ym text;
  v_year int;
  v_month int;
BEGIN
  IF p_emp IS NULL OR p_to_hotel IS NULL THEN
    RAISE EXCEPTION 'ensure_visibility: employee et hotel de destination requis';
  END IF;

  -- 1a. Autorisation permanente (employee_hotel_assignments) — upsert idempotent.
  -- ON CONFLICT sur (employee_id, target_hotel_id) : la contrainte UNIQUE
  -- porte ce nom logique en production (cf. BE.addHotelAssignment côté client).
  INSERT INTO employee_hotel_assignments (
    employee_id, source_hotel_id, target_hotel_id, notes, authorized_by, active
  ) VALUES (
    p_emp, p_from_hotel, p_to_hotel,
    'Renfort inter-hôtels — Planning Groupe (' || p_source || ')',
    auth.uid(), true
  )
  ON CONFLICT (employee_id, target_hotel_id) DO UPDATE
    SET active = true,
        notes = COALESCE(EXCLUDED.notes, employee_hotel_assignments.notes),
        source_hotel_id = COALESCE(employee_hotel_assignments.source_hotel_id, EXCLUDED.source_hotel_id);

  -- 1b. Activation mensuelle (employee_extra_activations) — un upsert par mois
  -- couvert par les jours. Idempotent : la contrainte UNIQUE porte sur
  -- (employee_id, hotel_id, year, month).
  FOREACH d IN ARRAY coalesce(p_days, ARRAY[]::date[])
  LOOP
    v_year  := extract(year FROM d)::int;
    v_month := extract(month FROM d)::int;
    ym := v_year::text || '-' || v_month::text;
    IF NOT (ym = ANY(seen)) THEN
      seen := seen || ym;
      INSERT INTO employee_extra_activations (
        employee_id, hotel_id, year, month, host_service_id, host_role,
        active, comment
      ) VALUES (
        p_emp, p_to_hotel, v_year, v_month, NULL, NULL,
        true, 'Renfort inter-hôtels appliqué depuis le Planning Groupe (' || p_source || ')'
      )
      ON CONFLICT (employee_id, hotel_id, year, month) DO UPDATE
        SET active = true,
            comment = COALESCE(EXCLUDED.comment, employee_extra_activations.comment);
    END IF;
  END LOOP;
END $function$;

COMMENT ON FUNCTION public._gmp_ensure_visibility(uuid,uuid,uuid,date[],text) IS
  'Garantit la visibilité extra d''un collaborateur inter-hôtels : upsert '
  'employee_hotel_assignments + employee_extra_activations pour chaque mois '
  'couvert. Idempotent. Appelée UNIQUEMENT par group_move_apply, dans sa '
  'transaction — toute exception déclenche le rollback complet.';

-- ── 2. RPC publique group_move_apply — insertion de l'appel visibilité ──────
-- Réécriture complète (CREATE OR REPLACE) pour intégrer l'appel atomique.
-- Seule la nouvelle section (marquée « ── visibilité extra ── ») est ajoutée
-- par rapport à la version antérieure ; le reste reproduit la logique
-- existante à l'identique (voir db/reconstruct/30_functions.sql:169).
CREATE OR REPLACE FUNCTION public.group_move_apply(p_id uuid, p_idempotency_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r group_move_proposals; v_op uuid; v_cur_fp text; v_unwaived int; v_existing group_move_applications;
        v_self_rank int; v_other record; v_days date[]; d date; v_applied int := 0; v_vacated int := 0; v_segs int := 0;
        v_cuts int4range[]; v_dstart int; v_dend int; v_full boolean; v_slot jsonb; v_kept int4range[]; kr int4range;
        v_oshift record; v_os int; v_oe int; v_dmin int; v_dmax int; v_anyfull boolean; v_result jsonb; v_validation jsonb;
BEGIN
  SELECT * INTO r FROM group_move_proposals WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition introuvable'; END IF;
  IF NOT public._gmp_can_access(r.from_hotel_id, r.to_hotel_id) THEN RAISE EXCEPTION 'Accès refusé'; END IF;

  SELECT array_agg(DISTINCT (s->>'date')::date ORDER BY (s->>'date')::date) INTO v_days
    FROM jsonb_array_elements(r.slots) s WHERE (s->>'date') IS NOT NULL;
  FOREACH d IN ARRAY coalesce(v_days, ARRAY[]::date[]) LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(r.employee_id::text || '|' || d::text, 0));
  END LOOP;

  SELECT * INTO v_existing FROM group_move_applications WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.status='completed' THEN RETURN coalesce(v_existing.result, jsonb_build_object('idempotent', true)); END IF;
    RAISE EXCEPTION 'Application déjà en cours pour cette clé';
  END IF;
  v_op := gen_random_uuid();
  INSERT INTO group_move_applications(idempotency_key, proposal_id, operation_id, applied_by, status)
  VALUES (p_idempotency_key, p_id, v_op, auth.uid(), 'processing');

  IF r.status = 'scheduled' THEN
    IF r.scheduled_at IS NULL OR r.scheduled_at > now() THEN RAISE EXCEPTION 'Programmé non arrivé à échéance'; END IF;
  ELSIF r.status <> 'approved' THEN RAISE EXCEPTION 'Statut non applicable (%).', r.status; END IF;

  IF r.decision = 'blocked' THEN RAISE EXCEPTION 'Proposition bloquée'; END IF;
  v_unwaived := (SELECT count(*) FROM jsonb_array_elements(coalesce(r.simulation->'blockers','[]'::jsonb)) b
                 WHERE (b->>'code') NOT IN (SELECT check_code FROM group_move_proposal_waivers WHERE proposal_id=p_id));
  IF v_unwaived > 0 THEN RAISE EXCEPTION 'Blocage non dérogé'; END IF;
  IF r.expires_at IS NOT NULL AND r.expires_at < now() THEN RAISE EXCEPTION 'Proposition expirée'; END IF;
  v_cur_fp := public._gmp_fingerprint(r.employee_id, r.period_from, r.period_to, r.from_hotel_id, r.to_hotel_id, r.to_service);
  IF r.server_fingerprint IS NOT NULL AND v_cur_fp <> r.server_fingerprint THEN
    UPDATE group_move_proposals SET staleness='to_refresh' WHERE id=p_id;
    RAISE EXCEPTION 'Données modifiées depuis la simulation : re-simulation requise';
  END IF;
  v_self_rank := CASE r.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 ELSE 0 END;
  FOR v_other IN SELECT * FROM group_move_open_for_employee(r.employee_id, p_id) o
    WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(r.slots) a JOIN jsonb_array_elements(o.slots) b ON (a->>'date')=(b->>'date'))
  LOOP
    IF (CASE v_other.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 WHEN 'pending_review' THEN 3 WHEN 'draft' THEN 2 ELSE 0 END) > v_self_rank
       OR ((CASE v_other.status WHEN 'scheduled' THEN 5 WHEN 'approved' THEN 4 WHEN 'pending_review' THEN 3 WHEN 'draft' THEN 2 ELSE 0 END)=v_self_rank AND v_other.created_at < r.created_at) THEN
      RAISE EXCEPTION 'Proposition concurrente prioritaire : revalidation nécessaire';
    END IF;
  END LOOP;

  PERFORM 1 FROM staff_planning WHERE employee_id=r.employee_id AND day = ANY(v_days) FOR UPDATE;

  v_validation := jsonb_build_object(
    'level', CASE WHEN jsonb_array_length(coalesce(r.simulation->'missing','[]'::jsonb)) > 0 THEN 'validation_partielle' ELSE 'valide_sur_donnees_disponibles' END,
    'checks_run', jsonb_build_array('planning','couverture','absences','trajet','chevauchement','expiration','concurrence','derogations','visibilite_extra'),
    'checks_unavailable', jsonb_build_array('competences','disponibilites','regles_rh_variables'),
    'missing', coalesce(r.simulation->'missing','[]'::jsonb)
  );

  PERFORM set_config('flowtym.audit_source','group_planning', true);
  PERFORM set_config('flowtym.audit_reason', coalesce(r.reason,'Renfort inter-hôtels'), true);
  PERFORM set_config('flowtym.operation_id', v_op::text, true);
  PERFORM set_config('flowtym.allow_move_write','on', true);

  FOREACH d IN ARRAY coalesce(v_days, ARRAY[]::date[]) LOOP
    v_cuts := ARRAY[]::int4range[]; v_dmin := NULL; v_dmax := NULL; v_anyfull := false;
    FOR v_slot IN SELECT * FROM jsonb_array_elements(r.slots) WHERE (value->>'date')::date = d LOOP
      IF nullif(v_slot->>'start','') IS NULL OR nullif(v_slot->>'end','') IS NULL THEN v_dstart := 0; v_dend := 1440; v_anyfull := true;
      ELSE v_dstart := extract(hour FROM (v_slot->>'start')::time)*60 + extract(minute FROM (v_slot->>'start')::time);
           v_dend := extract(hour FROM (v_slot->>'end')::time)*60 + extract(minute FROM (v_slot->>'end')::time); END IF;
      v_cuts := v_cuts || int4range(v_dstart, v_dend);
      INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
      VALUES (r.to_hotel_id, r.employee_id, d, v_dstart, v_dend, 'destination', 'PE', p_id, r.from_hotel_id);
      v_segs := v_segs + 1; v_dmin := least(coalesce(v_dmin,v_dstart), v_dstart); v_dmax := greatest(coalesce(v_dmax,v_dend), v_dend);
    END LOOP;
    SELECT shift_start, shift_end, status INTO v_oshift FROM staff_planning WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d;
    IF FOUND THEN
      IF v_oshift.shift_start IS NOT NULL THEN v_os := extract(hour FROM v_oshift.shift_start)*60 + extract(minute FROM v_oshift.shift_start);
           v_oe := extract(hour FROM v_oshift.shift_end)*60 + extract(minute FROM v_oshift.shift_end);
      ELSE v_os := 0; v_oe := 1440; END IF;
      v_kept := public._gmp_subtract(v_os, v_oe, v_cuts);
      FOREACH kr IN ARRAY v_kept LOOP
        INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
        VALUES (r.from_hotel_id, r.employee_id, d, lower(kr), upper(kr), 'origin', 'P', p_id, r.from_hotel_id);
        v_segs := v_segs + 1;
      END LOOP;
      IF coalesce(array_length(v_kept,1),0)=0 THEN
        UPDATE staff_planning SET status='MAD', shift_label=NULL, shift_start=NULL, shift_end=NULL, hours=NULL, source_proposal_id=p_id, updated_by=auth.uid(), updated_at=now()
         WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d;
        v_vacated := v_vacated + 1;
      ELSE
        UPDATE staff_planning SET shift_start=make_time((lower(v_kept[1])/60),(lower(v_kept[1])%60),0),
               shift_end=make_time(least(upper(v_kept[array_length(v_kept,1)]),1439)/60, upper(v_kept[array_length(v_kept,1)])%60,0),
               source_proposal_id=p_id, updated_by=auth.uid(), updated_at=now()
         WHERE hotel_id=r.from_hotel_id AND employee_id=r.employee_id AND day=d AND status IN ('P','PE');
      END IF;
    END IF;
    INSERT INTO staff_planning(hotel_id, employee_id, day, status, duration, break_minutes, shift_start, shift_end, shift_label, source_proposal_id, origin_hotel_id, updated_by)
    VALUES (r.to_hotel_id, r.employee_id, d, 'PE', 1, 0,
            CASE WHEN v_anyfull THEN NULL ELSE make_time(v_dmin/60, v_dmin%60, 0) END,
            CASE WHEN v_anyfull THEN NULL ELSE make_time(least(v_dmax,1439)/60, v_dmax%60, 0) END,
            CASE WHEN v_anyfull THEN NULL ELSE 'custom' END, p_id, r.from_hotel_id, auth.uid())
    ON CONFLICT (hotel_id, employee_id, day) DO UPDATE SET status='PE', shift_start=EXCLUDED.shift_start, shift_end=EXCLUDED.shift_end,
      shift_label=EXCLUDED.shift_label, source_proposal_id=EXCLUDED.source_proposal_id, origin_hotel_id=EXCLUDED.origin_hotel_id, updated_by=EXCLUDED.updated_by, updated_at=now();
    v_applied := v_applied + 1;
  END LOOP;

  -- ── visibilité extra (nouveau) ────────────────────────────────────────────
  -- MÊME transaction : toute exception déclenchée par _gmp_ensure_visibility
  -- rollback l'intégralité — impossible d'aboutir à une mission écrite sans
  -- autorisation ni activation mensuelle.
  PERFORM public._gmp_ensure_visibility(
    r.employee_id, r.from_hotel_id, r.to_hotel_id, v_days,
    'group_move:' || p_id::text
  );

  UPDATE group_move_proposals SET status='applied', applied_at=now(), applied_operation_id=v_op, staleness='valid', updated_at=now() WHERE id=p_id;
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (p_id, auth.uid(), 'applied', r.status, 'applied', jsonb_build_object('operation_id', v_op, 'days', v_applied, 'segments', v_segs, 'origin_vacated', v_vacated, 'validation', v_validation));
  PERFORM public._gmp_notify(p_id, 'applied', 'creator', null, jsonb_build_object('operation_id', v_op));

  UPDATE group_move_proposals SET status='cancelled', updated_at=now()
   WHERE employee_id=r.employee_id AND id<>p_id AND status IN ('draft','pending_review','approved','scheduled')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(slots) b JOIN jsonb_array_elements(r.slots) a ON (a->>'date')=(b->>'date'));

  v_result := jsonb_build_object('applied', true, 'proposal_id', p_id, 'operation_id', v_op, 'days', v_applied, 'segments', v_segs, 'origin_vacated', v_vacated, 'validation', v_validation);
  UPDATE group_move_applications SET status='completed', result=v_result WHERE idempotency_key=p_idempotency_key;
  RETURN v_result;
END $function$;

-- ── 3. Audit rétroactif — missions appliquées avant ce correctif ────────────
-- Fonction de LECTURE SEULE qui liste les missions déjà appliquées mais
-- potentiellement invisibles dans le planning de destination faute de
-- visibilité extra. Ne modifie AUCUNE donnée.
CREATE OR REPLACE FUNCTION public.group_move_visibility_audit()
 RETURNS TABLE (
   proposal_id uuid,
   employee_id uuid,
   from_hotel_id uuid,
   to_hotel_id uuid,
   period_from date,
   period_to date,
   applied_at timestamptz,
   missing_assignment boolean,
   missing_activations text[]
 ) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  WITH applied AS (
    SELECT p.id, p.employee_id, p.from_hotel_id, p.to_hotel_id,
           p.period_from, p.period_to, p.applied_at, p.slots
    FROM group_move_proposals p
    WHERE p.status = 'applied'
  ),
  needs AS (
    SELECT a.id AS proposal_id, a.employee_id, a.from_hotel_id, a.to_hotel_id,
           a.period_from, a.period_to, a.applied_at,
           NOT EXISTS (
             SELECT 1 FROM employee_hotel_assignments h
             WHERE h.employee_id = a.employee_id AND h.target_hotel_id = a.to_hotel_id AND h.active = true
           ) AS missing_assignment,
           array_agg(DISTINCT (extract(year FROM (s->>'date')::date)::int || '-' ||
                               lpad(extract(month FROM (s->>'date')::date)::text, 2, '0'))
                     ORDER BY (extract(year FROM (s->>'date')::date)::int || '-' ||
                               lpad(extract(month FROM (s->>'date')::date)::text, 2, '0'))
           ) FILTER (
             WHERE NOT EXISTS (
               SELECT 1 FROM employee_extra_activations ea
               WHERE ea.employee_id = a.employee_id
                 AND ea.hotel_id = a.to_hotel_id
                 AND ea.year = extract(year FROM (s->>'date')::date)::int
                 AND ea.month = extract(month FROM (s->>'date')::date)::int
                 AND ea.active = true
             )
           ) AS missing_activations
    FROM applied a
    LEFT JOIN jsonb_array_elements(a.slots) s ON true
    GROUP BY a.id, a.employee_id, a.from_hotel_id, a.to_hotel_id,
             a.period_from, a.period_to, a.applied_at
  )
  SELECT proposal_id, employee_id, from_hotel_id, to_hotel_id,
         period_from, period_to, applied_at,
         missing_assignment,
         coalesce(missing_activations, ARRAY[]::text[]) AS missing_activations
  FROM needs
  WHERE missing_assignment OR coalesce(array_length(missing_activations, 1), 0) > 0
  ORDER BY applied_at DESC;
$function$;

COMMENT ON FUNCTION public.group_move_visibility_audit() IS
  'Audit LECTURE SEULE : liste les propositions appliquées qui n''ont pas '
  'l''autorisation extra et/ou une activation mensuelle correspondante. '
  'À exécuter avant régularisation manuelle des données historiques.';

-- ── 4. Consignes de déploiement ─────────────────────────────────────────────
--   1. Vérifier les contraintes UNIQUE mentionnées en tête de fichier.
--   2. Appliquer cette migration en dev/staging d'abord.
--   3. Exécuter : SELECT * FROM group_move_visibility_audit();
--      Cette requête retourne la liste des missions à régulariser (données
--      créées avant ce correctif). NE PAS régulariser automatiquement :
--      me fournir la liste et attendre autorisation explicite (cf. cahier
--      des charges).
--   4. Après validation manuelle, une seconde migration effectuera la
--      régularisation en appelant _gmp_ensure_visibility pour chaque ligne
--      remontée par l'audit.
