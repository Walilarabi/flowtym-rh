-- ============================================================================
-- sql/tests/support_ticket_replies.sql — Lot 5 PR-06, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Inclut aussi le correctif de
-- sql/81 (policies support_tickets) et sql/82 (Lot 2), aucun des deux
-- n'étant encore appliqué en production au moment de ce lot.
-- ============================================================================
BEGIN;

\ir ../81_support_acl_hardening.sql
\ir ../82_platform_notifications.sql
\ir ../85_support_ticket_replies.sql

-- Fixtures : 2 tickets sur 2 hôtels différents (hôtels réels, comptes réels non-admin).
INSERT INTO public.support_tickets (id, hotel_id, module, feature, problem_type, description, steps, priority, status, user_email, user_role)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '7f55eb86-0fd4-4636-b8aa-ae1566ecb2c6', 'planning', 'test', 'bug', 'Ticket de test Lot 5A (hôtel A)', '[]'::jsonb, 'moyen', 'nouveau', 'reservation@grandhotelduhavre.com', 'admin_hotel'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '101be214-8b05-4f1c-8cfe-ceb9cf6a1881', 'planning', 'test', 'bug', 'Ticket de test Lot 5A (hôtel B)', '[]'::jsonb, 'moyen', 'nouveau', 'hotel@vendomeopera.com', 'admin_hotel');

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';

-- 1) Listing visible par super_admin
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.admin_list_support_tickets()
    WHERE id IN ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002');
  IF v_count <> 2 THEN RAISE EXCEPTION 'ECHEC : super_admin ne voit pas les 2 tickets fixtures (%)', v_count; END IF;
  RAISE NOTICE 'PASS admin_list_support_tickets : 2 tickets visibles.';
END $$;

-- 2) Réponses : publique + note interne + correction (même ticket), rejet cross-ticket
DO $$
DECLARE v_reply_pub uuid; v_note uuid; v_correction uuid;
BEGIN
  v_reply_pub := public.admin_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Réponse publique de test', false, NULL);
  v_note := public.admin_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Note interne de test', true, NULL);
  v_correction := public.admin_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Correction de la réponse publique', false, v_reply_pub);
  RAISE NOTICE 'PASS 3 réponses créées sur le ticket A (publique %, note %, correction %).', v_reply_pub, v_note, v_correction;

  BEGIN
    PERFORM public.admin_reply_support_ticket('bbbbbbbb-0000-0000-0000-000000000002', 'Tentative de correction cross-ticket', false, v_reply_pub);
    RAISE EXCEPTION 'ECHEC CRITIQUE : correction cross-ticket acceptée (devrait échouer)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%même ticket%' THEN RAISE NOTICE 'PASS correction cross-ticket rejetée par le trigger.';
    ELSE RAISE; END IF;
  END;
END $$;

-- 3) Masquage : motif obligatoire, effectif, réversible
DO $$
DECLARE v_reply_id uuid; v_hidden_at timestamptz;
BEGIN
  SELECT id INTO v_reply_id FROM public.support_ticket_replies WHERE ticket_id='aaaaaaaa-0000-0000-0000-000000000001' AND NOT is_internal_note ORDER BY seq LIMIT 1;

  BEGIN
    PERFORM public.admin_hide_support_ticket_reply(v_reply_id, '');
    RAISE EXCEPTION 'ECHEC CRITIQUE : masquage accepté sans motif';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'MOTIF_REQUIS%' THEN RAISE NOTICE 'PASS motif obligatoire pour masquer.'; ELSE RAISE; END IF;
  END;

  PERFORM public.admin_hide_support_ticket_reply(v_reply_id, 'Contenait une info interne par erreur');
  SELECT hidden_at INTO v_hidden_at FROM public.support_ticket_replies WHERE id = v_reply_id;
  IF v_hidden_at IS NULL THEN RAISE EXCEPTION 'ECHEC : hidden_at non renseigné après masquage'; END IF;
  RAISE NOTICE 'PASS masquage effectif (hidden_at=%).', v_hidden_at;
END $$;

-- 4) Changement de statut : notification créée une seule fois, jamais dupliquée
DO $$ BEGIN
  PERFORM public.admin_update_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'en_analyse', NULL, 'agent-test@flowtym.com');
  PERFORM public.admin_update_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'en_analyse', NULL, NULL);
