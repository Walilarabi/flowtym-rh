# ADR-012 — Phase 2 du Super Admin : plateforme SaaS de gestion commerciale et opérationnelle

**Statut** : Proposé — soumis pour validation CTO. Aucune migration, aucune RPC, aucun code
frontend n'a été écrit à ce stade. Ce document est la seule livraison de ce chantier tant
qu'il n'est pas validé, conformément à l'instruction explicite reçue ("ne commence aucun
développement avant validation de cette architecture").

**Portée** : six domaines, dans l'ordre de développement demandé — Paiements, Licences,
Périodes d'essai, Statistiques, Support, Supervision avancée. Objectif déclaré : transformer
le Super Admin actuel (portail de gestion, Phase 1, PR #1 à #19) en plateforme SaaS complète
de gestion commerciale et opérationnelle de Flowtym vis-à-vis de ses hôtels clients.

---

## 0. Méthode

Avant toute proposition d'architecture, un audit factuel exhaustif de l'existant a été mené
(lecture directe du code SQL versionné, des ADR 009/010/011, du dossier RC1, de la roadmap
produit, et introspection directe de la base de production `hzrzkvdebaadditvbqis` — tables,
colonnes, RLS, grants). Un écart a été détecté et corrigé en cours d'audit : voir §2.5
(Support) — deux tables (`support_tickets`, `help_articles`) existent réellement en
production mais n'étaient **pas versionnées** dans `sql/`, ce qui avait fait initialement
conclure à tort qu'aucune fondation Support n'existait. Corrigé par introspection directe
avant d'écrire ce document.

Aucune recommandation de ce document n'est fondée sur une supposition non vérifiée. Quand un
point n'a pas pu être tranché sans arbitrage business (choix de prestataire, budget, politique
de rétention), il est explicitement listé en §7 comme décision CTO à obtenir, plutôt que
tranché unilatéralement ici.

---

## 1. Doctrine héritée de la Phase 1 (à respecter à l'identique)

La Phase 2 ne réinvente aucune convention. Rappel de ce qui est déjà en vigueur (ADR-009,
confirmé par lecture directe de `sql/68` à `sql/79`) :

- **ACL des RPC `admin_*`** : `SECURITY DEFINER`, `SET search_path TO 'public','pg_temp'`,
  garde interne en première instruction (`IF NOT public.is_platform_admin() THEN RAISE
  EXCEPTION ... USING errcode='42501'`), puis `REVOKE ALL ... FROM PUBLIC, anon, service_role`
  + `GRANT EXECUTE ... TO authenticated`. Les helpers internes (`_`-préfixés) ne reçoivent
  **aucun** grant client (`REVOKE ALL FROM PUBLIC, anon, authenticated, service_role`).
- **Audit** : deux tables distinctes, jamais confondues — `platform_logs` via `_platform_log()`
  (action déclenchée par un admin, garde `is_platform_admin()` interne) ou
  `_platform_log_system()` (action système/trigger/cron, sans garde) ; table événementielle
  métier dédiée quand un cycle de vie le justifie (`hotel_subscription_events` pour les
  abonnements). Convention de nommage action : `<entité>.<verbe>`.
- **Tables sensibles / soft-delete** : jamais de `DELETE` sur une entité journalisée — statut
  (`archived`, `cancelled`, `expired`…) + historique événementiel.
- **Tests** : un fichier `sql/tests/<domaine>.sql` par migration/lot, pattern
  `BEGIN` / fixtures `pg_temp.zz_*` / blocs `DO $$...EXCEPTION WHEN OTHERS...END $$` loggés
  PASS/FAIL / `RAISE EXCEPTION` final si un FAIL / `ROLLBACK` — jamais de trace persistante.
- **Nommage migrations** : `sql/NN_<domaine>_<description>.sql`, numérotation continue.
  **Dernier fichier existant : `sql/79`. La Phase 2 commence à `sql/80`.**
