-- =============================================================================
-- Tests SQL du module Pointage v2 (post-audit).
-- Se lancent contre une base fraîche :
--   psql -f scratchpad/00_min_schema.sql
--   psql -f sql/62_pointage_terminals.sql
--   psql -f sql/63_pointage_terminals_hardening.sql
--   psql -f sql/tests/pointage_hardening.sql
-- Chaque bloc DO $$ ... $$ termine par un RAISE NOTICE 'OK: …'.
-- Un ASSERT qui échoue avorte immédiatement et signale la régression.
-- =============================================================================

-- ── Setup : hôtels, users, employés, session simulée ───────────────────────
-- Ordre : d'abord les tables qui référencent (staff_clockings pointe sur
-- pointage_terminals via terminal_id ; staff_clocking_idempotency pointe
-- sur staff_clockings), puis les tables référencées. Le trigger BEFORE
-- DELETE sur pointage_terminals bloquerait sinon.
DELETE FROM public.staff_clocking_idempotency;
DELETE FROM public.staff_clockings;
DELETE FROM public.pointage_terminal_events;
DELETE FROM public.pointage_terminals;
DELETE FROM public.staff_planning;
DELETE FROM public.employee_extra_activations;
DELETE FROM public.employee_hotel_assignments;
DELETE FROM public.employees;
DELETE FROM public.user_hotels;
DELETE FROM public.users;
DELETE FROM public.hotels;

INSERT INTO public.hotels(id, name, timezone, latitude, longitude, geofence_radius_meters, qr_clocking_enabled)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Hotel Paris',   'Europe/Paris',   48.8566, 2.3522, 150, true),
  ('22222222-2222-2222-2222-222222222222', 'Hotel Nice',    'Europe/Paris',   43.7102, 7.2620, 150, true),
  ('33333333-3333-3333-3333-333333333333', 'Hotel Cayenne', 'America/Cayenne',  4.9224, -52.3135, 150, true);

INSERT INTO public.users(id, auth_id, email, full_name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','00000000-0000-0000-0000-00000000aaaa','admin.paris@x.fr','Admin Paris'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','00000000-0000-0000-0000-00000000bbbb','admin.nice@x.fr','Admin Nice');
INSERT INTO public.user_hotels(user_id, hotel_id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','22222222-2222-2222-2222-222222222222');

INSERT INTO public.employees(id, hotel_id, first_name, last_name, active) VALUES
  ('e0000001-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Alice','Actif',   true),
  ('e0000002-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Bruno','Inactif', false),
  ('e0000003-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Chloé','Multi',   true),
  ('e0000004-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222','David','NiceOnly',true);

-- ── Test 1 : autorisation — hôtel principal + actif ────────────────────────
DO $$
BEGIN
  ASSERT public.employee_can_clock_at(
    'e0000001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    current_date
  ) = true, '1a. principal actif doit être autorisé';

  ASSERT public.employee_can_clock_at(
    'e0000002-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    current_date
  ) = false, '1b. principal INACTIF doit être refusé';

  ASSERT public.employee_can_clock_at(
    'e0000001-0000-0000-0000-000000000001',
    '22222222-2222-2222-2222-222222222222',
    current_date
  ) = false, '1c. hôtel étranger sans droits doit être refusé';

  RAISE NOTICE 'OK 1 · autorisation principal / inactif / étranger';
END $$;

-- ── Test 2 : autorisation — affectation permanente ─────────────────────────
DO $$
BEGIN
  INSERT INTO public.employee_hotel_assignments(employee_id, target_hotel_id, active)
  VALUES ('e0000003-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222', true);

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222',
    current_date
  ) = true, '2a. affectation permanente active → autorisé';

  UPDATE public.employee_hotel_assignments
     SET active = false
   WHERE employee_id='e0000003-0000-0000-0000-000000000003';

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222',
    current_date
  ) = false, '2b. affectation permanente désactivée → refusé';

  RAISE NOTICE 'OK 2 · affectation permanente (active / inactive)';
END $$;

