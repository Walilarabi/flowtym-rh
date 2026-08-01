-- =============================================================================
-- Tests SQL de sql/66_pointage_daily_summary.sql — pointage_range_summary().
-- Se lance après sql/tests/pointage_hardening.sql (schéma déjà en place).
-- Chaque bloc DO $$ ... $$ termine par un RAISE NOTICE 'OK …'.
-- =============================================================================

-- Nettoyage SCOPÉ à nos propres identifiants (préfixe d1/d2/d0a/d5c) : ce
-- fichier s'exécute après sql/tests/pointage_hardening.sql dans le runner
-- CI, dont les fixtures (hôtels 111.../222.../333..., employé e000...) sont
-- réutilisées PLUS TARD par scripts/test-pointage-concurrency.sh. Un DELETE
-- FROM public.hotels non scopé les détruirait (régression constatée).
-- Deletes explicites (pas uniquement CASCADE) : le schéma minimal CI ne met
-- pas toujours de FK hotel_id sur staff_planning/staff_clockings.
DELETE FROM public.staff_clocking_idempotency WHERE clocking_id IN (
  SELECT id FROM public.staff_clockings
   WHERE hotel_id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002')
);
DELETE FROM public.staff_clockings
 WHERE hotel_id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002');
DELETE FROM public.staff_planning
 WHERE hotel_id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002');
DELETE FROM public.department_schedules
 WHERE hotel_id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002');
DELETE FROM public.employees
 WHERE hotel_id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002');
DELETE FROM public.user_hotels WHERE user_id = 'd0a00001-0000-0000-0000-000000000001';
DELETE FROM public.users WHERE id = 'd0a00001-0000-0000-0000-000000000001';
DELETE FROM public.hotels
 WHERE id IN ('d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002');

INSERT INTO public.hotels(id, name, timezone, qr_clocking_enabled) VALUES
  ('d1000000-0000-0000-0000-000000000001', 'Hotel Paris', 'Europe/Paris', true),
  ('d2000000-0000-0000-0000-000000000002', 'Hotel Nice',  'Europe/Paris', true);

INSERT INTO public.users(id, auth_id, email, full_name, first_name, last_name) VALUES
  ('d0a00001-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000d0a01','manager.paris@x.fr','Manager Paris','Manager','Paris');
INSERT INTO public.user_hotels(user_id, hotel_id) VALUES
  ('d0a00001-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001');

INSERT INTO public.employees(id, hotel_id, first_name, last_name, active) VALUES
  ('d1e00001-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','Cas1','RetardRattrape',true),
  ('d1e00002-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000001','Cas2','RetardPartiel', true),
  ('d1e00003-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000001','Cas3','PartAnticipe',  true),
  ('d1e00004-0000-0000-0000-000000000004','d1000000-0000-0000-0000-000000000001','Cas4','RetardEtAnticipe',true),
  ('d1e00005-0000-0000-0000-000000000005','d1000000-0000-0000-0000-000000000001','Cas5','Avance',        true),
  ('d1e00006-0000-0000-0000-000000000006','d1000000-0000-0000-0000-000000000001','Cas6','SessionOuverte',true),
  ('d1e00007-0000-0000-0000-000000000007','d1000000-0000-0000-0000-000000000001','Cas7','SansPlanNiHoraire',true),
  ('d1e00008-0000-0000-0000-000000000008','d1000000-0000-0000-0000-000000000001','Cas8','HoraireParDefaut',true),
  ('d1e00009-0000-0000-0000-000000000009','d1000000-0000-0000-0000-000000000001','Cas9','TraverseMinuit',true),
  ('d1e00010-0000-0000-0000-000000000010','d1000000-0000-0000-0000-000000000001','Cas10','PlanifieNonPointe',true),
  -- Extra : hôtel principal = Nice, vient pointer/travailler à Paris.
  ('d2e00011-0000-0000-0000-000000000011','d2000000-0000-0000-0000-000000000002','Cas11','ExtraDepuisNice',true),
  -- Mise à disposition : hôtel principal = Nice, planifiée 'MAD' à Paris,
  -- n'a PAS ENCORE pointé — cas réel Karima OULSAADA (Grand Hôtel du Havre
  -- → Folkestone opera, 2026-07-28), absente du menu Pointage avant ce fix.
  ('d2e00012-0000-0000-0000-000000000012','d2000000-0000-0000-0000-000000000002','Cas12','MiseADisposition',true);

