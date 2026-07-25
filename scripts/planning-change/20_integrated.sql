-- ============================================================================
-- Validation intégrée : RLS RÉELLEMENT appliquée (rôle authenticated), confidentialité
-- des notifications, fuseau near-minuit, atomicité de l'audit. Après 10_tests.sql.
-- ============================================================================
\set FO   '22222222-2222-2222-2222-222222222222'
\set VO   '33333333-3333-3333-3333-333333333333'
\set RECEP 'a1111111-1111-1111-1111-111111111111'
\set DIR   'd1111111-1111-1111-1111-111111111111'
\set OTHER 'e1111111-1111-1111-1111-111111111111'
\set RECEPVO 'f1111111-1111-1111-1111-111111111111'

-- Prod accorde à authenticated la lecture de users/user_hotels (l'app les interroge) ;
-- on le reproduit pour évaluer les policies RLS (qui référencent ces tables).
GRANT SELECT ON public.users, public.user_hotels, public.platform_admins, public.hotels TO authenticated;

-- Compte Réception + demande côté VO (tests de cloisonnement).
INSERT INTO users(id,auth_id,hotel_id,email,full_name,role,is_active) VALUES ('bf111111-1111-1111-1111-111111111111',:'RECEPVO',:'VO','recepvo@v.test','RecepVO','reception',true);
INSERT INTO user_hotels(user_id,hotel_id,role) VALUES ('bf111111-1111-1111-1111-111111111111',:'VO','reception');
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES ('6a666666-0000-0000-0000-0000000000aa',:'VO','Vo','Emp','voemp@v.test',NULL);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'VO','6a666666-0000-0000-0000-0000000000aa','2020-05-01','P',1,0);
SELECT set_config('request.jwt.claim.sub',:'RECEPVO',false);
SELECT public.planning_change_request_create(:'VO','6a666666-0000-0000-0000-0000000000aa','2020-05-01','CP','vo motif',NULL);
SELECT set_config('request.jwt.claim.sub','',false);

-- ── RLS-7 : Réception FO ne voit PAS les demandes VO ──
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub',:'RECEP',true);
SELECT (count(*)=0) AS pass, 'VO visibles='||count(*)::text AS detail FROM planning_change_requests WHERE hotel_id=:'VO' \gset
COMMIT;
INSERT INTO pcr_results VALUES('RLS-7 (récep FO ne voit pas VO)', :'pass'::boolean, :'detail');

-- ── RLS-own : Réception FO ne voit QUE ses propres demandes ──
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub',:'RECEP',true);
SELECT (count(*) FILTER (WHERE requested_by <> :'RECEP')=0 AND count(*)>0) AS pass,
       'total='||count(*)::text||' dont autrui='||count(*) FILTER (WHERE requested_by <> :'RECEP')::text AS detail
  FROM planning_change_requests \gset
COMMIT;
INSERT INTO pcr_results VALUES('RLS-own (récep = ses demandes)', :'pass'::boolean, :'detail');

-- ── RLS-dir : Directeur FO voit FO, pas VO ──
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub',:'DIR',true);
SELECT (count(*) FILTER (WHERE hotel_id=:'FO')>0 AND count(*) FILTER (WHERE hotel_id=:'VO')=0) AS pass,
       'FO='||count(*) FILTER (WHERE hotel_id=:'FO')::text||' VO='||count(*) FILTER (WHERE hotel_id=:'VO')::text AS detail
  FROM planning_change_requests \gset
COMMIT;
INSERT INTO pcr_results VALUES('RLS-dir (directeur FO voit FO, pas VO)', :'pass'::boolean, :'detail');

-- ── RLS-cross : Directeur VO ne voit pas FO ──
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub',:'OTHER',true);
SELECT (count(*) FILTER (WHERE hotel_id=:'FO')=0 AND count(*) FILTER (WHERE hotel_id=:'VO')>0) AS pass,
       'FO='||count(*) FILTER (WHERE hotel_id=:'FO')::text||' VO='||count(*) FILTER (WHERE hotel_id=:'VO')::text AS detail
  FROM planning_change_requests \gset
COMMIT;
INSERT INTO pcr_results VALUES('RLS-cross (VO ne voit pas FO)', :'pass'::boolean, :'detail');

-- ── NOTIF-26a : aucun champ confidentiel dans la table notifications ──
INSERT INTO pcr_results SELECT 'NOTIF-26a (aucun champ confidentiel)',
  NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='planning_change_notifications'
    AND column_name IN ('reason','comment','email','phone','first_name','last_name','current_status','requested_status')),
  'colonnes='||(SELECT string_agg(column_name,',') FROM information_schema.columns WHERE table_name='planning_change_notifications');

-- ── NOTIF-26b : RLS notifications cloisonnée par hôtel ──
BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub',:'RECEP',true);
SELECT (count(*)=0) AS pass, 'notif VO visibles='||count(*)::text AS detail FROM planning_change_notifications WHERE hotel_id=:'VO' \gset
COMMIT;
INSERT INTO pcr_results VALUES('NOTIF-26b (notif VO invisibles à FO)', :'pass'::boolean, :'detail');

-- ── TZ-28 : near-minuit — divergence des dates locales selon hotels.timezone ──
INSERT INTO hotels(id,name,timezone) VALUES ('c1000000-0000-0000-0000-0000000000e1','KiriTZ','Pacific/Kiritimati'),('c2000000-0000-0000-0000-0000000000e2','Gmt12TZ','Etc/GMT+12');
INSERT INTO pcr_results SELECT 'TZ-28 (near-minuit +14 vs -12)',
  (public._pcr_today('c1000000-0000-0000-0000-0000000000e1') - public._pcr_today('c2000000-0000-0000-0000-0000000000e2')) BETWEEN 1 AND 2,
  '+14='||public._pcr_today('c1000000-0000-0000-0000-0000000000e1')::text||' / -12='||public._pcr_today('c2000000-0000-0000-0000-0000000000e2')::text;

-- ── ATOM-18 : erreur pendant l'audit => aucune écriture partielle (atomicité) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','66666666-6666-6666-6666-666666666666','2020-06-02','P',1,0);
DO $$ DECLARE v uuid; BEGIN
  PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-06-02','CP','atom',NULL);
  INSERT INTO pcr_ids VALUES('atom',v);
END $$;
-- casse l'audit UNIQUEMENT pour les nouvelles lignes (NOT VALID)
ALTER TABLE planning_audit ADD CONSTRAINT _tmp_atom CHECK (action <> 'update') NOT VALID;
DO $$ DECLARE v uuid; BEGIN v:=(SELECT id FROM pcr_ids WHERE name='atom');
  PERFORM set_config('request.jwt.claim.sub','d1111111-1111-1111-1111-111111111111',true);
  BEGIN PERFORM public.planning_change_request_decide(v,'approve'); INSERT INTO pcr_results VALUES('ATOM-18',false,'approbation passée malgré échec audit !');
  EXCEPTION WHEN others THEN
    INSERT INTO pcr_results VALUES('ATOM-18',
      (SELECT status='P' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-06-02')
      AND (SELECT status='pending' FROM planning_change_requests WHERE id=v),
      'échec audit -> aucune écriture partielle (planning=P, demande=pending)');
  END;
END $$;
ALTER TABLE planning_audit DROP CONSTRAINT _tmp_atom;