-- ── Test 3 : autorisation — activation Extra mensuelle ─────────────────────
DO $$
DECLARE
  d date := current_date;
  y int := extract(year FROM d)::int;
  m int := extract(month FROM d)::int;
BEGIN
  INSERT INTO public.employee_extra_activations(employee_id, hotel_id, year, month, active)
  VALUES ('e0000003-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222', y, m, true);

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', d
  ) = true, '3a. extra actif ce mois → autorisé';

  UPDATE public.employee_extra_activations SET active=false
   WHERE employee_id='e0000003-0000-0000-0000-000000000003';

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', d
  ) = false, '3b. extra désactivé → refusé';

  UPDATE public.employee_extra_activations SET active=true, month=CASE WHEN m=12 THEN 1 ELSE m+1 END, year=CASE WHEN m=12 THEN y+1 ELSE y END
   WHERE employee_id='e0000003-0000-0000-0000-000000000003';

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', d
  ) = false, '3c. extra pour un autre mois → refusé';

  RAISE NOTICE 'OK 3 · activation extra (mois courant / désactivée / autre mois)';
END $$;

-- ── Test 4 : autorisation — shift planifié ─────────────────────────────────
DO $$
BEGIN
  DELETE FROM public.employee_extra_activations WHERE employee_id='e0000003-0000-0000-0000-000000000003';

  INSERT INTO public.staff_planning(hotel_id, employee_id, day, status)
  VALUES ('22222222-2222-2222-2222-222222222222','e0000003-0000-0000-0000-000000000003', current_date, 'P');

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', current_date
  ) = true, '4a. shift P planifié aujourd''hui → autorisé';

  -- Shift dans un autre hôtel : refuse
  DELETE FROM public.staff_planning WHERE employee_id='e0000003-0000-0000-0000-000000000003';
  INSERT INTO public.staff_planning(hotel_id, employee_id, day, status)
  VALUES ('11111111-1111-1111-1111-111111111111','e0000003-0000-0000-0000-000000000003', current_date, 'P');

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', current_date
  ) = false, '4b. shift planifié dans un AUTRE hôtel → refusé';

  -- Absence (CP) ≠ P → pas d'autorisation
  DELETE FROM public.staff_planning WHERE employee_id='e0000003-0000-0000-0000-000000000003';
  INSERT INTO public.staff_planning(hotel_id, employee_id, day, status)
  VALUES ('22222222-2222-2222-2222-222222222222','e0000003-0000-0000-0000-000000000003', current_date, 'CP');

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', current_date
  ) = false, '4c. shift CP (congé) ne vaut pas P → refusé';

  DELETE FROM public.staff_planning WHERE employee_id='e0000003-0000-0000-0000-000000000003';
  RAISE NOTICE 'OK 4 · shift planifié (P / autre hôtel / absence)';
END $$;

-- ── Test 5 : autorisation — l'historique ne suffit PAS ─────────────────────
DO $$
BEGIN
  -- Chloé a pointé dans l'hôtel Nice il y a un mois, mais n'a AUCUN droit actuel.
  INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, clock_out_ts, source)
  VALUES ('22222222-2222-2222-2222-222222222222','e0000003-0000-0000-0000-000000000003',
          current_date - 30, now() - interval '30 days', now() - interval '29 days 22 hours', 'qr');

  ASSERT public.employee_can_clock_at(
    'e0000003-0000-0000-0000-000000000003',
    '22222222-2222-2222-2222-222222222222', current_date
  ) = false, '5. historique seul (ancien pointage) ne doit PAS autoriser un nouveau pointage';

  DELETE FROM public.staff_clockings;
  RAISE NOTICE 'OK 5 · historique seul → refusé (règle audit)';
END $$;

