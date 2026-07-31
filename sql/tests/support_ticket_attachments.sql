-- ============================================================================
-- sql/tests/support_ticket_attachments.sql — Lot 5 PR-07, tests transactionnels
-- BEGIN...ROLLBACK sur production réelle. Inclut aussi les correctifs de
-- sql/81 (policies support_tickets) et sql/82/85 (Lot 2 / Lot 5A), aucun des
-- trois n'étant encore appliqué en production au moment de ce lot.
-- ============================================================================
BEGIN;

\ir ../81_support_acl_hardening.sql
\ir ../82_platform_notifications.sql
\ir ../85_support_ticket_replies.sql
\ir ../86_support_ticket_attachments.sql

-- 0) Doctrine trois états de sql/86 (remplace les CREATE TABLE IF NOT EXISTS des deux
--    tables) : le \ir ci-dessus vient de les créer (cas A). Rejouer le fichier sur des
--    tables déjà conformes doit être un no-op silencieux (cas B) — les prédicats exacts
--    des CHECK et le reste du contrat ont déjà été validés indépendamment en production
--    (BEGIN...ROLLBACK) pendant l'écriture de cette migration.
\ir ../86_support_ticket_attachments.sql
DO $$ BEGIN RAISE NOTICE 'PASS cas B (tables déjà conformes) : second \ir de sql/86 exécuté sans exception.'; END $$;

-- Fixtures : 2 tickets sur 2 hôtels réels distincts. Comptes hôtel réels et
-- exclusifs à un seul hôtel chacun (vérifié via user_hotels : la plupart des
-- comptes de ces deux hôtels de test ont accès aux deux, ce qui masquerait une
-- régression d'isolation cross-hôtel — ces deux-là sont mono-hôtel).
INSERT INTO public.support_tickets (id, hotel_id, module, feature, problem_type, description, steps, priority, status, user_email, user_role)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '7f55eb86-0fd4-4636-b8aa-ae1566ecb2c6', 'planning', 'test', 'bug', 'Ticket de test Lot 5B (hôtel A)', '[]'::jsonb, 'moyen', 'nouveau', 'reservation@grandhotelduhavre.com', 'admin_hotel'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '101be214-8b05-4f1c-8cfe-ceb9cf6a1881', 'planning', 'test', 'bug', 'Ticket de test Lot 5B (hôtel B)', '[]'::jsonb, 'moyen', 'nouveau', 'hotel@vendomeopera.com', 'admin_hotel');

-- ============================================================================
-- 1) _can_access_support_ticket — hôtel A voit son ticket, pas celui de l'hôtel B
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"dbd29861-b6cd-4c19-9237-59963f8f20c8"}';
DO $$
DECLARE v_own boolean; v_other boolean;
BEGIN
  v_own := public._can_access_support_ticket('aaaaaaaa-0000-0000-0000-000000000001');
  v_other := public._can_access_support_ticket('bbbbbbbb-0000-0000-0000-000000000002');
  IF NOT v_own THEN RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A refusé sur son propre ticket'; END IF;
  IF v_other THEN RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A autorisé sur le ticket de l''hôtel B'; END IF;
  RAISE NOTICE 'PASS _can_access_support_ticket : hôtel A = propre ticket vrai, ticket hôtel B faux.';
END $$;

-- ============================================================================
-- 2) hotel_reply_support_ticket — succès sur son propre ticket (author_type/
--    author_user_id/is_internal_note fixés côté serveur)
-- ============================================================================
DO $$
DECLARE v_reply_id uuid; v_author_type text; v_author_user_id uuid; v_internal boolean;
BEGIN
  v_reply_id := public.hotel_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Réponse hôtel A de test');
  SELECT author_type, author_user_id, is_internal_note INTO v_author_type, v_author_user_id, v_internal
    FROM public.support_ticket_replies WHERE id = v_reply_id;
  IF v_author_type <> 'hotel_user' THEN RAISE EXCEPTION 'ECHEC : author_type incorrect (%)', v_author_type; END IF;
  IF v_author_user_id <> 'dbd29861-b6cd-4c19-9237-59963f8f20c8' THEN RAISE EXCEPTION 'ECHEC : author_user_id incorrect'; END IF;
  IF v_internal THEN RAISE EXCEPTION 'ECHEC CRITIQUE : un hotel_user a pu créer une note interne'; END IF;
  RAISE NOTICE 'PASS hotel_reply_support_ticket : réponse hôtel A créée (author_type=hotel_user, is_internal_note=false).';