INSERT INTO public.department_schedules(id, hotel_id, name, default_start_time, default_end_time) VALUES
  ('d5c00001-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','Réception 09h-17h','09:00','17:00');
UPDATE public.employees SET schedule_id='d5c00001-0000-0000-0000-000000000001' WHERE id='d1e00008-0000-0000-0000-000000000008';

-- ── Cas 1 : retard 15 min, rattrapage 15 min → solde = 0 ────────────────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00001-0000-0000-0000-000000000001','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00001-0000-0000-0000-000000000001','2026-01-12',
   '2026-01-12 08:15:00+01','2026-01-12 16:15:00+01','manual');

-- ── Cas 2 : retard 15 min, rattrapage 5 min → solde = +10 ───────────────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00002-0000-0000-0000-000000000002','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00002-0000-0000-0000-000000000002','2026-01-12',
   '2026-01-12 08:15:00+01','2026-01-12 16:05:00+01','manual');

-- ── Cas 3 : à l'heure, part 20 min plus tôt → solde = +20 ───────────────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00003-0000-0000-0000-000000000003','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00003-0000-0000-0000-000000000003','2026-01-12',
   '2026-01-12 08:00:00+01','2026-01-12 15:40:00+01','manual');

-- ── Cas 4 : retard 10 min ET part 15 min plus tôt → solde = +25 (cumul) ─────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00004-0000-0000-0000-000000000004','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00004-0000-0000-0000-000000000004','2026-01-12',
   '2026-01-12 08:10:00+01','2026-01-12 15:45:00+01','manual');

-- ── Cas 5 : part 12 min plus tard sans retard → solde = -12 (avance) ────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00005-0000-0000-0000-000000000005','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00005-0000-0000-0000-000000000005','2026-01-12',
   '2026-01-12 08:00:00+01','2026-01-12 16:12:00+01','manual');

-- ── Cas 6 : session encore ouverte (pas de clock_out) ───────────────────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00006-0000-0000-0000-000000000006','2026-01-12','P','08:00','16:00');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00006-0000-0000-0000-000000000006','2026-01-12',
   '2026-01-12 08:20:00+01', NULL, 'manual');

-- ── Cas 7 : aucun plan, aucun horaire par défaut, mais a pointé (extra libre) ──
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00007-0000-0000-0000-000000000007','2026-01-12',
   '2026-01-12 09:05:00+01','2026-01-12 17:00:00+01','manual');

-- ── Cas 8 : pas de shift_start/end du jour, mais schedule_id → default_* ────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00008-0000-0000-0000-000000000008','2026-01-12','P');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00008-0000-0000-0000-000000000008','2026-01-12',
   '2026-01-12 09:10:00+01','2026-01-12 17:00:00+01','manual');

-- ── Cas 9 : service de nuit traversant minuit (prévu 23:50 → réel 00:10) ────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00009-0000-0000-0000-000000000009','2026-01-12','P','21:00','23:50');
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00009-0000-0000-0000-000000000009','2026-01-12',
   '2026-01-12 21:00:00+01','2026-01-13 00:10:00+01','manual');

-- ── Cas 10 : planifié P mais n'a pas encore pointé ──────────────────────────
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status, shift_start, shift_end) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1e00010-0000-0000-0000-000000000010','2026-01-12','P','08:00','16:00');

-- ── Cas 11 : extra venu d'un autre hôtel, pointe à Paris sans plan Paris ────
INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source) VALUES
  ('d1000000-0000-0000-0000-000000000001','d2e00011-0000-0000-0000-000000000011','2026-01-12',
   '2026-01-12 10:00:00+01','2026-01-12 18:00:00+01','manual');

-- ── Cas 12 : mise à disposition (MAD) planifiée à Paris, pas encore pointée ─
INSERT INTO public.staff_planning(hotel_id, employee_id, day, status) VALUES
  ('d1000000-0000-0000-0000-000000000001','d2e00012-0000-0000-0000-000000000012','2026-01-12','MAD');