-- ── Test 6 : archivage terminal, DELETE bloqué si utilisé ──────────────────
DO $$
DECLARE
  v_result jsonb;
  v_terminal_id uuid;
  v_token text;
  v_clocking_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);

  v_result := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111', 'Réception', 'Comptoir principal');
  v_terminal_id := (v_result->>'id')::uuid;
  v_token := v_result->>'token';

  ASSERT v_token LIKE 'ftt_%', '6a. token doit commencer par ftt_';
  ASSERT length(v_token) >= 20, '6a2. token doit être long';

  -- Utilisation du terminal
  INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, source, terminal_id)
  VALUES ('11111111-1111-1111-1111-111111111111','e0000001-0000-0000-0000-000000000001',
          current_date, now(), 'qr', v_terminal_id)
  RETURNING id INTO v_clocking_id;

  -- DELETE doit être bloqué
  BEGIN
    DELETE FROM public.pointage_terminals WHERE id = v_terminal_id;
    RAISE EXCEPTION 'FAIL: DELETE d''un terminal utilisé ne doit pas passer';
  EXCEPTION WHEN foreign_key_violation THEN
    -- attendu
  END;

  -- Archivage OK
  PERFORM public.archive_pointage_terminal(v_terminal_id);
  ASSERT (SELECT is_active FROM public.pointage_terminals WHERE id=v_terminal_id) = false,
         '6b. archive rend le terminal inactif';
  ASSERT (SELECT archived_at IS NOT NULL FROM public.pointage_terminals WHERE id=v_terminal_id) = true,
         '6c. archive set archived_at';

  -- Réactivation impossible après archivage
  BEGIN
    PERFORM public.set_pointage_terminal_active(v_terminal_id, true);
    RAISE EXCEPTION 'FAIL: réactiver un terminal archivé ne doit pas passer';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  -- Trace d'audit présente pour create + archive
  ASSERT (SELECT count(*) FROM public.pointage_terminal_events
           WHERE terminal_id = v_terminal_id) = 2,
         '6d. 2 événements attendus (create + archive)';

  -- Suppression physique reste bloquée par le trigger même si archivé
  BEGIN
    DELETE FROM public.pointage_terminals WHERE id = v_terminal_id;
    RAISE EXCEPTION 'FAIL: DELETE physique interdit sur terminal référencé';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  RAISE NOTICE 'OK 6 · archivage + DELETE bloqué si référencé + audit';
END $$;

-- ── Test 7 : régénération atomique + audit ─────────────────────────────────
DO $$
DECLARE
  v_terminal jsonb;
  v_id uuid;
  v_first text;
  v_second text;
BEGIN
  DELETE FROM public.staff_clockings;
  DELETE FROM public.pointage_terminals;
  DELETE FROM public.pointage_terminal_events;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);

  v_terminal := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111','Cuisine','Zone de restauration');
  v_id := (v_terminal->>'id')::uuid;
  v_first := v_terminal->>'token';

  v_terminal := public.regenerate_pointage_terminal_token(v_id);
  v_second := v_terminal->>'token';

  ASSERT v_first <> v_second, '7a. nouveau token différent';
  ASSERT (SELECT token FROM public.pointage_terminals WHERE id=v_id) = v_second,
         '7b. la table reflète le nouveau token';
  ASSERT NOT EXISTS (SELECT 1 FROM public.pointage_terminals WHERE token=v_first),
         '7c. ancien token immédiatement invalide (absent en table)';
  ASSERT (SELECT count(*) FROM public.pointage_terminal_events
           WHERE terminal_id=v_id AND action='regenerate') = 1,
         '7d. événement regenerate journalisé';

  -- Refus si l'admin cible un hôtel qu'il ne gère pas
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000bbbb', true);
  BEGIN
    PERFORM public.regenerate_pointage_terminal_token(v_id);
    RAISE EXCEPTION 'FAIL: régénération cross-tenant autorisée par erreur';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RAISE NOTICE 'OK 7 · régénération atomique + isolation multi-tenant + audit';
END $$;

-- ── Test 8 : record_clocking — clock_in / clock_out séquentiels ────────────
DO $$
DECLARE
  v_terminal jsonb; v_tid uuid;
  r1 jsonb; r2 jsonb; r3 jsonb;
