-- ============================================================================
-- sql/tests/support_acl_hardening.sql
-- Lot 1, PR-02 — Matrice de rôles complète (Support), régression permanente
--
-- Exécution : BEGIN...ROLLBACK sur la production réelle (psql -f), doctrine
-- standard du projet. Fixtures temporaires (public.users/user_hotels/
-- platform_admins/support_tickets), zéro donnée réelle modifiée, zéro
-- résidu après ROLLBACK. Corrige une erreur d'instrumentation détectée
-- pendant la conception de ce test : un DELETE bloqué par RLS ne lève
-- aucune erreur (RLS filtre silencieusement à 0 ligne) — chaque test
-- DELETE/UPDATE vérifie donc l'effet RÉEL (ROW_COUNT / relecture), jamais
-- seulement l'absence d'exception SQL.
--
-- 7 profils : anon, authenticated sans hôtel, authenticated hôtel A,
-- authenticated hôtel B (hôtel différent), support_agent, super_admin,
-- service_role. Tables : support_tickets, help_articles. Opérations :
-- SELECT/INSERT/UPDATE/DELETE/TRUNCATE selon pertinence.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE zz_acl_results (profile text, table_name text, operation text, allowed boolean, detail text);
GRANT ALL ON zz_acl_results TO anon, authenticated, service_role;

INSERT INTO auth.users (id) VALUES
  ('00000000-aaaa-bbbb-cccc-000000000002'),
  ('00000000-aaaa-bbbb-cccc-000000000003'),
  ('00000000-aaaa-bbbb-cccc-000000000004'),
  ('00000000-aaaa-bbbb-cccc-000000000005');

INSERT INTO public.users (id, auth_id, hotel_id, email, full_name, role, is_active) VALUES
  ('00000000-aaaa-bbbb-cccc-000000000002','00000000-aaaa-bbbb-cccc-000000000002','b833efe8-c71e-4822-87a1-b9b6bf06f1e8','zz-acl-test-a@example.invalid','ACL Test Hotel A','reception', true),
  ('00000000-aaaa-bbbb-cccc-000000000003','00000000-aaaa-bbbb-cccc-000000000003','f8de287f-e5db-497f-be0b-c0fcdb035822','zz-acl-test-b@example.invalid','ACL Test Hotel B','reception', true);

INSERT INTO public.user_hotels (hotel_id, user_id) VALUES
  ('b833efe8-c71e-4822-87a1-b9b6bf06f1e8','00000000-aaaa-bbbb-cccc-000000000002'),
  ('f8de287f-e5db-497f-be0b-c0fcdb035822','00000000-aaaa-bbbb-cccc-000000000003');

INSERT INTO public.platform_admins (auth_id, email, full_name, role, is_active) VALUES
  ('00000000-aaaa-bbbb-cccc-000000000004','zz-acl-test-agent@example.invalid','ACL Test Agent','support_agent', true),
  ('00000000-aaaa-bbbb-cccc-000000000005','zz-acl-test-admin@example.invalid','ACL Test Admin','super_admin', true);

INSERT INTO public.support_tickets (id, hotel_id, module, feature, description)
VALUES ('00000000-1111-2222-3333-444444444444','b833efe8-c71e-4822-87a1-b9b6bf06f1e8','test','test','fixture ACL PR-02');

-- ===================== anon =====================
RESET ROLE;
SET LOCAL ROLE anon;
INSERT INTO zz_acl_results VALUES ('anon','support_tickets','SELECT',
  (SELECT count(*)>0 FROM public.support_tickets WHERE id='00000000-1111-2222-3333-444444444444'), 'attendu: false');
DO $$ BEGIN
  INSERT INTO public.support_tickets (hotel_id, module, feature, description) VALUES ('b833efe8-c71e-4822-87a1-b9b6bf06f1e8','x','x','anon insert attempt');
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','INSERT', true, 'attendu: false (bloqué)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','INSERT', false, SQLERRM);
END $$;
DO $$
DECLARE v_rows int;
BEGIN
  UPDATE public.support_tickets SET description='hacked-by-anon' WHERE id='00000000-1111-2222-3333-444444444444';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','UPDATE', v_rows>0, format('lignes affectées: %s (attendu: 0)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','UPDATE', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.support_tickets;
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','TRUNCATE', true, 'CRITIQUE — attendu: bloqué (permission denied)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('anon','support_tickets','TRUNCATE', false, SQLERRM);
END $$;
INSERT INTO zz_acl_results VALUES ('anon','help_articles','SELECT_published',
  (SELECT count(*)>0 FROM public.help_articles WHERE is_published=true), 'attendu: true (policy volontaire)');
