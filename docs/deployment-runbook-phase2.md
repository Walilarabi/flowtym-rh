# Runbook de déploiement — Phase 2 Super Admin (Lots 1-6 + P0 ACL)

Ce runbook décrit la procédure de déploiement en production de l'ensemble des PR de
Phase 2 (#21 à #31). **Aucune étape de ce document n'a été exécutée en production.** Il est
livré pour validation avant tout déploiement réel, conformément à la doctrine du dépôt
(voir CLAUDE.md / squelette d'exécution des migrations).

## 0. Pré-requis avant de commencer

- [ ] Ce runbook a été relu et approuvé par un humain habilité.
- [ ] Une fenêtre de maintenance (ou a minima une fenêtre de faible trafic) est réservée —
      aucune de ces migrations n'est bloquante en soi (additive uniquement), mais le
      rebase/merge en cascade de 11 PR demande de la concentration ininterrompue.
- [ ] Le cron reste désactivé pendant toute l'opération et après (aucun Lot de cette Phase 2
      n'active de cron — vérifié §8 ci-dessous).

## 1. Sauvegarde préalable

1. Vérifier qu'un point de restauration Supabase récent existe (Supabase effectue des
   sauvegardes automatiques quotidiennes sur ce projet — confirmer la date du dernier
   snapshot via le tableau de bord Supabase avant de commencer, pas supposé).
2. Exporter un dump `pg_dump --schema-only` du schéma `public` actuel (avant toute
   migration de cette Phase 2) et le conserver hors du dépôt (pas dans Git — trop volumineux
   et sensible) pour comparaison post-migration.
3. Noter le nombre de lignes des tables les plus sensibles avant migration (`hotels`,
   `hotel_subscriptions`, `support_tickets`, `users`) — aucune de ces migrations ne doit
   changer ces comptages (additive uniquement).

## 2. Ordre exact des merges et migrations

Les PR ont une structure de dépendance réelle (vérifiée via `list_pull_requests`, champ
`base`, pas supposée) :

```
main
 ├─ #21 Lot1 PR-01 (rétro-versionnement support_tickets)         sql/80
 ├─ #22 Lot1 PR-02 (ACL support_tickets)                          sql/81
 │   └─ #26 Lot5 PR-06 (Support back-office)                      sql/85
 │       └─ #27 Lot5 PR-07 (portail hôtel + pièces jointes)       sql/86
 │           └─ #28 Écran Divergence des droits                   (frontend seul)
 │               └─ #29 Lot6 (statistiques + santé) — fusionne aussi #24 (Lot3)
 │                        sql/83 (via fusion #24) + sql/87 + sql/89
 │                   └─ #30 Documentation (ADR-012, CHANGELOG)
 ├─ #23 Lot2 (platform_notifications)                              sql/82
 │   └─ #25 Lot4 (notifications d'essai J-7/J-3/J-1)                sql/84
 ├─ #24 Lot3 (licences en observation)                              sql/83
 │      (déjà fusionnée dans #29 — voir note ci-dessous)
 └─ #31 P0 ACL (7 tables) — INDÉPENDANTE, basée sur main             sql/88
```

**Note sur #24/#29** : #29 (Lot 6) a été explicitement fusionnée (`git merge`) avec #24
(Lot 3) pendant la passe de stabilisation, car `sql/87` (Lot 6) dépend réellement de la
logique de licences de `sql/83` (Lot 3) — ces deux branches étaient indépendantes (toutes
deux basées sur `main`) alors que le frontend de #29 appelait déjà des RPC définies par
#24. Conséquence pratique : **#24 doit être mergée avant ou en même temps que #29** ; si
#24 est mergée séparément d'abord, #29 devra être rebasée sur `main` post-merge de #24 pour
éviter un conflit de définition de fonctions (`CREATE OR REPLACE`, pas de conflit de contenu
réel, mais à vérifier).

**Ordre de merge recommandé** (squash-merge, mode du dépôt) :

1. `#31` (P0 ACL, indépendante — mergée en premier ou juste après #22, selon disponibilité)
2. `#21` → `#22` (Lot 1, fondation Support)
3. `#23` (Lot 2, fondation notifications) — indépendante de #21/#22
4. `#24` (Lot 3, licences) — indépendante, mais **doit précéder #29**
5. `#25` (Lot 4, notifications d'essai) — dépend de #23 seulement
6. `#26` → `#27` → `#28` (Lot 5 + écran divergence) — dépendent de #22
7. `#29` (Lot 6 — dépend de #28 ET #24)
8. `#30` (documentation — dépend de #29)

**Ordre exact des migrations SQL** (respecter cet ordre, chaque fichier déclare ses
dépendances en en-tête — voir §4 pour le détail par fichier) :

```
sql/80 → sql/81 → sql/82 → sql/83 → sql/84 → sql/85 → sql/86 → sql/87 → sql/88 → sql/89
```

`sql/88` (P0 ACL) est indépendante de la chaîne fonctionnelle et peut être appliquée à tout
moment de la séquence, y compris en premier — elle ne dépend d'aucun autre fichier de cette
liste.

## 3. Procédure — rebase entre chaque PR (obligatoire sous squash-merge)

Le dépôt utilise le squash-merge (à confirmer dans les réglages GitHub du dépôt avant de
commencer — si le mode réel diffère, cette procédure doit être adaptée). Sous squash-merge,
chaque merge réécrit l'historique de `main` par un seul commit : **l'ordre `#21→#31` ne
suffit PAS à garantir que la PR suivante ne contient que son propre lot** si elle n'est pas
rebasée après chaque merge.

Après CHAQUE merge individuel :

1. `git fetch origin main`
2. Pour la PR suivante dans l'ordre : `git checkout <branche> && git rebase origin/main`
3. Vérifier que `git diff origin/main...<branche> --stat` ne contient QUE les fichiers du
   lot attendu (pas de fichiers d'un lot déjà mergé qui réapparaîtraient par erreur de
   rebase) — comparer à la liste de fichiers connue de ce lot (voir CHANGELOG.md).
4. Résoudre les conflits un par un — pour ce dépôt, les conflits attendus sont
   essentiellement dans `admin.html` (plusieurs lots ajoutent des vues/fonctions dans le
   même fichier monolithique) ; jamais dans les fichiers `sql/*.sql` (chaque lot a ses
   propres numéros de fichiers, pas de collision possible par construction).
5. `git push --force-with-lease origin <branche>` (jamais `--force` simple — protège contre
   l'écrasement d'un push concurrent).
6. Relancer la CI complète sur la branche rebasée et attendre le vert avant de continuer.
7. Vérifier que les migrations attendues pour ce lot sont bien présentes et inchangées
   (`git show <branche>:sql/NN_....sql | diff - <copie de référence validée>`).
8. Seulement alors, autoriser le merge de cette PR, puis répéter à partir de l'étape 1 pour
   la PR suivante.

## 4. Commandes d'application des migrations

Pour chaque fichier, dans l'ordre du §2 :

```
mcp__Supabase__apply_migration(project_id=<prod>, name="<nom_du_fichier_sans_extension>", query=<contenu_du_fichier>)
```

Chaque fichier est écrit pour être idempotent-safe à l'application unique (`CREATE OR
REPLACE FUNCTION`, doctrine trois états pour `sql/85`/`sql/86`, `has_table_privilege`-gardé
pour `sql/88`) — **aucun fichier de cette liste ne doit être rejoué deux fois volontairement
en production sans relire d'abord son propre contrat de non-régression** (le rejeu accidentel
via `apply_migration` sur un objet déjà conforme doit produire un no-op silencieux et vérifié,
jamais une erreur bloquante — c'est exactement ce que la doctrine trois états garantit pour
`sql/85`/`sql/86`).

## 5. Vérification PostgREST après chaque lot de migrations

Après chaque groupe de migrations appliqué (au minimum après `sql/82`, `sql/85`, `sql/86`,
`sql/87`, `sql/89` — tout fichier qui crée ou modifie une fonction exposée en RPC) :

1. Forcer un rechargement du schéma PostgREST (`NOTIFY pgrst, 'reload schema'` ou
   équivalent via le tableau de bord Supabase).
2. Vérifier qu'un appel RPC simple sur une fonction nouvellement créée répond sans erreur
   `PGRST202` (fonction introuvable dans le cache PostgREST) depuis un client authentifié de
   test.

## 6. Déploiement des Edge Functions

Fonctions concernées par cette Phase 2 : `platform-send-notification` (Lot 2),
`support-ticket-attachment-request-upload`, `support-ticket-attachment-confirm`,
`support-ticket-attachment-download-url` (Lot 5B).

1. `mcp__Supabase__deploy_edge_function` pour chacune, avec `verify_jwt` conforme à leur
   authentification réelle (les 3 fonctions Support attendent un JWT utilisateur classique,
   `platform-send-notification` n'accepte QUE `x-internal-key`, jamais un JWT — vérifier ce
   réglage explicitement avant déploiement, une erreur ici casserait son authentification).
2. Vérifier `list_edge_functions` post-déploiement : statut `ACTIVE` pour les 4 fonctions.

## 7. Configuration des secrets

Secrets requis, à définir via le tableau de bord Supabase (jamais commités, jamais dans les
logs) avant tout test réel du dispatcher de notifications :

| Secret | Fonction | Statut à date de ce document |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Toutes | Déjà configuré (secret plateforme standard) |
| `RESEND_API_KEY` | `platform-send-notification` | **Non vérifié — à confirmer avant tout envoi réel** |
| `PLATFORM_NOTIFICATION_INTERNAL_KEY` | `platform-send-notification` | **Non vérifié — à générer si absent, jamais réutiliser une valeur de test** |

## 8. Création/vérification du bucket Storage

Bucket `support-ticket-attachments` (Lot 5B, `sql/86`) : créé par la migration elle-même
(`INSERT INTO storage.buckets ... ON CONFLICT DO UPDATE SET public = false, ...`) — aucune
action manuelle requise, mais **vérifier après application** que `public = false` (la
migration force cette valeur même sur un conflit, mais une vérification post-application
reste la seule preuve réelle) :

```sql
SELECT public, file_size_limit FROM storage.buckets WHERE id = 'support-ticket-attachments';
```

## 9. Smoke tests post-migration (checklist minimale)

- [ ] `/admin` : connexion Super Admin réussie, tableau de bord affiche des KPI réels
      (pas d'erreur, pas de valeurs `undefined`).
- [ ] Licences : `admin_list_license_usage()` retourne des lignes cohérentes avec les
      abonnements réels ; le sous-score licences de `admin_hotel_health_scores()` concorde
      (voir `sql/tests/license_usage_single_source_of_truth.sql` pour le prédicat exact).
- [ ] Essais : `admin_preview_trial_ending_notifications()` puis
      `admin_run_trial_ending_notifications()` sur un abonnement trial réel proche
      d'échéance — vérifier l'insertion dans `platform_notifications`, statut `pending`.
- [ ] Support back-office : lister les tickets, répondre, masquer une réponse.
- [ ] Portail hôtel Support (`/support`) : créer un ticket, réponse publique visible côté
      back-office, note interne invisible côté hôtel.
- [ ] Pièce jointe : vérifier que le bouton d'upload est bien désactivé (stratégie A) avec
      le message « Pièces jointes bientôt disponibles » — PAS un bouton fonctionnel menant
      à un fichier inaccessible.
- [ ] Divergence des droits : écran se charge, lecture seule confirmée (aucune action de
      correction visible).
- [ ] Statistiques : `admin_platform_statistics()` retourne un objet cohérent, `licenses`
      concorde avec l'écran Licences (même source, `sql/89`).
- [ ] P0 : `TRUNCATE` refusé pour `anon` sur les 7 tables (`rms_decisions` en particulier),
      confirmé par une tentative directe.

## 10. Matrice de contrôle RLS (post-application, avant d'ouvrir l'accès aux utilisateurs réels)

| Table/Fonction | anon | authenticated non-admin | authenticated hôtel A (son ticket) | authenticated hôtel A (ticket hôtel B) | super_admin |
|---|---|---|---|---|---|
| `support_ticket_replies` (SELECT direct) | 0 ligne (RLS) | 0 ligne hors son hôtel | ses réponses publiques non masquées | 0 ligne | RLS bypass admin |
| `support_ticket_attachments` (SELECT direct) | erreur (aucun grant) | erreur (aucun grant) | erreur (aucun grant — RPC only) | erreur | erreur (RPC only) |
| `admin_list_support_tickets()` | erreur 42501 | erreur 42501 | n/a (pas de RPC hôtel équivalente) | n/a | OK |
| `hotel_reply_support_ticket()` | erreur 42501 | erreur 42501 | OK | erreur 42501 | erreur (doit utiliser `admin_reply_support_ticket`) |
| `rms_decisions`/6 autres (TRUNCATE) | refusé (P0) | refusé (P0) | n/a | n/a | n/a (pas de bypass TRUNCATE, jamais nécessaire) |
| `_hotel_license_usage_snapshot()` (appel direct) | erreur (aucun grant) | erreur (aucun grant) | erreur (aucun grant) | erreur | erreur (aucun grant — même le propriétaire des RPC publiques) |

## 11. Procédure d'arrêt (stop-the-line)

Si une vérification du §9 ou §10 échoue :

1. **Ne pas continuer la chaîne de merges suivante.** Le lot en échec reste la dernière PR
   mergée ; les PR suivantes de la chaîne restent non mergées (elles ne sont pas affectées
   tant qu'elles ne sont pas rebasées/mergées).
2. Documenter l'échec précis (requête, résultat obtenu, résultat attendu) avant toute
   correction — jamais une correction à l'aveugle.
3. Si l'échec est dans une fonction (`CREATE OR REPLACE FUNCTION`) : corriger et réappliquer
   uniquement cette fonction (une redéfinition est par nature non destructive — jamais besoin
   d'un rollback de schéma).
4. Si l'échec est dans une création de table (`sql/85`/`sql/86`, doctrine trois états) : la
   migration elle-même aura déjà refusé de s'appliquer silencieusement (`RAISE EXCEPTION`
   explicite côté état divergent) — lire le message d'erreur exact, il nomme la colonne/
   contrainte/index en cause.

## 12. Migration corrective en cas d'échec après application

- Pour une fonction : une nouvelle migration `sql/9N_fix_<nom>.sql` avec `CREATE OR REPLACE
  FUNCTION` corrigée — jamais de correction manuelle hors migration versionnée (doctrine du
  dépôt, cf. anti-pattern déjà documenté deux fois pour `hotels`/`hotel_groups`/
  `platform_admins`).
- Pour une donnée déjà insérée par erreur (ex. une notification envoyée par erreur à un
  mauvais destinataire) : jamais de `DELETE` — utiliser les mécanismes de correction déjà
  prévus par chaque domaine (masquage pour les réponses Support, `status='abandoned'` avec
  `final_error` explicite pour une notification, jamais une suppression physique).

## 13. Procédure de retour à la version frontend précédente

`admin.html`, `support-portal.html`, `index.html`, `portal.html` sont des fichiers HTML
statiques servis par Vercel, sans build. Le retour arrière est un simple redéploiement Vercel
du commit précédent sur `main` (`vercel rollback` ou re-déploiement du SHA précédent depuis
le tableau de bord Vercel) — n'affecte jamais la base de données (les migrations SQL sont
additives et restent en place ; un rollback frontend seul est toujours sûr et rapide).

## 14. Absence d'activation du cron — confirmation explicite

**Aucun fichier de cette Phase 2 (sql/80 à sql/89) ne crée, modifie, ni active de job cron,
`pg_cron`, ni de trigger planifié.** Toutes les actions de traitement (essais, notifications)
sont des RPC à déclenchement manuel exclusivement (`admin_run_trial_ending_notifications()`,
etc.), vérifié par relecture de chaque fichier de migration listé au §2 et confirmé par
recherche exhaustive de `pg_cron`/`cron.schedule` dans l'ensemble des fichiers `sql/80` à
`sql/89` (aucune occurrence). Ce runbook ne prévoit l'activation d'aucun cron à aucune étape.