END $$;

-- ============================================================================
-- 3) hotel_reply_support_ticket — rejet cross-hôtel et corps vide
-- ============================================================================
DO $$ BEGIN
  PERFORM public.hotel_reply_support_ticket('bbbbbbbb-0000-0000-0000-000000000002', 'Tentative cross-hôtel');
  RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A a pu répondre au ticket de l''hôtel B';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%n''appartient pas à votre hôtel%' THEN RAISE NOTICE 'PASS rejet cross-hôtel sur hotel_reply_support_ticket.';
  ELSE RAISE; END IF;
END $$;

DO $$ BEGIN
  PERFORM public.hotel_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', '   ');
  RAISE EXCEPTION 'ECHEC CRITIQUE : réponse vide acceptée';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'REPONSE_VIDE%' THEN RAISE NOTICE 'PASS corps vide rejeté (REPONSE_VIDE).';
  ELSE RAISE; END IF;
END $$;

-- ============================================================================
-- 4) list_support_ticket_attachments — hôtel A OK sur son ticket, refusé sur
--    celui de l'hôtel B
-- ============================================================================
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');
  RAISE NOTICE 'PASS hôtel A liste ses pièces jointes (% ligne(s), 0 pour l''instant).', v_count;
END $$;

DO $$ BEGIN
  PERFORM public.list_support_ticket_attachments('bbbbbbbb-0000-0000-0000-000000000002');
  RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel A a pu lister les pièces jointes du ticket de l''hôtel B';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'Accès refusé%' THEN RAISE NOTICE 'PASS rejet cross-hôtel sur list_support_ticket_attachments.';
  ELSE RAISE; END IF;
END $$;

-- ============================================================================
-- 5) hôtel B : accès à son propre ticket, jamais à celui de l'hôtel A (symétrie)
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"1a126371-efad-4c80-b798-1c5951536882"}';
DO $$ BEGIN
  PERFORM public.hotel_reply_support_ticket('bbbbbbbb-0000-0000-0000-000000000002', 'Réponse hôtel B de test');
  RAISE NOTICE 'PASS hôtel B répond à son propre ticket.';
END $$;

DO $$ BEGIN
  PERFORM public.hotel_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Tentative hôtel B sur ticket hôtel A');
  RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel B a pu répondre au ticket de l''hôtel A';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%n''appartient pas à votre hôtel%' THEN RAISE NOTICE 'PASS rejet cross-hôtel symétrique (hôtel B -> ticket hôtel A).';
  ELSE RAISE; END IF;
END $$;

-- ============================================================================
-- 6) Un Super Admin doit utiliser admin_reply_support_ticket, jamais la RPC hôtel
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$ BEGIN
  PERFORM public.hotel_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'Tentative admin via RPC hôtel');
  RAISE EXCEPTION 'ECHEC CRITIQUE : un Super Admin a pu utiliser hotel_reply_support_ticket';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%doit utiliser admin_reply_support_ticket%' THEN RAISE NOTICE 'PASS admin bloqué sur hotel_reply_support_ticket.';
  ELSE RAISE; END IF;
END $$;

DO $$
DECLARE v_count_a int; v_count_b int;
BEGIN
  SELECT count(*) INTO v_count_a FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');
  SELECT count(*) INTO v_count_b FROM public.list_support_ticket_attachments('bbbbbbbb-0000-0000-0000-000000000002');
  RAISE NOTICE 'PASS admin liste les pièces jointes des 2 tickets (A=%, B=%).', v_count_a, v_count_b;
END $$;

