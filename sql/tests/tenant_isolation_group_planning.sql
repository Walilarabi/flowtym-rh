-- sql/tests/tenant_isolation_group_planning.sql
-- Suite de non-régression P0 — isolation inter-groupes du Planning Groupe.
--
-- À exécuter APRÈS sql/97_security_group_planning_isolation.sql. Convention du projet :
-- BEGIN...ROLLBACK, fixtures synthétiques créées et détruites dans la même transaction, jamais
-- de COMMIT. Usage : coller entre BEGIN; et ROLLBACK; (jamais en production réelle sans rollback
-- final).
--
-- Portée : crée deux groupes hôteliers totalement indépendants — BOUDAA HOTELS et REDOUANE
-- HOTELS — avec 2 hôtels chacun, 1 salarié standard + 1 extra (compte portail) par groupe, un
-- manager ('direction') et un collaborateur ('reception') par groupe avec accès aux DEUX hôtels
-- de leur groupe (nécessaire pour interagir légitimement avec un déplacement inter-hôtels — voir
-- _gmp_can_access, qui exige from_hotel_id ET to_hotel_id dans pl_my_hotels()), et un admin
-- plateforme. Un déplacement inter-hôtels réel (hb1 -> hb2) est créé côté Boudaa, avec ses
-- sous-objets (événement, annulation, remplacement, segment de planning).
--
-- Chaque test impersonne un principal (via request.jwt.claims, comme un vrai JWT Supabase) SOUS
-- LE RÔLE POSTGRES `authenticated` (jamais le rôle de connexion du script, qui a typiquement
-- rolbypassrls=true et invaliderait silencieusement toute assertion RLS) et vérifie qu'aucune
-- donnée du groupe Boudaa n'est jamais visible par un principal Redouane, et réciproquement —
-- tout en vérifiant qu'un principal peut toujours voir les données de SON PROPRE groupe (pas de
-- régression fonctionnelle) et que l'admin plateforme continue de voir les deux groupes
-- (bypass intentionnel, pas une fuite).
--
-- Couvre : group_move_timeline (correctif #1), group_move_cancellations / group_move_replacements
-- (correctif #2, RLS), v_staff_day_flags (correctif #3, security_invoker), et en non-régression :
-- group_staff_directory, hotel_group_get, org_get, RLS portail employees/extras.

BEGIN;

CREATE TEMP TABLE ti_results (test_no int PRIMARY KEY, name text, status text, detail text);
CREATE OR REPLACE FUNCTION pg_temp.ti_log(p_no int, p_name text, p_status text, p_detail text) RETURNS void AS $$
  INSERT INTO ti_results VALUES (p_no, p_name, p_status, left(coalesce(p_detail,''), 300))
  ON CONFLICT (test_no) DO UPDATE SET status = excluded.status, detail = excluded.detail;
$$ LANGUAGE sql SECURITY DEFINER;

-- Positionne les DEUX conventions de GUC JWT utilisées dans ce dépôt : la forme JSON
-- `request.jwt.claims` (auth.uid() réel de Supabase, production/branches — cf. zz3_as dans
-- sql/tests/phase2c_lot2_hotels_groups.sql) ET la forme aplatie `request.jwt.claim.sub` (shim
-- local de db/reconstruct/00_bootstrap.sql, utilisée par les suites P0/concurrence/planning-
-- change). Chaque environnement ignore la convention qu'il ne lit pas — aucun effet croisé —
-- ce qui permet à ce fichier de tourner à l'identique en local (CI, reconstruct) et contre un
-- vrai Supabase (production/branche, validé lors de l'incident).
CREATE OR REPLACE FUNCTION pg_temp.ti_as(p_auth_id uuid) RETURNS void AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true),
         set_config('request.jwt.claim.sub', p_auth_id::text, true);
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- Fixtures : deux groupes totalement indépendants, 2 hôtels chacun, 1 salarié
-- standard + 1 extra par groupe, 1 manager + 1 collaborateur par groupe (accès
-- aux 2 hôtels de leur groupe), 1 admin plateforme, 1 déplacement inter-hôtels
-- réel côté Boudaa avec ses sous-objets.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_gid_b uuid; v_gid_r uuid;
  v_hb1 uuid; v_hb2 uuid; v_hr1 uuid; v_hr2 uuid;
  v_svc_b uuid; v_svc_r uuid;
  v_emp_b uuid; v_emp_r uuid; v_extra_b uuid; v_extra_r uuid;
  v_auth_bdir uuid; v_auth_bcol uuid; v_auth_rdir uuid; v_auth_rcol uuid;
  v_auth_extra_b uuid; v_auth_extra_r uuid; v_auth_admin uuid;
  v_u_bdir uuid; v_u_bcol uuid; v_u_rdir uuid; v_u_rcol uuid;
  v_prop_b uuid := gen_random_uuid();
BEGIN
  INSERT INTO hotel_groups(name) VALUES ('ZZTI BOUDAA HOTELS') RETURNING id INTO v_gid_b;
  INSERT INTO hotel_groups(name) VALUES ('ZZTI REDOUANE HOTELS') RETURNING id INTO v_gid_r;
  INSERT INTO hotels(name, group_id, hotel_code) VALUES ('ZZTI Boudaa H1', v_gid_b, 'ZTB1') RETURNING id INTO v_hb1;
  INSERT INTO hotels(name, group_id, hotel_code) VALUES ('ZZTI Boudaa H2', v_gid_b, 'ZTB2') RETURNING id INTO v_hb2;
  INSERT INTO hotels(name, group_id, hotel_code) VALUES ('ZZTI Redouane H1', v_gid_r, 'ZTR1') RETURNING id INTO v_hr1;
  INSERT INTO hotels(name, group_id, hotel_code) VALUES ('ZZTI Redouane H2', v_gid_r, 'ZTR2') RETURNING id INTO v_hr2;

  INSERT INTO staff_departments(hotel_id, name) VALUES (v_hb2, 'ZZTI Reception') RETURNING id INTO v_svc_b;
  INSERT INTO staff_departments(hotel_id, name) VALUES (v_hr2, 'ZZTI Reception') RETURNING id INTO v_svc_r;

  INSERT INTO employees(hotel_id, first_name, last_name, department, role, status)
    VALUES (v_hb1, 'Zzti', 'BoudaaEmp', 'ZZTI Reception', 'reception', 'actif') RETURNING id INTO v_emp_b;
  INSERT INTO employees(hotel_id, first_name, last_name, department, role, status)
    VALUES (v_hr1, 'Zzti', 'RedouaneEmp', 'ZZTI Reception', 'reception', 'actif') RETURNING id INTO v_emp_r;

  v_auth_extra_b := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_extra_b);
  v_auth_extra_r := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_extra_r);
  INSERT INTO employees(hotel_id, first_name, last_name, department, role, status, portal_auth_id, portal_enabled)
    VALUES (v_hb2, 'Zzti', 'BoudaaExtra', 'ZZTI Reception', 'reception', 'actif', v_auth_extra_b, true) RETURNING id INTO v_extra_b;
  INSERT INTO employees(hotel_id, first_name, last_name, department, role, status, portal_auth_id, portal_enabled)
    VALUES (v_hr2, 'Zzti', 'RedouaneExtra', 'ZZTI Reception', 'reception', 'actif', v_auth_extra_r, true) RETURNING id INTO v_extra_r;

  v_auth_bdir := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_bdir);
  v_auth_bcol := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_bcol);
  v_auth_rdir := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_rdir);
  v_auth_rcol := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_rcol);
  v_auth_admin := gen_random_uuid(); INSERT INTO auth.users(id) VALUES (v_auth_admin);

  INSERT INTO users(auth_id, hotel_id, email, full_name, role) VALUES (v_auth_bdir, v_hb1, 'zzti-bdir@example.invalid', 'ZZTI Boudaa Direction', 'direction') RETURNING id INTO v_u_bdir;
  INSERT INTO users(auth_id, hotel_id, email, full_name, role) VALUES (v_auth_bcol, v_hb1, 'zzti-bcol@example.invalid', 'ZZTI Boudaa Collab', 'reception') RETURNING id INTO v_u_bcol;
  INSERT INTO users(auth_id, hotel_id, email, full_name, role) VALUES (v_auth_rdir, v_hr1, 'zzti-rdir@example.invalid', 'ZZTI Redouane Direction', 'direction') RETURNING id INTO v_u_rdir;
  INSERT INTO users(auth_id, hotel_id, email, full_name, role) VALUES (v_auth_rcol, v_hr1, 'zzti-rcol@example.invalid', 'ZZTI Redouane Collab', 'reception') RETURNING id INTO v_u_rcol;

  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_bdir, v_hb1, 'direction', true);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_bdir, v_hb2, 'direction', false);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_bcol, v_hb1, 'reception', true);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_bcol, v_hb2, 'reception', false);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_rdir, v_hr1, 'direction', true);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_rdir, v_hr2, 'direction', false);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_rcol, v_hr1, 'reception', true);
  INSERT INTO user_hotels(user_id, hotel_id, role, is_default) VALUES (v_u_rcol, v_hr2, 'reception', false);

  INSERT INTO platform_admins(auth_id, email, role, is_active) VALUES (v_auth_admin, 'zzti-admin@example.invalid', 'super_admin', true);

  INSERT INTO group_move_proposals(id, group_id, employee_id, from_hotel_id, to_hotel_id, from_service, to_service,
    period_from, period_to, slots, reason, status, decision)
  VALUES (v_prop_b, v_gid_b, v_emp_b, v_hb1, v_hb2, 'ZZTI Reception', 'ZZTI Reception',
    '2099-06-01','2099-06-01', jsonb_build_array(jsonb_build_object('date','2099-06-01')), 'test isolation', 'applied', 'allowed');
  INSERT INTO group_move_proposal_events(proposal_id, actor, action, old_status, new_status)
    VALUES (v_prop_b, v_auth_bdir, 'applied', 'approved', 'applied');
  INSERT INTO group_move_cancellations(idempotency_key, proposal_id, scope, cancelled_by, status, result)
    VALUES ('zzti-cancel-'||v_prop_b::text, v_prop_b, 'full', v_auth_bdir, 'completed', jsonb_build_object('cancelled', true));
  INSERT INTO group_move_replacements(idempotency_key, old_proposal_id, new_proposal_id, replaced_by, status, result)
    VALUES ('zzti-replace-'||v_prop_b::text, v_prop_b, v_prop_b, v_auth_bdir, 'completed', jsonb_build_object('replaced', true));
  INSERT INTO staff_planning_segments(hotel_id, employee_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id, origin_hotel_id)
    VALUES (v_hb2, v_emp_b, '2099-06-01', 0, 1440, 'destination', 'PE', v_prop_b, v_hb1);

  CREATE TEMP TABLE ti_ids AS SELECT
    v_gid_b gid_b, v_gid_r gid_r, v_hb1, v_hb2, v_hr1, v_hr2, v_emp_b, v_emp_r, v_extra_b, v_extra_r,
    v_auth_bdir, v_auth_bcol, v_auth_rdir, v_auth_rcol, v_auth_extra_b, v_auth_extra_r, v_auth_admin, v_prop_b;
