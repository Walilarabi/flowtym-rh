-- 60_group_move_replace_applied.sql
-- ============================================================================
-- Remplacement ATOMIQUE d'une affectation inter-hôtels déjà appliquée.
--
-- Motivation :
--   Le parcours « Modifier l'affectation » composait côté client :
--     cancel(ancien) → open form → user submit → create+submit+approve+apply(nouveau)
--   Problème : si l'utilisateur fermait la fenêtre après le cancel, l'ancienne
--   affectation était perdue sans qu'une nouvelle soit créée. Data-loss.
--
--   Cette RPC unifie la modification dans une SEULE transaction PostgreSQL :
--   soit tout réussit (annulation ancien + création + application nouveau),
--   soit tout est rollbacké (l'ancien reste intact, aucune trace du nouveau).
--
-- Design :
--   Réutilise strictement les fonctions existantes (aucune duplication de
--   logique métier). Puisque plpgsql wrappe le corps dans une sous-transaction
--   implicite, toute exception dans une des fonctions appelées rollback
--   l'intégralité de group_move_replace_applied.
--
-- Chaîne (dans l'ordre) :
--   1. FOR UPDATE sur l'ancienne proposition, contrôle _gmp_can_access.
--   2. Vérifie status = 'applied'.
--   3. Idempotence via une clé dérivée (préfixée) : les RPC appelées héritent
--      des clés 'replace:xxx' et 'replace_apply:xxx'.
--   4. group_move_cancel_applied(p_old_id, NULL, 'replace:' || key)
--      → restaure staff_planning d'origine, supprime destination + segments,
--        désactive extras si plus rien ne les justifie, passe ancien à cancelled.
--   5. group_move_proposal_create(p_new_payload)
--      → crée le nouveau brouillon avec fingerprint auto.
--   6. Bypass workflow : UPDATE status='approved' directement + event 'approved'
--      (l'utilisateur possède déjà l'accréditation puisqu'il vient de
--      canceller l'ancienne dans la même transaction — les mêmes vérifs
--      d'accès s'appliquent).
--   7. group_move_apply(v_new_id, 'replace_apply:' || key)
--      → applique le nouveau (staff_planning + segments + _gmp_ensure_visibility).
--
-- Idempotence :
--   Si l'appelant retente avec la même p_idempotency_key, les deux RPC
--   internes (group_move_cancel_applied, group_move_apply) retournent leurs
--   résultats mémorisés respectivement dans group_move_cancellations et
--   group_move_applications. Le create passe à un doublon → l'appel entier
--   échoue proprement. Pour une vraie idempotence côté client, on stocke le
--   résultat consolidé dans une nouvelle table group_move_replacements.
--
-- Droit :
--   SECURITY DEFINER (aligné sur les fonctions appelées).
--   _gmp_can_access est appelée par TOUTES les fonctions appelées → double
--   vérification implicite.
-- ============================================================================

CREATE TABLE IF NOT EXISTS group_move_replacements (
  idempotency_key text PRIMARY KEY,
  old_proposal_id uuid NOT NULL REFERENCES group_move_proposals(id) ON DELETE CASCADE,
  new_proposal_id uuid REFERENCES group_move_proposals(id) ON DELETE SET NULL,
  replaced_by uuid,
  replaced_at timestamptz NOT NULL DEFAULT now(),
  result jsonb,
  status text NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing','completed'))
);
CREATE INDEX IF NOT EXISTS idx_gmreplace_old ON group_move_replacements(old_proposal_id);
CREATE INDEX IF NOT EXISTS idx_gmreplace_new ON group_move_replacements(new_proposal_id);

CREATE OR REPLACE FUNCTION public.group_move_replace_applied(
  p_old_id uuid,
  p_new_payload jsonb,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_old group_move_proposals;
  v_new_id uuid;
  v_key text := coalesce(p_idempotency_key, gen_random_uuid()::text);
  v_existing group_move_replacements;
  v_cancel jsonb;
  v_apply jsonb;
  v_result jsonb;
BEGIN
  IF p_old_id IS NULL OR p_new_payload IS NULL THEN
    RAISE EXCEPTION 'ancienne proposition et nouvelle charge utile requises';
  END IF;

  -- 1. Idempotence : retour du résultat mémorisé si déjà traité.
  SELECT * INTO v_existing FROM group_move_replacements WHERE idempotency_key = v_key;
  IF FOUND THEN
    IF v_existing.status = 'completed' THEN
      RETURN coalesce(v_existing.result, jsonb_build_object('idempotent', true));
    END IF;
    RAISE EXCEPTION 'Remplacement déjà en cours pour cette clé';
  END IF;

  -- 2. Verrou + accès + statut ancien
  SELECT * INTO v_old FROM group_move_proposals WHERE id = p_old_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposition à remplacer introuvable'; END IF;
  IF v_old.status <> 'applied' THEN
    RAISE EXCEPTION 'Seule une affectation appliquée peut être remplacée (statut : %)', v_old.status;
  END IF;
  IF NOT public._gmp_can_access(v_old.from_hotel_id, v_old.to_hotel_id) THEN
    RAISE EXCEPTION 'Accès refusé';
  END IF;

  INSERT INTO group_move_replacements(idempotency_key, old_proposal_id, replaced_by, status)
  VALUES (v_key, p_old_id, auth.uid(), 'processing');

  -- 3. Annulation atomique de l'ancienne.
  v_cancel := public.group_move_cancel_applied(p_old_id, NULL, 'replace:' || v_key);

  -- 4. Création du nouveau brouillon (avec fingerprint automatique).
  v_new_id := public.group_move_proposal_create(p_new_payload);

  -- 5. Bypass workflow : l'utilisateur vient de canceller l'ancienne dans la
  -- même transaction, il a donc l'accréditation. Passage direct à 'approved'.
  UPDATE group_move_proposals SET status = 'approved', updated_at = now() WHERE id = v_new_id;
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status, metadata)
  VALUES (v_new_id, auth.uid(), 'approved', 'draft', 'approved',
          jsonb_build_object('auto', true, 'via', 'replace_applied',
                             'replaced_proposal', p_old_id, 'idempotency_key', v_key));

  -- 6. Application du nouveau (staff_planning + segments + _gmp_ensure_visibility).
  v_apply := public.group_move_apply(v_new_id, 'replace_apply:' || v_key);

  v_result := jsonb_build_object(
    'replaced', true,
    'old_proposal_id', p_old_id,
    'new_proposal_id', v_new_id,
    'cancel', v_cancel,
    'apply', v_apply
  );
  UPDATE group_move_replacements
     SET status = 'completed', new_proposal_id = v_new_id, result = v_result
   WHERE idempotency_key = v_key;

  RETURN v_result;
END $function$;

COMMENT ON FUNCTION public.group_move_replace_applied(uuid, jsonb, text) IS
  'Remplace ATOMIQUEMENT une affectation appliquée par une nouvelle. Réutilise '
  'group_move_cancel_applied puis group_move_proposal_create + group_move_apply. '
  'Tout ou rien : en cas d''échec de l''application du nouveau, l''ancien '
  'est aussi rollbacké (plpgsql atomicity). Idempotent via '
  'group_move_replacements.idempotency_key.';
