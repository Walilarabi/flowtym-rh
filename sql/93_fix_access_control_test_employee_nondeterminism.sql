-- 93_fix_access_control_test_employee_nondeterminism.sql
-- ============================================================================
-- Corrige une migration NON DÉTERMINISTE qui casse le rejeu de branche.
--
-- Migration fautive : 20260607051239_access_control_rls_fixes_and_test_employee
-- (section "5. CRÉER EMPLOYÉ TEST PORTAIL").
--
-- Cause racine démontrée : l'insertion de l'employé de test utilisait un
-- UUID littéral, réel identifiant d'un hôtel de production (Folkestone
-- Opéra) :
--
--   INSERT INTO public.employees (hotel_id, ...)
--   VALUES ('02b9eb0e-89ef-45de-ba8e-20d4b41c500c', ...)
--
-- Sur production, cet hôtel existe : la contrainte FK employees_hotel_id_
-- fkey est satisfaite. Sur un rejeu de branche Supabase (Branching 2.0,
-- with_data:false — public.hotels part totalement vide), cet UUID ne
-- correspond à aucune ligne :
--   ERROR: insert or update on table "employees" violates foreign key
--   constraint "employees_hotel_id_fkey"
-- → migration non déterministe : son succès dépend d'un ID de production
--   figé en dur, jamais garanti par le mécanisme de rejeu.
--
-- Correction appliquée (root cause, pas contournement) : résolution
-- dynamique du premier hôtel disponible (`SELECT id FROM hotels LIMIT 1`)
-- au lieu du littéral figé. Si aucun hôtel n'existe (rejeu vierge sans
-- seed), l'insertion de l'employé de test est sautée silencieusement —
-- aucune migration ultérieure connue à ce jour n'en dépend (c'est un
-- fixture de test portail, pas un objet structurel).
--
-- Application : édition EN PLACE du texte déjà stocké dans
-- supabase_migrations.schema_migrations pour la version 20260607051239 —
-- pas un apply_migration standard (qui ajouterait une nouvelle ligne
-- d'historique timestampée "maintenant", inutile pour corriger le rejeu).
-- Sans impact sur la production : cette migration a déjà été exécutée en
-- production ; éditer le texte stocké ne rejoue rien contre la
-- production, ça ne change que le comportement des FUTURS rejeux de
-- branche. Constat additionnel (sans rapport avec la correction) :
-- l'employé de test walilarabi+salarie@gmail.com n'est plus présent en
-- production aujourd'hui (0 ligne) — vraisemblablement supprimé depuis,
-- sans lien avec le sujet de ce correctif.
-- ============================================================================

DO $repair$
DECLARE v_hotel_id uuid;
BEGIN
  SELECT id INTO v_hotel_id FROM public.hotels LIMIT 1;
  IF v_hotel_id IS NOT NULL THEN
    INSERT INTO public.employees (
      hotel_id, first_name, last_name, email,
      role, department, contract_type,
      hire_date, rest_days, active,
      portal_enabled, portal_invite_token, portal_invite_expires_at
    )
    VALUES (
      v_hotel_id,
      'Test',
      'SALARIÉ',
      'walilarabi+salarie@gmail.com',
      'Femme de chambre',
      'Étage',
      'CDD',
      '2026-01-01',
      ARRAY[0,6],
      true,
      true,
      encode(gen_random_bytes(32), 'hex'),
      now() + INTERVAL '7 days'
    )
    ON CONFLICT DO NOTHING;
  END IF;
END $repair$;