-- ============================================================================
-- 7) service_role simule l'Edge Function d'upload : insère une pièce jointe
--    réelle, vérifie visibilité RPC (propriétaire OK, autre hôtel refusé) et
--    invisibilité en accès table direct pour authenticated (aucun grant, même
--    pour le propriétaire ou un Super Admin — tout passe par la RPC/Edge Fn).
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE service_role;
DO $$
DECLARE v_attach_id uuid;
BEGIN
  INSERT INTO public.support_ticket_attachments
    (ticket_id, storage_path, original_filename, mime_type, size_bytes, status, uploaded_by)
  VALUES (
    'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000001/test-fixture.pdf',
    'facture.pdf', 'application/pdf', 123456, 'uploaded', 'dbd29861-b6cd-4c19-9237-59963f8f20c8'
  ) RETURNING id INTO v_attach_id;
  RAISE NOTICE 'PASS service_role insère une pièce jointe (id=%).', v_attach_id;
END $$;

-- CHECK mime_type / size_bytes
DO $$ BEGIN
  INSERT INTO public.support_ticket_attachments
    (ticket_id, storage_path, original_filename, mime_type, size_bytes, status, uploaded_by)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'x/virus.exe', 'virus.exe', 'application/x-msdownload', 100, 'uploaded', 'dbd29861-b6cd-4c19-9237-59963f8f20c8');
  RAISE EXCEPTION 'ECHEC CRITIQUE : mime_type interdit accepté';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS CHECK mime_type rejette un type interdit.'; END $$;

DO $$ BEGIN
  INSERT INTO public.support_ticket_attachments
    (ticket_id, storage_path, original_filename, mime_type, size_bytes, status, uploaded_by)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'x/trop-gros.pdf', 'trop-gros.pdf', 'application/pdf', 99999999, 'uploaded', 'dbd29861-b6cd-4c19-9237-59963f8f20c8');
  RAISE EXCEPTION 'ECHEC CRITIQUE : fichier > 10 Mo accepté';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS CHECK size_bytes rejette un fichier > 10 Mo.'; END $$;

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"dbd29861-b6cd-4c19-9237-59963f8f20c8"}';
DO $$
DECLARE v_count int; v_status text;
BEGIN
  SELECT count(*), max(status) INTO v_count, v_status FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');
  IF v_count <> 1 OR v_status <> 'uploaded' THEN RAISE EXCEPTION 'ECHEC : hôtel A ne voit pas la pièce jointe attendue (count=%, status=%)', v_count, v_status; END IF;
  RAISE NOTICE 'PASS hôtel A voit sa pièce jointe via list_support_ticket_attachments (status=uploaded).';
END $$;

DO $$ BEGIN
  PERFORM count(*) FROM public.support_ticket_attachments WHERE ticket_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated a pu lire support_ticket_attachments directement (sans RPC)';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS accès table direct refusé pour authenticated (RPC/Edge Functions uniquement).'; END $$;

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"1a126371-efad-4c80-b798-1c5951536882"}';
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.list_support_ticket_attachments('bbbbbbbb-0000-0000-0000-000000000002');
  IF v_count <> 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : hôtel B voit une pièce jointe qui ne lui appartient pas'; END IF;
  RAISE NOTICE 'PASS hôtel B ne voit aucune pièce jointe étrangère (isolation confirmée).';
END $$;

