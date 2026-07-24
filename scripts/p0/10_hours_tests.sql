-- ============================================================================
-- SEED + TESTS P0 (fictif). Flag hours.source=segments. Garde-fou paie actif.
-- ============================================================================
\set MGR '55555555-5555-5555-5555-555555555555'
\set FO  '22222222-2222-2222-2222-222222222222'
\set VO  '33333333-3333-3333-3333-333333333333'
\set EMP '66666666-6666-6666-6666-666666666666'
SELECT set_config('request.jwt.claim.sub', :'MGR', false);

INSERT INTO hotel_groups(id,name,features) VALUES ('11111111-1111-1111-1111-111111111111','Groupe Test','{}'::jsonb);
INSERT INTO hotels(id,name,city,group_id) VALUES (:'FO','Origine','Paris','11111111-1111-1111-1111-111111111111'),(:'VO','Destination','Paris','11111111-1111-1111-1111-111111111111');
INSERT INTO users(id,auth_id,full_name,email) VALUES ('44444444-4444-4444-4444-444444444444',:'MGR','Mgr','m@t.l');
INSERT INTO user_hotels(user_id,hotel_id) VALUES ('44444444-4444-4444-4444-444444444444',:'FO'),('44444444-4444-4444-4444-444444444444',:'VO');
INSERT INTO employees(id,first_name,last_name) VALUES (:'EMP','Alex','Test');
INSERT INTO staff_departments(hotel_id,name) VALUES (:'FO','Réception'),(:'VO','Réception');
INSERT INTO hotel_travel_times(from_hotel_id,to_hotel_id,duration_min,safety_margin_min) VALUES (:'FO',:'VO',20,10);
SELECT group_move_workflow_set('11111111-1111-1111-1111-111111111111','[]'::jsonb);

-- Active le moteur segments pour le groupe (flag), journalisé.
SELECT set_group_hours_source('11111111-1111-1111-1111-111111111111','segments');

