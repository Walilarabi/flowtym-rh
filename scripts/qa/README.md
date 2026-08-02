# Recette d'acceptation staging — Phase 2 Super Admin

Workflow GitHub Actions **manuel** (`workflow_dispatch` uniquement, jamais sur `push`/`pull_request`)
qui exécute une recette complète et réelle (HTTP, pas de mock) contre la branche de staging
Supabase dédiée à la Phase 2, puis nettoie systématiquement ce qu'il a créé.

## Portée

- Aucun code métier dans cette PR : uniquement `.github/workflows/phase2-staging-acceptance.yml`,
  `scripts/qa/phase2-staging-acceptance.sh`, les fixtures de référence
  `scripts/qa/fixtures/production_*.json`, et ce document.
- La cible est **exclusivement** la branche de staging (nom `phase2-staging`, project ref
  `jutigvpcwiwvxkabbolg`). Le script refuse de s'exécuter si l'URL contient le project ref de
  production ou tout autre ref de la liste interdite, si `CONFIRM_STAGING` ≠ `YES`, ou si
  l'environnement GitHub n'est pas nommé `phase2-staging`.
- **Cette branche n'est pas un projet Supabase séparé** : c'est une branche (Supabase Branching
  2.0) rattachée au projet `flowtym-housekeeping` (ref `hzrzkvdebaadditvbqis`), organisation
  `walilarabi@gmail.com's Org`. Elle n'apparaît donc pas dans la liste des projets du tableau de
  bord, mais dans l'onglet **Branches** de ce projet. Voir §1 pour la procédure d'accès exacte.

## 1. Localiser la branche de staging et récupérer les secrets

**`phase2-staging` n'est pas un projet Supabase distinct** — c'est une branche (Supabase
Branching 2.0) du projet `flowtym-housekeeping` (ref `hzrzkvdebaadditvbqis`), organisation
`walilarabi@gmail.com's Org`. Pour y accéder :