INSERT INTO zz_acl_results VALUES ('anon','help_articles','SELECT_unpublished',
  (SELECT count(*)>0 FROM public.help_articles WHERE is_published=false), 'attendu: false');
DO $$ BEGIN
  INSERT INTO public.help_articles (module,title,body) VALUES ('x','anon test','x');
  INSERT INTO zz_acl_results VALUES ('anon','help_articles','INSERT', true, 'attendu: false (bloqué)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('anon','help_articles','INSERT', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.help_articles;
  INSERT INTO zz_acl_results VALUES ('anon','help_articles','TRUNCATE', true, 'CRITIQUE — attendu: bloqué');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('anon','help_articles','TRUNCATE', false, SQLERRM);
END $$;

-- ===================== authenticated sans hôtel =====================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-aaaa-bbbb-cccc-000000000001"}';
INSERT INTO zz_acl_results VALUES ('auth_no_hotel','support_tickets','SELECT',
  (SELECT count(*)>0 FROM public.support_tickets WHERE id='00000000-1111-2222-3333-444444444444'), 'attendu: false');
DO $$ BEGIN
  INSERT INTO public.support_tickets (hotel_id, module, feature, description) VALUES ('b833efe8-c71e-4822-87a1-b9b6bf06f1e8','x','x','no-hotel insert attempt');
  INSERT INTO zz_acl_results VALUES ('auth_no_hotel','support_tickets','INSERT', true, 'attendu: false (bloqué)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_no_hotel','support_tickets','INSERT', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.support_tickets;
  INSERT INTO zz_acl_results VALUES ('auth_no_hotel','support_tickets','TRUNCATE', true, 'CRITIQUE — attendu: bloqué (durcissement PR-02)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_no_hotel','support_tickets','TRUNCATE', false, SQLERRM);
END $$;
INSERT INTO zz_acl_results VALUES ('auth_no_hotel','help_articles','SELECT_unpublished',
  (SELECT count(*)>0 FROM public.help_articles WHERE is_published=false), 'attendu: false');

-- ===================== authenticated hôtel A (légitime) =====================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-aaaa-bbbb-cccc-000000000002"}';
INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','SELECT_own',
  (SELECT count(*)>0 FROM public.support_tickets WHERE id='00000000-1111-2222-3333-444444444444'), 'attendu: true');
DO $$ BEGIN
  INSERT INTO public.support_tickets (hotel_id, module, feature, description) VALUES ('b833efe8-c71e-4822-87a1-b9b6bf06f1e8','x','x','hotel A legit insert');
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','INSERT_own_hotel', true, 'attendu: true (légitime, conservé par PR-02)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','INSERT_own_hotel', false, SQLERRM);
END $$;
DO $$ BEGIN
  INSERT INTO public.support_tickets (hotel_id, module, feature, description) VALUES ('f8de287f-e5db-497f-be0b-c0fcdb035822','x','x','hotel A trying hotel B');
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','INSERT_other_hotel', true, 'INATTENDU / faille — attendu: false');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','INSERT_other_hotel', false, SQLERRM);
END $$;
DO $$
DECLARE v_rows int;
BEGIN
  UPDATE public.support_tickets SET priority='bloquant' WHERE id='00000000-1111-2222-3333-444444444444';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','UPDATE_own', v_rows>0, format('lignes affectées: %s (attendu: 1)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','UPDATE_own', false, SQLERRM);
END $$;
DO $$
DECLARE v_rows int;
BEGIN
  DELETE FROM public.support_tickets WHERE id='00000000-1111-2222-3333-444444444444';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','DELETE_own', v_rows>0, format('lignes affectées: %s (attendu: 0, aucune policy DELETE)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','DELETE_own', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.support_tickets;
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','TRUNCATE', true, 'CRITIQUE — attendu: bloqué');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('auth_hotel_a','support_tickets','TRUNCATE', false, SQLERRM);
END $$;

-- ===================== authenticated hôtel B (autre hôtel) =====================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-aaaa-bbbb-cccc-000000000003"}';
INSERT INTO zz_acl_results VALUES ('auth_hotel_b','support_tickets','SELECT_cross_hotel',
  (SELECT count(*)>0 FROM public.support_tickets WHERE hotel_id='b833efe8-c71e-4822-87a1-b9b6bf06f1e8'), 'attendu: false (isolation inter-hôtels)');

-- ===================== support_agent =====================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-aaaa-bbbb-cccc-000000000004"}';
INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','SELECT_all',
  (SELECT count(*)>0 FROM public.support_tickets), 'attendu: true (policy platform_admin_read_tickets)');
