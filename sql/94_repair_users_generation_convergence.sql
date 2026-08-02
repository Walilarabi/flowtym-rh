-- ============================================================================
-- sql/94_repair_users_generation_convergence.sql
-- Régularisation — convergence de génération de public.users vers la forme
-- réellement servie par production (ADR-012 §9, audit de dérive du
-- 2026-08-02)
--
-- Contexte : `00001_initial_schema` (baseline squashée, trackée) définit
-- `users` avec first_name/last_name/email/role/hotel_id (nullable, ON DELETE
-- SET NULL)/active/invited_by/invitation_accepted_at/last_login_at/
-- created_at/updated_at — vérifié par lecture directe du texte de 00001. La
-- table réellement servie par production a été redéfinie hors bande :
-- first_name/last_name fusionnées en full_name, active→is_active,
-- invited_by/invitation_accepted_at retirées, hotel_id passé NOT NULL avec
-- ON DELETE RESTRICT (au lieu de nullable/SET NULL), auth_id passé NOT NULL
-- avec sa propre FK+UNIQUE vers auth.users, ajout de users_hotel_id_email_key.
--
-- Cible retenue : la forme de PRODUCTION — confirmée le 2026-08-02 comme
-- étant celle réellement utilisée par des dizaines de fonctions live
-- (admin_list_user_access, admin_get_user_detail, admin_set_user_status,
-- _resolve_app_access_core, current_user_has_app, platform_dashboard_kpis,
-- admin_platform_overview_kpis, admin_platform_alerts, etc.) et par les 14
-- lignes réelles de production (full_name/is_active/auth_id/hotel_id tous
-- peuplés, aucune trace de first_name/last_name).
--
-- Preuve « zéro référence » pour chaque colonne retirée ci-dessous : les
-- seules occurrences de first_name/last_name trouvées dans le dépôt et dans
-- le corps des fonctions live de production appartiennent à d'AUTRES tables
-- (employees, candidates, guests, hk_staff, staff_members — confirmé via
-- pg_attribute, aucune n'appartient à public.users) ; invited_by et
-- invitation_accepted_at : 0 occurrence nulle part (colonne ni référencée en
-- lecture ni en écriture) ; la colonne booléenne legacy `active` (distincte
-- de `is_active`) : 0 référence identifiée comme colonne de users.
--
-- Ce fichier n'est PAS idempotent au sens Postgres natif pour les DROP
-- COLUMN (`DROP COLUMN IF EXISTS` l'est) mais suit le même patron trois-états
-- que sql/93 : détecte l'état pristine (colonnes legacy présentes) vs déjà
-- convergé (absentes) vs partiel inattendu.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration. À
-- appliquer sur une branche fraîchement rejouée AVANT toute insertion de
-- données dans users (fixtures QA ou autres) — un `hotel_id`/`auth_id` NOT
-- NULL sur une table déjà peuplée avec des valeurs NULL ferait échouer cette
-- migration de façon explicite (ALTER COLUMN ... SET NOT NULL), jamais
-- silencieusement.
-- ============================================================================

DO $converge_users$
DECLARE
  v_has_legacy boolean;
  v_has_target boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='first_name')
    INTO v_has_legacy;
  SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='full_name')
    INTO v_has_target;

  IF v_has_target AND NOT v_has_legacy THEN
    RAISE NOTICE '[users] déjà convergé vers la génération production — aucune action.';
    RETURN;
  END IF;

  IF NOT v_has_target AND NOT v_has_legacy THEN
    RAISE EXCEPTION '[users] état inattendu : ni first_name (génération pristine) ni full_name (génération cible) présents. Aucune correction automatique — vérifier manuellement.';
  END IF;

  -- A) full_name/is_active : sur un rejeu pristine pur, ces colonnes cible
  -- n'existent pas encore (00001 ne les crée pas) — les ajouter si besoin,
  -- avec backfill depuis first_name/last_name/active pour toute ligne déjà
  -- présente (table normalement vide sur un rejeu frais).
  IF NOT v_has_target THEN
    EXECUTE 'ALTER TABLE public.users ADD COLUMN full_name text';
    EXECUTE 'ALTER TABLE public.users ADD COLUMN is_active boolean NOT NULL DEFAULT true';
    EXECUTE $u$UPDATE public.users SET full_name = trim(both ' ' from coalesce(first_name,'') || ' ' || coalesce(last_name,'')) WHERE full_name IS NULL$u$;
    EXECUTE 'UPDATE public.users SET is_active = active WHERE active IS NOT NULL';
    EXECUTE 'ALTER TABLE public.users ALTER COLUMN full_name SET NOT NULL';
  END IF;

  -- B) auth_id / hotel_id : NOT NULL + FK cible. Échec explicite (jamais
  -- silencieux) si une ligne existante a l'un des deux à NULL — signe que la
  -- table contient déjà des données incompatibles avec la cible, à traiter
  -- manuellement avant de rejouer cette migration.
  IF EXISTS (SELECT 1 FROM public.users WHERE auth_id IS NULL) THEN
    RAISE EXCEPTION '[users] au moins une ligne a auth_id NULL — impossible de poser NOT NULL sans perte de données implicite. Aucune correction automatique.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE hotel_id IS NULL) THEN
    RAISE EXCEPTION '[users] au moins une ligne a hotel_id NULL — impossible de poser NOT NULL sans perte de données implicite. Aucune correction automatique.';
  END IF;

  EXECUTE 'ALTER TABLE public.users ALTER COLUMN auth_id SET NOT NULL';
  EXECUTE 'ALTER TABLE public.users ALTER COLUMN hotel_id SET NOT NULL';

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.users'::regclass AND conname='users_auth_id_fkey') THEN
    EXECUTE 'ALTER TABLE public.users ADD CONSTRAINT users_auth_id_fkey FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE CASCADE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.users'::regclass AND conname='users_hotel_id_email_key') THEN
    EXECUTE 'ALTER TABLE public.users ADD CONSTRAINT users_hotel_id_email_key UNIQUE (hotel_id, email)';
  END IF;

  -- hotel_id FK : cible ON DELETE RESTRICT (production bloque la suppression
  -- d'un hôtel ayant encore des utilisateurs) au lieu de ON DELETE SET NULL
  -- (baseline pristine — désormais impossible de toute façon puisque
  -- hotel_id est NOT NULL ci-dessus, SET NULL y échouerait silencieusement
  -- en pratique). Divergence sémantique réelle, pas cosmétique.
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid='public.users'::regclass AND conname='users_hotel_id_fkey'
      AND pg_get_constraintdef(oid) LIKE '%ON DELETE SET NULL%'
  ) THEN
    EXECUTE 'ALTER TABLE public.users DROP CONSTRAINT users_hotel_id_fkey';
    EXECUTE 'ALTER TABLE public.users ADD CONSTRAINT users_hotel_id_fkey FOREIGN KEY (hotel_id) REFERENCES public.hotels(id) ON DELETE RESTRICT';
  END IF;

  -- C) Trigger cible : app.set_updated_at() au lieu du générique
  -- update_updated_at() du baseline (fonction app.set_updated_at déjà
  -- créée par 0010, réutilisée ici — jamais redéfinie dans ce fichier).
  IF EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='users' AND tg.tgname='set_updated_at') THEN
    EXECUTE 'DROP TRIGGER set_updated_at ON public.users';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid WHERE c.relnamespace='public'::regnamespace AND c.relname='users' AND tg.tgname='trg_users_updated_at') THEN
    EXECUTE 'CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION app.set_updated_at()';
  END IF;

  -- D) Policies cibles : users_select restreinte à hotel_id = get_user_
  -- hotel_id() (production) remplace la version baseline qui ajoutait
  -- `OR auth_id = auth.uid()`. users_delete/insert/update (baseline) sont
  -- retirées au profit de users_hotel_select/users_hotel_update
  -- (production).
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_select'
      AND qual LIKE '%auth_id = auth.uid()%') THEN
    EXECUTE 'DROP POLICY users_select ON public.users';
    EXECUTE $pol$CREATE POLICY users_select ON public.users FOR SELECT USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_delete') THEN
    EXECUTE 'DROP POLICY users_delete ON public.users';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_insert') THEN
    EXECUTE 'DROP POLICY users_insert ON public.users';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_update') THEN
    EXECUTE 'DROP POLICY users_update ON public.users';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_hotel_select') THEN
    EXECUTE $pol$CREATE POLICY users_hotel_select ON public.users FOR SELECT TO authenticated USING (hotel_id = get_user_hotel_id())$pol$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='users_hotel_update') THEN
    EXECUTE $pol$CREATE POLICY users_hotel_update ON public.users FOR UPDATE TO authenticated USING (hotel_id = get_user_hotel_id()) WITH CHECK (hotel_id = get_user_hotel_id())$pol$;
  END IF;

  -- E) Index cibles.
  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_users_auth ON public.users USING btree (auth_id)';
  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_users_hotel ON public.users USING btree (hotel_id)';

  -- F) Retrait des colonnes de l'ancienne génération — preuve de zéro
  -- référence documentée en en-tête de fichier. CASCADE retire
  -- automatiquement users_invited_by_fkey (rattachée à invited_by).
  IF v_has_legacy THEN
    EXECUTE 'ALTER TABLE public.users DROP COLUMN IF EXISTS first_name CASCADE';
    EXECUTE 'ALTER TABLE public.users DROP COLUMN IF EXISTS last_name CASCADE';
    EXECUTE 'ALTER TABLE public.users DROP COLUMN IF EXISTS active CASCADE';
    EXECUTE 'ALTER TABLE public.users DROP COLUMN IF EXISTS invited_by CASCADE';
    EXECUTE 'ALTER TABLE public.users DROP COLUMN IF EXISTS invitation_accepted_at CASCADE';
  END IF;

  RAISE NOTICE '[users] convergence de génération terminée (colonnes, contraintes NOT NULL/FK, trigger, policies, index, retraits justifiés).';
END
$converge_users$;
