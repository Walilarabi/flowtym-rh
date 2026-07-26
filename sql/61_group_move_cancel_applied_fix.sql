-- 61_group_move_cancel_applied_fix.sql
-- ============================================================================
-- Correction bloquante — group_move_cancel_applied (migration 59) échouait avec
--   ERROR 42803: column "staff_planning_segments.hotel_id" must appear in the
--   GROUP BY clause or be used in an aggregate function
--   at PL/pgSQL function group_move_cancel_applied line 60
--
-- Cause : le SELECT récupérant les segments d'origine mélangeait la colonne
-- hotel_id (non agrégée) et min()/max()/bool_or() (agrégats) sans GROUP BY.
--
-- Correction : GROUP BY hotel_id LIMIT 1. Métier : un salarié n'a qu'un seul
-- hôtel d'origine par jour, la contrainte d'unicité de staff_planning
-- (hotel_id, employee_id, day) le garantit.
--
-- Second point : les RAISE de la migration 59 utilisaient des libellés sans
-- accents (Acces refuse au lieu d'Accès refusé). Le regex client _fnErrorMsg
-- (avec accents) ne matchait pas → fallback affichait « Impossible d'annuler
-- cette affectation. » au lieu du vrai message métier « Vous n'avez pas les
-- droits nécessaires sur cet établissement. ». Migration corrective restaure
-- les accents.
--
-- Réécriture complète CREATE OR REPLACE (aucune donnée touchée).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.group_move_cancel_applied(
  p_id uuid,
  p_only_day date DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  r group_move_proposals;
  v_key text := coalesce(p_idempotency_key, gen_random_uuid()::text);
  v_existing group_move_cancellations;
  v_days date[];
  d date;
  v_slot jsonb;
  v_remaining_slots jsonb := '[]'::jsonb;
  v_scope text;
  v_removed int := 0;
  v_restored int := 0;
  v_deactivated int := 0;
  v_result jsonb;
  v_orig record;
  v_seg record;
BEGIN
  IF p_id IS NULL THEN RAISE EXCEPTION 'proposition requise'; END IF;

  SELECT * INTO r FROM group_move_proposals WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition introuvable'; END IF;
  IF NOT public._gmp_can_access(r.from_hotel_id, r.to_hotel_id) THEN
    RAISE EXCEPTION 'Accès refusé';
  END IF;
  IF r.status <> 'applied' THEN
    RAISE EXCEPTION 'Seule une affectation appliquée peut être annulée (statut actuel : %)', r.status;
  END IF;

  SELECT * INTO v_existing FROM group_move_cancellations WHERE idempotency_key = v_key;
  IF FOUND THEN
    IF v_existing.status = 'completed' THEN
      RETURN coalesce(v_existing.result, jsonb_build_object('idempotent', true));
    END IF;
    RAISE EXCEPTION 'Annulation déjà en cours pour cette clé';
  END IF;
  v_scope := CASE WHEN p_only_day IS NULL THEN 'full' ELSE 'day' END;
  INSERT INTO group_move_cancellations(idempotency_key, proposal_id, scope, scope_day, cancelled_by, status)
  VALUES (v_key, p_id, v_scope, p_only_day, auth.uid(), 'processing');

  IF p_only_day IS NOT NULL THEN
    v_days := ARRAY[p_only_day];
  ELSE
    SELECT array_agg(DISTINCT (s->>'date')::date ORDER BY (s->>'date')::date) INTO v_days
      FROM jsonb_array_elements(r.slots) s WHERE (s->>'date') IS NOT NULL;
  END IF;

  IF v_days IS NULL OR array_length(v_days,1) IS NULL THEN
    RAISE EXCEPTION 'Aucun jour à annuler';
  END IF;

  FOREACH d IN ARRAY v_days LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(r.employee_id::text || '|' || d::text, 0));
  END LOOP;

  PERFORM set_config('flowtym.audit_source','group_planning_cancel', true);
  PERFORM set_config('flowtym.audit_reason','Annulation d''un déplacement inter-hôtels appliqué', true);
  PERFORM set_config('flowtym.allow_move_write','on', true);

  FOREACH d IN ARRAY v_days LOOP
    -- CORRECTIF SQL 42803 : GROUP BY hotel_id + LIMIT 1 (unicité par jour
    -- garantie par staff_planning(hotel_id, employee_id, day)).
    -- Correctif SQL 42803 : GROUP BY + LIMIT 1 (unicité par jour garantie
    -- par staff_planning(hotel_id, employee_id, day)). Alias explicite s.*
    -- pour lever toute ambiguïté.
    SELECT s.hotel_id, min(s.seg_start_min) AS s, max(s.seg_end_min) AS e,
           bool_or(s.seg_start_min = 0 AND s.seg_end_min = 1440) AS anyfull
      INTO v_orig
      FROM staff_planning_segments s
     WHERE s.source_proposal_id = p_id AND s.day = d AND s.kind = 'origin'
     GROUP BY s.hotel_id
     LIMIT 1;
    IF v_orig.hotel_id IS NOT NULL THEN
      -- Cas 1 : la RPC apply a mémorisé des segments d'origine (nouveau flux)
      UPDATE staff_planning
         SET status = 'P',
             shift_start = CASE WHEN v_orig.anyfull THEN NULL ELSE make_time(v_orig.s/60, v_orig.s%60, 0) END,
             shift_end   = CASE WHEN v_orig.anyfull THEN NULL ELSE make_time(least(v_orig.e,1439)/60, v_orig.e%60, 0) END,
             updated_by  = auth.uid(),
             updated_at  = now(),
             source_proposal_id = NULL
       WHERE hotel_id = v_orig.hotel_id
         AND employee_id = r.employee_id
         AND day = d;
      v_restored := v_restored + 1;
    ELSE
      -- Cas 2 : aucune trace segment (proposition historique appliquée AVANT
      -- migration 57). L'origine peut être :
      --  · une ligne staff_planning status='MAD' avec source_proposal_id=p_id
      --    (le RPC apply historique la mettait en MAD sans mémoriser le shift)
      --  · absente (le déplacement n'a pas vidé de shift existant)
      -- Restauration best-effort : si une ligne MAD tracée par ce déplacement
      -- existe côté from_hotel, on la remet en 'P' shift null (journée
      -- complète par défaut). Sinon on n'écrit rien.
      UPDATE staff_planning
         SET status = 'P',
             shift_start = NULL, shift_end = NULL, shift_label = NULL,
             updated_by = auth.uid(), updated_at = now(),
             source_proposal_id = NULL
       WHERE hotel_id = r.from_hotel_id
         AND employee_id = r.employee_id
         AND day = d
         AND status = 'MAD'
         AND source_proposal_id = p_id;
      IF FOUND THEN v_restored := v_restored + 1; END IF;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM staff_planning_segments
       WHERE hotel_id = r.to_hotel_id AND employee_id = r.employee_id
         AND day = d AND kind = 'destination'
         AND source_proposal_id <> p_id
    ) THEN
      DELETE FROM staff_planning
       WHERE hotel_id = r.to_hotel_id AND employee_id = r.employee_id
         AND day = d AND source_proposal_id = p_id;
      v_removed := v_removed + 1;
    END IF;

    DELETE FROM staff_planning_segments
     WHERE source_proposal_id = p_id AND day = d;
  END LOOP;

  -- Correctif 42702 : alias renommé (dd) pour éviter la collision avec la
  -- variable PL/pgSQL d.
  FOR v_seg IN
    SELECT DISTINCT extract(year FROM t.dd)::int AS y, extract(month FROM t.dd)::int AS m
      FROM unnest(v_days) AS t(dd)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM staff_planning sp
       WHERE sp.hotel_id = r.to_hotel_id AND sp.employee_id = r.employee_id
         AND extract(year FROM sp.day)::int = v_seg.y
         AND extract(month FROM sp.day)::int = v_seg.m
    ) THEN
      UPDATE employee_extra_activations
         SET active = false,
             comment = 'Désactivation automatique — annulation Planning Groupe (' || p_id::text || ')',
             updated_at = now()
       WHERE employee_id = r.employee_id
         AND hotel_id = r.to_hotel_id
         AND year = v_seg.y
         AND month = v_seg.m
         AND active = true;
      IF FOUND THEN
        v_deactivated := v_deactivated + 1;
        INSERT INTO employee_extra_activation_history (
          employee_id, hotel_id, year, month, host_service_id, host_role,
          active, comment, action, actor_id, actor_name
        )
        SELECT r.employee_id, r.to_hotel_id, v_seg.y, v_seg.m, ea.host_service_id, ea.host_role,
               false, 'Annulation Planning Groupe (' || p_id::text || ')',
               'deactivate', u.id, coalesce(u.full_name, u.email)
        FROM employee_extra_activations ea
        LEFT JOIN users u ON u.auth_id = auth.uid()
        WHERE ea.employee_id = r.employee_id AND ea.hotel_id = r.to_hotel_id
          AND ea.year = v_seg.y AND ea.month = v_seg.m
        LIMIT 1;
      END IF;
    END IF;
  END LOOP;

  IF v_scope = 'full' THEN
    UPDATE group_move_proposals
       SET status = 'cancelled', updated_at = now()
     WHERE id = p_id;
  ELSE
    FOR v_slot IN SELECT * FROM jsonb_array_elements(r.slots)
    LOOP
      IF (v_slot->>'date')::date <> p_only_day THEN
        v_remaining_slots := v_remaining_slots || v_slot;
      END IF;
    END LOOP;
    IF jsonb_array_length(v_remaining_slots) = 0 THEN
      UPDATE group_move_proposals SET status = 'cancelled', updated_at = now() WHERE id = p_id;
    ELSE
      UPDATE group_move_proposals
         SET slots = v_remaining_slots,
             period_from = (SELECT min((s->>'date')::date) FROM jsonb_array_elements(v_remaining_slots) s),
             period_to   = (SELECT max((s->>'date')::date) FROM jsonb_array_elements(v_remaining_slots) s),
             updated_at = now()
       WHERE id = p_id;
    END IF;
  END IF;

  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (p_id, auth.uid(),
          CASE WHEN v_scope='full' THEN 'cancelled_after_apply' ELSE 'cancelled_segment' END,
          'applied', 'cancelled',
          jsonb_build_object('scope', v_scope, 'day', p_only_day,
                             'days', array_to_json(v_days), 'removed', v_removed,
                             'restored', v_restored, 'deactivated', v_deactivated,
                             'idempotency_key', v_key));

  v_result := jsonb_build_object(
    'cancelled', true, 'proposal_id', p_id, 'scope', v_scope,
    'day', p_only_day, 'days', array_to_json(v_days),
    'removed', v_removed, 'restored', v_restored, 'deactivated', v_deactivated
  );
  UPDATE group_move_cancellations SET status='completed', result=v_result WHERE idempotency_key=v_key;
  RETURN v_result;
END $function$;