- **Numérotation ADR** : dernier existant `ADR-011`. Ce document est **ADR-012**.
- **Doctrine cron** (ADR-010 §3) : aucun job `pg_cron` n'est jamais activé dans la même
  migration que la fonctionnalité qu'il déclenche. Activation = migration séparée, dédiée,
  avec validation CTO explicite et distincte. **Cette doctrine s'applique à toute proposition
  de cron de ce document** (dunning, métriques, essais) — aucun cron n'est activé par les PR
  proposées en §6 sans un round de validation dédié supplémentaire.
- **Leçon du P0 (PR #18)** : un écart entre ce qu'une action annonce en prévisualisation et ce
  qu'elle exécute réellement est une classe de bug jugée inacceptable. **Toute nouvelle action
  de traitement par lot (dunning, essais, métriques) doit exposer une RPC de prévisualisation
  en lecture seule dont le prédicat est strictement identique à celui de l'exécution**, sur le
  modèle `admin_preview_expired_trials_processing()` / `admin_run_expired_trials_processing()`.

---

## 2. État de l'existant, par domaine (audit factuel)

### 2.1 Paiements

**Existe** (`sql/75`, `sql/76`) : `platform_invoices` (cycle `proforma → issued → cancelled`,
snapshot de facturation figé à l'émission), `platform_payments` (paiement distinct de la
facture, statuts `recorded/pending/failed/reversed`), `platform_credit_notes` (avoir, jamais
fusionné dans la facture), séquences de numérotation dédiées. RPC complètes : création,
émission, annulation, encaissement, réversion, avoir, KPIs (`platform_billing_dashboard_kpis`).
`financial_state` calculé à la lecture (`unpaid/partially_paid/paid/overdue/fully_credited`).

**Lacunes confirmées par le code lui-même** :
- Aucune passerelle de paiement réelle connectée (`method` est un enum texte libre).
- `platform_settings.dunning_days_before` existe, est validé et affiché côté Paramètres, mais
  **n'est lu par aucun code** — aucune relance n'est jamais envoyée.
- `platform_invoices.pdf_url` réservé mais jamais écrit — l'export actuel est
  `window.print()` côté navigateur, pas un PDF serveur.

### 2.2 Licences

**Existe** (`sql/70`, `sql/71`, `sql/78`) : `subscription_plans` (catalogue, `plan_scope`
public/interne, `is_commercializable`), `plan_modules` (accès binaire plan↔application),
`hotel_addon_subscriptions` (add-ons optionnels), `hotel_subscriptions.snapshot_limits`
(jsonb, photographie figée des limites au moment de l'attribution — `max_users`, `max_rooms`,
etc.). Cycle de vie RPC complet (create/change/suspend/renew/cancel/régularisation legacy).

**Lacune confirmée** : `snapshot_limits` est stocké mais **jamais comparé à un usage réel** —
aucune RPC ne compte les utilisateurs actifs ou les chambres d'un hôtel pour le confronter à
sa limite. « Licence » aujourd'hui = accès binaire par module, pas un système de quota. Aucune
clé de licence, aucun décompte de sièges consommés.

### 2.3 Périodes d'essai

**Existe** (`sql/70`, `sql/79`, ADR-011) : cycle de vie complet sur `hotel_subscriptions`
(`trial → extend borné (max_trial_extensions) → convert/expire`), audit trail
(`hotel_subscription_events`), prévisualisation/exécution désormais strictement cohérentes
(P0, PR #18, mergée). Doctrine cron déjà documentée (ADR-010 §3) mais **jamais activée**
(`grep cron.schedule` : une seule occurrence en commentaire, jamais exécutée — confirmé
également par `0 job pg_cron` en production).

**Lacune confirmée** : item roadmap #15 (« cron essais expirés », Must) non réalisé — le
traitement reste 100 % manuel. Aucune notification (email) avant expiration d'un essai.

### 2.4 Statistiques

**Existe** (`sql/76`) : `admin_platform_overview_kpis()` (18 KPI/5 blocs calculés à la volée,
4 fenêtres de période), `admin_platform_alerts()` (9 détecteurs), `admin_rights_divergence_report()`
(Phase 2A, jamais exposée à l'écran). **Aucune** vue matérialisée, table d'agrégats ou de
série temporelle — tout est recalculé à chaque appel, confirmé par recherche exhaustive.

**Lacunes confirmées** (roadmap, Lot C) : pas de MRR/ARR/churn réel (#17, Must — les objectifs
`mrr_target`/`arr_target` existent en Paramètres mais ne pilotent rien) ; pas de delta vs
période précédente (#16) ; pas de score de santé hôtel (#27) ; pas de détection d'anomalies
(#30, Could) ; pas de vue diff avant/après sur l'audit (#21) ; rapport de divergence de droits
invisible côté écran bien que déjà calculé côté serveur (#6).

### 2.5 Support

**Correction d'audit importante** : les tables `support_tickets` et `help_articles` **existent
réellement en production** (vérifié par introspection directe), contrairement à la première
conclusion d'audit fondée sur la seule recherche dans le dépôt git. **Elles ne sont
simplement pas versionnées dans `sql/`** — le même type de dette que celle déjà documentée
par ADR-011 pour d'autres objets bootstrappés hors migration.

**`support_tickets`** (0 ligne à ce jour) : ticket hôtel→éditeur, colonnes riches
(`module`, `feature`, `problem_type`, `steps` jsonb, `priority`, `status` défaut `nouveau`,
`assigned_to` texte libre, `classification`, `risk_score`, `diagnostic_details` jsonb,
`claude_response`). RLS déjà correcte et fonctionnelle : un utilisateur hôtel
(`user_hotels`) crée/lit/modifie les tickets de son propre hôtel ; `is_platform_admin()` lit
et modifie tous les tickets. **Aucune RPC** : le portail interagirait aujourd'hui en accès
table direct, ce qui contredit la doctrine RPC-only de la Phase 1.

**`help_articles`** : base de connaissance (`module`, `title`, `body`, `tags[]`,
`is_published`, `view_count`). RLS correcte (lecture publique si publié ou admin ; écriture
réservée aux rôles `super_admin`/`support_agent` via le helper `platform_admin_role()`, déjà
existant). **Faille confirmée** : les **grants au niveau table** accordent `INSERT/SELECT/
UPDATE/DELETE/TRUNCATE` à `anon` sur les deux tables — la sécurité ne tient que sur la RLS,
ce qui contredit explicitement la doctrine du projet (« ne jamais reposer uniquement sur la
RLS », déjà citée comme dette identifiée mais non corrigée en RC1 §D.7). À corriger, pas à
contourner.

**Non liés, confirmés hors-sujet** : `portal_requests`/`portal_messages` (messagerie RH
interne salarié↔manager, RLS et flux totalement différents) ; `aide.html` (base de
connaissance RH, statique, aucun lien avec `help_articles`) ; `maintenance_tickets`
(tickets opérationnels PMS/Housekeeping, périmètre distinct). Aucun des trois ne sera
touché ni fusionné.

Le tag `STUB_INFO.support` dans `admin.html:755` affirme un accès « en lecture seule », ce qui
est inexact (les admins peuvent aussi modifier) — à corriger dans la même PR que la mise en
place des RPC.

### 2.6 Supervision avancée

**Existe** (`sql/76`) : `admin_supervision_status()` — signaux **honnêtes**, jamais de
placeholder trompeur (`mutation_error_monitoring_available: false`,
`edge_function_error_monitoring_available: false`, `webhooks_configured: false`,
confirmé par le code et par le smoke test RC1). `admin_list_platform_audit_log()` — seule
pagination serveur réelle du portail à ce jour, 6 filtres.

**Lacunes confirmées** (roadmap) : aucun monitoring d'erreurs réel front/Edge Functions (#22,
Must — Sentry explicitement nommé dans l'audit produit) ; aucun historique d'incidents ni
routage (#35, Could) ; `webhooks_configured` toujours `false` (item #34, hors du périmètre des
6 domaines demandés, non traité ici).

### 2.7 Infrastructure transverse déjà disponible (à réutiliser, pas à redévelopper)

Plusieurs domaines de la Phase 2 ont besoin d'envoyer un email sortant (relance, alerte
d'essai, notification de ticket). Un canal existe déjà et fonctionne : `RESEND_API_KEY` +
appel direct à `api.resend.com/emails`, utilisé par l'Edge Function `supabase/functions/sig-send`
(notifications de signature électronique). **Aucun nouveau prestataire d'email n'est
nécessaire** — la Phase 2 doit réutiliser Resend via une brique partagée (§3.0), pas en
introduire un second.

---

## 3. Architecture proposée, par domaine

### 3.0 Fondation transverse — notifications sortantes (préalable, PR-00)

Trois domaines (Paiements/dunning, Essais/notification d'expiration, Support/notification de
ticket) ont besoin du même mécanisme : envoyer un email, une seule fois par événement, avec
audit. Plutôt que trois tables et trois bouts de code Resend quasi identiques, une seule
brique partagée :

- **Table `platform_notifications`** : `id`, `category` (CHECK `dunning`/`trial_ending`/
  `support_ticket_update`/`support_ticket_new`/…), `reference_type`, `reference_id`,
  `recipient_email`, `channel` (défaut `email`), `status` (`pending`/`sent`/`failed`),
  `dedupe_key` **UNIQUE** (ex. `dunning:<invoice_id>:<offset>`, `trial:<subscription_id>:<jours>`)
  — l'idempotence est générique, portée par la contrainte unique, pas réimplémentée par
  domaine. `sent_at`, `error`, `created_at`.
- **Edge Function `platform-send-notification`** : unique point d'appel à l'API Resend,
  service-role uniquement (jamais appelée depuis le client), écrit le résultat dans
  `platform_notifications`.
- Aucune RPC cliente : les domaines producteurs (dunning, essais, support) insèrent une ligne
  `pending` avec leur `dedupe_key`, un appel serveur (RPC interne ou l'Edge Function
  elle-même) déclenche l'envoi. Détail d'implémentation à trancher au moment de la PR-00,
  pas ici.

### 3.1 Paiements

1. **PDF réel de facture** — `platform_invoices.pdf_url` déjà réservé, aucune colonne
   supplémentaire. Nouveau bucket Storage privé `platform-invoices` (même doctrine que
   `rh_12_storage_buckets_setup`/`37_contracts_storage_bucket`). Nouvelle Edge Function
   `platform-invoice-pdf` (génère, upload, met à jour `pdf_url` via service-role). RPC
   `admin_generate_invoice_pdf(invoice_id)` déclenche la génération, gardée
   `is_platform_admin()`.
2. **Dunning réel** — nouvelle table `platform_dunning_log` (`invoice_id`, `day_offset`,
   `sent_at`, `status`, **`UNIQUE(invoice_id, day_offset)`** pour l'idempotence). Nouvelle
   paire de RPC symétriques (doctrine §1) : `admin_preview_dunning_run()` (lecture seule,
   même prédicat que l'exécution) et `admin_run_dunning_check()` (déclenchement manuel dans
   un premier temps — lit `platform_settings.dunning_days_before`, confronte aux factures
   `issued` non soldées, insère dans `platform_notifications` via la brique §3.0 pour chaque
   palier non encore envoyé). Cron d'activation = migration séparée, hors périmètre de cette
   première PR (doctrine §1).
3. **Passerelle de paiement réelle** — nouvelle table `platform_payment_intents`
   (`invoice_id`, `provider`, `external_ref`, `status`, `checkout_url`, `amount`, `currency`)
   distincte de `platform_payments` (une intention devient un paiement enregistré seulement
   après confirmation) ; nouvelle table `platform_payment_provider_events` (`event_id`
   **UNIQUE** — idempotence webhook, `payload`, `processed_at`). RPC
   `admin_create_payment_intent(invoice_id)` (admin-gated) + Edge Function
   `platform-payment-webhook` (vérifie la signature du prestataire, upsert idempotent, appelle
   un helper interne `_record_platform_payment_from_webhook(...)` — jamais
   `admin_record_platform_payment` directement, car ce chemin est système, pas admin, même
   distinction `_platform_log`/`_platform_log_system` que partout ailleurs). **Bloquée par une
   décision CTO : quel prestataire ?** (§7.1). Le schéma proposé est volontairement
   agnostique du prestataire pour ne pas figer ce choix dans l'ADR.

### 3.2 Licences

Aucune nouvelle table — cohérent avec la convention « pas d'agrégat pré-calculé » déjà en
vigueur (§2.4). Nouvelle RPC `admin_list_license_usage()` : pour chaque hôtel, confronte
`hotel_subscriptions.snapshot_limits` à un décompte réel (utilisateurs actifs via
`user_hotels`, chambres via `rooms`, etc.). Nouveau type d'alerte `license_quota_exceeded`
ajouté à `admin_platform_alerts()` (extension de la RPC existante, pas une nouvelle RPC
parallèle). **Aucun blocage** en V1 — observation et alerte seulement, dans la continuité
directe de la doctrine « observe avant enforce » déjà actée par ADR-010 pour la résolution des
droits applicatifs. Ne touche ni ne reconnecte jamais `hotel_app_subscriptions` (ADR-011 —
composant legacy en sursis, aucune nouvelle fonctionnalité ne doit s'y adosser).

### 3.3 Périodes d'essai

Deux livrables, quasiment aucune nouvelle donnée :
1. **Activation du cron** — migration dédiée (`sql/8N`), wrapper interne
   `_cron_process_expired_hotel_subscription_trials()` (contexte `postgres`/`pg_cron`, pas un
   appel authentifié — ne peut pas passer par `admin_run_expired_trials_processing()` qui
   exige `is_platform_admin()`), journalisé via `_platform_log_system` (déclenchement système,
   pas admin), appelle la même fonction métier `process_expired_hotel_subscription_trials()`
   déjà en place — **aucune nouvelle logique de traitement**, seulement un nouveau
   déclencheur. Nécessite une validation CTO explicite et dédiée avant merge (doctrine ADR-010
   §3 — pas seulement avant activation en production).
2. **Notification avant expiration** — réutilise `platform_notifications` (§3.0) et le
   détecteur `trial_ending_soon` déjà existant dans `admin_platform_alerts()` comme source de
   la liste à notifier ; aucune nouvelle table.

### 3.4 Statistiques

1. **`platform_metrics_daily`** (`metric_date` PK, `mrr`, `arr`, `active_subscriptions`,
   `trial_subscriptions`, `new_subscriptions`, `churned_subscriptions`, `active_hotels`,
   `computed_at`) — une ligne par jour. RPC `admin_recompute_platform_metrics(p_date DEFAULT
   current_date)` (déclenchement manuel en V1, upsert idempotent sur `metric_date`) et
   `admin_platform_metrics_series(p_from, p_to)` (lecture, alimente #17 MRR/ARR/churn réel et
   #16 delta vs période précédente). Activation cron = migration séparée ultérieure, même
   doctrine que partout ailleurs dans ce document.
2. **`admin_hotel_health_score(hotel_id)`** — RPC calculée (pas de table), combine des
   signaux déjà existants (`financial_state`, statut d'essai, volume de tickets support une
   fois §3.5 livré). Dépend donc de PR Support — placée en fin de lot Statistiques dans le
   plan §6.
3. **Rapport de divergence de droits (#6)** — `admin_rights_divergence_report()` existe déjà
   depuis la Phase 2A. Aucun backend nouveau : uniquement un écran frontend qui l'appelle.
   Explicitement signalé pour éviter qu'une PR ne redéveloppe la même RPC sous un autre nom.
4. **Hors périmètre v1** (Could dans la roadmap, pas de conception forcée ici) : détection
   d'anomalies (#30), facturation consolidée par groupe (#26).

### 3.5 Support

1. **Migration de rétro-documentation + durcissement ACL** (première PR du lot, aucun
   changement de comportement fonctionnel visé) : verse `support_tickets` et `help_articles`
   dans `sql/` avec des instructions idempotentes (`CREATE TABLE IF NOT EXISTS` /
   vérifications d'existence pour les policies), pour que le dépôt redevienne la source de
   vérité. Corrige la faille de grants : `REVOKE ALL ... FROM anon` sur les deux tables (la
   RLS reste inchangée, seuls les grants table-level trop larges sont retirés — alignement
   sur la doctrine « ne jamais reposer sur la RLS seule »).
2. **RPC de triage** : `admin_list_support_tickets(...)`, `admin_get_support_ticket_detail(id)`,
   `admin_update_support_ticket(id, status, assigned_to, classification, risk_score,
   response)` — ACL standard, `support_agent` autorisé via `platform_admin_role()` (helper
   déjà existant). Chaque mutation écrit désormais dans `platform_logs` via `_platform_log`
   (aujourd'hui : aucun audit sur les modifications de ticket, accès table brut). Corrige au
   passage la description inexacte de `STUB_INFO.support` dans `admin.html`.
3. **RPC CMS** : `admin_list_help_articles`, `admin_upsert_help_article`,
   `admin_publish_help_article`, `admin_archive_help_article` — même doctrine ACL, restreint
   aux rôles déjà prévus par la RLS existante (`super_admin`/`support_agent`).
4. **Notification de changement de statut** (optionnelle, réutilise §3.0) — email au
   `user_email` du ticket quand son statut change. Non bloquante pour le reste du lot.
5. **Point ouvert, non tranché ici** : aucun point d'entrée ne permet aujourd'hui à un hôtel de
   *créer* un ticket depuis `index.html`/`portal.html` — la table est prête côté RLS mais rien
   ne l'alimente. Décision CTO nécessaire (§7.6) : le lot Support Phase 2 livre-t-il d'abord le
   triage admin seul (tickets créés autrement, ou aucun tant que ce point n'est pas tranché),
   ou inclut-il aussi le formulaire de création côté hôtel ?

### 3.6 Supervision avancée

1. **Sentry (ou équivalent) frontend** — SDK JS dans `admin.html`. Bloqué par une décision
   CTO (compte, DSN, coût, politique de rétention — §7.5). Aucune nouvelle table.
2. **Sentry Edge Functions** — nouvelle brique partagée `supabase/functions/_shared/sentry.ts`
   (même emplacement que `_shared/cors.ts` déjà existant), càblée dans les Edge Functions
   existantes et nouvelles.
3. **Mise à jour honnête de `admin_supervision_status()`** — une fois réellement instrumenté,
   `mutation_error_monitoring_available`/`edge_function_error_monitoring_available` passent à
   `true`. **Extension de la RPC existante, pas une nouvelle RPC** — préserve la doctrine
   d'honnêteté des signaux déjà en place.
4. **`platform_incidents`** (historique d'incidents + routage, item #35) — nouvelle table
   (`title`, `description`, `severity`, `status`, `started_at`, `resolved_at`,
   `related_alert_type`) + RPC `admin_list/create/update_incident`. Priorité **Could** dans la
   roadmap existante — proposé comme lot distinct, optionnel, à la fin du plan §6, pas comme
   prérequis du reste de la Supervision avancée.
5. **Hors périmètre** : `webhooks_configured` (item roadmap #34) — chantier séparé, non inclus
   dans les 6 domaines demandés.

---

## 4. Preuve de non-duplication

| Nouvelle brique (Phase 2) | Domaine | S'appuie sur (Phase 1, inchangé) | Ne duplique pas / ne reconnecte pas |
|---|---|---|---|
| `platform_notifications` + Edge Function dédiée | Transverse | Resend (`sig-send`, réutilisé) | N'introduit pas de second prestataire d'email |
| Bucket + Edge Function PDF facture | Paiements | `platform_invoices.pdf_url` (déjà réservé) | Ne remplace pas `financial_state`, ne touche pas au cycle facture existant |
| `platform_dunning_log` + preview/run | Paiements | `platform_settings.dunning_days_before` (déjà existant, jamais lu) | N'invente pas de nouveau champ de configuration |
| `platform_payment_intents`/`_provider_events` | Paiements | `platform_payments` (paiement confirmé reste la même table) | N'ajoute pas de statut au cycle `platform_invoices` existant |
| `admin_list_license_usage` + alerte `license_quota_exceeded` | Licences | `subscription_plans`, `plan_modules`, `snapshot_limits`, `admin_platform_alerts` (étendue, pas recréée) | Ne touche jamais `hotel_app_subscriptions` (ADR-011, legacy) ; ne réactive pas le mode `enforce` (ADR-010, hors périmètre) |
| Cron essais + wrapper interne | Essais | `process_expired_hotel_subscription_trials()` (PR #18, logique inchangée) | Ne recrée pas de logique de traitement, seulement un déclencheur |
| `platform_metrics_daily` + RPC série | Statistiques | `admin_platform_overview_kpis` (inchangée, KPI instantanés conservés) | Ne remplace pas les KPI existants, les complète par une dimension temporelle absente aujourd'hui |
| Écran divergence de droits | Statistiques | `admin_rights_divergence_report()` (Phase 2A, déjà écrite) | Zéro nouveau backend — évite une réécriture involontaire |
| Migration rétro-doc + `REVOKE anon` | Support | `support_tickets`/`help_articles` (schéma et RLS existants, inchangés) | Ne recrée pas les tables, les verse dans `sql/` telles quelles |
| RPC triage + CMS support | Support | `platform_admin_role()`, `_platform_log` (déjà existants) | Ne fusionne pas avec `portal_requests`/`aide.html`/`maintenance_tickets` (périmètres distincts confirmés) |
| `_shared/sentry.ts` | Supervision | `_shared/cors.ts` (même emplacement, même convention) | Étend `admin_supervision_status()` au lieu d'en créer une seconde |
| `platform_incidents` | Supervision | `admin_platform_alerts` (source des alertes qui peuvent devenir un incident) | N'duplique pas le journal d'audit (`platform_logs`) |

---

## 5. Plan de réalisation — PR petites, indépendantes, testables

Chaque PR suit strictement la doctrine §1 : migration `sql/8N_...`, fichier de tests dédié
`sql/tests/...`, vérification ACL exhaustive, Jest si frontend touché, un seul commit
significatif par PR, revue avant merge. Aucun cron n'est activé sans une PR de validation
CTO dédiée et séparée de la PR qui livre la fonctionnalité sous-jacente.

| # | PR | Domaine | Dépend de | Bloquée par une décision CTO ? |
|---|---|---|---|---|
| 00 | `platform_notifications` + Edge Function Resend partagée | Transverse | — | Non |
| 01 | PDF réel de facture (bucket + Edge Function + RPC) | Paiements | — | Non |
| 02 | Dunning réel (preview + run manuel) | Paiements | PR-00 | Non |
| 03 | Passerelle de paiement réelle (intent + webhook) | Paiements | PR-00 (notif. de confirmation) | **Oui — choix du prestataire (§7.1)** |
| 04 | `admin_list_license_usage` + alerte quota | Licences | — | Non (V1 observe-only, §7.2) |
| 05 | Rétro-doc + `REVOKE anon` sur `support_tickets`/`help_articles` | Support | — | Non |
| 06 | RPC triage tickets + correction `STUB_INFO` | Support | PR-05 | Non |
| 07 | RPC CMS `help_articles` | Support | PR-05 | Non |
| 08 | Notification changement de statut ticket | Support | PR-00, PR-06 | Non |
| 09 | Cron essais expirés (migration dédiée) | Essais | — | **Oui — validation CTO dédiée (doctrine ADR-010 §3, §7.3)** |
| 10 | Notification essai bientôt expiré | Essais | PR-00 | Non |
| 11 | `platform_metrics_daily` + `admin_recompute_platform_metrics` (manuel) + série | Statistiques | — | Non |
| 12 | Écran divergence de droits (frontend seul, `admin_rights_divergence_report` existante) | Statistiques | — | Non |
| 13 | `admin_hotel_health_score` | Statistiques | PR-11, PR-06 | Non |
| 14 | Sentry frontend (`admin.html`) | Supervision | — | **Oui — compte/DSN Sentry (§7.5)** |
| 15 | Sentry Edge Functions + `admin_supervision_status` honnête | Supervision | PR-14 (DSN) | Non (peut démarrer avec un DSN de test) |
| 16 | `platform_incidents` (stretch, Could) | Supervision | PR-15 (source d'alertes) | Non — optionnelle, dernière du plan |

L'ordre respecte la priorité demandée par domaine (Paiements → Licences → Essais →
Statistiques → Support → Supervision) tout en plaçant PR-00 et PR-05 en tête de leur domaine
respectif car elles sont des prérequis techniques pour tout le reste de ce même domaine. Les
frontends (écrans `admin.html`) ne sont volontairement pas détaillés PR par PR ici — même
pattern que la Phase 1 (Lots 1 à 5) : chaque brique backend ci-dessus est livrée, testée et
mergée avant que l'écran correspondant ne soit construit dans une PR de suite dédiée.

---

## 6. Risques et vigilance

- **PR-03 (paiement réel)** est la plus risquée du plan — touche un flux financier réel,
  dépend d'un prestataire externe, introduit une surface d'attaque nouvelle (webhook public).
  À traiter avec la même rigueur que les migrations financières passées (tests en
  transaction sur données réelles, vérification de signature webhook obligatoire,
  idempotence stricte via `event_id` unique).
- **PR-09 (cron essais)** touche un flux qui modifie des statuts d'abonnement réels en
  production sans intervention humaine — la doctrine ADR-010 §3 doit être appliquée à la
  lettre, pas seulement citée.
- **Dette de versioning découverte en §2.5** (`support_tickets`/`help_articles` non
  versionnées) : PR-05 n'est pas seulement une PR Support, elle referme un vrai gap de
  gouvernance. Elle doit être traitée en priorité, indépendamment du reste du planning.

---

## 7. Décisions CTO nécessaires avant ou pendant l'exécution

1. **Prestataire de paiement** (Stripe ou autre) — bloque PR-03. Le schéma proposé est
   agnostique du choix, mais aucun code n'est écrit avant que le choix soit fait.
2. **Licences — alerte seule ou blocage réel un jour ?** Ce document recommande
   observe-only en V1 (cohérent avec la doctrine ADR-010), mais c'est un arbitrage produit,
   pas une décision technique.
3. **Activation du cron essais expirés** (#15 roadmap) — validation dédiée requise, distincte
   de la validation du présent document (doctrine déjà actée par ADR-010 §3).
4. **Activation d'un cron pour le dunning et pour le recalcul quotidien des métriques** —
   même doctrine, décisions séparées, non couvertes par une validation générique de cet ADR.
5. **Compte de monitoring d'erreurs** (Sentry ou équivalent) — coût, politique de rétention
   des données, bloque PR-14.
6. **Support — périmètre de la V1** : triage admin seul (tickets alimentés autrement), ou
   inclusion d'un point d'entrée de création de ticket côté `index.html`/`portal.html` dans le
   même chantier ?
7. **`platform_incidents`** (#35, Could) : inclus dans le batch initial ou reporté à un futur
   chantier de Supervision ?

---

## Prochaine étape

Ce document est soumis pour validation. Conformément à l'instruction reçue, aucun
développement (migration, RPC, frontend) ne démarre avant validation explicite de cette
architecture — et, pour PR-03/PR-09/PR-14, avant les décisions CTO listées en §7 qui les
concernent spécifiquement.