-- ── Test 1 : cas 1-5 — formules retard / rattrapage / solde ─────────────────
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00001-0000-0000-0000-000000000001';
  ASSERT r.retard_matin_min = 15,      '1a. cas1 retard_matin doit être 15';
  ASSERT r.rattrapage_soir_min = 15,   '1a. cas1 rattrapage_soir doit être 15';
  ASSERT r.solde_jour_min = 0,         '1a. cas1 solde doit être 0';

  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00002-0000-0000-0000-000000000002';
  ASSERT r.retard_matin_min = 15 AND r.rattrapage_soir_min = 5 AND r.solde_jour_min = 10,
    '1b. cas2 solde doit être +10';

  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00003-0000-0000-0000-000000000003';
  ASSERT r.retard_matin_min = 0 AND r.rattrapage_soir_min = 0 AND r.solde_jour_min = 20,
    '1c. cas3 solde doit être +20 (départ anticipé pur)';

  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00004-0000-0000-0000-000000000004';
  ASSERT r.retard_matin_min = 10 AND r.rattrapage_soir_min = 0 AND r.solde_jour_min = 25,
    '1d. cas4 solde doit être +25 (retard + départ anticipé cumulés)';

  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00005-0000-0000-0000-000000000005';
  ASSERT r.retard_matin_min = 0 AND r.rattrapage_soir_min = 12 AND r.solde_jour_min = -12,
    '1e. cas5 solde doit être -12 (avance)';

  RAISE NOTICE 'OK 1 · formules retard/rattrapage/solde — cas 1 à 5 conformes au cahier des charges';
END $$;

-- ── Test 2 : session ouverte → sortie/rattrapage/solde NULL, retard connu ───
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00006-0000-0000-0000-000000000006';
  ASSERT r.is_open = true,                 '2a. session ouverte doit être détectée';
  ASSERT r.real_out IS NULL,               '2b. real_out doit être NULL tant que non pointé';
  ASSERT r.retard_matin_min = 20,          '2c. retard_matin reste calculable (20 min)';
  ASSERT r.rattrapage_soir_min IS NULL,    '2d. rattrapage_soir NULL (pas de sortie)';
  ASSERT r.solde_jour_min IS NULL,         '2e. solde_jour NULL (incomplet)';
  RAISE NOTICE 'OK 2 · session ouverte — pas de 0 fantôme, NULL explicite';
END $$;

-- ── Test 3 : aucun plan ni horaire par défaut → tout NULL sauf le pointage ──
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00007-0000-0000-0000-000000000007';
  ASSERT r.planned_in IS NULL AND r.planned_out IS NULL,
    '3a. sans plan ni schedule_id, planned_in/out doivent être NULL';
  ASSERT r.retard_matin_min IS NULL AND r.rattrapage_soir_min IS NULL AND r.solde_jour_min IS NULL,
    '3b. GREATEST(0,NULL) ne doit JAMAIS masquer un NULL en 0 (piège PostgreSQL)';
  ASSERT r.real_in IS NOT NULL, '3c. le pointage réel reste visible malgré l''absence de plan';
  RAISE NOTICE 'OK 3 · absence de plan/horaire → NULL propre, pas de faux 0';
END $$;

-- ── Test 4 : repli sur l'horaire par défaut (department_schedules) ──────────
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00008-0000-0000-0000-000000000008';
  ASSERT r.planned_in = '09:00'::time AND r.planned_out = '17:00'::time,
    '4a. planned_in/out doivent venir de department_schedules via employees.schedule_id';
  ASSERT r.retard_matin_min = 10, '4b. retard calculé sur l''horaire par défaut (09:10 vs 09:00)';
  RAISE NOTICE 'OK 4 · repli sur l''horaire par défaut du salarié';
END $$;

-- ── Test 5 : service traversant minuit ──────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00009-0000-0000-0000-000000000009';
  ASSERT r.rattrapage_soir_min = 20,
    '5a. prévu 23:50 / réel 00:10 doit donner +20 min, jamais -23h40';
  ASSERT r.solde_jour_min = -20, '5b. solde = -20 (0 retard - 20 rattrapage)';
  RAISE NOTICE 'OK 5 · normalisation minuit correcte (pas de -23h40 aberrant)';
END $$;

