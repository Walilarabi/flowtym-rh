# Recette d'acceptation staging — Phase 2 Super Admin

Workflow GitHub Actions **manuel** (`workflow_dispatch` uniquement, jamais sur `push`/`pull_request`)
qui exécute une recette complète et réelle (HTTP, pas de mock) contre la branche de staging
Supabase dédiée à la Phase 2, puis nettoie systématiquement ce qu'il a créé.

## Portée

- Aucun code métier dans cette PR : uniquement `.github/workflows/phase2-staging-acceptance.yml`,
  `scripts/qa/phase2-staging-acceptance.sh`, les fixtures de référence
  `scripts/qa/fixtures/production_*.json`, et ce document.
- La cible est **exclusivement** la branche de staging (project ref `kjsriewplpqztmypoars`). Le
  script refuse de s'exécuter si l'URL contient le project ref de production ou tout autre ref
  de la liste interdite, si `CONFIRM_STAGING` ≠ `YES`, ou si l'environnement GitHub n'est pas
  nommé `phase2-staging`.

## 1. Secrets GitHub à configurer

Dans **Settings → Environments → phase2-staging → Environment secrets** de ce dépôt (pas en
secrets de repo globaux — l'environnement `phase2-staging` doit exister, le workflow le
référence explicitement), ajoute exactement ces quatre secrets :

| Nom exact | Contenu |
|---|---|
| `PHASE2_STAGING_URL` | URL de l'API du projet de staging (`https://kjsriewplpqztmypoars.supabase.co`) |
| `PHASE2_STAGING_ANON_KEY` | Clé anon/publishable du projet de staging |
| `PHASE2_STAGING_SERVICE_ROLE_KEY` | Clé service_role du projet de staging (setup/cleanup uniquement) |
| `PHASE2_NOTIFICATION_INTERNAL_KEY` | Valeur exacte du secret `PLATFORM_NOTIFICATION_INTERNAL_KEY` déjà configuré sur l'Edge Function `platform-send-notification` du projet de staging |

La clé Resend (`RESEND_API_KEY`) reste exclusivement dans les secrets d'Edge Function du
projet Supabase de staging (Dashboard → Edge Functions → Secrets) — elle n'est **jamais** lue
par GitHub Actions ni transmise au workflow.

## 2. Lancer le workflow (3 étapes)

1. Onglet **Actions** du dépôt → sélectionner **"Phase 2 — Recette d'acceptation staging"**.
2. Cliquer **Run workflow**.
3. Dans le champ `confirm_staging`, taper exactement `YES`, puis **Run workflow**.

## 3. Résultat

- Le résumé du run (onglet Summary du job) affiche PASS/FAIL/verdict.
- Un artefact `phase2-staging-acceptance-result` (rétention 30 jours) contient
  `phase2-staging-acceptance-result.json` (liste des vérifications, codes HTTP, timestamps —
  aucun secret, aucun JWT, aucun payload sensible complet) et `structural_diff.json` (détail de
  la comparaison structurelle staging/production).
- Le job échoue (exit non nul) au premier échec critique (ex. login impossible, fixture
  impossible à créer) ; les échecs non critiques sont listés en fin de run sans interrompre le
  reste de la recette.

## 4. Comparaison structurelle staging/production

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

**État connu au moment de la création de cette PR :** la comparaison structurelle **échouera**
sur le staging actuel. 34 des 42 tables de référence divergent réellement de la production
(colonnes manquantes, contraintes/index/triggers absents — dont le trigger de chaînage de hash
`trg_audit_chain_link` sur `audit_logs`). Cause : ce staging a été reconstruit manuellement après
l'échec du rejeu automatique des migrations par Supabase (`MIGRATIONS_FAILED`, lacune réelle et
préexistante dans l'historique de migrations tracké de la production), en recréant les tables à
la main plutôt qu'en rejouant l'historique réel. **C'est un blocage de déploiement documenté, pas
un bug de cette PR QA** : la comparaison fonctionne comme prévu en détectant cette dérive. La
correction (reconstruction fidèle du staging, par ex. via `pg_dump --schema-only` de la
production plutôt qu'un rejeu Supabase) est un travail séparé, hors périmètre de cette PR.

## 5. Nettoyage de secours

Le `trap EXIT` du script nettoie toujours ses fixtures (comptes Auth + lignes de tables),
identifiées par un `RUN_TAG` unique (`phase2qa-<timestamp>-<run_id>`) affiché en tête de log et
inclus dans l'artefact. Si le nettoyage automatique échoue partiellement (rapporté explicitement
dans le résumé et l'artefact) ou si le job est interrompu brutalement :

1. Dashboard Supabase → projet de staging → **Authentication** → filtrer par le `RUN_TAG` du run
   concerné (visible dans les logs/l'artefact) → supprimer les comptes correspondants.
2. **Table Editor** → sur `hotels`, `users`, `user_hotels`, `platform_admins`, `subscription_plans`,
   `platform_apps`, `hotel_subscriptions`, `support_tickets`, `platform_notifications` → filtrer
   les lignes dont le nom/email contient le `RUN_TAG` → supprimer.

## 6. Gestion du staging après une recette concluante

Ne pas supprimer l'environnement de staging tant que cette recette n'est pas passée avec succès
au moins une fois. Une fois concluante : exporter les preuves (artefact du run), supprimer la
branche de staging Supabase, supprimer ou renouveler `PHASE2_NOTIFICATION_INTERNAL_KEY` et la
clé Resend associée, confirmer qu'aucune ressource temporaire ne reste active.
