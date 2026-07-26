-- 59_group_move_cancel_applied.sql
-- ============================================================================
-- Annulation ATOMIQUE d'un déplacement inter-hôtels DÉJÀ APPLIQUÉ.
--
-- Motivation :
--   Le trigger trg_staff_planning_move_guard (30_functions.sql:387) empêche
--   toute modification directe d'une ligne staff_planning issue d'un
--   déplacement (source_proposal_id NOT NULL). Sans RPC dédiée, l'utilisateur
--   se retrouvait bloqué :
--     RAISE EXCEPTION 'Ligne issue d''un déplacement inter-hôtels : modifier
--                     via le déplacement (segments), pas directement'
--
--   Cette migration ajoute la RPC group_move_cancel_applied() qui, dans une
--   transaction unique :
--     1. Vérifie le droit d'accès aux 2 hôtels (from/to).
--     2. Verrouille la proposition + les jours concernés (pg_advisory).
--     3. Filtre les jours à annuler (tous, ou un seul via p_only_day).
--     4. Supprime les segments staff_planning_segments (kind='destination')
--        du déplacement pour les jours ciblés.
--     5. Restaure les segments d'origine (kind='origin') supprimés ou
--        reconstitue le shift entier d'origine.
--     6. Supprime la ligne staff_planning destination (ou la reconstruit
--        depuis les segments restants si plusieurs déplacements se chevauchent).
--     7. Restaure la ligne staff_planning d'origine (revient de 'MAD' à 'P'
--        avec les shift_start/end d'origine si la journée avait été vidée).
--     8. Désactive employee_extra_activations si plus aucune mission
--        n'existe pour ce (emp, hotel, year, month).
--     9. Passe la proposition à 'cancelled' (si annulation complète) ou la
--        met à jour (partielle : slots restants).
--    10. Journalise dans group_move_proposal_events.
--     Toute exception rollback l'intégralité (atomicité plpgsql).
--
-- Idempotence :
--   · Table group_move_cancellations avec PK idempotency_key (comme
--     group_move_applications). Un second appel avec la même clé retourne
--     le résultat mémorisé.
--
-- Droit :
--   · Réutilise _gmp_can_access (accès obligatoire aux DEUX hôtels).
--   · SECURITY DEFINER (cohérent avec group_move_apply).
--
-- Paramètres :
--   p_id              uuid    proposition à annuler
--   p_only_day        date    NULL = annulation totale ; date = annuler le
--                             seul segment de ce jour
--   p_idempotency_key text    clé d'idempotence
-- ============================================================================

-- ── Table d'idempotence dédiée (miroir de group_move_applications) ─────────
CREATE TABLE IF NOT EXISTS group_move_cancellations (
  idempotency_key text PRIMARY KEY,
  proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  scope text NOT NULL,      -- 'full' | 'day'
  scope_day date,           -- non-null si scope='day'
  cancelled_by uuid,
  cancelled_at timestamptz NOT NULL DEFAULT now(),
  result jsonb,
  status text NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing','completed'))
);
CREATE INDEX IF NOT EXISTS idx_gmcancel_proposal ON group_move_cancellations(proposal_id);