CREATE TABLE p0_results(test text, intitule text, attendu text, obtenu text, pass boolean);
CREATE OR REPLACE FUNCTION chk(p_test text, p_lbl text, p_exp text, p_got text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO p0_results VALUES(p_test,p_lbl,p_exp,p_got,p_exp IS NOT DISTINCT FROM p_got);
$$;

-- helper move : crée+soumet+applique une proposition (slot avec start/end)
CREATE OR REPLACE FUNCTION mv(p_day date, p_start text, p_end text, p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v uuid; slot jsonb;
BEGIN
  slot := jsonb_build_object('date',p_day::text);
  IF p_start IS NOT NULL THEN slot := slot || jsonb_build_object('start',p_start,'end',p_end); END IF;
  v := group_move_proposal_create(jsonb_build_object('employee_id','66666666-6666-6666-6666-666666666666',
    'from_hotel_id','22222222-2222-2222-2222-222222222222','to_hotel_id','33333333-3333-3333-3333-333333333333',
    'to_service','Réception','from_service','Réception','period_from',p_day::text,'period_to',p_day::text,
    'slots',jsonb_build_array(slot),'decision','allowed','simulation',jsonb_build_object('blockers','[]'::jsonb)));
  PERFORM group_move_proposal_submit(v);
  RETURN group_move_apply(v, p_key);
END $$;

-- ── T1 journée complète 1 hôtel (VO 08-16 = 8h) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-01',480,960,'destination','PE');
SELECT chk('T1','journée complète 1 hôtel (VO 08-16)','8.00 hotels=1', (staff_hours_day(:'EMP','2035-07-01')->>'net_hours')||' hotels='||jsonb_array_length(staff_hours_day(:'EMP','2035-07-01')->'by_hotel'));

-- ── T2 journée partielle (VO 09-13 = 4h) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-02',540,780,'destination','PE');
SELECT chk('T2','journée partielle (VO 09-13)','4.00', (staff_hours_day(:'EMP','2035-07-02')->>'net_hours'));

-- ── T3 deux segments même hôtel + pause (VO 08-12 & 14-18 = 8h net, 2h pause) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-03',480,720,'destination','PE'),(:'VO',:'EMP','2035-07-03',840,1080,'destination','PE');
SELECT chk('T3','2 segments même hôtel + pause','8.00 pause=2.00 brut=10.00',
  (staff_hours_day(:'EMP','2035-07-03')->>'net_hours')||' pause='||(staff_hours_day(:'EMP','2035-07-03')->>'break_hours')||' brut='||(staff_hours_day(:'EMP','2035-07-03')->>'gross_hours'));

-- ── T4 deux segments deux hôtels (FO 08-12 + VO 13-17 = 8h, pas de doublon) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'FO',:'EMP','2035-07-04',480,720,'origin','P'),(:'VO',:'EMP','2035-07-04',780,1020,'destination','PE');
SELECT chk('T4','2 hôtels même jour','8.00 hotels=2', (staff_hours_day(:'EMP','2035-07-04')->>'net_hours')||' hotels='||jsonb_array_length(staff_hours_day(:'EMP','2035-07-04')->'by_hotel'));

-- ── T5 déplacement réduisant l'origine (slot 08-12 ; origine gardée 12-16) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES (:'FO',:'EMP','2035-07-05','P',1,0,'J','08:00','16:00');
SELECT mv('2035-07-05','08:00','12:00','K-T5');
SELECT chk('T5','déplacement réduit origine','8.00 FO=4.00 VO=4.00',
  (staff_hours_day(:'EMP','2035-07-05')->>'net_hours')
  ||' FO='||(SELECT hours::text FROM staff_segment_hours(:'EMP','2035-07-05') WHERE hotel_id=:'FO')
  ||' VO='||(SELECT hours::text FROM staff_segment_hours(:'EMP','2035-07-05') WHERE hotel_id=:'VO'));

-- ── T6 déplacement coupant au milieu (slot 11-13 ; origine 08-11 + 13-16) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES (:'FO',:'EMP','2035-07-06','P',1,0,'J','08:00','16:00');
SELECT mv('2035-07-06','11:00','13:00','K-T6');
SELECT chk('T6','déplacement coupe au milieu','8.00 origine_segs=2 FO=6.00 VO=2.00',
  (staff_hours_day(:'EMP','2035-07-06')->>'net_hours')
  ||' origine_segs='||(SELECT count(*)::text FROM staff_planning_segments WHERE employee_id=:'EMP' AND day='2035-07-06' AND kind='origin')
  ||' FO='||(SELECT hours::text FROM staff_segment_hours(:'EMP','2035-07-06') WHERE hotel_id=:'FO')
  ||' VO='||(SELECT hours::text FROM staff_segment_hours(:'EMP','2035-07-06') WHERE hotel_id=:'VO'));

-- ── T7 pause unique = T3 (déjà couvert) : ré-assert pause unique ──
SELECT chk('T7','pause unique (=T3)','2.00', (staff_hours_day(:'EMP','2035-07-03')->>'break_hours'));

-- ── T8 plusieurs pauses (VO 08-10,12-14,16-18 = 6h net, 4h pause) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-08',480,600,'destination','PE'),(:'VO',:'EMP','2035-07-08',720,840,'destination','PE'),(:'VO',:'EMP','2035-07-08',960,1080,'destination','PE');
SELECT chk('T8','plusieurs pauses','6.00 pause=4.00', (staff_hours_day(:'EMP','2035-07-08')->>'net_hours')||' pause='||(staff_hours_day(:'EMP','2035-07-08')->>'break_hours'));

-- ── T9 passage minuit = 2 segments 2 jours (22-24 puis 00-06) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-09',1320,1440,'destination','PE'),(:'VO',:'EMP','2035-07-10',0,360,'destination','PE');
SELECT chk('T9','minuit = 2 segments/2 jours','2.00 6.00', (staff_hours_day(:'EMP','2035-07-09')->>'net_hours')||' '||(staff_hours_day(:'EMP','2035-07-10')->>'net_hours'));

-- ── T11 absence partielle (matin travaillé 08-12, après-midi absent) ──
INSERT INTO staff_planning_segments(hotel_id,employee_id,day,seg_start_min,seg_end_min,kind,status) VALUES (:'VO',:'EMP','2035-07-11',480,720,'destination','PE');
INSERT INTO staff_absences(hotel_id,employee_id,type,start_date,end_date) VALUES (:'VO',:'EMP','CP','2035-07-11','2035-07-11');
SELECT chk('T11','absence partielle (matin travaillé)','4.00', (staff_hours_day(:'EMP','2035-07-11')->>'net_hours'));

-- ── T12 journée non travaillée (grille MAD, aucun segment) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes) VALUES (:'VO',:'EMP','2035-07-12','MAD',1,0);
SELECT chk('T12','journée non travaillée','0.00', (staff_hours_day(:'EMP','2035-07-12')->>'net_hours'));

