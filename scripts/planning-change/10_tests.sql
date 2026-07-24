-- ============================================================================
-- Tests DB — planning_change_requests (23 cas). Simule les utilisateurs via le
-- GUC request.jwt.claim.sub (auth.uid()). Base reconstruite depuis le dépôt.
-- ============================================================================
\set FO   '22222222-2222-2222-2222-222222222222'
\set VO   '33333333-3333-3333-3333-333333333333'
\set RECEP 'a1111111-1111-1111-1111-111111111111'
\set DIR   'd1111111-1111-1111-1111-111111111111'
\set MGR   'c0111111-1111-1111-1111-111111111111'
\set OTHER 'e1111111-1111-1111-1111-111111111111'
\set EMP   '66666666-6666-6666-6666-666666666666'
\set EMPMGR '77777777-7777-7777-7777-777777777777'

-- ── SEED (admin, auth.uid() NULL => gardes non déclenchées) ───────────────────
INSERT INTO hotel_groups(id,name) VALUES ('11111111-1111-1111-1111-111111111111','G');
INSERT INTO hotels(id,name,group_id,timezone) VALUES (:'FO','Origine','11111111-1111-1111-1111-111111111111','Europe/Paris'),(:'VO','Autre','11111111-1111-1111-1111-111111111111','Europe/Paris');
INSERT INTO users(id,auth_id,hotel_id,email,full_name,role,is_active) VALUES
  ('b1111111-1111-1111-1111-111111111111',:'RECEP',:'FO','recep@f.test','Recep','reception',true),
  ('b2111111-1111-1111-1111-111111111111',:'DIR',:'FO','dir@f.test','Dir','direction',true),
  ('b3111111-1111-1111-1111-111111111111',:'MGR',:'FO','mgr@flowtym.test','Mgr','gouvernante',true),
  ('b4111111-1111-1111-1111-111111111111',:'OTHER',:'VO','other@v.test','Other','direction',true);
INSERT INTO user_hotels(user_id,hotel_id,role) VALUES
  ('b1111111-1111-1111-1111-111111111111',:'FO','reception'),
  ('b2111111-1111-1111-1111-111111111111',:'FO','direction'),
  ('b3111111-1111-1111-1111-111111111111',:'FO','gouvernante'),
  ('b4111111-1111-1111-1111-111111111111',:'VO','direction');
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  (:'EMPMGR',:'FO','Manager','Hierarch','mgr@flowtym.test',NULL),
  (:'EMP',:'FO','Alex','Test','emp@f.test',:'EMPMGR');
-- Journées : passée (2020), aujourd'hui (tz hôtel), future.
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO',:'EMP','2020-01-06','P',1,0);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes)
  SELECT :'FO',:'EMP', public._pcr_today(:'FO'), 'P',1,0;
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes)
  SELECT :'FO',:'EMP', public._pcr_today(:'FO')+1, 'P',1,0;

CREATE TABLE pcr_results(test text, pass boolean, detail text);
CREATE TABLE pcr_ids(name text primary key, id uuid);

-- ── T1/T2 : Réception NE PEUT PAS modifier une journée passée (garde backend) ─
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  BEGIN UPDATE staff_planning SET status='CP' WHERE hotel_id='22222222-2222-2222-2222-222222222222' AND employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-06';
    INSERT INTO pcr_results VALUES('T1/T2',false,'aucune exception');
  EXCEPTION WHEN sqlstate 'FL010' THEN INSERT INTO pcr_results VALUES('T1/T2',true,'FL010 (direct backend refusé)');
    WHEN others THEN INSERT INTO pcr_results VALUES('T1/T2',false,'autre: '||SQLERRM); END;
END $$;

-- ── T3 : Réception peut modifier le jour J ───────────────────────────────────
DO $$ DECLARE d date; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  d := public._pcr_today('22222222-2222-2222-2222-222222222222');
  BEGIN UPDATE staff_planning SET status='CP' WHERE hotel_id='22222222-2222-2222-2222-222222222222' AND employee_id='66666666-6666-6666-6666-666666666666' AND day=d;
    INSERT INTO pcr_results VALUES('T3', (SELECT status='CP' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day=d), 'jour J modifiable');
  EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T3',false,'bloqué: '||SQLERRM); END;
END $$;