1. Dashboard Supabase → ouvrir le projet **flowtym-housekeeping**.
2. Menu de gauche (ou sélecteur en haut de l'écran) → **Branches**.
3. Cliquer sur la branche **`phase2-staging`** (project ref `jutigvpcwiwvxkabbolg`) → cela ouvre
   sa propre console, distincte de celle de production.
4. Dans cette console de branche → **Project Settings → API** : c'est là que se trouvent son URL,
   sa clé anon/publishable et sa clé service_role — **jamais celles de production**.
5. Dans cette même console de branche → **Edge Functions → platform-send-notification →
   Secrets** : c'est là que se configurent `PLATFORM_NOTIFICATION_INTERNAL_KEY` et
   `RESEND_API_KEY` (voir tableau ci-dessous).

## 2. Secrets GitHub à configurer

Dans **Settings → Environments → phase2-staging → Environment secrets** de ce dépôt (pas en
secrets de repo globaux — l'environnement `phase2-staging` doit exister, le workflow le
référence explicitement), ajoute exactement ces quatre secrets, avec les valeurs récupérées à
l'étape précédente :

| Nom exact | Contenu |
|---|---|
| `PHASE2_STAGING_URL` | URL de l'API de la branche `phase2-staging` (`https://jutigvpcwiwvxkabbolg.supabase.co`) |
| `PHASE2_STAGING_ANON_KEY` | Clé anon/publishable de la branche `phase2-staging` |
| `PHASE2_STAGING_SERVICE_ROLE_KEY` | Clé service_role de la branche `phase2-staging` (setup/cleanup uniquement) |
| `PHASE2_NOTIFICATION_INTERNAL_KEY` | Même valeur que `PLATFORM_NOTIFICATION_INTERNAL_KEY` configuré sur l'Edge Function `platform-send-notification` de la branche `phase2-staging` |

La clé Resend (`RESEND_API_KEY`) reste exclusivement dans les secrets d'Edge Function de la
branche `phase2-staging` (Dashboard → Edge Functions → Secrets) — elle n'est **jamais** lue
par GitHub Actions ni transmise au workflow.

## 3. Lancer le workflow (3 étapes)

1. Onglet **Actions** du dépôt → sélectionner **"Phase 2 — Recette d'acceptation staging"**.
2. Cliquer **Run workflow**.
3. Dans le champ `confirm_staging`, taper exactement `YES`, puis **Run workflow**.

Avant toute autre action (migration, setup, test, appel Edge Function), le workflow exécute une
étape dédiée **"Valider la cible (garde-fou obligatoire, avant toute action)"** qui vérifie, à
partir de 3 sources indépendantes (`PHASE2_STAGING_URL`, le ref encodé dans le JWT de la clé
anon, le ref encodé dans le JWT de la clé service_role), que la cible est exactement et
uniquement la branche `phase2-staging` (ref `jutigvpcwiwvxkabbolg`) — jamais la production. La
même validation est répétée en tout premier dans `scripts/qa/phase2-staging-acceptance.sh`
lui-même (`scripts/qa/lib/target-guard.sh`). Un test de non-régression dédié
(`scripts/qa/tests/test-target-guard.sh`) tourne automatiquement sur chaque push/PR (CI
`ci.yml`, job "QA — garde-fou cible phase2-staging (non-régression)") pour garantir que ce
garde-fou ne peut pas être supprimé ou affaibli accidentellement.

## 4. Résultat

- Le résumé du run (onglet Summary du job) affiche PASS/FAIL/verdict.
- Un artefact `phase2-staging-acceptance-result` (rétention 30 jours) contient
  `phase2-staging-acceptance-result.json` (liste des vérifications, codes HTTP, timestamps —
  aucun secret, aucun JWT, aucun payload sensible complet) et `structural_diff.json` (détail de
  la comparaison structurelle staging/production).
- Le job échoue (exit non nul) au premier échec critique (ex. login impossible, fixture
  impossible à créer) ; les échecs non critiques sont listés en fin de run sans interrompre le
  reste de la recette.

## 5. Comparaison structurelle staging/production

`scripts/qa/fixtures/production_schema_snapshot.json` et
`production_functions_snapshot.json` sont des instantanés **read-only** de la structure réelle
de production (colonnes, types, nullabilité, contraintes, index, triggers, RLS enabled/forced,
policies, grants, signatures de fonctions, search_path, owner), capturés une fois et committés
— le workflow ne se connecte **jamais** à la production, il compare le staging live à cette
référence figée.

Deux catégories de tables :
- **Tables de référence (42)** : existent déjà en production, doivent structurellement
  correspondre exactement au snapshot committé.
- **Tables Phase 2 nouvelles (4)** : `platform_notifications`, `support_ticket_replies`,
  `support_ticket_attachments`, `support_ticket_attachment_access_log` — introduites par les PR
  encore ouvertes (sql/80-89), pas encore en production. Contrôle d'existence + RLS activée
  uniquement, jamais comparées à un snapshot de production puisqu'elle ne les a pas encore.

**État connu (rejeu natif Supabase pur, vérifié à deux reprises, zéro intervention manuelle) :**
le rejeu des 262 migrations réelles de production sur une branche vierge est déterministe et
reproductible (deux rejeux indépendants strictement identiques). La comparaison structurelle,
elle, **échouera néanmoins** sur 16 des 42 tables de référence — et c'est le comportement attendu
du contrôle : il détecte une dérive réelle et préexistante de la production elle-même, jamais un
défaut du rejeu. Vérifié en lecture seule directement sur la production (`hzrzkvdebaadditvbqis`),
exemples confirmés :
- `audit_logs` : RLS activée en production avec 4 policies (`audit_hotel_read`,
  `audit_logs_admin_read`, `audit_logs_modify`, `audit_logs_select`) — absentes de tout fichier
  `sql/*.sql` tracké, donc absentes après un rejeu pur.
- `users.hotel_id` / `users.auth_id` : `NOT NULL` en production réelle, `NULL`-able après rejeu
  pur — un `ALTER COLUMN ... SET NOT NULL` a été appliqué directement en production sans jamais
  passer par une migration trackée.
- Plusieurs tables (`hotels`, `rooms`, `invoices`, `payments`, `rms_decisions`, `rms_settings`,
  `lighthouse_days`, `employees`, `help_articles`, `staff_departments`, `user_invitations`)
  portent en production des colonnes/contraintes/index/triggers absents de l'historique tracké.

**Cause racine confirmée : dérive non trackée de la production elle-même** (modifications
appliquées directement — Dashboard/SQL manuel — jamais capturées par une migration versionnée),
**pas** une reconstruction manuelle défaillante du staging (l'ancienne branche de staging
reconstruite à la main, et le diagnostic qui l'accompagnait, ont été remplacés par ce rejeu natif
pur — voir le rapport de qualification SQL du 1er août 2026). La comparaison structurelle
continue donc, à raison, de signaler ces 16 tables comme divergentes. **Ce n'est pas un bug de
cette PR QA ni du rejeu** : combler cette dérive documentée exigerait de nouvelles migrations de
rattrapage, un travail de réparation des migrations explicitement fermé et hors périmètre de
cette PR.

## 6. Nettoyage de secours

Le `trap EXIT` du script nettoie toujours ses fixtures (comptes Auth + lignes de tables),
identifiées par un `RUN_TAG` unique (`phase2qa-<timestamp>-<run_id>`) affiché en tête de log et
inclus dans l'artefact. Si le nettoyage automatique échoue partiellement (rapporté explicitement
dans le résumé et l'artefact) ou si le job est interrompu brutalement :

1. Dashboard Supabase → projet **flowtym-housekeeping** → **Branches** → **phase2-staging** →
   **Authentication** → filtrer par le `RUN_TAG` du run concerné (visible dans les
   logs/l'artefact) → supprimer les comptes correspondants.
2. Même branche → **Table Editor** → sur `hotels`, `users`, `user_hotels`, `platform_admins`,
   `subscription_plans`, `platform_apps`, `hotel_subscriptions`, `support_tickets`,
   `platform_notifications` → filtrer les lignes dont le nom/email contient le `RUN_TAG` →
   supprimer.

## 7. Gestion du staging après une recette concluante

Ne pas supprimer l'environnement de staging tant que cette recette n'est pas passée avec succès
au moins une fois. Une fois concluante : exporter les preuves (artefact du run), supprimer la
branche `phase2-staging` (Dashboard → flowtym-housekeeping → Branches), supprimer ou renouveler
`PHASE2_NOTIFICATION_INTERNAL_KEY` et la clé Resend associée, confirmer qu'aucune ressource
temporaire ne reste active.
