-- ============================================================================
-- sql/81_support_acl_hardening.sql
-- Lot 1, PR-02 — Durcissement ACL/RLS du domaine Support
--
-- Strictement postérieure et indépendante de sql/80 (rétro-versionnement).
-- Initialement conçue comme GRANT/REVOKE uniquement (aucune policy RLS
-- modifiée) — corrigé ci-dessous : le rejeu du test avec des fixtures
-- représentatives de la production réelle a révélé une régression sur les
-- policies elles-mêmes (voir « CORRECTION MAJEURE » plus bas), exactement le
-- cas que l'ADR-012 §3.5.2 réservait explicitement à cette PR (« correction
-- de policy, si nécessaire »).
--
-- CORRECTION MAJEURE (découverte pendant la conception du Lot 5A, hors
-- périmètre initial de cette PR mais touchant directement une table de son
-- périmètre) : les policies `support_select`/`support_insert`/`support_update`
-- comparent `user_hotels.user_id = auth.uid()`. Or `user_hotels.user_id`
-- référence `public.users.id` (FOREIGN KEY confirmée), **pas** `auth.users.id`
-- — `auth.uid()` renvoie l'auth_id du JWT, une valeur différente de
-- `public.users.id` pour un utilisateur réel (vérifié : ce sont deux UUID
-- distincts en production). Conséquence : ces trois policies ne matchent
-- JAMAIS pour un utilisateur hôtel réel — prouvé en production (transaction
-- annulée) avec un vrai compte hôtel existant (`reservation@
-- grandhotelduhavre.com`) : un INSERT légitime dans son propre hôtel est
-- rejeté avec `new row violates row-level security policy`.
--
-- Le premier jeu de tests de cette PR (sql/tests/support_acl_hardening.sql,
-- profils auth_hotel_a/auth_hotel_b) ne l'avait PAS détecté : sa fixture
-- insérait `public.users.id = auth_id` (même valeur, par accident de
-- construction du jeu de données), ce qui fait coïncider les deux espaces
-- d'identifiants et masque entièrement le bug. Corrigé dans ce même fichier
-- de test (fixture désormais avec `users.id` généré séparément de `auth_id`,
-- comme en production réelle) — voir ce fichier pour le nouveau test qui
-- aurait détecté la régression avec l'ancienne fixture.
--
-- Recherche de portée : ce même motif exact (`user_hotels.user_id =
-- auth.uid()` sans passer par `public.users.auth_id`) existe aussi sur
-- `rms_decisions`, `salon_events`, `lighthouse_imports`, `lighthouse_days`,
-- `rms_settings`, `onboarding_tasks`, `mi_imported_events` — vérifié en
-- lecture seule sur `pg_policies`, AUCUNE modification apportée à ces tables
-- ici : elles sont hors périmètre du domaine Support et de la Phase 2 Super
-- Admin, appartiennent à des modules RH/RMS/Salon/Lighthouse actifs,
-- nécessitent leur propre analyse et leurs propres tests dédiés avant toute
-- correction. Signalé explicitement dans le rapport final comme le point le
-- plus prioritaire hors périmètre de cette Phase 2 — nécessite une PR dédiée.
--
-- Corrigé uniquement ici : `support_select`/`support_insert`/`support_update`
-- sur `support_tickets` (jointe via `public.users` pour retrouver le bon
-- `user_id`), strictement nécessaire au Lot 5 (back-office et portail
-- Support) qui dépend directement de cette table.
--
-- Le reste de cette PR est GRANT/REVOKE uniquement, justifié par un audit
-- factuel réel (matrice de rôles ci-dessous), jamais par supposition.
--
-- CONSTAT CENTRAL DE L'AUDIT (le plus grave) : `TRUNCATE` sur une table avec
-- RLS n'est PAS filtré par les policies RLS — c'est une propriété documentée
-- de PostgreSQL (RLS ne s'applique qu'aux commandes DML ligne par ligne :
-- SELECT/INSERT/UPDATE/DELETE). Vérifié réellement en production (BEGIN...
-- ROLLBACK) : le rôle `anon` — utilisé par TOUT visiteur non authentifié —
-- pouvait exécuter `TRUNCATE public.support_tickets` et vider la table
-- entière, tous hôtels confondus, sans passer par aucune policy. Confirmé
-- également sur `help_articles` et sur `authenticated`. C'est la
-- vulnérabilité la plus sérieuse identifiée dans ce lot.
--
-- Matrice de rôles testée réellement en production (BEGIN...ROLLBACK,
-- fixtures temporaires, jamais de donnée réelle modifiée) — 7 profils :
-- anon, authenticated sans hôtel, authenticated hôtel A, authenticated
-- hôtel B (hôtel différent), support_agent, super_admin, service_role —
-- SELECT/INSERT/UPDATE/DELETE sur support_tickets et help_articles. Résumé :
--   - anon             : aucune donnée non publiée visible ni modifiable
--                        (RLS bloque tout), mais grants table-level trop
--                        larges (INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/
--                        TRIGGER accordés alors qu'aucun n'est jamais permis
--                        par aucune policy).
--   - authenticated sans hôtel : aucune donnée visible ni modifiable (RLS),
--                        mêmes grants table-level excessifs qu'anon.
--   - authenticated hôtel A/B  : isolation inter-hôtels confirmée (hôtel B
--                        ne voit jamais les tickets de l'hôtel A, tentative
--                        d'insertion d'un ticket pour un autre hôtel bloquée
--                        par la policy `support_insert`). INSERT/SELECT/
--                        UPDATE sur son propre hôtel fonctionnent (légitime,
--                        à conserver). DELETE bloqué (aucune policy DELETE
--                        n'existe pour ce profil sur support_tickets —
--                        confirmé par GET DIAGNOSTICS ROW_COUNT=0, pas
--                        seulement l'absence d'erreur).
--   - support_agent/super_admin : lecture/mise à jour de tous les tickets
--                        (policies platform_admin_*), gestion complète de
--                        help_articles (policy FOR ALL). DELETE sur
--                        support_tickets également bloqué (aucune policy
--                        DELETE — vérifié à 0 ligne réellement affectée,
--                        corrigeant une première instrumentation de test
--                        erronée qui n'avait vérifié que l'absence d'erreur,
--                        pas l'effet réel — voir sql/tests/support_acl_hardening.sql).
--   - service_role     : bypass RLS confirmé (rolbypassrls=true), propriété
--                        du rôle, jamais exposé à un client — comportement
--                        attendu, aucune action.
--
-- Décisions de durcissement (principe du moindre privilège, aucune policy
-- touchée) :
--   support_tickets  : REVOKE ALL FROM anon (aucun usage légitime, RLS
--                       bloque déjà tout — l'excès de grant est purement du
--                       surface d'attaque inutile, TRUNCATE en tête).
--                       REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE FROM
--                       authenticated (aucune policy ne permet DELETE sur
--                       cette table pour ce rôle, TRUNCATE n'a aucun usage
--                       légitime côté client, REFERENCES/TRIGGER ne sont
--                       jamais utilisés par un rôle API).
--                       INSERT/SELECT/UPDATE conservés pour authenticated
--                       (légitimement utilisés, filtrés par RLS).
--   help_articles    : REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES,
--                       TRIGGER FROM anon (seul SELECT est un usage
--                       légitime et volontaire — policy help_articles_select
--                       autorise explicitement la lecture publique des
--                       articles publiés).
--                       REVOKE TRUNCATE, REFERENCES, TRIGGER FROM
--                       authenticated. **DELETE conservé pour authenticated**
--                       — nécessaire : super_admin/support_agent sont des
--                       lignes dans platform_admins, pas des rôles Postgres
--                       distincts ; ils opèrent sous le rôle Postgres
--                       `authenticated`, et la policy help_articles_write
--                       (FOR ALL) autorise légitimement leur DELETE, filtré
--                       par `platform_admin_role()`.
--   support_ticket_seq : REVOKE USAGE FROM anon (jamais atteint : le
--                       trigger qui l'utilise ne s'exécute qu'après un
--                       INSERT déjà bloqué par RLS pour ce rôle).
--                       USAGE conservé pour authenticated (le trigger
--                       `support_set_ticket_number()` n'est pas SECURITY
--                       DEFINER — il s'exécute avec les droits de l'appelant,
--                       donc authenticated doit garder USAGE pour que les
--                       insertions légitimes de hotel_user continuent de
--                       fonctionner).
--
-- Fonctions trigger (support_set_ticket_number/support_set_updated_at/
-- trg_help_articles_updated_at) : EXECUTE reste accordé à PUBLIC — non
-- modifié. Analyse : ces fonctions retournent le pseudo-type `trigger`,
-- qu'aucun rôle ne peut invoquer directement via SELECT (rejeté par le
-- système de types de PostgreSQL, indépendamment de tout GRANT) ; le
-- déclenchement par trigger n'est lui-même jamais soumis à une vérification
-- EXECUTE séparée. Revoquer ce grant n'aurait aucun effet de sécurité réel
-- — non fait, pour ne pas durcir un point qui n'est pas un risque (cf.
-- doctrine « ne jamais corriger sans preuve réelle », ADR-012 §2.5.4).
--
-- Seules les 3 policies support_select/support_insert/support_update de
-- support_tickets sont modifiées (correction majeure ci-dessus) ; aucune
-- autre policy RLS touchée. Aucune donnée métier modifiée. Pas de
-- BEGIN/COMMIT/ROLLBACK dans ce fichier (même doctrine que sql/80).
-- ============================================================================