-- ── T4 : Réception peut modifier une journée future ──────────────────────────
DO $$ DECLARE d date; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  d := public._pcr_today('22222222-2222-2222-2222-222222222222')+1;
  BEGIN UPDATE staff_planning SET status='CP' WHERE hotel_id='22222222-2222-2222-2222-222222222222' AND employee_id='66666666-6666-6666-6666-666666666666' AND day=d;
    INSERT INTO pcr_results VALUES('T4', (SELECT status='CP' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day=d), 'futur modifiable');
  EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T4',false,'bloqué: '||SQLERRM); END;
END $$;

-- ── T5 : demande sur journée passée créée en « pending » ; T-route manager ────
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-01-06','CP','Oubli de saisie',NULL);
  INSERT INTO pcr_ids VALUES('main',v);
  INSERT INTO pcr_results VALUES('T5', (SELECT status='pending' AND assigned_to='manager' FROM planning_change_requests WHERE id=v), 'pending + routage manager');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T5',false,'erreur: '||SQLERRM); END $$;

-- ── T6 : le planning ne change PAS avant approbation ─────────────────────────
INSERT INTO pcr_results SELECT 'T6', (status='P'), 'statut inchangé ('||status||')' FROM staff_planning WHERE employee_id=:'EMP' AND day='2020-01-06';

-- ── T10 : le demandeur (Réception) ne peut pas approuver sa propre demande ────
DO $$ DECLARE v uuid; BEGIN v:=(SELECT id FROM pcr_ids WHERE name='main');
  PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  BEGIN PERFORM public.planning_change_request_decide(v,'approve'); INSERT INTO pcr_results VALUES('T10',false,'approbation permise !');
  EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T10', SQLERRM LIKE '%demandeur%', 'refus: '||SQLERRM); END;
END $$;

-- ── T11 : un responsable d'un AUTRE établissement ne peut pas traiter ─────────
DO $$ DECLARE v uuid; BEGIN v:=(SELECT id FROM pcr_ids WHERE name='main');
  PERFORM set_config('request.jwt.claim.sub','e1111111-1111-1111-1111-111111111111',true);
  BEGIN PERFORM public.planning_change_request_decide(v,'approve'); INSERT INTO pcr_results VALUES('T11',false,'traitement permis !');
  EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T11', SQLERRM LIKE '%Accès refusé%' OR SQLERRM LIKE '%autre établissement%', 'refus: '||SQLERRM); END;
END $$;

-- ── T12 : demande en doublon (même salarié, même date) bloquée ───────────────
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  BEGIN PERFORM public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-01-06','RTT','autre motif',NULL);
    INSERT INTO pcr_results VALUES('T12',false,'doublon permis !');
  EXCEPTION WHEN sqlstate 'FL011' THEN INSERT INTO pcr_results VALUES('T12',true,'FL011 (doublon bloqué)');
    WHEN others THEN INSERT INTO pcr_results VALUES('T12',false,'autre: '||SQLERRM); END;
END $$;

