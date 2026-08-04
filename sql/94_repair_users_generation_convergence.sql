-- ============================================================================
-- sql/94_repair_users_generation_convergence.sql
-- Régularisation ADDITIVE de public.users vers la forme réellement servie
-- par production (ADR-012 §9, audit de dérive du 2026-08-02 ; révisé le
-- 2026-08-02 suite à l'arbitrage explicite du mandat : aucun DROP COLUMN
-- sans audit du dépôt PMS, inaccessible depuis ce dépôt).
--
-- Contexte : `00001_initial_schema` (baseline squashée, trackée) définit
-- `users` avec first_name/last_name/email/role/hotel_id (nullable, ON DELETE
-- SET NULL)/active/invited_by/invitation_accepted_at/last_login_at/
-- created_at/updated_at — vérifié par lecture directe du texte de 00001. La
-- table réellement servie par production a été redéfinie hors bande :
-- first_name/last_name fusionnées en full_name, active→is_active,
-- hotel_id passé NOT NULL avec ON DELETE RESTRICT (au lieu de nullable/SET
-- NULL), auth_id passé NOT NULL avec sa propre FK+UNIQUE vers auth.users,
-- ajout de users_hotel_id_email_key.
--
-- Cible retenue pour les colonnes ADDITIVES : la forme de PRODUCTION —
-- confirmée le 2026-08-02 comme étant celle réellement utilisée par des
-- dizaines de fonctions live (admin_list_user_access, admin_get_user_detail,
-- admin_set_user_status, _resolve_app_access_core, current_user_has_app,
-- platform_dashboard_kpis, admin_platform_overview_kpis,
-- admin_platform_alerts, etc.) et par les 14 lignes réelles de production
-- (full_name/is_active/auth_id/hotel_id tous peuplés).
--
-- RÉVISION 2026-08-02 — colonnes first_name, last_name, active, invited_by,
-- invitation_accepted_at : la version précédente de ce fichier les DROPpait
-- sur preuve de « zéro référence dans ce dépôt + corps des fonctions de
-- production ». Cette preuve est jugée insuffisante par le mandat : le PMS
-- vit dans un dépôt séparé non accessible depuis cette session. Aucun DROP
-- COLUMN n'est donc exécuté ici. Les 5 colonnes legacy sont CONSERVÉES
-- intégralement, uniquement marquées comme dépréciées via COMMENT ON
-- COLUMN — le retrait effectif est différé à une migration ultérieure,
-- après audit complet du dépôt PMS.
--
-- Ce fichier suit le même patron trois-états que sql/93 : détecte l'état
-- pristine (colonnes legacy présentes) vs déjà convergé (full_name présent)
-- vs un état partiel inattendu.
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

  -- A) full_name/is_active : ajout additif + backfill depuis
  -- first_name/last_name/active pour toute ligne déjà présente (table
  -- normalement vide sur un rejeu frais). Ne touche jamais first_name/
  -- last_name/active elles-mêmes, qui restent intactes (cf. section F).
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
  -- manuellement avant de rejouer cette migration. Poser NOT NULL ne
  -- supprime aucune donnée (contrairement à un DROP COLUMN) : il bloque
  -- seulement l'insertion future de NULL.
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
  -- (baseline pristine). Divergence sémantique réelle, pas cosmétique.
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
  -- (production). Le retrait d'une policy ne touche jamais aux données.
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

  -- F) RÉVISÉ — aucun DROP COLUMN. Les 5 colonnes de l'ancienne génération
  -- sont marquées legacy/dépréciées via commentaire, jamais retirées tant
  -- que l'audit du dépôt PMS n'a pas prouvé l'absence de toute lecture.
  IF v_has_legacy THEN
    EXECUTE $c$COMMENT ON COLUMN public.users.first_name IS 'LEGACY (ancienne génération, fusionnée dans "full_name") — conservée sans retrait : aucune preuve d''absence de lecture côté dépôt PMS (hors périmètre de cet audit). Ne pas utiliser pour du nouveau code. Retrait différé à une migration ultérieure après audit PMS complet.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.users.last_name IS 'LEGACY (ancienne génération, fusionnée dans "full_name") — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.users.active IS 'LEGACY (ancienne génération, remplacée par "is_active") — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.users.invited_by IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
    EXECUTE $c$COMMENT ON COLUMN public.users.invitation_accepted_at IS 'LEGACY (ancienne génération) — conservée sans retrait, audit PMS requis avant suppression. Ne pas utiliser pour du nouveau code.'$c$;
  END IF;

  RAISE NOTICE '[users] convergence additive terminée (colonnes, contraintes NOT NULL/FK, trigger, policies, index) ; colonnes legacy conservées et marquées dépréciées, aucun DROP COLUMN.';
END
$converge_users$;