DO $harden_support_tickets$
DECLARE
  v_anon_has_truncate boolean;
  v_authenticated_has_truncate boolean;
BEGIN
  SELECT has_table_privilege('anon','public.support_tickets','TRUNCATE') INTO v_anon_has_truncate;
  SELECT has_table_privilege('authenticated','public.support_tickets','TRUNCATE') INTO v_authenticated_has_truncate;

  IF v_anon_has_truncate AND v_authenticated_has_truncate THEN
    RAISE NOTICE '[support_tickets] état pré-durcissement détecté — application du REVOKE.';
    EXECUTE 'REVOKE ALL ON public.support_tickets FROM anon';
    EXECUTE 'REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE ON public.support_tickets FROM authenticated';
    RAISE NOTICE '[support_tickets] durcissement appliqué : anon = aucun privilège ; authenticated = INSERT/SELECT/UPDATE uniquement.';
  ELSIF NOT v_anon_has_truncate AND NOT v_authenticated_has_truncate THEN
    IF has_table_privilege('anon','public.support_tickets','SELECT')
       OR has_table_privilege('anon','public.support_tickets','INSERT')
       OR has_table_privilege('anon','public.support_tickets','UPDATE')
       OR has_table_privilege('anon','public.support_tickets','DELETE') THEN
      RAISE EXCEPTION '[support_tickets] état inattendu : TRUNCATE déjà révoqué mais anon conserve un autre privilège table-level — écart avec le contrat de durcissement attendu (anon ne devrait avoir aucun privilège). Aucune correction automatique.';
    END IF;
    RAISE NOTICE '[support_tickets] déjà durci — aucune action.';
  ELSE
    RAISE EXCEPTION '[support_tickets] état partiel inattendu : anon_has_truncate=% authenticated_has_truncate=% — ni pré-durcissement homogène, ni post-durcissement homogène. Aucune correction automatique.', v_anon_has_truncate, v_authenticated_has_truncate;
  END IF;