-- ── Test 6 : planifié mais pas encore pointé (Non pointé) ───────────────────
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00010-0000-0000-0000-000000000010';
  ASSERT r.planning_status = 'P',   '6a. statut planifié doit être remonté';
  ASSERT r.real_in IS NULL,         '6b. real_in NULL tant qu''aucun pointage';
  ASSERT r.retard_matin_min IS NULL,'6c. pas de retard calculable sans pointage réel';
  RAISE NOTICE 'OK 6 · planifié non pointé — ligne présente, métriques NULL';
END $$;

-- ── Test 7 : extra inter-hôtel visible + is_extra=true (régression LOT1) ───
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d2e00011-0000-0000-0000-000000000011';
  ASSERT r.employee_id IS NOT NULL, '7a. l''extra doit apparaître à l''hôtel où il a pointé';
  ASSERT r.is_extra = true,         '7b. is_extra doit être vrai (hôtel principal ≠ hôtel visité)';

  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d1e00001-0000-0000-0000-000000000001';
  ASSERT r.is_extra = false, '7c. un salarié local doit avoir is_extra=false';
  RAISE NOTICE 'OK 7 · visibilité inter-hôtel (is_extra) — corrige la régression du menu Pointage RH';
END $$;

-- ── Test 7bis : statut MAD (mise à disposition) visible avant tout pointage ─
-- Régression réelle (2026-07-28) : Karima OULSAADA, Grand Hôtel du Havre,
-- mise à disposition de Folkestone opera — absente du menu Pointage tant
-- que 'MAD' n'était pas dans le filtre de statut planifié (sql/67).
DO $$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  SELECT * INTO r FROM public.pointage_range_summary(
    'd1000000-0000-0000-0000-000000000001','2026-01-12','2026-01-12'
  ) WHERE employee_id='d2e00012-0000-0000-0000-000000000012';
  ASSERT r.employee_id IS NOT NULL, '7d. un salarié planifié MAD doit apparaître, même sans avoir encore pointé';
  ASSERT r.planning_status = 'MAD', '7e. le statut planifié remonté doit être MAD';
  ASSERT r.is_extra = true,         '7f. MAD à un hôtel différent du principal → is_extra=true';
  ASSERT r.real_in IS NULL,         '7g. pas encore pointée → real_in NULL (Non pointé côté UI)';
  RAISE NOTICE 'OK 7bis · statut MAD inclus dans le périmètre planifié (régression Karima OULSAADA corrigée)';
END $$;

-- ── Test 8 : isolation multi-hôtel stricte ──────────────────────────────────
DO $$
DECLARE ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  BEGIN
    PERFORM * FROM public.pointage_range_summary(
      'd2000000-0000-0000-0000-000000000002','2026-01-12','2026-01-12'
    );
  EXCEPTION WHEN OTHERS THEN
    ok := SQLSTATE = '42501';
  END;
  ASSERT ok, '8a. hôtel hors pl_my_hotels() doit lever 42501 NOT_ALLOWED';
  RAISE NOTICE 'OK 8 · isolation multi-hôtel (NOT_ALLOWED sur hôtel étranger)';
END $$;

-- ── Test 9 : garde-fou plage de dates ────────────────────────────────────────
DO $$
DECLARE ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000d0a01', true);
  BEGIN
    PERFORM * FROM public.pointage_range_summary(
      'd1000000-0000-0000-0000-000000000001','2026-01-01','2027-01-01'
    );
  EXCEPTION WHEN OTHERS THEN
    ok := SQLSTATE = '22023';
  END;
  ASSERT ok, '9a. plage > 92 jours doit être refusée';
  RAISE NOTICE 'OK 9 · garde-fou RANGE_TOO_WIDE';
END $$;

-- ── Test 10 : grants — anon/PUBLIC bloqués, authenticated autorisé ──────────
DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM information_schema.routine_privileges
     WHERE routine_schema='public' AND routine_name='pointage_range_summary'
       AND grantee IN ('PUBLIC','anon')
  ), '10a. anon/PUBLIC ne doivent avoir aucun droit EXECUTE';
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.routine_privileges
     WHERE routine_schema='public' AND routine_name='pointage_range_summary'
       AND grantee='authenticated'
  ), '10b. authenticated doit pouvoir exécuter la RPC';
  RAISE NOTICE 'OK 10 · grants stricts (anon/PUBLIC refusés, authenticated autorisé)';
END $$;