-- ============================================================================
-- 8) anon bloqué partout (RPC et accès table direct)
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public._can_access_support_ticket('aaaaaaaa-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu appeler _can_access_support_ticket';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur _can_access_support_ticket.'; END $$;

DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.hotel_reply_support_ticket('aaaaaaaa-0000-0000-0000-000000000001', 'x');
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu répondre à un ticket';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur hotel_reply_support_ticket.'; END $$;

DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu lister des pièces jointes';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur list_support_ticket_attachments.'; END $$;

DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM count(*) FROM public.support_ticket_attachments;
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu lire support_ticket_attachments';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur accès table direct support_ticket_attachments.'; END $$;

RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- 9) support_ticket_attachment_access_log — service_role seul autorisé à
--    écrire ; authenticated n'a aucun accès table direct, même Super Admin
--    (aucune RPC de lecture n'est exposée dans ce lot — limite documentée :
--    le journal n'est aujourd'hui consultable que par requête SQL directe en
--    tant que service_role, jamais depuis l'UI Super Admin).
-- ============================================================================
SET LOCAL ROLE service_role;
DO $$
DECLARE v_log_id uuid; v_attach_id uuid;
BEGIN
  SELECT id INTO v_attach_id FROM public.support_ticket_attachments WHERE ticket_id='aaaaaaaa-0000-0000-0000-000000000001' AND status='uploaded' LIMIT 1;
  INSERT INTO public.support_ticket_attachment_access_log (attachment_id, ticket_id, user_id, action)
  VALUES (v_attach_id, 'aaaaaaaa-0000-0000-0000-000000000001', 'dbd29861-b6cd-4c19-9237-59963f8f20c8', 'download_url_issued')
  RETURNING id INTO v_log_id;
  RAISE NOTICE 'PASS service_role écrit dans support_ticket_attachment_access_log (id=%).', v_log_id;
END $$;

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$ BEGIN
  PERFORM count(*) FROM public.support_ticket_attachment_access_log;
  RAISE EXCEPTION 'ECHEC CRITIQUE : authenticated (même super_admin) a pu lire le journal directement (sans grant table)';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS journal d''accès illisible en direct pour authenticated (aucune RPC exposée dans ce lot — limite documentée).'; END $$;

RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- 10) Bucket Storage : privé, taille correcte, aucune policy storage.objects,
--     et re-upsert idempotent (régression de la dérive public=true corrigée
--     dans ce lot : ON CONFLICT DO UPDATE force désormais public=false).
-- ============================================================================
DO $$
DECLARE v_bucket record; v_policy_count int;
BEGIN
  SELECT public, file_size_limit INTO v_bucket FROM storage.buckets WHERE id='support-ticket-attachments';
  IF v_bucket IS NULL THEN RAISE EXCEPTION 'ECHEC CRITIQUE : bucket support-ticket-attachments introuvable'; END IF;
  IF v_bucket.public IS DISTINCT FROM false THEN RAISE EXCEPTION 'ECHEC CRITIQUE : bucket support-ticket-attachments n''est pas privé (public=%)', v_bucket.public; END IF;
  IF v_bucket.file_size_limit <> 10485760 THEN RAISE EXCEPTION 'ECHEC : file_size_limit incorrect (%)', v_bucket.file_size_limit; END IF;

  SELECT count(*) INTO v_policy_count FROM pg_policies
  WHERE schemaname='storage' AND tablename='objects' AND (qual LIKE '%support-ticket-attachments%' OR with_check LIKE '%support-ticket-attachments%');
  IF v_policy_count <> 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : % policy(ies) storage.objects référencent ce bucket (attendu 0 — accès Edge Functions uniquement)', v_policy_count; END IF;

  RAISE NOTICE 'PASS bucket privé (public=false), taille correcte (10 Mo), aucune policy storage.objects (accès Edge Functions service_role uniquement).';
END $$;

-- Simule une dérive manuelle (public=true) puis rejoue l'upsert de la migration :
-- le correctif (public = false explicite dans le DO UPDATE) doit la corriger.
DO $$ BEGIN
  UPDATE storage.buckets SET public = true WHERE id = 'support-ticket-attachments';
END $$;
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'support-ticket-attachments', 'support-ticket-attachments', false, 10485760,
  ARRAY[
    'application/pdf','image/jpeg','image/png','image/heic','image/webp','image/gif',
    'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
DO $$
DECLARE v_public boolean;
BEGIN
  SELECT public INTO v_public FROM storage.buckets WHERE id='support-ticket-attachments';
  IF v_public IS DISTINCT FROM false THEN RAISE EXCEPTION 'ECHEC CRITIQUE : re-upsert n''a pas restauré public=false après une dérive manuelle'; END IF;
  RAISE NOTICE 'PASS re-upsert idempotent restaure public=false même si le bucket avait dérivé vers public=true.';
END $$;

-- ============================================================================
-- 11) admin_delete_support_ticket_attachment — suppression logique réservée au
--     staff Support : motif obligatoire, journalisée (action=soft_deleted),
--     disparaît de list_support_ticket_attachments, double-suppression rejetée,
--     non-staff bloqué.
-- ============================================================================
RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';

