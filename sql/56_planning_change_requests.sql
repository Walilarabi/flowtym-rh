-- ============================================================================
-- 56_planning_change_requests.sql — Demandes de modification de statut pour les
-- journées PASSÉES (rôle Réception). Circuit d'approbation par la hiérarchie
-- métier existante (employees.manager_id) avec fallback Directeur, sans nouveau
-- rôle ni nouvelle enum. Réutilise rh_my_role() et is_platform_admin().
--
-- NON appliqué en production. Idempotent lorsque raisonnable. Testé sur cluster
-- local jetable. Ne modifie PAS le moteur d'heures ni hours.source.
-- ============================================================================

-- ── Table des demandes ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.planning_change_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id      uuid NOT NULL REFERENCES public.hotels(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  day           date NOT NULL,
  current_status  text NOT NULL,            -- statut figé au moment de la demande
  requested_status text NOT NULL,
  reason        text NOT NULL,              -- motif obligatoire
  comment       text,
  requested_by  uuid,                       -- auth.uid() du demandeur
  assigned_to   text NOT NULL CHECK (assigned_to IN ('manager','director')),
  assigned_manager_id uuid REFERENCES public.employees(id),  -- figé (snapshot)
  status        text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','approved','rejected','cancelled','obsolete')),
  decided_by    uuid,
  decided_at    timestamptz,
  reject_reason text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
-- Une seule demande ACTIVE (pending) par collaborateur et par date.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pcr_pending
  ON public.planning_change_requests (hotel_id, employee_id, day) WHERE status='pending';
CREATE INDEX IF NOT EXISTS idx_pcr_hotel_status ON public.planning_change_requests (hotel_id, status);
CREATE INDEX IF NOT EXISTS idx_pcr_requester     ON public.planning_change_requests (requested_by);

-- ── Notifications (trace + badge ; recipients par périmètre) ─────────────────
CREATE TABLE IF NOT EXISTS public.planning_change_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.planning_change_requests(id) ON DELETE CASCADE,
  hotel_id   uuid NOT NULL,
  recipient_scope text NOT NULL,   -- 'manager' | 'director' | 'requester'
  event      text NOT NULL,        -- 'created'|'approved'|'rejected'|'cancelled'|'obsolete'
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at    timestamptz
);

-- ── Helpers ──────────────────────────────────────────────────────────────────
-- « Aujourd'hui » selon le fuseau horaire de l'HÔTEL (pas l'UTC navigateur).
CREATE OR REPLACE FUNCTION public._pcr_today(p_hotel uuid)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT timezone FROM hotels WHERE id=p_hotel),'Europe/Paris'))::date;
$$;

-- Compte utilisateur UNIQUE, ACTIF, correspondant à l'e-mail normalisé du manager
-- et présent dans le périmètre de l'hôtel. Retourne users.id, ou NULL (=> fallback).
CREATE OR REPLACE FUNCTION public._pcr_manager_account(p_manager_emp uuid, p_hotel uuid)
 RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_email text; v_cnt int; v_uid uuid;
BEGIN
  SELECT lower(trim(email)) INTO v_email FROM employees WHERE id = p_manager_emp;
  IF v_email IS NULL OR v_email = '' THEN RETURN NULL; END IF;          -- e-mail absent
  -- correspondance GLOBALE unique (ambiguïté => fallback)
  SELECT count(*) INTO v_cnt FROM users u WHERE u.is_active = true AND lower(trim(u.email)) = v_email;
  IF v_cnt <> 1 THEN RETURN NULL; END IF;                              -- 0 ou >1 => fallback
  SELECT u.id INTO v_uid FROM users u WHERE u.is_active = true AND lower(trim(u.email)) = v_email;
  -- le compte unique doit appartenir au périmètre de l'hôtel
  IF NOT EXISTS (SELECT 1 FROM user_hotels uh WHERE uh.user_id = v_uid AND uh.hotel_id = p_hotel) THEN
    RETURN NULL;                                                       -- hors périmètre => fallback
  END IF;
  RETURN v_uid;
END $$;

-- ── Garde backend : Réception ne peut PAS écrire une journée passée ──────────
CREATE OR REPLACE FUNCTION public.trg_pcr_reception_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_hotel uuid; v_day date;
BEGIN
  IF auth.uid() IS NULL THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
  v_hotel := CASE WHEN TG_OP='DELETE' THEN OLD.hotel_id ELSE NEW.hotel_id END;
  v_day   := CASE WHEN TG_OP='DELETE' THEN OLD.day      ELSE NEW.day      END;
  -- Ne bloque QUE le rôle Réception sur l'hôtel concerné, pour une journée < aujourd'hui (fuseau hôtel).
  IF public.rh_my_role(v_hotel) = 'reception' AND v_day < public._pcr_today(v_hotel) THEN
    RAISE EXCEPTION 'Réception : modification directe interdite sur une journée passée (%). Utilisez « Demander une modification ».', v_day
      USING ERRCODE = 'FL010';
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS trg_pcr_reception_guard ON public.staff_planning;
CREATE TRIGGER trg_pcr_reception_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.staff_planning
  FOR EACH ROW EXECUTE FUNCTION public.trg_pcr_reception_guard();