BEGIN
  DELETE FROM public.staff_clockings;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);
  v_terminal := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111','Réception');
  v_tid := (v_terminal->>'id')::uuid;

  r1 := public.record_clocking('e0000001-0000-0000-0000-000000000001',
                               '11111111-1111-1111-1111-111111111111', v_tid, 'qr', 'ik-1');
  ASSERT r1->>'action' = 'clock_in', '8a. 1er appel → clock_in';

  r2 := public.record_clocking('e0000001-0000-0000-0000-000000000001',
                               '11111111-1111-1111-1111-111111111111', v_tid, 'qr', 'ik-2');
  ASSERT r2->>'action' = 'clock_out', '8b. 2e appel → clock_out';

  -- Rejeu avec la MÊME clé d'idempotence → même ligne, aucun nouveau
  r3 := public.record_clocking('e0000001-0000-0000-0000-000000000001',
                               '11111111-1111-1111-1111-111111111111', v_tid, 'qr', 'ik-2');
  ASSERT r3->>'id' = r2->>'id', '8c. rejeu idempotency-key → même ligne';
  ASSERT (r3->>'idempotent')::bool = true, '8d. rejeu marqué idempotent';

  ASSERT (SELECT count(*) FROM public.staff_clockings
           WHERE employee_id='e0000001-0000-0000-0000-000000000001') = 1,
         '8e. exactement 1 pointage stocké malgré 3 appels';

  RAISE NOTICE 'OK 8 · record_clocking séquentiel + idempotency key';
END $$;

-- ── Test 9 : SQL empêche 2 pointages ouverts pour le même salarié ──────────
DO $$
DECLARE
  v_terminal jsonb; v_tid uuid;
  v_err text;
BEGIN
  DELETE FROM public.staff_clockings;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);
  v_terminal := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111','Bar');
  v_tid := (v_terminal->>'id')::uuid;

  PERFORM public.record_clocking('e0000001-0000-0000-0000-000000000001',
                                 '11111111-1111-1111-1111-111111111111', v_tid, 'qr', NULL);

  -- Tentative directe d'insérer un second clock_in ouvert → doit être refusée
  BEGIN
    INSERT INTO public.staff_clockings(hotel_id, employee_id, day, clock_in_ts, source, terminal_id)
    VALUES ('11111111-1111-1111-1111-111111111111','e0000001-0000-0000-0000-000000000001',
            current_date, now(), 'manual', v_tid);
    RAISE EXCEPTION 'FAIL: 2 pointages ouverts acceptés par la base';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  RAISE NOTICE 'OK 9 · unique partiel : 1 seul pointage ouvert par employé';
END $$;

-- ── Test 10 : day dérive du fuseau de l'hôtel (poste de nuit) ──────────────
DO $$
DECLARE
  v_terminal jsonb; v_tid uuid;
  r jsonb;
  v_local_day date;
BEGIN
  -- Hôtel Cayenne : UTC-3, timezone America/Cayenne
  DELETE FROM public.staff_clockings;
  DELETE FROM public.pointage_terminals;
  DELETE FROM public.user_hotels;
  INSERT INTO public.user_hotels(user_id, hotel_id) VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','33333333-3333-3333-3333-333333333333');
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);
  v_terminal := public.create_pointage_terminal(
    '33333333-3333-3333-3333-333333333333','Réception');
  v_tid := (v_terminal->>'id')::uuid;

  -- Employé actif sur Cayenne
  INSERT INTO public.employees(id, hotel_id, first_name, last_name)
  VALUES ('e0000005-0000-0000-0000-000000000005','33333333-3333-3333-3333-333333333333','Éva','Nuit');

  r := public.record_clocking('e0000005-0000-0000-0000-000000000005',
                              '33333333-3333-3333-3333-333333333333', v_tid, 'qr', 'nuit-1');
  v_local_day := public.pl_hotel_local_day('33333333-3333-3333-3333-333333333333', now());
  ASSERT (r->>'day')::date = v_local_day,
         '10a. day == date civile locale de l''hôtel';

  RAISE NOTICE 'OK 10 · day dérive du fuseau hôtel (Cayenne)';