END $$;

GRANT SELECT ON ti_ids TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- Matrice de tests — exécutée sous le rôle Postgres `authenticated` (comme un
-- vrai appel PostgREST porteur d'un JWT), jamais sous le rôle de connexion du
-- script (qui a souvent rolbypassrls=true et invaliderait silencieusement
-- toute assertion basée sur RLS).
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  r ti_ids%rowtype;
  v_tl jsonb; v_cnt int; v_grp jsonb; v_org jsonb; v_dir jsonb;
BEGIN
  SELECT * INTO r FROM ti_ids;

  -- 1. group_move_timeline (correctif #1)
  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  v_tl := public.group_move_timeline(r.v_prop_b);
  IF v_tl IS NOT NULL AND jsonb_array_length(v_tl->'events') > 0 THEN
    PERFORM pg_temp.ti_log(1,'timeline: Boudaa dir lit sa propre proposition','PASS', v_tl::text);
  ELSE PERFORM pg_temp.ti_log(1,'timeline: Boudaa dir lit sa propre proposition','FAIL', coalesce(v_tl::text,'null')); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rdir);
  v_tl := public.group_move_timeline(r.v_prop_b);
  IF v_tl IS NULL THEN
    PERFORM pg_temp.ti_log(2,'timeline: Redouane dir NE VOIT PAS la proposition Boudaa','PASS','null (attendu)');
  ELSE PERFORM pg_temp.ti_log(2,'timeline: Redouane dir NE VOIT PAS la proposition Boudaa','FAIL', 'FUITE: '||v_tl::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rcol);
  v_tl := public.group_move_timeline(r.v_prop_b);
  IF v_tl IS NULL THEN
    PERFORM pg_temp.ti_log(3,'timeline: Redouane collaborateur NE VOIT PAS la proposition Boudaa','PASS','null (attendu)');
  ELSE PERFORM pg_temp.ti_log(3,'timeline: Redouane collaborateur NE VOIT PAS la proposition Boudaa','FAIL', 'FUITE: '||v_tl::text); END IF;

  -- 2. group_move_cancellations (correctif #2, RLS)
  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  SELECT count(*) INTO v_cnt FROM group_move_cancellations WHERE proposal_id = r.v_prop_b;
  IF v_cnt = 1 THEN PERFORM pg_temp.ti_log(4,'cancellations: Boudaa dir voit sa propre annulation','PASS', v_cnt::text);
  ELSE PERFORM pg_temp.ti_log(4,'cancellations: Boudaa dir voit sa propre annulation','FAIL', v_cnt::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rdir);
  SELECT count(*) INTO v_cnt FROM group_move_cancellations WHERE proposal_id = r.v_prop_b;
  IF v_cnt = 0 THEN PERFORM pg_temp.ti_log(5,'cancellations: Redouane dir NE VOIT PAS l''annulation Boudaa','PASS','0 (attendu)');
  ELSE PERFORM pg_temp.ti_log(5,'cancellations: Redouane dir NE VOIT PAS l''annulation Boudaa','FAIL', 'FUITE: '||v_cnt::text); END IF;

  -- 3. group_move_replacements (correctif #2, RLS)
  PERFORM pg_temp.ti_as(r.v_auth_bcol);
  SELECT count(*) INTO v_cnt FROM group_move_replacements WHERE old_proposal_id = r.v_prop_b;
  IF v_cnt = 1 THEN PERFORM pg_temp.ti_log(7,'replacements: Boudaa collaborateur voit son propre remplacement','PASS', v_cnt::text);
  ELSE PERFORM pg_temp.ti_log(7,'replacements: Boudaa collaborateur voit son propre remplacement','FAIL', v_cnt::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rcol);
  SELECT count(*) INTO v_cnt FROM group_move_replacements WHERE old_proposal_id = r.v_prop_b;
  IF v_cnt = 0 THEN PERFORM pg_temp.ti_log(8,'replacements: Redouane collaborateur NE VOIT PAS le remplacement Boudaa','PASS','0 (attendu)');
  ELSE PERFORM pg_temp.ti_log(8,'replacements: Redouane collaborateur NE VOIT PAS le remplacement Boudaa','FAIL', 'FUITE: '||v_cnt::text); END IF;

  -- 4. v_staff_day_flags (correctif #3, security_invoker)
  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  SELECT count(*) INTO v_cnt FROM v_staff_day_flags WHERE employee_id = r.v_emp_b;
  IF v_cnt = 1 THEN PERFORM pg_temp.ti_log(9,'day_flags: Boudaa dir voit son propre salarie','PASS', v_cnt::text);
  ELSE PERFORM pg_temp.ti_log(9,'day_flags: Boudaa dir voit son propre salarie','FAIL', v_cnt::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rdir);
  SELECT count(*) INTO v_cnt FROM v_staff_day_flags WHERE employee_id = r.v_emp_b;
  IF v_cnt = 0 THEN PERFORM pg_temp.ti_log(10,'day_flags: Redouane dir NE VOIT PAS le salarie Boudaa','PASS','0 (attendu)');
  ELSE PERFORM pg_temp.ti_log(10,'day_flags: Redouane dir NE VOIT PAS le salarie Boudaa','FAIL', 'FUITE: '||v_cnt::text); END IF;

  -- 5. Non-régression : surfaces déjà correctement scopées
  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  v_dir := (SELECT coalesce(jsonb_agg(hotel_id),'[]'::jsonb) FROM public.group_staff_directory() WHERE hotel_id IN (r.v_hb1, r.v_hb2, r.v_hr1, r.v_hr2));
  IF v_dir @> to_jsonb(r.v_hb1) AND NOT (v_dir @> to_jsonb(r.v_hr1)) AND NOT (v_dir @> to_jsonb(r.v_hr2)) THEN
    PERFORM pg_temp.ti_log(11,'group_staff_directory: Boudaa dir voit Boudaa, jamais Redouane','PASS', v_dir::text);
  ELSE PERFORM pg_temp.ti_log(11,'group_staff_directory: Boudaa dir voit Boudaa, jamais Redouane','FAIL', v_dir::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_rdir);
  v_dir := (SELECT coalesce(jsonb_agg(hotel_id),'[]'::jsonb) FROM public.group_staff_directory() WHERE hotel_id IN (r.v_hb1, r.v_hb2, r.v_hr1, r.v_hr2));
  IF v_dir @> to_jsonb(r.v_hr1) AND NOT (v_dir @> to_jsonb(r.v_hb1)) AND NOT (v_dir @> to_jsonb(r.v_hb2)) THEN
    PERFORM pg_temp.ti_log(12,'group_staff_directory: Redouane dir voit Redouane, jamais Boudaa','PASS', v_dir::text);
  ELSE PERFORM pg_temp.ti_log(12,'group_staff_directory: Redouane dir voit Redouane, jamais Boudaa','FAIL', v_dir::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_admin);
  v_dir := (SELECT coalesce(jsonb_agg(hotel_id),'[]'::jsonb) FROM public.group_staff_directory() WHERE hotel_id IN (r.v_hb1, r.v_hb2, r.v_hr1, r.v_hr2));
  IF v_dir @> to_jsonb(r.v_hb1) AND v_dir @> to_jsonb(r.v_hr1) THEN
    PERFORM pg_temp.ti_log(13,'group_staff_directory: admin plateforme voit les deux groupes (attendu)','PASS', v_dir::text);
  ELSE PERFORM pg_temp.ti_log(13,'group_staff_directory: admin plateforme voit les deux groupes (attendu)','FAIL', v_dir::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  BEGIN
    v_grp := public.hotel_group_get(r.v_hr1);
    PERFORM pg_temp.ti_log(14,'hotel_group_get: Boudaa dir ne peut pas interroger un hotel Redouane','FAIL', 'aucune exception: '||v_grp::text);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'NON_AUTORISE' THEN PERFORM pg_temp.ti_log(14,'hotel_group_get: Boudaa dir ne peut pas interroger un hotel Redouane','PASS','NON_AUTORISE (attendu)');
    ELSE PERFORM pg_temp.ti_log(14,'hotel_group_get: Boudaa dir ne peut pas interroger un hotel Redouane','FAIL', SQLERRM); END IF;
  END;

  PERFORM pg_temp.ti_as(r.v_auth_bdir);
  v_org := public.org_get();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_org->'members') m WHERE (m->>'id')::uuid = r.v_hb2)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_org->'members') m WHERE (m->>'id')::uuid IN (r.v_hr1, r.v_hr2)) THEN
    PERFORM pg_temp.ti_log(15,'org_get: Boudaa dir - members = Boudaa uniquement, jamais Redouane','PASS', v_org::text);
  ELSE PERFORM pg_temp.ti_log(15,'org_get: Boudaa dir - members = Boudaa uniquement, jamais Redouane','FAIL', v_org::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_extra_b);
  SELECT count(*) INTO v_cnt FROM employees WHERE id IN (r.v_extra_b, r.v_extra_r);
  IF v_cnt = 1 THEN PERFORM pg_temp.ti_log(16,'portail extra: extra Boudaa ne voit que sa propre fiche (jamais Redouane)','PASS', v_cnt::text);
  ELSE PERFORM pg_temp.ti_log(16,'portail extra: extra Boudaa ne voit que sa propre fiche (jamais Redouane)','FAIL', v_cnt::text); END IF;

  PERFORM pg_temp.ti_as(r.v_auth_extra_r);
  SELECT count(*) INTO v_cnt FROM employees WHERE id IN (r.v_extra_b, r.v_extra_r);
  IF v_cnt = 1 THEN PERFORM pg_temp.ti_log(17,'portail extra: extra Redouane ne voit que sa propre fiche (jamais Boudaa)','PASS', v_cnt::text);
  ELSE PERFORM pg_temp.ti_log(17,'portail extra: extra Redouane ne voit que sa propre fiche (jamais Boudaa)','FAIL', v_cnt::text); END IF;
END $$;

RESET ROLE;

-- 6. group_move_cancellations sous role anon (non authentifié du tout) : ne doit jamais
--    renvoyer de ligne exploitable, que ce soit par RLS (0 ligne) ou par absence de droit
--    (insufficient_privilege) — les deux issues sont une correction acceptable.
DO $$
DECLARE v_cnt int;
BEGIN
  SET LOCAL ROLE anon;
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    SELECT count(*) INTO v_cnt FROM group_move_cancellations;
    IF v_cnt = 0 THEN
      PERFORM pg_temp.ti_log(6,'cancellations: anon (non authentifie) ne voit aucune ligne (RLS)','PASS','0 lignes (attendu, RLS applique meme a anon)');
    ELSE
      PERFORM pg_temp.ti_log(6,'cancellations: anon (non authentifie) ne voit aucune ligne (RLS)','FAIL', 'anon a pu lire '||v_cnt::text||' lignes');
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.ti_log(6,'cancellations: anon (non authentifie) ne voit aucune ligne (RLS)','PASS','insufficient_privilege (variante acceptable)');
  END;
  RESET ROLE;
END $$;

-- ---------------------------------------------------------------------------
-- Rapport final : échoue explicitement (RAISE EXCEPTION) si un seul test a échoué —
-- garantit que ce fichier fait réellement échouer le job CI en cas de régression.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fail int; v_total int;
BEGIN
  SELECT count(*) FILTER (WHERE status <> 'PASS'), count(*) INTO v_fail, v_total FROM ti_results;
  RAISE NOTICE '========================================';
  RAISE NOTICE 'Isolation inter-groupes Planning Groupe : % / % PASS', v_total - v_fail, v_total;
  RAISE NOTICE '========================================';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'FUITE INTER-GROUPES DETECTEE : % test(s) en echec sur %. Detail : %',
      v_fail, v_total, (SELECT string_agg(name || ' -> ' || detail, ' | ') FROM ti_results WHERE status <> 'PASS');
  END IF;
END $$;

ROLLBACK;