-- ── T7/T8 : le manager assigné approuve ; statut appliqué + audité ───────────
DO $$ DECLARE v uuid; r jsonb; BEGIN v:=(SELECT id FROM pcr_ids WHERE name='main');
  PERFORM set_config('request.jwt.claim.sub','c0111111-1111-1111-1111-111111111111',true);
  r := public.planning_change_request_decide(v,'approve');
  INSERT INTO pcr_results VALUES('T7', (SELECT status='approved' FROM planning_change_requests WHERE id=v), 'manager approuve');
  INSERT INTO pcr_results VALUES('T8',
    (SELECT status='CP' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-06')
    AND EXISTS(SELECT 1 FROM planning_audit WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-06' AND source='planning_change_request'),
    'appliqué + audité');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T7/T8',false,'erreur: '||SQLERRM); END $$;

-- ── T9 : un Directeur refuse une (nouvelle) demande sans modifier le planning ─
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO',:'EMP','2020-01-07','P',1,0);
DO $$ DECLARE v uuid; BEGIN
  PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-01-07','MAL','arrêt',NULL);
  PERFORM set_config('request.jwt.claim.sub','d1111111-1111-1111-1111-111111111111',true);
  PERFORM public.planning_change_request_decide(v,'reject','non justifié');
  INSERT INTO pcr_results VALUES('T9',
    (SELECT status='rejected' AND reject_reason='non justifié' FROM planning_change_requests WHERE id=v)
    AND (SELECT status='P' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-07'),
    'refus sans modif planning');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T9',false,'erreur: '||SQLERRM); END $$;

-- ── T13 : obsolescence — statut modifié depuis la demande => non écrasé ───────
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO',:'EMP','2020-01-08','P',1,0);
DO $$ DECLARE v uuid; BEGIN
  PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-01-08','CP','x',NULL);
  -- un Directeur modifie directement la journée entre-temps
  PERFORM set_config('request.jwt.claim.sub','d1111111-1111-1111-1111-111111111111',true);
  UPDATE staff_planning SET status='RTT' WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-08';
  PERFORM public.planning_change_request_decide(v,'approve');   -- retourne 'obsolete', n'applique pas
  INSERT INTO pcr_results VALUES('T13',
    (SELECT status='obsolete' FROM planning_change_requests WHERE id=v)
    AND (SELECT status='RTT' FROM staff_planning WHERE employee_id='66666666-6666-6666-6666-666666666666' AND day='2020-01-08'),
    'obsolète (persisté), valeur récente RTT non écrasée');
END $$;

-- ── T14 : « aujourd'hui » selon le fuseau de l'hôtel (pas UTC) ────────────────
INSERT INTO pcr_results SELECT 'T14',
  public._pcr_today(:'FO') = (now() AT TIME ZONE (SELECT timezone FROM hotels WHERE id=:'FO'))::date,
  'today = date locale hôtel ('||public._pcr_today(:'FO')||')';

-- ── T15/T16 : correspondance e-mail insensible casse + espaces => manager ─────
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  ('88888888-0000-0000-0000-000000000015',:'FO','Sub','A','sub15@f.test','99999999-0000-0000-0000-000000000015'),
  ('99999999-0000-0000-0000-000000000015',:'FO','MgrCase','X','  MGR@Flowtym.TEST  ',NULL);  -- casse + espaces
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','88888888-0000-0000-0000-000000000015','2020-02-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','88888888-0000-0000-0000-000000000015','2020-02-01','CP','m',NULL);
  INSERT INTO pcr_results VALUES('T15/T16', (SELECT assigned_to='manager' AND assigned_manager_id='99999999-0000-0000-0000-000000000015' FROM planning_change_requests WHERE id=v), 'match casse+espaces');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T15/T16',false,'err: '||SQLERRM); END $$;

-- ── T17 : manager SANS compte utilisateur => fallback Directeur ──────────────
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  ('88888888-0000-0000-0000-000000000017',:'FO','Sub','B','sub17@f.test','99999999-0000-0000-0000-000000000017'),
  ('99999999-0000-0000-0000-000000000017',:'FO','MgrNoAcct','X','noaccount@f.test',NULL);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','88888888-0000-0000-0000-000000000017','2020-02-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','88888888-0000-0000-0000-000000000017','2020-02-01','CP','m',NULL);
  INSERT INTO pcr_results VALUES('T17', (SELECT assigned_to='director' AND assigned_manager_id IS NULL FROM planning_change_requests WHERE id=v), 'fallback directeur (pas de compte)');
  INSERT INTO pcr_results VALUES('T20', v IS NOT NULL, 'demande créée malgré absence de compte manager');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T17',false,'err: '||SQLERRM); END $$;

-- ── T18 : manager avec compte INACTIF => fallback Directeur ──────────────────
INSERT INTO users(id,auth_id,hotel_id,email,full_name,role,is_active) VALUES ('c8111111-1111-1111-1111-111111111111','c8111111-1111-1111-1111-111111111111',:'FO','inactif@f.test','Inactif','gouvernante',false);
INSERT INTO user_hotels(user_id,hotel_id,role) VALUES ('c8111111-1111-1111-1111-111111111111',:'FO','gouvernante');
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  ('88888888-0000-0000-0000-000000000018',:'FO','Sub','C','sub18@f.test','99999999-0000-0000-0000-000000000018'),
  ('99999999-0000-0000-0000-000000000018',:'FO','MgrInactif','X','inactif@f.test',NULL);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','88888888-0000-0000-0000-000000000018','2020-02-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','88888888-0000-0000-0000-000000000018','2020-02-01','CP','m',NULL);
  INSERT INTO pcr_results VALUES('T18', (SELECT assigned_to='director' FROM planning_change_requests WHERE id=v), 'fallback directeur (compte inactif)');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T18',false,'err: '||SQLERRM); END $$;

-- ── T19 : correspondance AMBIGUË (2 comptes actifs même e-mail) => fallback ───
INSERT INTO users(id,auth_id,hotel_id,email,full_name,role,is_active) VALUES
  ('c9111111-1111-1111-1111-111111111111','c9111111-1111-1111-1111-111111111111',:'FO','ambigu@f.test','A1','gouvernante',true),
  ('ca111111-1111-1111-1111-111111111111','ca111111-1111-1111-1111-111111111111',:'FO','ambigu@f.test','A2','gouvernante',true);
INSERT INTO user_hotels(user_id,hotel_id,role) VALUES ('c9111111-1111-1111-1111-111111111111',:'FO','gouvernante'),('ca111111-1111-1111-1111-111111111111',:'FO','gouvernante');
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  ('88888888-0000-0000-0000-000000000019',:'FO','Sub','D','sub19@f.test','99999999-0000-0000-0000-000000000019'),
  ('99999999-0000-0000-0000-000000000019',:'FO','MgrAmbigu','X','ambigu@f.test',NULL);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','88888888-0000-0000-0000-000000000019','2020-02-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','88888888-0000-0000-0000-000000000019','2020-02-01','CP','m',NULL);
  INSERT INTO pcr_results VALUES('T19', (SELECT assigned_to='director' AND assigned_manager_id IS NULL FROM planning_change_requests WHERE id=v), 'fallback directeur (ambigu, aucun choix arbitraire)');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T19',false,'err: '||SQLERRM); END $$;

-- ── T21 : le Directeur peut approuver même si un manager valide est assigné ───
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO',:'EMP','2020-03-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','66666666-6666-6666-6666-666666666666','2020-03-01','CP','m',NULL);
  PERFORM set_config('request.jwt.claim.sub','d1111111-1111-1111-1111-111111111111',true);  -- Directeur
  PERFORM public.planning_change_request_decide(v,'approve');
  INSERT INTO pcr_results VALUES('T21', (SELECT status='approved' AND assigned_to='manager' FROM planning_change_requests WHERE id=v), 'directeur approuve malgré manager assigné');
EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T21',false,'err: '||SQLERRM); END $$;

-- ── T22 : changement de manager après création ne modifie pas assigned_manager_id ─
DO $$ DECLARE v uuid; before uuid; BEGIN
  v:=(SELECT id FROM pcr_ids WHERE name='main'); before:=(SELECT assigned_manager_id FROM planning_change_requests WHERE id=v);
  UPDATE employees SET manager_id=NULL WHERE id='66666666-6666-6666-6666-666666666666';  -- change hiérarchie
  INSERT INTO pcr_results VALUES('T22', (SELECT assigned_manager_id FROM planning_change_requests WHERE id=v) IS NOT DISTINCT FROM before AND before IS NOT NULL, 'assigned figé malgré changement manager');
END $$;

-- ── T23 : compte e-mail correspondant mais HORS périmètre hôtel => pas d'approbation ─
-- Manager dont l'e-mail correspond à un user présent uniquement sur VO (autre hôtel).
INSERT INTO users(id,auth_id,hotel_id,email,full_name,role,is_active) VALUES ('cb111111-1111-1111-1111-111111111111','cb111111-1111-1111-1111-111111111111',:'VO','crosshotel@f.test','Cross','gouvernante',true);
INSERT INTO user_hotels(user_id,hotel_id,role) VALUES ('cb111111-1111-1111-1111-111111111111',:'VO','gouvernante');
INSERT INTO employees(id,hotel_id,first_name,last_name,email,manager_id) VALUES
  ('88888888-0000-0000-0000-000000000023',:'FO','Sub','E','sub23@f.test','99999999-0000-0000-0000-000000000023'),
  ('99999999-0000-0000-0000-000000000023',:'FO','MgrCross','X','crosshotel@f.test',NULL);
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'FO','88888888-0000-0000-0000-000000000023','2020-04-01','P',1,0);
DO $$ DECLARE v uuid; BEGIN PERFORM set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
  v := public.planning_change_request_create('22222222-2222-2222-2222-222222222222','88888888-0000-0000-0000-000000000023','2020-04-01','CP','m',NULL);
  -- routage : compte hors périmètre FO => fallback director attendu
  INSERT INTO pcr_results VALUES('T23-route', (SELECT assigned_to='director' FROM planning_change_requests WHERE id=v), 'compte hors hôtel => fallback director');
  -- et le compte cross ne peut pas approuver (hors périmètre + pas manager assigné)
  PERFORM set_config('request.jwt.claim.sub','cb111111-1111-1111-1111-111111111111',true);
  BEGIN PERFORM public.planning_change_request_decide(v,'approve'); INSERT INTO pcr_results VALUES('T23',false,'approbation hors périmètre permise !');
  EXCEPTION WHEN others THEN INSERT INTO pcr_results VALUES('T23', true, 'refus hors périmètre: '||SQLERRM); END;
END $$;