END
$harden_support_tickets$;

DO $harden_help_articles$
DECLARE
  v_anon_has_truncate boolean;
  v_authenticated_has_truncate boolean;
BEGIN
  SELECT has_table_privilege('anon','public.help_articles','TRUNCATE') INTO v_anon_has_truncate;
  SELECT has_table_privilege('authenticated','public.help_articles','TRUNCATE') INTO v_authenticated_has_truncate;

  IF v_anon_has_truncate AND v_authenticated_has_truncate THEN
    RAISE NOTICE '[help_articles] état pré-durcissement détecté — application du REVOKE.';
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.help_articles FROM anon';
    EXECUTE 'REVOKE TRUNCATE, REFERENCES, TRIGGER ON public.help_articles FROM authenticated';
    RAISE NOTICE '[help_articles] durcissement appliqué : anon = SELECT uniquement (policy help_articles_select) ; authenticated = INSERT/SELECT/UPDATE/DELETE (policies existantes).';
  ELSIF NOT v_anon_has_truncate AND NOT v_authenticated_has_truncate THEN
    IF has_table_privilege('anon','public.help_articles','INSERT')
       OR has_table_privilege('anon','public.help_articles','UPDATE')
       OR has_table_privilege('anon','public.help_articles','DELETE')
       OR NOT has_table_privilege('anon','public.help_articles','SELECT') THEN
      RAISE EXCEPTION '[help_articles] état inattendu : TRUNCATE déjà révoqué mais les autres privilèges d''anon ne correspondent pas au contrat attendu (SELECT seul). Aucune correction automatique.';
    END IF;
    RAISE NOTICE '[help_articles] déjà durci — aucune action.';
  ELSE
    RAISE EXCEPTION '[help_articles] état partiel inattendu : anon_has_truncate=% authenticated_has_truncate=% — ni pré-durcissement homogène, ni post-durcissement homogène. Aucune correction automatique.', v_anon_has_truncate, v_authenticated_has_truncate;
  END IF;