END $$;

-- ── Test 11 : idempotency-key sur SLUG unique ──────────────────────────────
DO $$
DECLARE
  v_terminal jsonb; v_tid uuid;
  r jsonb;
BEGIN
  DELETE FROM public.staff_clockings;
  -- Restaurer l'accès Paris (test 10 avait basculé user_hotels sur Cayenne)
  INSERT INTO public.user_hotels(user_id, hotel_id)
  VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111')
  ON CONFLICT DO NOTHING;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000aaaa', true);
  v_terminal := public.create_pointage_terminal(
    '11111111-1111-1111-1111-111111111111','Ménage');
  v_tid := (v_terminal->>'id')::uuid;

  -- Deux appels concurrents simulés en série avec la même clé → 1 seule ligne
  r := public.record_clocking('e0000001-0000-0000-0000-000000000001',
                              '11111111-1111-1111-1111-111111111111', v_tid, 'qr', 'retry-abc');
  ASSERT (r->>'idempotent')::bool IS DISTINCT FROM true, '11a. 1er appel non idempotent';

  r := public.record_clocking('e0000001-0000-0000-0000-000000000001',
                              '11111111-1111-1111-1111-111111111111', v_tid, 'qr', 'retry-abc');
  ASSERT (r->>'idempotent')::bool = true, '11b. 2e appel marqué idempotent';

  ASSERT (SELECT count(*) FROM public.staff_clockings
           WHERE employee_id='e0000001-0000-0000-0000-000000000001'
             AND clock_out_ts IS NULL) = 1,
         '11c. 1 seul pointage ouvert malgré 2 retries';

  RAISE NOTICE 'OK 11 · idempotency-key rejeu réseau';
END $$;

-- ── Test 12 : record_clocking non exécutable sans service_role ─────────────
DO $$
BEGIN
  -- authenticated ne DOIT PAS pouvoir invoquer record_clocking
  ASSERT NOT has_function_privilege('authenticated',
    'public.record_clocking(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE'),
    '12a. authenticated ne doit pas avoir EXECUTE sur record_clocking';
  ASSERT has_function_privilege('service_role',
    'public.record_clocking(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE'),
    '12b. service_role doit avoir EXECUTE sur record_clocking';

  RAISE NOTICE 'OK 12 · record_clocking réservé à service_role';
END $$;

-- ── Test 13 : signatures des RPC / fonctions attendues ─────────────────────
DO $$
BEGIN
  ASSERT to_regprocedure('public.employee_can_clock_at(uuid,uuid,date)') IS NOT NULL,
    '13a. employee_can_clock_at(uuid,uuid,date) doit exister';
  ASSERT to_regprocedure('public.record_clocking(uuid,uuid,uuid,text,text,jsonb)') IS NOT NULL,
    '13b. record_clocking(uuid,uuid,uuid,text,text,jsonb) doit exister';
  ASSERT to_regprocedure('public.pl_hotel_local_day(uuid,timestamptz)') IS NOT NULL,
    '13c. pl_hotel_local_day(uuid,timestamptz) doit exister';
  ASSERT to_regprocedure('public.generate_terminal_token()') IS NOT NULL,
    '13d. generate_terminal_token() doit exister';
  ASSERT to_regprocedure('public.create_pointage_terminal(uuid,text,text)') IS NOT NULL,
    '13e. create_pointage_terminal(uuid,text,text) doit exister';
  ASSERT to_regprocedure('public.rename_pointage_terminal(uuid,text,text)') IS NOT NULL,
    '13f. rename_pointage_terminal(uuid,text,text) doit exister';
  ASSERT to_regprocedure('public.regenerate_pointage_terminal_token(uuid)') IS NOT NULL,
    '13g. regenerate_pointage_terminal_token(uuid) doit exister';
  ASSERT to_regprocedure('public.set_pointage_terminal_active(uuid,boolean)') IS NOT NULL,
    '13h. set_pointage_terminal_active(uuid,boolean) doit exister';
  ASSERT to_regprocedure('public.archive_pointage_terminal(uuid)') IS NOT NULL,
    '13i. archive_pointage_terminal(uuid) doit exister';
  ASSERT to_regprocedure('public.set_pointage_terminal_security(uuid,int,int,int)') IS NOT NULL,
    '13j. set_pointage_terminal_security(uuid,int,int,int) doit exister';

  RAISE NOTICE 'OK 13 · signatures RPC/fn';