DO $$
DECLARE v_attach_id uuid;
BEGIN
  SELECT id INTO v_attach_id FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001') LIMIT 1;
  BEGIN
    PERFORM public.admin_delete_support_ticket_attachment(v_attach_id, '');
    RAISE EXCEPTION 'ECHEC CRITIQUE : suppression acceptée sans motif';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'MOTIF_REQUIS%' THEN RAISE NOTICE 'PASS motif obligatoire pour supprimer une pièce jointe.'; ELSE RAISE; END IF;
  END;
END $$;

DO $$
DECLARE v_attach_id uuid; v_count_before int; v_count_after int; v_log_count int;
BEGIN
  SELECT id INTO v_attach_id FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001') LIMIT 1;
  SELECT count(*) INTO v_count_before FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');

  PERFORM public.admin_delete_support_ticket_attachment(v_attach_id, 'Fichier envoyé par erreur, doublon');

  SELECT count(*) INTO v_count_after FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001');
  IF v_count_after <> v_count_before - 1 THEN
    RAISE EXCEPTION 'ECHEC : la pièce jointe supprimée est toujours listée (avant=%, après=%)', v_count_before, v_count_after;
  END IF;
  RAISE NOTICE 'PASS suppression logique effective : disparue de list_support_ticket_attachments (avant=%, après=%).', v_count_before, v_count_after;

  BEGIN
    PERFORM public.admin_delete_support_ticket_attachment(v_attach_id, 'Nouvelle tentative');
    RAISE EXCEPTION 'ECHEC CRITIQUE : double suppression acceptée';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'DEJA_SUPPRIMEE%' THEN RAISE NOTICE 'PASS double suppression rejetée (DEJA_SUPPRIMEE).'; ELSE RAISE; END IF;
  END;
END $$;

RESET ROLE; RESET request.jwt.claims;
SET LOCAL ROLE service_role;
DO $$
DECLARE v_log_count int;
BEGIN
  SELECT count(*) INTO v_log_count FROM public.support_ticket_attachment_access_log
  WHERE ticket_id = 'aaaaaaaa-0000-0000-0000-000000000001' AND action = 'soft_deleted';
  IF v_log_count <> 1 THEN RAISE EXCEPTION 'ECHEC : % entrée(s) soft_deleted dans le journal (attendu 1)', v_log_count; END IF;
  RAISE NOTICE 'PASS suppression journalisée dans support_ticket_attachment_access_log (action=soft_deleted).';
END $$;

RESET ROLE; RESET request.jwt.claims;
UPDATE public.platform_admins SET role='billing_admin' WHERE auth_id='7afa461c-71a9-4a89-bca0-9de08e405bc7';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
DO $$
DECLARE v_attach_id uuid;
BEGIN
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claims TO '{"sub":"dbd29861-b6cd-4c19-9237-59963f8f20c8"}';
  SELECT id INTO v_attach_id FROM public.list_support_ticket_attachments('aaaaaaaa-0000-0000-0000-000000000001') LIMIT 1;
  RESET ROLE; RESET request.jwt.claims; SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claims TO '{"sub":"7afa461c-71a9-4a89-bca0-9de08e405bc7"}';
  PERFORM public.admin_delete_support_ticket_attachment(v_attach_id, 'Tentative billing_admin');
  RAISE EXCEPTION 'ECHEC CRITIQUE : billing_admin a pu supprimer une pièce jointe (hors périmètre Support)';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS billing_admin bloqué sur admin_delete_support_ticket_attachment (moindre privilège respecté).'; END $$;

RESET ROLE; RESET request.jwt.claims;
UPDATE public.platform_admins SET role='super_admin' WHERE auth_id='7afa461c-71a9-4a89-bca0-9de08e405bc7';

DO $$ BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_delete_support_ticket_attachment('00000000-0000-0000-0000-000000000000', 'x');
  RAISE EXCEPTION 'ECHEC CRITIQUE : anon a pu appeler admin_delete_support_ticket_attachment';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS anon bloqué sur admin_delete_support_ticket_attachment.'; END $$;

RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN RAISE NOTICE 'TOUS LES CONTROLES support_ticket_attachments (Lot 5B) PASSENT.'; END $$;
ROLLBACK;