END
$harden_help_articles$;

DO $harden_sequence$
DECLARE
  v_anon_has_usage boolean;
BEGIN
  SELECT has_sequence_privilege('anon','public.support_ticket_seq','USAGE') INTO v_anon_has_usage;
  IF v_anon_has_usage THEN
    RAISE NOTICE '[support_ticket_seq] état pré-durcissement détecté — application du REVOKE.';
    EXECUTE 'REVOKE USAGE ON SEQUENCE public.support_ticket_seq FROM anon';
    RAISE NOTICE '[support_ticket_seq] durcissement appliqué : anon = aucun privilège ; authenticated conserve USAGE (nécessaire au trigger non-SECURITY-DEFINER).';
  ELSE
    IF NOT has_sequence_privilege('authenticated','public.support_ticket_seq','USAGE') THEN
      RAISE EXCEPTION '[support_ticket_seq] état inattendu : authenticated devrait conserver USAGE (nécessaire aux insertions légitimes) mais ne l''a pas. Aucune correction automatique.';
    END IF;
    RAISE NOTICE '[support_ticket_seq] déjà durci — aucune action.';
  END IF;
END
$harden_sequence$;

-- ----------------------------------------------------------------------------
-- Correction majeure (voir en-tête du fichier) : support_select/support_insert/
-- support_update comparaient user_hotels.user_id directement à auth.uid(), alors
-- que user_hotels.user_id référence public.users.id (pas auth.users.id) — ces
-- policies ne matchaient jamais pour un utilisateur hôtel réel. Corrigé en
-- passant par public.users.auth_id, seule jointure correcte vers auth.uid().
-- ----------------------------------------------------------------------------
DO $fix_support_tickets_hotel_policies$
DECLARE
  v_select_qual text;
  v_insert_check text;
  v_update_qual text;
  v_broken_pattern text := '%user_hotels.user_id = auth.uid()%';
  v_fixed_marker text := '%u.auth_id = auth.uid()%';
BEGIN
  SELECT qual INTO v_select_qual FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets' AND policyname='support_select';
  SELECT with_check INTO v_insert_check FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets' AND policyname='support_insert';
  SELECT qual INTO v_update_qual FROM pg_policies WHERE schemaname='public' AND tablename='support_tickets' AND policyname='support_update';

  IF v_select_qual LIKE v_broken_pattern AND v_insert_check LIKE v_broken_pattern AND v_update_qual LIKE v_broken_pattern THEN
    RAISE NOTICE '[support_tickets policies] motif défectueux détecté (user_hotels.user_id = auth.uid() direct) — correction.';

    EXECUTE $ddl$
      DROP POLICY support_select ON public.support_tickets
    $ddl$;
    EXECUTE $ddl$
      CREATE POLICY support_select ON public.support_tickets FOR SELECT USING (
        hotel_id IN (
          SELECT uh.hotel_id FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id WHERE u.auth_id = auth.uid()
        )
      )
    $ddl$;

    EXECUTE $ddl$
      DROP POLICY support_insert ON public.support_tickets
    $ddl$;
    EXECUTE $ddl$
      CREATE POLICY support_insert ON public.support_tickets FOR INSERT WITH CHECK (
        hotel_id IN (
          SELECT uh.hotel_id FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id WHERE u.auth_id = auth.uid()
        )
      )
    $ddl$;

    EXECUTE $ddl$
      DROP POLICY support_update ON public.support_tickets
    $ddl$;
    EXECUTE $ddl$
      CREATE POLICY support_update ON public.support_tickets FOR UPDATE USING (
        hotel_id IN (
          SELECT uh.hotel_id FROM public.user_hotels uh JOIN public.users u ON u.id = uh.user_id WHERE u.auth_id = auth.uid()
        )
      )
    $ddl$;

    RAISE NOTICE '[support_tickets policies] correction appliquée : jointure via public.users.auth_id sur les 3 policies.';
  ELSIF v_select_qual LIKE v_fixed_marker AND v_insert_check LIKE v_fixed_marker AND v_update_qual LIKE v_fixed_marker THEN
    RAISE NOTICE '[support_tickets policies] déjà corrigées — aucune action.';
  ELSE
    RAISE EXCEPTION '[support_tickets policies] état inattendu (ni motif défectueux homogène, ni motif corrigé homogène) — aucune correction automatique. select=% insert=% update=%', v_select_qual, v_insert_check, v_update_qual;
  END IF;
END
$fix_support_tickets_hotel_policies$;