END $$;

-- ── Test 14 : RLS active + policies présentes ──────────────────────────────
DO $$
DECLARE v_rls boolean; v_pols int;
BEGIN
  SELECT relrowsecurity INTO v_rls FROM pg_class WHERE relname='pointage_terminals';
  ASSERT v_rls = true, '14a. RLS active sur pointage_terminals';
  SELECT count(*) INTO v_pols FROM pg_policies
   WHERE schemaname='public' AND tablename='pointage_terminals';
  ASSERT v_pols >= 1, '14b. au moins une policy sur pointage_terminals';

  SELECT relrowsecurity INTO v_rls FROM pg_class WHERE relname='pointage_terminal_events';
  ASSERT v_rls = true, '14c. RLS active sur pointage_terminal_events';
  SELECT count(*) INTO v_pols FROM pg_policies
   WHERE schemaname='public' AND tablename='pointage_terminal_events';
  ASSERT v_pols >= 1, '14d. au moins une policy sur pointage_terminal_events';

  RAISE NOTICE 'OK 14 · RLS + policies actives';
END $$;

-- ── Test 15 : index unique partiel + trigger BEFORE DELETE ─────────────────
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE schemaname='public'
                    AND indexname='staff_clockings_one_open_per_employee'),
    '15a. index unique partiel staff_clockings_one_open_per_employee présent';

  -- L'idempotence est portée par la PK de staff_clocking_idempotency(key)
  -- (voir migration 63 §10) — pas par un index sur staff_clockings.
  ASSERT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE schemaname='public'
                    AND tablename='staff_clocking_idempotency'
                    AND indexdef ILIKE '%(key)%'),
    '15b. staff_clocking_idempotency porte l''unicité de la clé';

  ASSERT EXISTS (SELECT 1 FROM pg_trigger t
                  JOIN pg_class c ON c.oid = t.tgrelid
                 WHERE c.relname='pointage_terminals'
                   AND t.tgname='trg_pointage_terminals_no_delete_if_used'
                   AND NOT t.tgisinternal),
    '15c. trigger trg_pointage_terminals_no_delete_if_used présent';

  RAISE NOTICE 'OK 15 · index unique + trigger no-delete';
END $$;

-- ── Test 16 : grants — authenticated ne peut PAS exécuter record_clocking ──
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon',
    'public.record_clocking(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE'),
    '16a. anon ne doit pas exécuter record_clocking';
  ASSERT NOT has_function_privilege('authenticated',
    'public.record_clocking(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE'),
    '16b. authenticated ne doit pas exécuter record_clocking';
  ASSERT has_function_privilege('service_role',
    'public.record_clocking(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE'),
    '16c. service_role doit exécuter record_clocking';

  ASSERT has_function_privilege('authenticated',
    'public.create_pointage_terminal(uuid,text,text)', 'EXECUTE'),
    '16d. authenticated doit exécuter create_pointage_terminal';
  ASSERT has_function_privilege('authenticated',
    'public.regenerate_pointage_terminal_token(uuid)', 'EXECUTE'),
    '16e. authenticated doit exécuter regenerate_pointage_terminal_token';
  ASSERT has_function_privilege('authenticated',
    'public.archive_pointage_terminal(uuid)', 'EXECUTE'),
    '16f. authenticated doit exécuter archive_pointage_terminal';

  RAISE NOTICE 'OK 16 · grants stricts (record_clocking réservé service_role)';
END $$;

DO $$ BEGIN RAISE NOTICE '========================================'; RAISE NOTICE 'TOUS LES TESTS SQL SONT PASSÉS'; RAISE NOTICE '========================================'; END $$;