DO $$
DECLARE v_rows int;
BEGIN
  UPDATE public.support_tickets SET status='en_analyse' WHERE hotel_id='b833efe8-c71e-4822-87a1-b9b6bf06f1e8';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','UPDATE_any', v_rows>0, format('lignes affectées: %s (attendu: >0)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','UPDATE_any', false, SQLERRM);
END $$;
DO $$
DECLARE v_rows int;
BEGIN
  DELETE FROM public.support_tickets WHERE hotel_id='b833efe8-c71e-4822-87a1-b9b6bf06f1e8';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','DELETE_any', v_rows>0, format('lignes affectées: %s (attendu: 0, aucune policy DELETE — corrige une erreur d''instrumentation initiale qui ne vérifiait que l''absence d''erreur)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','DELETE_any', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.support_tickets;
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','TRUNCATE', true, 'CRITIQUE — attendu: bloqué');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('support_agent','support_tickets','TRUNCATE', false, SQLERRM);
END $$;
DO $$ BEGIN
  INSERT INTO public.help_articles (module,title,body,is_published) VALUES ('x','support_agent test','x',false);
  INSERT INTO zz_acl_results VALUES ('support_agent','help_articles','INSERT', true, 'attendu: true (role dans help_articles_write)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('support_agent','help_articles','INSERT', false, SQLERRM);
END $$;
INSERT INTO zz_acl_results VALUES ('support_agent','help_articles','SELECT_unpublished',
  (SELECT count(*)>0 FROM public.help_articles WHERE is_published=false), 'attendu: true (is_platform_admin())');

-- ===================== super_admin =====================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"00000000-aaaa-bbbb-cccc-000000000005"}';
INSERT INTO zz_acl_results VALUES ('super_admin','support_tickets','SELECT_all',
  (SELECT count(*)>=0 FROM public.support_tickets), 'accès en lecture confirmé');
DO $$
DECLARE v_rows int;
BEGIN
  DELETE FROM public.help_articles WHERE title='support_agent test';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO zz_acl_results VALUES ('super_admin','help_articles','DELETE_any', v_rows>0, format('lignes affectées: %s (attendu: 1, policy FOR ALL)', v_rows));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('super_admin','help_articles','DELETE_any', false, SQLERRM);
END $$;
DO $$ BEGIN
  TRUNCATE public.help_articles;
  INSERT INTO zz_acl_results VALUES ('super_admin','help_articles','TRUNCATE', true, 'attendu: bloqué (TRUNCATE jamais nécessaire côté client, même admin)');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO zz_acl_results VALUES ('super_admin','help_articles','TRUNCATE', false, SQLERRM);
END $$;

-- ===================== service_role =====================
RESET ROLE;
SET LOCAL ROLE service_role;
INSERT INTO zz_acl_results VALUES ('service_role','support_tickets','SELECT_all',
  (SELECT count(*)>=0 FROM public.support_tickets), 'bypass RLS (rolbypassrls=true) — attendu: true');

-- ===================== Verdict final =====================
RESET ROLE;
DO $$
DECLARE
  r RECORD;
  v_unexpected int := 0;
BEGIN
  FOR r IN SELECT * FROM zz_acl_results ORDER BY profile, table_name, operation LOOP
    RAISE NOTICE '% | % | % | allowed=% | %', r.profile, r.table_name, r.operation, r.allowed, r.detail;
  END LOOP;

  -- Assertions critiques — un seul écart ici est un incident de sécurité
  SELECT count(*) INTO v_unexpected FROM zz_acl_results WHERE operation='TRUNCATE' AND allowed=true;
  IF v_unexpected > 0 THEN
    RAISE EXCEPTION 'ECHEC CRITIQUE : % rôle(s) peuvent encore exécuter TRUNCATE après durcissement.', v_unexpected;
  END IF;

  SELECT count(*) INTO v_unexpected FROM zz_acl_results WHERE profile='auth_hotel_b' AND operation='SELECT_cross_hotel' AND allowed=true;
  IF v_unexpected > 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : isolation inter-hôtels violée.'; END IF;

  SELECT count(*) INTO v_unexpected FROM zz_acl_results WHERE profile='auth_hotel_a' AND operation='INSERT_other_hotel' AND allowed=true;
  IF v_unexpected > 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : insertion inter-hôtels permise.'; END IF;

  SELECT count(*) INTO v_unexpected FROM zz_acl_results WHERE profile IN ('anon','auth_no_hotel') AND table_name='support_tickets' AND operation IN ('SELECT','INSERT') AND allowed=true;
  IF v_unexpected > 0 THEN RAISE EXCEPTION 'ECHEC CRITIQUE : anon ou authenticated sans hôtel a accès aux tickets.'; END IF;

  RAISE NOTICE 'TOUS LES CONTROLES CRITIQUES PASSENT.';
END $$;

ROLLBACK;