END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$
DECLARE v_notif_count int; v_status text; v_assigned text;
BEGIN
  SELECT count(*) INTO v_notif_count FROM public.platform_notifications WHERE reference_type='support_ticket' AND reference_id='aaaaaaaa-0000-0000-0000-000000000001';
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'ECHEC : % notification(s) de changement de statut (attendu 1)', v_notif_count; END IF;
  SELECT status, assigned_to INTO v_status, v_assigned FROM public.support_tickets WHERE id='aaaaaaaa-0000-0000-0000-000000000001';
  IF v_status <> 'en_analyse' OR v_assigned <> 'agent-test@flowtym.com' THEN RAISE EXCEPTION 'ECHEC : statut/assignation incorrects'; END IF;
  RAISE NOTICE 'PASS 1 seule notification de statut malgré 2 appels, assignation correcte.';
END $$;

-- 5) RLS hôtel réel (users.id != auth_id, comme en production) : hôtel A voit uniquement
--    sa réponse publique non masquée (la correction), jamais la note interne ni le ticket
--    masqué, jamais rien du ticket de l'hôtel B.
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"dbd29861-b6cd-4c19-9237-59963f8f20c8"}';
DO $$
DECLARE v_visible int; v_internal_visible int; v_other_hotel_visible int;
BEGIN
  SELECT count(*) INTO v_visible FROM public.support_ticket_replies WHERE ticket_id='aaaaaaaa-0000-0000-0000-000000000001';
  IF v_visible <> 1 THEN RAISE EXCEPTION 'ECHEC : hôtel A voit % réponse(s) (attendu 1 : la correction, publique et non masquée)', v_visible; END IF;

  SELECT count(*) INTO v_internal_visible FROM public.support_ticket_replies WHERE ticket_id='aaaaaaaa-0000-0000-0000-000000000001' AND is_internal_note;
  IF v_internal_visible <> 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A voit une note interne'; END IF;

  SELECT count(*) INTO v_other_hotel_visible FROM public.support_ticket_replies WHERE ticket_id='bbbbbbbb-0000-0000-0000-000000000002';
  IF v_other_hotel_visible <> 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A voit des réponses du ticket de l''hôtel B'; END IF;

  RAISE NOTICE 'PASS RLS hôtel A (users.id != auth_id, représentatif de la production réelle) : 1 réponse visible, 0 note interne, 0 fuite inter-hôtel.';
END $$;

-- 6) Append-only : aucune modification directe possible, quel que soit le rôle authenticated
DO $$ BEGIN
  BEGIN
    UPDATE public.support_ticket_replies SET body = 'tentative de modification' WHERE ticket_id='aaaaaaaa-0000-0000-0000-000000000001';
    RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A a pu modifier une réponse (append-only violé)';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS hôtel A ne peut pas modifier (append-only, aucun grant UPDATE pour authenticated).';
  END;
END $$;

-- 7) Rôles : support_agent autorisé, billing_admin bloqué (mutation temporaire du compte
--    réel, restaurée à super_admin avant le ROLLBACK)
RESET ROLE; RESET request.jwt.claims;
UPDATE public.platform_admins SET role='support_agent' WHERE auth_id='7afa461c-71a9-4a89-bca0-9de08e405bc7';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.admin_list_support_tickets();
  RAISE NOTICE 'PASS support_agent autorisé sur admin_list_support_tickets (% ligne(s)).', v_count;
END $$;

RESET ROLE; RESET request.jwt.claims;
UPDATE public.platform_admins SET role='billing_admin' WHERE auth_id='7afa461c-71a9-4a89-bca0-9de08e405bc7';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$ BEGIN
  PERFORM public.admin_list_support_tickets();
  RAISE EXCEPTION 'ECHEC CRITIQUE : billing_admin a pu accéder au Support back-office';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS billing_admin bloqué (moindre privilège respecté).'; END $$;

RESET ROLE; RESET request.jwt.claims;
UPDATE public.platform_admins SET role='super_admin' WHERE auth_id='7afa461c-71a9-4a89-bca0-9de08e405bc7';

-- 8) anon / authenticated non-admin bloqués sur toutes les RPC et le helper interne
DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_list_support_tickets();
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu lister les tickets';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur admin_list_support_tickets.'; END $$;

DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public.admin_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'x', false, NULL);
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated non-admin a pu répondre';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS authenticated non-admin bloqué sur admin_reply_support_ticket.'; END $$;

DO $$ BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims TO '{"sub":"00000000-0000-0000-0000-000000000099"}';
  PERFORM public._is_support_staff();
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated a pu appeler directement le helper interne _is_support_staff';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS helper interne inaccessible directement (aucun grant).'; END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES support_ticket_replies PASSENT.'; END $$;
ROLLBACK;
