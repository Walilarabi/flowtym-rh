-- ============================================================================
-- SEED FICTIF minimal (aucune donnée de production / personnelle réelle).
-- 1 groupe, 2 hôtels (FO origine / VO destination), 1 manager (accès aux 2),
-- 1 collaborateur, 1 temps de trajet, propositions A/B/C1/C2/D1/D2/E/F/G.
-- Workflow [] => auto-approbation. Chaque scénario a son propre jour (indépendance).
-- ============================================================================
\set MGR   '55555555-5555-5555-5555-555555555555'
\set FO    '22222222-2222-2222-2222-222222222222'
\set VO    '33333333-3333-3333-3333-333333333333'
\set EMP   '66666666-6666-6666-6666-666666666666'

SELECT set_config('request.jwt.claim.sub', :'MGR', false);

INSERT INTO hotel_groups(id,name,features) VALUES ('11111111-1111-1111-1111-111111111111','Groupe Test','{}'::jsonb);
INSERT INTO hotels(id,name,city,group_id) VALUES
  (:'FO','Hôtel Origine','Paris','11111111-1111-1111-1111-111111111111'),
  (:'VO','Hôtel Destination','Paris','11111111-1111-1111-1111-111111111111');
INSERT INTO users(id,auth_id,full_name,email) VALUES ('44444444-4444-4444-4444-444444444444',:'MGR','Manager Test','mgr@test.local');
INSERT INTO user_hotels(user_id,hotel_id) VALUES ('44444444-4444-4444-4444-444444444444',:'FO'),('44444444-4444-4444-4444-444444444444',:'VO');
INSERT INTO employees(id,first_name,last_name) VALUES (:'EMP','Alex','Test');
INSERT INTO hotel_travel_times(from_hotel_id,to_hotel_id,duration_min,safety_margin_min) VALUES (:'FO',:'VO',20,10);

-- Workflow vide => auto-approuvé (pas d'approbateur).
SELECT group_move_workflow_set('11111111-1111-1111-1111-111111111111','[]'::jsonb);

-- Grille origine préexistante (P 08:00-16:00) pour tous les jours SAUF E.
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES
  (:'FO',:'EMP','2035-06-02','P',1,0,'J','08:00','16:00'),  -- A
  (:'FO',:'EMP','2035-06-03','P',1,0,'J','08:00','16:00'),  -- B
  (:'FO',:'EMP','2035-06-04','P',1,0,'J','08:00','16:00'),  -- C
  (:'FO',:'EMP','2035-06-05','P',1,0,'J','08:00','16:00'),  -- D1
  (:'FO',:'EMP','2035-06-06','P',1,0,'J','08:00','16:00'),  -- D2
  (:'FO',:'EMP','2035-06-11','P',1,0,'J','08:00','16:00'),  -- F
  (:'FO',:'EMP','2035-06-12','P',1,0,'J','08:00','16:00');  -- G
-- (jour E 2035-06-10 : AUCUNE ligne staff_planning, par conception du scénario E)

CREATE TABLE IF NOT EXISTS cc_map(name text PRIMARY KEY, pid uuid, day date);

CREATE OR REPLACE FUNCTION cc_prep(p_name text, p_day date) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  v := group_move_proposal_create(jsonb_build_object(
    'employee_id','66666666-6666-6666-6666-666666666666',
    'from_hotel_id','22222222-2222-2222-2222-222222222222',
    'to_hotel_id','33333333-3333-3333-3333-333333333333',
    'to_service','Réception','from_service','Réception',
    'period_from',p_day::text,'period_to',p_day::text,
    'slots', jsonb_build_array(jsonb_build_object('date',p_day::text)),
    'decision','allowed','simulation',jsonb_build_object('blockers','[]'::jsonb)));
  PERFORM group_move_proposal_submit(v);
  INSERT INTO cc_map(name,pid,day) VALUES (p_name,v,p_day);
  RETURN v;
END $$;

SELECT cc_prep('A','2035-06-02');
SELECT cc_prep('B','2035-06-03');
SELECT cc_prep('C1','2035-06-04');
SELECT cc_prep('C2','2035-06-04');
SELECT cc_prep('D1','2035-06-05');
SELECT cc_prep('D2','2035-06-06');
SELECT cc_prep('E','2035-06-10');
SELECT cc_prep('F','2035-06-11');
SELECT cc_prep('G','2035-06-12');

SELECT name, pid, day, (SELECT status FROM group_move_proposals p WHERE p.id=cc_map.pid) status FROM cc_map ORDER BY name;
