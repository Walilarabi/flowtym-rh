# Rapport de migrations — Phase 2 Super Admin (sql/80 à sql/89)

Couvre exactement les fichiers demandés par le CTO (« sql/80-87 + la nouvelle migration P0 ») plus `sql/89`, ajoutée pendant le round de stabilisation (item 9, source unique de vérité des licences) et qui modifie le comportement de `sql/83`/`sql/87`. Aucune de ces migrations n'est appliquée en production à la date de ce rapport (2026-07-31) — statut confirmé par `list_migrations` (Supabase) avant rédaction.

Convention de lecture par migration : **Objet** · **Dépendances** · **État actuel en production** · **Comportement attendu après application** · **Tests** · **Ordre d'application** · **Vérifications post-application**.

---

## sql/80 — `support_retro_versioning.sql`

- **Objet** : rétro-versionnement à l'identique de `support_tickets`/`help_articles` (déjà présents en production, jamais versionnés) — colonnes, contraintes, index, séquence, 3 fonctions/triggers, 7 policies RLS, grants, commentaires. Doctrine trois états (`DO $domain_support_tickets$` : absent → création / conforme → no-op / divergent → `RAISE EXCEPTION`), empreinte structurelle globale calculée depuis `pg_catalog`.
- **Dépendances** : aucune (objets déjà présents et audités en production, cf. ADR-012 §2.5).
- **État actuel en production** : `support_tickets`/`help_articles` existent déjà, non versionnés côté dépôt. La migration est donc un **no-op confirmé** en l'état actuel (vérifié par `BEGIN...ROLLBACK` : OID identiques avant/après, `support_ticket_seq.last_value` inchangé, aucun `nextval()`).
- **Comportement attendu** : aucun changement de comportement ni de permission en production (c'est strictement le but — le durcissement ACL est sql/81, distinct).
- **Tests** : `sql/tests/support_retro_versioning.sql` (`\ir`, jamais appliqué en prod par cette voie) + smoke test complet sur PostgreSQL 16.13 local jetable (4 états : absent/conforme/partiel/divergent).
- **Ordre d'application** : en premier parmi le domaine Support (PR #21, base `main`).
- **Vérifications post-application** : `SELECT support_contract_v1()` (empreinte) doit être identique avant/après ; `\d support_tickets` doit lister exactement les mêmes policies qu'avant migration (aucun changement de permission).

## sql/81 — `support_acl_hardening.sql`

- **Objet** : durcissement ACL/RLS du domaine Support. **Correction majeure découverte pendant la conception** : les policies `support_select`/`support_insert`/`support_update` comparaient `user_hotels.user_id = auth.uid()` directement — `user_hotels.user_id` référence `public.users.id`, pas `auth.users.id` ; `auth.uid()` renvoie l'`auth_id` du JWT. Ces policies ne matchaient donc **jamais** pour un utilisateur hôtel réel (prouvé en production avec un compte réel, transaction annulée). Corrigées en passant par `public.users.auth_id`.
- **Dépendances** : strictement postérieure à sql/80 (mais indépendante fonctionnellement).
- **État actuel en production** : les 3 policies défectueuses sont actives — un utilisateur hôtel réel ne peut aujourd'hui voir/écrire aucun ticket via ces policies (fail-closed, pas de fuite).
- **Comportement attendu** : les utilisateurs hôtel réels retrouvent l'accès à leurs propres tickets ; `anon`/rôles non concernés restent bloqués.
- **Tests** : `sql/tests/support_acl_hardening.sql` — fixtures avec un vrai compte hôtel (`users.id != auth_id`, représentatif de la production) prouvant la régression puis la correction.
- **Ordre d'application** : immédiatement après sql/80 (PR #22, base historiquement `main`, actuellement contient aussi le fix décrit dans PR #22 mise à jour — voir item 6).
- **Vérifications post-application** : un compte hôtel réel doit voir exactement ses propres tickets (test SELECT direct) ; `EXPLAIN` des policies ne doit référencer que `public.users.auth_id`, plus jamais `user_hotels.user_id = auth.uid()`.

## sql/82 — `platform_notifications.sql`

- **Objet** : fondation transverse de notifications (table `platform_notifications`, RLS activée sans policy, `dedupe_key` UNIQUE, canal email uniquement) + Edge Function `platform-send-notification` (authentification `x-internal-key`, jamais un JWT utilisateur), registre de templates versionné côté Edge Function.
- **Dépendances** : aucune. Indépendant des Lots 1.
- **État actuel en production** : `platform_notifications` n'existe pas.
- **Comportement attendu** : création de la table (absent → création ; présent et conforme → no-op ; état inattendu → `RAISE EXCEPTION`). Aucune donnée existante affectée (nouvel objet isolé).
- **Tests** : `sql/tests/platform_notifications.sql` (idempotence par `dedupe_key`, garde de concurrence `pending→sending` via `ROW_COUNT`, `anon`/`authenticated` bloqués, `service_role` OK) — validés sur base locale éphémère uniquement (`lot2_test`), **pas encore rejoués en transaction annulée sur la production réelle** (limite documentée dans la PR #23 depuis l'origine).
- **Ordre d'application** : indépendant, mais doit précéder sql/84, sql/85, sql/86 (qui en dépendent fonctionnellement pour la notification).
- **Vérifications post-application** : `INSERT` de test avec `dedupe_key` dupliqué doit échouer silencieusement (`ON CONFLICT DO NOTHING`, 0 ligne ajoutée) ; `anon`/`authenticated` doivent recevoir `permission denied` sur `SELECT`.

## sql/83 — `super_admin_lot3_license_usage_observation.sql`

- **Objet** : `admin_list_license_usage()` (quota vs consommation réelle par hôtel) + extension d'`admin_platform_alerts()` (type `license_quota_exceeded`, même prédicat que la fonction de listing).
- **Dépendances** : aucune. Indépendant des Lots 1/2.
- **État actuel en production** : ces deux fonctions n'existent pas sous cette forme (`admin_platform_alerts()` existe déjà depuis sql/76, sans la branche `license_quota_exceeded`).
- **Comportement attendu** : **superseded par sql/89** (voir plus bas) — `sql/83` crée la première version de `admin_list_license_usage()` (calcul dupliqué en SQL direct), que `sql/89` réécrit ensuite (`CREATE OR REPLACE`) pour déléguer à `_hotel_license_usage_snapshot()`. Les deux fichiers doivent être appliqués **dans l'ordre** (83 avant 89) pour que la fonction existe déjà au moment où 89 la remplace — 89 échouerait sinon sur `admin_platform_alerts()` qui utilise `CREATE OR REPLACE` sur une fonction déjà existante depuis sql/76, donc ce n'est pas bloquant en soi, mais la doctrine de non-duplication (item 9) n'est atteinte qu'une fois 89 appliqué.
- **Tests** : `sql/tests/lot3_license_usage_observation.sql` — quota `NULL` → toujours `unavailable`, fixture de dépassement réellement injectée (`snapshot_limits.max_users = 0` sur un abonnement réel, annulée par `ROLLBACK`), prédicat strictement identique entre les deux fonctions.
- **Ordre d'application** : après sql/80/81/82 (indépendant en réalité, mais avant sql/89 qui le réécrit).
- **Vérifications post-application** : `admin_list_license_usage()` et `admin_platform_alerts()` (branche `license_quota_exceeded`) doivent renvoyer un ensemble d'hôtels en dépassement strictement identique.

## sql/84 — `trial_ending_notifications.sql`

- **Objet** : notifications de fin d'essai (J-7/J-3/J-1) via `_trial_ending_notification_candidates()` (source unique du prédicat d'éligibilité), `admin_preview_trial_ending_notifications()`, `admin_run_trial_ending_notifications()`.
- **Dépendances** : sql/82 (`platform_notifications`).
- **État actuel en production** : aucune de ces fonctions n'existe.
- **Comportement attendu** : **corrigé pendant le round de stabilisation (item 10, commit `2182d57`)** — le `dedupe_key` initial ne contenait pas la date d'échéance, donc un palier déjà notifié n'était jamais renotifié après une extension/un raccourcissement de l'essai. Le `dedupe_key` inclut désormais `to_char((trial_ends_at AT TIME ZONE 'Europe/Paris')::date, 'YYYY-MM-DD')`, garantissant un nouveau cycle de notification à chaque changement réel d'échéance, tout en préservant l'idempotence intra-cycle.
- **Tests** : `sql/tests/trial_ending_notifications.sql` — idempotence stricte (2 exécutions successives), extension dans la même fenêtre (nouveau `dedupe_key`, historique préservé), raccourcissement déclenchant un nouveau cycle, bord Europe/Paris à minuit, exclusion sur transition de statut trial→active.
- **Ordre d'application** : après sql/82.
- **Vérifications post-application** : déplacer `trial_ends_at` d'un hôtel de test doit produire un nouveau `dedupe_key` distinct de l'ancien ; rejouer `admin_run_trial_ending_notifications()` deux fois de suite sans changement de date doit produire exactement 1 ligne insérée, la 2ᵉ fois 0 ligne avec `skipped_already_sent` > 0.

## sql/85 — `support_ticket_replies.sql`

- **Objet** : fil de réponses append-only (`support_ticket_replies`) avec notes internes et masquage audité, RPC de triage/réponse/masquage. Doctrine trois états pour la création de table (corrigée pendant le round de stabilisation, item 8, commit `14b03d0` — remplace un `CREATE TABLE IF NOT EXISTS` initial).
- **Dépendances** : sql/80 (`support_tickets`) et sql/82 (`platform_notifications`, pour les notifications de suivi).
- **État actuel en production** : `support_ticket_replies` n'existe pas.
- **Comportement attendu** : absent → création complète (colonnes, contraintes dont `support_ticket_replies_internal_note_author_check`, index, trigger `_check_support_ticket_reply_correction_same_ticket`, policies, grants, commentaire) ; conforme → no-op ; divergent → `RAISE EXCEPTION` avec diagnostic.
- **Tests** : `sql/tests/support_ticket_replies.sql` — correction cross-ticket rejetée par trigger, append-only confirmé (`UPDATE` direct rejeté), RLS testée avec un compte hôtel réel, `support_agent` autorisé/`billing_admin` bloqué, rejeu no-op (cas B), contrainte corrompue → exception (cas C, `SAVEPOINT`).
- **Ordre d'application** : après sql/80 et sql/82.
- **Vérifications post-application** : `pg_get_constraintdef()` de `support_ticket_replies_internal_note_author_check` doit correspondre exactement à la chaîne attendue dans le fichier (piège déjà rencontré une fois — vérifier par sonde directe, ne jamais supposer) ; une 2ᵉ application immédiate doit être un no-op silencieux.

## sql/86 — `support_ticket_attachments.sql`

- **Objet** : portail hôtel Support (`hotel_reply_support_ticket()`, `_can_access_support_ticket()`), pièces jointes (`support_ticket_attachments`, `support_ticket_attachment_access_log`, statuts antivirus honnêtes — `clean` jamais atteint automatiquement), bucket Storage privé, `list_support_ticket_attachments()`, et **nouvelle RPC `admin_delete_support_ticket_attachment()`** (suppression logique, ajoutée pendant le round de stabilisation, item 4).
- **Dépendances** : sql/85 (`support_ticket_replies`), sql/80 (`support_tickets`).
- **État actuel en production** : aucun de ces objets n'existe.
- **Comportement attendu** : doctrine trois états pour les deux tables (corrigée pendant le round de stabilisation, item 8) ; bucket Storage privé upserté avec `public = false` forcé explicitement (corrige une dérive possible si le bucket existait déjà en `public = true`).
- **Tests** : `sql/tests/support_ticket_attachments.sql` — isolation cross-hôtel, rejet admin sur la RPC hôtel, CHECK mime_type/taille, accès table direct refusé, bucket privé sans policy `storage.objects`, re-upsert idempotent après dérive `public=true`, RPC de suppression (motif obligatoire, journalisée, double-suppression rejetée).
- **Ordre d'application** : après sql/85.
- **Vérifications post-application** : `SELECT public FROM storage.buckets WHERE id = 'support-ticket-attachments'` doit renvoyer `false` ; aucune policy sur `storage.objects` pour ce bucket ne doit exister (accès Edge Function uniquement).

## sql/87 — `super_admin_lot6_statistics_health_score.sql`

- **Objet** : `admin_platform_statistics()` (KPIs plateforme globaux), `_hotel_license_usage_rows()` (helper interne, **remplacé par sql/89**), `_hotel_health_subscores(p_hotel_id)`, `admin_hotel_health_scores()` (score de santé client/hôtel composite).
- **Dépendances** : sql/83 (licences), sql/85/86 (support, pour les sous-scores liés aux tickets).
- **État actuel en production** : aucun de ces objets n'existe.
- **Comportement attendu** : **partiellement superseded par sql/89**, qui fait un `CREATE OR REPLACE` sur `admin_platform_statistics()` (source de licences changée pour `_hotel_license_usage_snapshot()`) et sur `_hotel_health_subscores()` (idem), puis `DROP FUNCTION _hotel_license_usage_rows()`. `sql/87` doit donc être appliqué avant `sql/89`, jamais après (sinon `sql/89` recréerait `_hotel_license_usage_rows()` implicitement absent à corriger, et l'ordre `DROP` en fin de sql/89 échouerait si `sql/87` n'a pas déjà créé cette fonction).
- **Tests** : suite Jest 522/522 + smoke test Playwright mocké (KPIs, score de santé, 4 statuts de licence).
- **Ordre d'application** : après sql/83, sql/85, sql/86 ; **avant** sql/89.
- **Vérifications post-application** : `admin_hotel_health_scores()` doit renvoyer un score cohérent (0-100) pour un hôtel réel ; aucune erreur de fonction manquante (`_hotel_license_usage_rows` doit exister à ce stade, avant d'être droppée par sql/89).

## sql/88 — `p0_seven_tables_acl_grant_hardening.sql` (nouvelle migration P0, item 5)

- **Objet** : durcissement des grants table-level sur 7 tables (`rms_decisions`, `salon_events`, `lighthouse_imports`, `lighthouse_days`, `rms_settings`, `onboarding_tasks`, `mi_imported_events`) partageant le même motif que `support_tickets` avant sql/81 — `REVOKE ALL ... FROM anon` + `REVOKE TRUNCATE, REFERENCES, TRIGGER, DELETE ... FROM authenticated`. **Ne modifie aucune policy RLS** (audit réel documenté dans la PR #31 : 2 tables ont une policy de repli correcte — code mort inoffensif ; 5 tables n'ont aucune policy correcte — verrouillage fonctionnel préexistant, pas une fuite, hors périmètre de cette PR).
- **Dépendances** : aucune. Basée sur `main`, indépendante des branches Phase 2.
- **État actuel en production** : `anon` possède aujourd'hui `TRUNCATE` sur les 7 tables — **prouvé directement en production** (transaction annulée : `TRUNCATE public.rms_decisions` exécuté avec succès par `anon` avant correction).
- **Comportement attendu** : après application, `anon` = aucun privilège sur les 7 tables ; `authenticated` = exactement SELECT/INSERT/UPDATE (DELETE était déjà inopérant, aucune policy DELETE n'existant sur aucune des 7 tables).
- **Tests** : `sql/tests/p0_seven_tables_acl_grant_hardening.sql` — 10/10 assertions PASS (état pré-durcissement, preuve directe TRUNCATE avant/après, matrices de grants, non-régression RLS sur `lighthouse_days` avec un compte réel, idempotence, comptage de policies inchangé).
- **Ordre d'application** : indépendante, peut être appliquée avant ou après sql/80/81 (même nature de correctif, tables différentes — pas de dépendance réelle).
- **Vérifications post-application** : `anon` doit recevoir `insufficient_privilege` sur `TRUNCATE rms_decisions` ; `authenticated` doit recevoir `insufficient_privilege` sur `TRUNCATE onboarding_tasks` ; `onboarding_tasks` reste fonctionnellement verrouillée pour tous (comportement préexistant inchangé, PAS corrigé par cette migration — correction séparée nécessaire, domaine RH/onboarding).

## sql/89 — `super_admin_license_usage_single_source_of_truth.sql` (nouvelle migration, item 9)

- **Objet** : élimine la duplication du calcul de consommation de licences entre `admin_list_license_usage()` (sql/83), `_hotel_license_usage_rows()` (sql/87) et la branche `license_quota_exceeded` d'`admin_platform_alerts()` (sql/83). Crée `_hotel_license_usage_snapshot()` (helper interne, **zéro grant à quiconque**, `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role`), puis `CREATE OR REPLACE` de 4 consommateurs pour qu'ils sourcent tous depuis ce helper unique : `admin_list_license_usage()`, `admin_platform_alerts()`, `admin_platform_statistics()`, `_hotel_health_subscores()`. Termine par `DROP FUNCTION IF EXISTS public._hotel_license_usage_rows()`.
- **Dépendances** : sql/83, sql/87 (réécrit leurs fonctions).
- **État actuel en production** : aucun des objets concernés n'existe (dépend de sql/83/87, non appliquées).
- **Comportement attendu** : les 4 consommateurs renvoient un résultat identique à avant (même hôtel, mêmes chiffres) — c'est un refactor de calcul, pas un changement de comportement observable.
- **Tests** : `sql/tests/license_usage_single_source_of_truth.sql` — chaîne `\ir` sql/81/82/83/85/86/87 puis sql/89, comparaison avant/après sur un hôtel réel (Au Royal Mad), 4/4 tests PASS (résultat identique par les 4 consommateurs, helper interne inaccessible directement à `anon`/`authenticated`/`service_role`).
- **Ordre d'application** : **dernière** migration de la chaîne — après sql/83 et sql/87 impérativement (sinon les `CREATE OR REPLACE` échouent sur des fonctions inexistantes, et le `DROP FUNCTION _hotel_license_usage_rows()` final échoue si sql/87 n'a jamais créé cet objet).
- **Vérifications post-application** : `SELECT * FROM _hotel_license_usage_snapshot()` doit échouer avec `permission denied` pour toute connexion `anon`/`authenticated`/`service_role` directe (aucun grant) ; les 4 consommateurs doivent continuer à fonctionner normalement pour `authenticated`+`is_platform_admin()`.

---

## Ordre d'application global recommandé (résumé)

```
80 → 81 → 82 → 83 → 84 → 85 → 86 → 87 → 89
```
`88` est indépendante et peut être insérée n'importe où dans cette chaîne (recommandé : en tout premier, avant `80`, puisqu'elle ne dépend de rien et corrige une exposition `TRUNCATE` déjà prouvée en production).

Cet ordre reflète les dépendances **de contenu SQL** (quelle fonction référence quel objet), pas nécessairement l'ordre de merge des PR GitHub — voir le rapport séparé sur l'empilement des PR (item 12) et `docs/deployment-runbook-phase2.md` §2 pour la correspondance PR ↔ branche ↔ ordre réel.

## Limite de ce rapport

Aucune de ces 10 migrations n'a été appliquée en production au moment de la rédaction. Chaque migration a été validée soit en transaction annulée (`BEGIN...ROLLBACK`) directement sur la production réelle pour celles qui en dépendent (80, 81, 83, 84, 85, 86, 88, 89), soit sur une base locale/éphémère isolée pour celle qui ne pouvait pas encore l'être sans ses dépendances en place (82 — voir sa limite documentée ci-dessus, non encore rejouée en transaction annulée sur la production réelle). Les « Vérifications post-application » listées ci-dessus sont des procédures à exécuter lors du déploiement réel (voir runbook), pas des résultats déjà obtenus en production.