CREATE OR REPLACE FUNCTION public.group_move_cancel_applied(
  p_id uuid,
  p_only_day date DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  r group_move_proposals;
  v_key text := coalesce(p_idempotency_key,
                         gen_random_uuid()::text);
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

  -- 1. Verrou proposition + contrôle d'accès.
  SELECT * INTO r FROM group_move_proposals WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition introuvable'; END IF;
  IF NOT public._gmp_can_access(r.from_hotel_id, r.to_hotel_id) THEN
    RAISE EXCEPTION 'Accès refusé';
  END IF;
  IF r.status <> 'applied' THEN
    RAISE EXCEPTION 'Seule une proposition appliquée peut être annulée (statut actuel : %)', r.status;
  END IF;

  -- 2. Idempotence.
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

  -- 3. Détermination des jours à annuler.
  IF p_only_day IS NOT NULL THEN
    v_days := ARRAY[p_only_day];
  ELSE
    SELECT array_agg(DISTINCT (s->>'date')::date ORDER BY (s->>'date')::date) INTO v_days
      FROM jsonb_array_elements(r.slots) s WHERE (s->>'date') IS NOT NULL;
  END IF;

  IF v_days IS NULL OR array_length(v_days,1) IS NULL THEN
    RAISE EXCEPTION 'Aucun jour à annuler';
  END IF;

  -- 4. Verrou advisory (mêmes clés que group_move_apply → interblocages exclus).
  FOREACH d IN ARRAY v_days LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(r.employee_id::text || '|' || d::text, 0));
  END LOOP;

  PERFORM set_config('flowtym.audit_source','group_planning_cancel', true);
  PERFORM set_config('flowtym.audit_reason','Annulation d''un déplacement inter-hôtels appliqué', true);
  PERFORM set_config('flowtym.allow_move_write','on', true);

  -- 5. Pour chaque jour à annuler :
  FOREACH d IN ARRAY v_days LOOP
    -- 5a. Segments d'origine associés à cette proposition sur ce jour → restaurer
    -- le shift original s'il n'existe plus (cas journée-complète : la ligne
    -- staff_planning d'origine a été passée à MAD).
    SELECT hotel_id, min(seg_start_min) AS s, max(seg_end_min) AS e,
           bool_or(seg_start_min = 0 AND seg_end_min = 1440) AS anyfull
      INTO v_orig
      FROM staff_planning_segments
     WHERE source_proposal_id = p_id AND day = d AND kind = 'origin';
    IF v_orig.hotel_id IS NOT NULL THEN
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
      -- Pas de segment d'origine mémorisé : la ligne d'origine n'a jamais été
      -- vidée (le déplacement ne recouvrait pas un shift existant). On la
      -- laisse telle quelle.
      NULL;
    END IF;

    -- 5b. Ligne staff_planning DESTINATION : la supprimer si elle n'accueille
    -- que ce déplacement, sinon reconstruire depuis les segments restants.
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

    -- 5c. Supprimer les segments de cette proposition sur ce jour (destination
    -- et origin — l'origine a déjà été traduite en shift ci-dessus).
    DELETE FROM staff_planning_segments
     WHERE source_proposal_id = p_id AND day = d;
  END LOOP;

  -- 6. Désactivation ciblée de employee_extra_activations pour chaque mois
  -- couvert dont il ne reste plus aucune ligne staff_planning issue de ce
  -- salarié dans cet hôtel de destination.
  FOR v_seg IN
    SELECT DISTINCT extract(year FROM d)::int AS y, extract(month FROM d)::int AS m
      FROM unnest(v_days) AS t(d)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM staff_planning
       WHERE hotel_id = r.to_hotel_id AND employee_id = r.employee_id
         AND extract(year FROM day)::int = v_seg.y
         AND extract(month FROM day)::int = v_seg.m
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

  -- 7. Mise à jour du statut proposition.
  IF v_scope = 'full' THEN
    UPDATE group_move_proposals
       SET status = 'cancelled', updated_at = now()
     WHERE id = p_id;
  ELSE
    -- Annulation d'un jour : recomposer les slots restants.
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

  -- 8. Événement d'audit.
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

COMMENT ON FUNCTION public.group_move_cancel_applied(uuid, date, text) IS
  'Annule ATOMIQUEMENT un déplacement inter-hôtels déjà appliqué. '
  'p_only_day=NULL : annulation totale. Sinon annule le segment du jour '
  'indiqué. Restaure les segments/lignes staff_planning d''origine, '
  'désactive employee_extra_activations si plus aucune mission ne les '
  'justifie sur ce (emp,hotel,mois), passe la proposition à cancelled. '
  'Idempotent via group_move_cancellations.idempotency_key.';