-- ── T14 reconstruction depuis segments (build via move, delete grille, rebuild) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES (:'FO',:'EMP','2035-07-14','P',1,0,'J','08:00','16:00');
SELECT mv('2035-07-14','08:00','12:00','K-T14');
-- net avant reconstruction (segments = source de vérité)
CREATE TEMP TABLE _t14 AS SELECT (staff_hours_day(:'EMP','2035-07-14')->>'net_hours') AS before;
-- supprime la projection grille puis reconstruit
DELETE FROM staff_planning WHERE employee_id=:'EMP' AND day='2035-07-14';
SELECT staff_planning_rebuild_day(:'EMP','2035-07-14');
SELECT chk('T14','reconstruction depuis segments','8.00',
  (SELECT before FROM _t14)||CASE WHEN (SELECT before FROM _t14)=(staff_hours_day(:'EMP','2035-07-14')->>'net_hours') THEN '' ELSE ' DIVERGE' END);

-- ── T15 cas historique compatible (grille 08-16, aucun segment) ──
-- Le canonical doit égaler la valeur legacy (8h) sur un jour non déplacé.
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES (:'VO',:'EMP','2035-07-15','P',1,0,'J','08:00','16:00');
SELECT chk('T15','parité legacy jour compatible','8.00 legacy=8.00',
  (staff_hours_day(:'EMP','2035-07-15')->>'net_hours')||' legacy='||staff_day_hours(:'EMP','2035-07-15')::text);

-- ── T10 aucun doublon (total cross-hôtel après déplacement complet = 8h, pas 16) ──
INSERT INTO staff_planning(hotel_id,employee_id,day,status,duration,break_minutes,shift_label,shift_start,shift_end) VALUES (:'FO',:'EMP','2035-07-16','P',1,0,'J','08:00','16:00');
SELECT mv('2035-07-16',NULL,NULL,'K-T10');  -- déplacement journée complète
SELECT chk('T10','aucun doublon (jour complet déplacé)','8.00', (staff_hours_day(:'EMP','2035-07-16')->>'net_hours'));

-- ── service_id : ventilation présente après déplacement (T5) ──
SELECT chk('SVC','ventilation par service_id (T5)','2 total=8.00',
  jsonb_array_length(staff_hours_day(:'EMP','2035-07-05')->'by_service')::text||' total='||
  (SELECT round(sum((e->>'net_hours')::numeric),2)::text FROM jsonb_array_elements(staff_hours_day(:'EMP','2035-07-05')->'by_service') e));

-- ── T-semaine (agrégat) : semaine du 2035-07-01 (lun) — T1..T? net sommés ──
SELECT chk('WEEK','agrégat semaine 01-07/07','total>=0 & jours=7',
  CASE WHEN (staff_hours_week(:'EMP','2035-07-01')->>'total_net')::numeric >= 0
        AND jsonb_array_length(staff_hours_week(:'EMP','2035-07-01')->'days')=7 THEN 'total>=0 & jours=7' ELSE 'KO' END);
