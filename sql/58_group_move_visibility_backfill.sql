-- 58_group_move_visibility_backfill.sql
-- ============================================================================
-- Régularisation des propositions déjà appliquées (status='applied') qui
-- n'ont PAS de visibilité extra complète (audit remonté par
-- group_move_visibility_audit()).
--
-- ⚠  À N'APPLIQUER QU'APRÈS validation manuelle de la liste :
--    SELECT * FROM group_move_visibility_audit();
--
-- Idempotente : peut être rejouée sans effet supplémentaire, car
-- _gmp_ensure_visibility s'appuie exclusivement sur des upserts
-- (ON CONFLICT). Un salarié déjà autorisé et déjà activé reste inchangé.
--
-- Sécurité : chaque proposition est traitée dans sa propre transaction
-- interne (bloc BEGIN/EXCEPTION). Une proposition qui échoue (ex. service
-- introuvable dans staff_departments de la destination) est enregistrée
-- dans un rapport de sortie mais n'interrompt pas la régularisation des
-- autres.
--
-- Rapport : la fonction retourne un jsonb récapitulatif
--   { total, regularized, skipped, failures: [{proposal_id, reason}] }.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.group_move_visibility_backfill(p_dry_run boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_days date[];
  v_total int := 0;
  v_ok int := 0;
  v_failed int := 0;
  v_failures jsonb := '[]'::jsonb;
BEGIN
  FOR r IN SELECT * FROM group_move_visibility_audit() LOOP
    v_total := v_total + 1;
    IF p_dry_run THEN
      CONTINUE;
    END IF;
    BEGIN
      -- Reconstruit v_days à partir des slots de la proposition (les slots
      -- restent stockés dans la table).
      SELECT array_agg(DISTINCT (s->>'date')::date ORDER BY (s->>'date')::date)
        INTO v_days
        FROM group_move_proposals p, jsonb_array_elements(p.slots) s
       WHERE p.id = r.proposal_id AND (s->>'date') IS NOT NULL;
      IF v_days IS NULL OR array_length(v_days,1) IS NULL THEN
        v_failed := v_failed + 1;
        v_failures := v_failures || jsonb_build_object('proposal_id', r.proposal_id, 'reason', 'aucun slot exploitable');
        CONTINUE;
      END IF;
      PERFORM public._gmp_ensure_visibility(
        r.employee_id, r.from_hotel_id, r.to_hotel_id, r.to_service, v_days,
        'backfill:' || r.proposal_id::text
      );
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      v_failures := v_failures || jsonb_build_object('proposal_id', r.proposal_id, 'reason', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'total_pending', v_total,
    'regularized', v_ok,
    'failures', v_failed,
    'details', v_failures
  );
END $function$;

COMMENT ON FUNCTION public.group_move_visibility_backfill(boolean) IS
  'Régularise les propositions appliquées sans visibilité extra. p_dry_run=true '
  '(défaut) ne fait qu''énumérer. p_dry_run=false applique. Idempotente. '
  'À exécuter APRÈS validation manuelle de group_move_visibility_audit().';

-- Utilisation :
--   SELECT group_move_visibility_backfill(true);   -- énumération à blanc
--   -- validation manuelle par un humain
--   SELECT group_move_visibility_backfill(false);  -- application effective