-- ── RPC : création d'une demande (journée passée) ────────────────────────────
CREATE OR REPLACE FUNCTION public.planning_change_request_create(
  p_hotel uuid, p_employee uuid, p_day date, p_requested_status text, p_reason text, p_comment text DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_cur text; v_mgr_emp uuid; v_assigned text := 'director'; v_assigned_mgr uuid := NULL; v_id uuid;
BEGIN
  IF p_hotel NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'Accès refusé à cet établissement'; END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'Le motif est obligatoire'; END IF;
  IF p_day >= public._pcr_today(p_hotel) THEN
    RAISE EXCEPTION 'Une demande ne concerne que les journées passées (modifiez directement le jour même ou futur)';
  END IF;
  SELECT status INTO v_cur FROM staff_planning WHERE hotel_id=p_hotel AND employee_id=p_employee AND day=p_day;
  v_cur := coalesce(v_cur, '∅');   -- pas de ligne => statut vide figé
  -- Routage figé : manager hiérarchique si compte unique/actif/in-scope, sinon Directeur.
  SELECT manager_id INTO v_mgr_emp FROM employees WHERE id=p_employee;
  IF v_mgr_emp IS NOT NULL AND public._pcr_manager_account(v_mgr_emp, p_hotel) IS NOT NULL THEN
    v_assigned := 'manager'; v_assigned_mgr := v_mgr_emp;
  END IF;
  BEGIN
    INSERT INTO planning_change_requests(hotel_id, employee_id, day, current_status, requested_status,
       reason, comment, requested_by, assigned_to, assigned_manager_id, status)
    VALUES (p_hotel, p_employee, p_day, v_cur, p_requested_status, p_reason, nullif(trim(p_comment),''),
       auth.uid(), v_assigned, v_assigned_mgr, 'pending')
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Une demande est déjà en attente pour ce collaborateur à cette date' USING ERRCODE='FL011';
  END;
  INSERT INTO planning_change_notifications(request_id, hotel_id, recipient_scope, event)
  VALUES (v_id, p_hotel, v_assigned, 'created');
  RETURN v_id;
END $$;

-- ── RPC : décision (approuver / refuser) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.planning_change_request_decide(
  p_id uuid, p_decision text, p_reject_reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r planning_change_requests; v_cur text; v_uid uuid;
        v_is_dir boolean; v_is_admin boolean; v_is_mgr boolean;
BEGIN
  SELECT * INTO r FROM planning_change_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'Demande déjà traitée (%).', r.status; END IF;
  -- Cloisonnement : l'hôtel de la demande doit être dans le périmètre de l'utilisateur.
  IF r.hotel_id NOT IN (SELECT public.pl_my_hotels()) THEN RAISE EXCEPTION 'Accès refusé (autre établissement)'; END IF;
  -- Le demandeur ne peut jamais décider de sa propre demande.
  IF auth.uid() = r.requested_by THEN RAISE EXCEPTION 'Le demandeur ne peut pas décider de sa propre demande'; END IF;
  -- Autorisations (jamais uniquement via une donnée frontend) :
  v_is_admin := public.is_platform_admin();
  v_is_dir   := (public.rh_my_role(r.hotel_id) = 'direction');       -- Directeur : toujours autorisé
  SELECT id INTO v_uid FROM users WHERE auth_id = auth.uid() AND is_active = true LIMIT 1;
  v_is_mgr   := (r.assigned_to='manager' AND r.assigned_manager_id IS NOT NULL
                 AND v_uid IS NOT NULL AND public._pcr_manager_account(r.assigned_manager_id, r.hotel_id) = v_uid);
  IF NOT (v_is_admin OR v_is_dir OR v_is_mgr) THEN RAISE EXCEPTION 'Non autorisé à traiter cette demande'; END IF;

  IF p_decision = 'approve' THEN
    -- Contrôle d'obsolescence : ne jamais écraser une valeur plus récente.
    SELECT status INTO v_cur FROM staff_planning WHERE hotel_id=r.hotel_id AND employee_id=r.employee_id AND day=r.day;
    v_cur := coalesce(v_cur, '∅');
    IF v_cur IS DISTINCT FROM r.current_status THEN
      -- Ne jamais écraser une valeur plus récente : on CLASSE la demande obsolète
      -- (persisté, sans lever d'exception qui annulerait ce marquage) et on N'APPLIQUE PAS.
      UPDATE planning_change_requests SET status='obsolete', decided_by=auth.uid(), decided_at=now(), updated_at=now() WHERE id=r.id;
      INSERT INTO planning_change_notifications(request_id, hotel_id, recipient_scope, event) VALUES (r.id, r.hotel_id, 'requester', 'obsolete');
      RETURN jsonb_build_object('status','obsolete','applied',false,'reason','statut modifié depuis la demande','from',r.current_status,'now',v_cur);
    END IF;
    -- Application atomique (audit via trigger planning_audit).
    PERFORM set_config('flowtym.audit_source','planning_change_request', true);
    PERFORM set_config('flowtym.audit_reason', coalesce(r.reason,'Modification validée'), true);
    UPDATE staff_planning SET status=r.requested_status, updated_by=auth.uid(), updated_at=now()
      WHERE hotel_id=r.hotel_id AND employee_id=r.employee_id AND day=r.day;
    IF NOT FOUND THEN
      INSERT INTO staff_planning(hotel_id, employee_id, day, status, duration, break_minutes, updated_by)
      VALUES (r.hotel_id, r.employee_id, r.day, r.requested_status, 1, 0, auth.uid());
    END IF;
    UPDATE planning_change_requests SET status='approved', decided_by=auth.uid(), decided_at=now(), updated_at=now() WHERE id=r.id;
    INSERT INTO planning_change_notifications(request_id, hotel_id, recipient_scope, event) VALUES (r.id, r.hotel_id, 'requester', 'approved');
    RETURN jsonb_build_object('status','approved','applied',true,'day',r.day,'new_status',r.requested_status);

  ELSIF p_decision = 'reject' THEN
    UPDATE planning_change_requests SET status='rejected', decided_by=auth.uid(), decided_at=now(),
      reject_reason=nullif(trim(p_reject_reason),''), updated_at=now() WHERE id=r.id;
    INSERT INTO planning_change_notifications(request_id, hotel_id, recipient_scope, event) VALUES (r.id, r.hotel_id, 'requester', 'rejected');
    RETURN jsonb_build_object('status','rejected','applied',false);
  ELSE
    RAISE EXCEPTION 'Décision invalide (approve|reject attendu)';
  END IF;
END $$;

-- ── RPC : annulation par le demandeur (uniquement si pending) ─────────────────
CREATE OR REPLACE FUNCTION public.planning_change_request_cancel(p_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r planning_change_requests;
BEGIN
  SELECT * INTO r FROM planning_change_requests WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'Seule une demande en attente peut être annulée'; END IF;
  IF auth.uid() <> r.requested_by THEN RAISE EXCEPTION 'Seul le demandeur peut annuler sa demande'; END IF;
  UPDATE planning_change_requests SET status='cancelled', updated_at=now() WHERE id=r.id;
  INSERT INTO planning_change_notifications(request_id, hotel_id, recipient_scope, event) VALUES (r.id, r.hotel_id, r.assigned_to, 'cancelled');
END $$;

-- ── RLS : cloisonnement par hotel_id + visibilité ciblée ─────────────────────
ALTER TABLE public.planning_change_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pcr_select ON public.planning_change_requests;
CREATE POLICY pcr_select ON public.planning_change_requests FOR SELECT TO authenticated
USING (
  hotel_id IN (SELECT public.pl_my_hotels()) AND (
    requested_by = auth.uid()
    OR public.rh_my_role(hotel_id) = 'direction'
    OR public.is_platform_admin()
    OR (assigned_to='manager' AND assigned_manager_id IS NOT NULL
        AND public._pcr_manager_account(assigned_manager_id, hotel_id) =
            (SELECT id FROM users WHERE auth_id=auth.uid() AND is_active=true LIMIT 1))
  )
);
-- Insertion directe restreinte (le chemin normal est le RPC SECURITY DEFINER).
DROP POLICY IF EXISTS pcr_insert ON public.planning_change_requests;
CREATE POLICY pcr_insert ON public.planning_change_requests FOR INSERT TO authenticated
WITH CHECK (hotel_id IN (SELECT public.pl_my_hotels()) AND requested_by = auth.uid());
-- Pas de policy UPDATE/DELETE pour authenticated : transitions via RPC uniquement,
-- historique non supprimable depuis l'interface standard.

ALTER TABLE public.planning_change_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pcrn_select ON public.planning_change_notifications;
CREATE POLICY pcrn_select ON public.planning_change_notifications FOR SELECT TO authenticated
USING (hotel_id IN (SELECT public.pl_my_hotels()));

-- ── GRANTs (conditionnels : rôle authenticated absent d'un cluster nu) ───────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    GRANT SELECT ON public.planning_change_requests TO authenticated;
    GRANT SELECT ON public.planning_change_notifications TO authenticated;
    GRANT EXECUTE ON FUNCTION public.planning_change_request_create(uuid,uuid,date,text,text,text) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.planning_change_request_decide(uuid,text,text) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.planning_change_request_cancel(uuid) TO authenticated;
  END IF;
END $$;
