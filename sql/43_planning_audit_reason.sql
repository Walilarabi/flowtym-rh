-- 43_planning_audit_reason.sql
-- Renforce l'exploitabilité du journal d'audit du planning.
--
-- RAPPEL — déjà présents (Phase 1) :
--   * operation_id uuid  : identique pour toutes les lignes d'une même instruction
--                          (import Excel, publication, auto-remplissage, drag&drop
--                          multiple, IA, synchronisation…). Index : idx_planning_audit_op.
--   * source text        : application / portail / import / auto-remplissage / api / système.
--
-- AJOUT ici : reason (motif/contexte de l'action), FACULTATIF.
--   Renseigné automatiquement quand l'origine est connue, via le GUC
--   flowtym.audit_reason posé par l'application dans la même transaction :
--     SELECT set_config('flowtym.audit_reason','Remplacement maladie', true);
--   Reste NULL si non fourni.

ALTER TABLE public.planning_audit ADD COLUMN IF NOT EXISTS reason text;

COMMENT ON COLUMN public.planning_audit.reason IS
  'Motif/contexte de l''action (facultatif). Ex : Import Excel, Remplacement maladie, Correction manuelle, Suggestion IA, Publication, Synchronisation, Auto-remplissage, Décision RH. Posé via current_setting(''flowtym.audit_reason'').';

CREATE INDEX IF NOT EXISTS idx_planning_audit_reason ON public.planning_audit(reason) WHERE reason IS NOT NULL;

-- Trigger : lit le motif depuis le GUC (comme source / operation_id).
CREATE OR REPLACE FUNCTION public.trg_planning_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_actor uuid := auth.uid(); v_name text; v_src text; v_action text; v_hotel uuid; v_emp uuid; v_day date;
        v_old jsonb; v_new jsonb; v_op uuid; v_reason text;
BEGIN
  IF TG_OP='INSERT' THEN
    v_action:='insert'; v_hotel:=NEW.hotel_id; v_emp:=NEW.employee_id; v_day:=NEW.day;
    v_new:=jsonb_build_object('status',NEW.status,'shift_label',NEW.shift_label,'duration',NEW.duration,'hours',NEW.hours,'note',NEW.note);
  ELSIF TG_OP='UPDATE' THEN
    IF OLD.status IS NOT DISTINCT FROM NEW.status AND OLD.shift_label IS NOT DISTINCT FROM NEW.shift_label
       AND OLD.duration IS NOT DISTINCT FROM NEW.duration AND OLD.hours IS NOT DISTINCT FROM NEW.hours
       AND OLD.note IS NOT DISTINCT FROM NEW.note THEN RETURN NEW; END IF;
    v_action:='update'; v_hotel:=NEW.hotel_id; v_emp:=NEW.employee_id; v_day:=NEW.day;
    v_old:=jsonb_build_object('status',OLD.status,'shift_label',OLD.shift_label,'duration',OLD.duration,'hours',OLD.hours,'note',OLD.note);
    v_new:=jsonb_build_object('status',NEW.status,'shift_label',NEW.shift_label,'duration',NEW.duration,'hours',NEW.hours,'note',NEW.note);
  ELSE
    v_action:='delete'; v_hotel:=OLD.hotel_id; v_emp:=OLD.employee_id; v_day:=OLD.day;
    v_old:=jsonb_build_object('status',OLD.status,'shift_label',OLD.shift_label,'duration',OLD.duration,'hours',OLD.hours,'note',OLD.note);
  END IF;

  v_src := nullif(current_setting('flowtym.audit_source', true),'');
  IF v_actor IS NOT NULL THEN
    SELECT coalesce(full_name,email) INTO v_name FROM users WHERE auth_id=v_actor LIMIT 1;
    IF v_name IS NOT NULL THEN IF v_src IS NULL THEN v_src:='app'; END IF;
    ELSE
      SELECT (first_name||' '||last_name) INTO v_name FROM employees WHERE portal_auth_id=v_actor LIMIT 1;
      IF v_name IS NOT NULL AND v_src IS NULL THEN v_src:='portail'; END IF;
    END IF;
  END IF;
  IF v_src IS NULL THEN v_src:='système'; END IF;

  v_op := coalesce(nullif(current_setting('flowtym.operation_id', true),'')::uuid,
                   md5(txid_current()::text||'|'||statement_timestamp()::text)::uuid);

  v_reason := nullif(current_setting('flowtym.audit_reason', true),'');

  INSERT INTO planning_audit(hotel_id,employee_id,day,action,old_values,new_values,actor_auth_id,actor_name,source,operation_id,reason)
    VALUES(v_hotel,v_emp,v_day,v_action,v_old,v_new,v_actor,coalesce(v_name,'Système'),v_src,v_op,v_reason);
  RETURN COALESCE(NEW,OLD);
END $function$;
