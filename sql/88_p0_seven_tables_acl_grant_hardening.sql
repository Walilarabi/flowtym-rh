-- ============================================================================
-- sql/88_p0_seven_tables_acl_grant_hardening.sql
-- P0 sécurité — durcissement des grants sur 7 tables RH/RMS/Salon/Lighthouse
-- (rms_decisions, salon_events, lighthouse_imports, lighthouse_days,
-- rms_settings, onboarding_tasks, mi_imported_events)
--
-- Contexte : ces 7 tables partagent le même motif défectueux que
-- support_tickets AVANT sql/81 (Lot 1 PR-02, ADR-012 §3.5.2) — une ou
-- plusieurs policies RLS comparent `user_hotels.user_id = auth.uid()`
-- directement au lieu de passer par `public.users.auth_id`. Trouvé en
-- lecture seule (pg_policies) pendant le Lot 1 PR-02, hors périmètre Support/
-- Phase 2 à l'époque, signalé et documenté sans correction (ADR-012 §2, §9).
--
-- CE FICHIER NE CORRIGE PAS LES POLICIES. Audit réel effectué avant d'écrire
-- une seule ligne de code (voir tableau ci-dessous) : sur les 7 tables,
-- SEULES les grants table-level excédentaires (mêmes vecteurs que
-- support_tickets : TRUNCATE non filtré par RLS, REFERENCES/TRIGGER sans
-- usage légitime côté API) constituent une vulnérabilité PROUVÉE et
-- UNIFORME sur les 7 — corrigée ici, à l'identique de sql/81. Les policies
-- RLS elles-mêmes se répartissent en deux situations réellement distinctes,
-- vérifiées par lecture directe de pg_policies ET des définitions de
-- get_user_hotel_id()/get_user_role() (qui, elles, joignent correctement via
-- public.users.auth_id) :
--
--   A. lighthouse_days, lighthouse_imports : possèdent CHACUNE une policy
--      supplémentaire basée sur get_user_hotel_id() (correcte) EN PLUS de
--      la policy défectueuse (`_own`, jamais concluante). RLS additionne les
--      policies par OR : la policy correcte suffit à accorder l'accès réel
--      à un utilisateur hôtel légitime. La policy `_own` est du code mort
--      (jamais vraie), pas une vulnérabilité — elle ne PEUT PAS élargir
--      l'accès au-delà de ce que la policy correcte autorise déjà.
--      Nettoyage cosmétique possible ultérieurement, non urgent.
--   B. rms_decisions, rms_settings, salon_events, onboarding_tasks,
--      mi_imported_events : n'ont AUCUNE policy de repli correcte. Leur(s)
--      seule(s) policy(ies) RLS ne matchent jamais un utilisateur hôtel réel
--      → ces tables sont aujourd'hui INACCESSIBLES en lecture/écriture via
--      un appel client direct (PostgREST), quel que soit l'utilisateur —
--      c'est un défaut FONCTIONNEL (verrouillage, fail-closed), PAS une
--      fuite de données (aucune ligne n'est exposée à qui que ce soit tant
--      que la policy ne matche jamais). `onboarding_tasks` est confirmé
--      appelée directement par `index.html` (`.from('onboarding_tasks')`,
--      lignes ~1315/1324) — si cette fonctionnalité semble cassée en
--      production aujourd'hui, cette policy en est très probablement la
--      cause ; à vérifier et corriger par l'équipe propriétaire du domaine
--      RH/onboarding, DANS UNE PR SÉPARÉE, DÉDIÉE À CE DOMAINE, jamais dans
--      une PR de sécurité P0 (une correction de policy change un
--      comportement fonctionnel, ne doit jamais être mêlée à un simple
--      retrait de privilège excédentaire — même doctrine que sql/81/ADR-012
--      §1 : « une PR de durcissement distincte du rétro-versionnement,
--      jamais fusionnée avec lui »). Aucune RPC ne référence ces 7 tables
--      (vérifié par recherche exhaustive dans sql/*.sql) : tout accès
--      passe par PostgREST direct, donc par RLS — leur éventuel
--      dysfonctionnement fonctionnel n'est pas masqué par un contournement
--      SECURITY DEFINER quelque part.
--
-- Vulnérabilité prouvée en production avant correction (transaction
-- annulée, aucune donnée modifiée) : `anon` a pu exécuter
-- `TRUNCATE public.rms_decisions` avec succès — confirmé le 31/07/2026.
-- TRUNCATE n'est structurellement jamais filtré par RLS (propriété
-- documentée de PostgreSQL — RLS ne s'applique qu'aux commandes DML ligne
-- par ligne SELECT/INSERT/UPDATE/DELETE), donc ce constat s'étend
-- nécessairement aux 6 autres tables partageant les mêmes grants par
-- défaut (vérifié directement, tableau identique sur les 7).
--
-- Décision de durcissement : REVOKE ALL FROM anon (aucun usage légitime
-- identifié sur aucune des 7 tables — ce sont des tables opérationnelles
-- internes RH/RMS/Salon/Lighthouse, jamais exposées publiquement,
-- contrairement à help_articles) ; REVOKE TRUNCATE, REFERENCES, TRIGGER,
-- DELETE FROM authenticated (aucune policy DELETE n'existe sur aucune des
-- 7 tables — confirmé — donc DELETE est déjà inopérant pour authenticated,
-- son retrait est cohérent avec sql/81 §Périmètre ; TRUNCATE/REFERENCES/
-- TRIGGER n'ont aucun usage légitime côté API PostgREST, qui n'expose
-- jamais ces commandes). INSERT/SELECT/UPDATE conservés pour authenticated
-- sur les 7 tables, à l'identique de sql/81 pour support_tickets — leur
-- filtrage par RLS (correct ou non selon la situation A/B ci-dessus) n'est
-- PAS modifié par cette migration.
--
-- Trois-états (absent/conforme/divergent) implicite via has_table_privilege :
-- le bloc échoue explicitement si l'état constaté ne correspond ni au
-- « avant » ni à l'« après » attendu, plutôt que d'appliquer aveuglément.
--
-- Pas de BEGIN/COMMIT/ROLLBACK. SQL pur, compatible apply_migration.
-- ============================================================================

DO $harden_seven_tables$
DECLARE
  v_table text;
  v_tables text[] := ARRAY[
    'rms_decisions', 'salon_events', 'lighthouse_imports', 'lighthouse_days',
    'rms_settings', 'onboarding_tasks', 'mi_imported_events'
  ];
  v_anon_has_truncate boolean;
  v_authenticated_has_truncate boolean;
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'anon', 'public.' || v_table, 'TRUNCATE') INTO v_anon_has_truncate;
    EXECUTE format('SELECT has_table_privilege(%L, %L, %L)', 'authenticated', 'public.' || v_table, 'TRUNCATE') INTO v_authenticated_has_truncate;

    IF v_anon_has_truncate AND v_authenticated_has_truncate THEN
      RAISE NOTICE '[%] état pré-durcissement détecté — application du REVOKE.', v_table;
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', v_table);
      EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE ON public.%I FROM authenticated', v_table);
      RAISE NOTICE '[%] durcissement appliqué : anon = aucun privilège ; authenticated = INSERT/SELECT/UPDATE uniquement.', v_table;
    ELSIF NOT v_anon_has_truncate AND NOT v_authenticated_has_truncate THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.role_table_grants
        WHERE table_schema = 'public' AND table_name = v_table AND grantee = 'anon'
      ) THEN
        RAISE EXCEPTION '[%] état inattendu : TRUNCATE déjà révoqué mais anon conserve un autre privilège table-level — écart avec le contrat de durcissement attendu (anon ne devrait avoir aucun privilège). Aucune correction automatique.', v_table;
      END IF;
      RAISE NOTICE '[%] déjà durci — aucune action.', v_table;
    ELSE
      RAISE EXCEPTION '[%] état partiel inattendu : anon_has_truncate=% authenticated_has_truncate=% — ni pré-durcissement homogène, ni post-durcissement homogène. Aucune correction automatique.', v_table, v_anon_has_truncate, v_authenticated_has_truncate;
    END IF;
  END LOOP;
END
$harden_seven_tables$;
