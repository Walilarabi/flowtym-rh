-- sql/97_security_group_planning_isolation.sql
-- P0 SECURITY — fuite d'isolation inter-groupes dans le Planning Groupe.
--
-- Incident : un utilisateur d'un groupe hôtelier (ex. Boudaa Hotels) pouvait accéder à des
-- données d'un AUTRE groupe (ex. Redouane Hotels) via trois surfaces distinctes, toutes dans le
-- module "déplacements inter-hôtels" (group_move_*) :
--
--  1. group_move_timeline(p_id) vérifiait seulement que la proposition existait quelque part
--     (`WHERE p_id IN (SELECT id FROM group_move_proposals)`), jamais que ses hôtels
--     appartenaient à l'appelant — contrairement à TOUTES les fonctions sœurs du module
--     (group_move_proposals_list, group_move_reservations, group_move_open_for_employee,
--     group_move_apply, group_move_cancel_applied, group_move_replace_applied,
--     group_move_approval_decide, ... — toutes appellent _gmp_guard()/_gmp_can_access() en
--     premier). Un utilisateur authentifié connaissant (ou énumérant) l'UUID d'une proposition
--     d'un autre groupe recevait son historique complet (événements, approbations,
--     notifications) via ce seul appel RPC.
--  2. group_move_cancellations et group_move_replacements avaient RLS totalement DÉSACTIVÉE,
--     avec des GRANT complets (SELECT/INSERT/UPDATE/DELETE/TRUNCATE) à `anon` ET
--     `authenticated` — les deux seules tables de tout le schéma public dans ce cas. N'importe
--     quelle requête PostgREST anonyme (clé publique anon, sans authentification) pouvait lire
--     l'intégralité de ces deux tables, tous groupes confondus.
--  3. v_staff_day_flags était une vue sans `security_invoker` sur staff_planning_segments : elle
--     s'exécutait avec les privilèges du propriétaire de la vue et contournait donc entièrement
--     la policy RLS de la table sous-jacente (sps_manager), exposant employee_id/statuts
--     multi-hôtels de n'importe quel groupe à `anon`/`authenticated`.
--
-- Aucune des trois racines n'est un défaut de conception du modèle hôtel_groups/RLS lui-même :
-- get_user_hotel_id(), pl_my_hotels(), org_get(), hotel_group_get(), group_planning(),
-- group_staff_directory(), les policies de group_move_proposals et de ses autres tables filles
-- (group_move_applications, group_move_approvals, group_move_notifications,
-- group_move_proposal_events, group_move_proposal_waivers) étaient déjà correctement scopées —
-- confirmé par audit de code + preuve automatisée (sql/tests/tenant_isolation_group_planning.sql).
--
-- Correctifs, tous additifs/least-privilege, aucune donnée modifiée :

BEGIN;

-- 1. group_move_timeline : ajoute le même filtre d'appartenance hôtel que toutes les fonctions
--    sœurs (from_hotel_id ET to_hotel_id dans pl_my_hotels()). Conserve le contrat existant
--    (retourne NULL si absent/non autorisé, jamais d'exception) puisque le frontend
--    (BE.gmpTimeline) traite déjà ce cas silencieusement.
CREATE OR REPLACE FUNCTION public.group_move_timeline(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('action',action,'old_status',old_status,'new_status',new_status,'comment',comment,'metadata',metadata,'at',created_at) ORDER BY created_at),'[]'::jsonb)
               FROM group_move_proposal_events WHERE proposal_id=p_id),
    'approvals', (SELECT coalesce(jsonb_agg(jsonb_build_object('step',step_index,'key',step_key,'approver_type',approver_type,'status',status,'decided_at',decided_at,'comment',comment) ORDER BY step_index),'[]'::jsonb)
                 FROM group_move_approvals WHERE proposal_id=p_id),
    'notifications', (SELECT coalesce(jsonb_agg(jsonb_build_object('event',event,'recipient',recipient_type,'sent_at',sent_at,'at',created_at) ORDER BY created_at),'[]'::jsonb)
                     FROM group_move_notifications WHERE proposal_id=p_id)
  )
  WHERE p_id IN (
    SELECT id FROM group_move_proposals
    WHERE from_hotel_id IN (SELECT public.pl_my_hotels())
      AND to_hotel_id IN (SELECT public.pl_my_hotels())
  );
$function$;

-- 2. group_move_cancellations / group_move_replacements : active RLS (absente), ajoute la même
--    policy de lecture que toutes les autres tables filles de group_move_proposals (déléguer à
--    la RLS de group_move_proposals elle-même via IN, motif déjà utilisé par gmapp_access/
--    gma_access/gmn_access/gmpe_access/gmpw_access), et retire les GRANT d'écriture qu'aucune de
--    ces tables n'a jamais eu besoin d'exposer à PostgREST (seules group_move_cancel_applied /
--    group_move_replace_applied y écrivent, en SECURITY DEFINER — indépendant des GRANT de rôle).
ALTER TABLE public.group_move_cancellations ENABLE ROW LEVEL SECURITY;
CREATE POLICY gmc_access ON public.group_move_cancellations
  FOR SELECT
  USING (proposal_id IN (SELECT id FROM public.group_move_proposals));
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.group_move_cancellations FROM anon, authenticated;

ALTER TABLE public.group_move_replacements ENABLE ROW LEVEL SECURITY;
CREATE POLICY gmr_access ON public.group_move_replacements
  FOR SELECT
  USING (
    old_proposal_id IN (SELECT id FROM public.group_move_proposals)
    OR new_proposal_id IN (SELECT id FROM public.group_move_proposals)
  );
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.group_move_replacements FROM anon, authenticated;

-- 3. v_staff_day_flags : force le mode security_invoker pour que la vue applique la RLS de
--    staff_planning_segments (sps_manager) plutôt que de s'exécuter avec les privilèges de son
--    propriétaire.
ALTER VIEW public.v_staff_day_flags SET (security_invoker = true);

COMMIT;
