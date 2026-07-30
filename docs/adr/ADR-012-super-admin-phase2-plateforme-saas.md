# ADR-012 — Phase 2 du Super Admin : plateforme SaaS de gestion commerciale et opérationnelle

**Statut** : Proposé, round 2 — révision architecturale demandée après un premier retour
favorable sur l'orientation générale. Toujours en attente de validation définitive. Aucune
migration, aucune RPC, aucun code frontend n'a été écrit à ce stade — ni au round 1, ni dans
cette révision.

**Portée** : six domaines, dans l'ordre de développement demandé — Paiements, Licences,
Périodes d'essai, Statistiques, Support, Supervision avancée.

**Ce qui a changé depuis le round 1** :
1. Le lot de fondation Support (rétro-versionnement) est détaillé au niveau DDL complet —
   contraintes, index, triggers, grants, policies, fonctions, séquence — et devient
   explicitement le premier chantier technique de toute la Phase 2 (§2.5, §3.5, §6-PR01/02/03).
2. La qualification de la faille `help_articles`/`support_tickets` a été retirée tant qu'elle
   n'était pas démontrée. Un test réel a été exécuté en base (rôle `anon`, en transaction,
   annulé) — résultat en §2.5.4. Le durcissement ACL est désormais une PR distincte du
   rétro-versionnement, justifiée par ce test, pas par une supposition.
3. Les 7 décisions CTO du round 1 ont reçu une réponse (§5) — reprises une à une pour
   vérification qu'aucune n'a été oubliée.
4. `platform_notifications` est spécifiée à un niveau opérationnel complet (§3.0).
5. Chaque métrique Statistiques est formellement définie (source, formule, fréquence, fuseau,
   traitement des annulations/avoirs/changements de plan, rejouabilité) — §3.4.
6. Les questions métier Paiements sont listées avant tout choix de prestataire, avec le
   contexte déjà connu de l'architecture existante — §3.1.
7. Le plan de PR est réorganisé dans l'ordre demandé, avec fiche complète par PR (objectif,
   fichiers, dépendances, migrations, risques, tests, critères d'acceptation, rollback) — §6.

---

## 0. Méthode

Round 1 : audit factuel par 5 recherches parallèles + lecture directe des ADR/RC1/roadmap.
Round 2 (cette révision) : introspection complémentaire ciblée sur `support_tickets`/
`help_articles` (contraintes, index, triggers, séquence, fonctions associées) et **un test
d'intrusion réel, exécuté en base**, pour qualifier précisément l'exposition `anon` — décrit
en §2.5.4. Le test a été conduit en transaction (`BEGIN ... ROLLBACK`), avec `SET LOCAL ROLE
anon` pour endosser exactement le rôle Postgres utilisé par PostgREST pour les requêtes non
authentifiées (l'appel REST direct depuis le sandbox était bloqué par la politique réseau,
comme documenté pour `*.vercel.app` ailleurs dans ce projet — `SET ROLE` teste la même
mécanique de permission, au niveau où elle est réellement appliquée par Postgres). Vérifié
après coup : zéro résidu en production (`support_tickets` : 0 ligne, `help_articles` : 8
lignes inchangées, aucun titre `ANON*`). Effet de bord mineur et sans impact fonctionnel signalé
en §2.5.4 (compteur de séquence).

---

## 1. Doctrine héritée de la Phase 1 (inchangée, à respecter à l'identique)

- **ACL des RPC `admin_*`** : `SECURITY DEFINER`, `SET search_path TO 'public','pg_temp'`,
  garde interne (`IF NOT public.is_platform_admin() THEN RAISE EXCEPTION ... '42501'`), puis
  `REVOKE ALL ... FROM PUBLIC, anon, service_role` + `GRANT EXECUTE ... TO authenticated`.
  Helpers internes (`_`-préfixés) : aucun grant client.
- **Audit** : `platform_logs` via `_platform_log()` (admin) ou `_platform_log_system()`
  (système/trigger/cron) ; table événementielle métier dédiée quand un cycle de vie le
  justifie.
- **Tables sensibles / soft-delete** : jamais de `DELETE` sur une entité journalisée.
- **Tests** : `sql/tests/<domaine>.sql`, `BEGIN` / fixtures `pg_temp.zz_*` / blocs
  `DO $$...EXCEPTION WHEN OTHERS...END $$` / `RAISE EXCEPTION` si FAIL / `ROLLBACK`.
- **Nommage migrations** : `sql/NN_<domaine>_<description>.sql`. Dernier existant : `sql/79`.
  **La Phase 2 commence à `sql/80`.**
- **Numérotation ADR** : dernier existant `ADR-011`. Ce document est **ADR-012**.
- **Doctrine cron** (ADR-010 §3) : jamais activé dans la même migration que la fonctionnalité.
  Migration séparée + validation CTO explicite et distincte.
- **Leçon du P0 (PR #18)** : toute action de traitement par lot doit exposer une RPC de
  prévisualisation dont le prédicat est strictement identique à celui de l'exécution.
- **Principe du moindre privilège** (précisé dans cette révision) : un écart entre grants et
  RLS ne se corrige qu'après avoir démontré, par un test réel, ce que l'écart permet
  effectivement — jamais par supposition. Voir §2.5.4.

---

## 2. État de l'existant, par domaine

### 2.1 Paiements — inchangé depuis le round 1

`platform_invoices`/`platform_payments`/`platform_credit_notes` (cycle complet, `sql/75`,
`sql/76`). Lacunes confirmées : pas de passerelle de paiement réelle, `dunning_days_before`
jamais lu, `pdf_url` jamais écrit (export = `window.print()`).

### 2.2 Licences — inchangé depuis le round 1

`subscription_plans`/`plan_modules`/`hotel_addon_subscriptions`/`snapshot_limits` (`sql/70`,
`sql/71`, `sql/78`). `snapshot_limits` stocké, jamais comparé à un usage réel. Accès binaire
par module, pas de système de quota ni de clé de licence.

### 2.3 Périodes d'essai — inchangé depuis le round 1

Cycle complet sur `hotel_subscriptions` (`sql/70`, `sql/79`, ADR-011), preview/exécution
cohérentes depuis le P0. Cron jamais activé (0 job `pg_cron` en production). Aucune
notification avant expiration.

### 2.4 Statistiques — inchangé depuis le round 1

`admin_platform_overview_kpis`/`admin_platform_alerts`/`admin_rights_divergence_report`
(`sql/76`). Aucun agrégat ni série temporelle — tout est recalculé à la volée. Pas de
MRR/ARR/churn réel, pas de delta période, pas de score de santé.

### 2.5 Support — inventaire technique complet (rétro-versionnement)

**Rappel du constat central** : `support_tickets` et `help_articles` existent réellement en
production (introspection directe de `hzrzkvdebaadditvbqis`) mais **ne sont versionnées dans
aucun fichier `sql/`**. C'est le même type de dette que celle déjà documentée par ADR-011 pour
d'autres objets bootstrappés hors migration. C'est traité ici comme le **premier risque** de la
Phase 2, avant tout développement nouveau (voir §3.5, §6-PR01/02/03).

#### 2.5.1 `support_tickets` — inventaire exact

**Colonnes** : `id uuid PK DEFAULT gen_random_uuid()`, `hotel_id uuid NOT NULL`,
`ticket_number text` (généré par trigger, jamais saisi), `module text NOT NULL`,
`feature text NOT NULL`, `problem_type text NOT NULL DEFAULT 'autre'`,
`description text NOT NULL`, `steps jsonb NOT NULL DEFAULT '[]'`, `expected_result text`,
`actual_result text`, `priority text NOT NULL DEFAULT 'moyen'`, `attachment_url text`,
`user_id uuid`, `user_email text`, `user_role text`, `current_module text`,
`current_page text`, `browser_info jsonb`, `related_entity_id text`,
`status text NOT NULL DEFAULT 'nouveau'`, `assigned_to text`, `claude_response text`,
`classification text`, `created_at timestamptz NOT NULL DEFAULT now()`,
`updated_at timestamptz NOT NULL DEFAULT now()`, `risk_score text`, `diagnostic_details jsonb`.

**Contraintes** :
- `support_tickets_pkey` — `PRIMARY KEY (id)`.
- `support_tickets_ticket_number_key` — `UNIQUE (ticket_number)`.
- `support_tickets_hotel_id_fkey` — `FOREIGN KEY (hotel_id) REFERENCES hotels(id) ON DELETE CASCADE`.
- `support_tickets_user_id_fkey` — `FOREIGN KEY (user_id) REFERENCES auth.users(id)`.
- `support_tickets_status_check` — `status IN ('nouveau','en_analyse','attente_utilisateur','en_correction','resolu','ferme')`.
- `support_tickets_priority_check` — `priority IN ('bloquant','eleve','moyen','faible')`.
- `support_tickets_classification_check` — `classification IN ('bug','amelioration','question') OR classification IS NULL`.
- `support_tickets_risk_score_check` — `risk_score IN ('faible','moyen','eleve','critique')`.
- `support_tickets_description_check` — `char_length(description) <= 500`.

**Index** : `support_tickets_pkey` (id), `support_tickets_ticket_number_key` (ticket_number),
`idx_support_tickets_hotel` (hotel_id, created_at DESC), `idx_support_tickets_status`
(hotel_id, status).

**Triggers** :
- `trg_support_ticket_number` (BEFORE INSERT) → `support_set_ticket_number()` : génère
  `'SUP-' || TO_CHAR(created_at,'YYYYMM') || '-' || LPAD(nextval('support_ticket_seq')::text,4,'0')`.
- `trg_support_updated_at` (BEFORE UPDATE) → `support_set_updated_at()` : `NEW.updated_at = now()`.

**Séquence** : `support_ticket_seq` — `USAGE` accordé à `anon`, `authenticated`, `service_role`,
`postgres`. **Note** : cette séquence n'est *pas* transactionnelle (comportement standard
Postgres) — une tentative d'`INSERT` bloquée après coup par la RLS a tout de même pu
consommer une valeur (le trigger `BEFORE INSERT` s'exécute avant l'évaluation de la clause RLS
`WITH CHECK`). Constaté pendant le test du §2.5.4 : la séquence porte la trace d'appels de
test malgré le `ROLLBACK` — sans aucune conséquence fonctionnelle (un simple saut dans la
numérotation des tickets, sans donnée exposée ni corrompue).

**Grants table-level actuels** (à reproduire à l'identique dans la migration de
rétro-versionnement, §3.5.1) : `anon`, `authenticated`, `service_role`, `postgres` ont tous
`INSERT/SELECT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER`.

#### 2.5.2 `help_articles` — inventaire exact

**Colonnes** : `id uuid PK`, `module text NOT NULL`, `title text NOT NULL`, `slug text`,
`excerpt text`, `body text NOT NULL`, `tags text[] NOT NULL`, `sort_order integer NOT NULL`,
`is_published boolean NOT NULL`, `view_count integer NOT NULL`, `created_by uuid`,
`updated_by uuid`, `created_at timestamptz NOT NULL`, `updated_at timestamptz NOT NULL`.

**Contraintes** : `help_articles_pkey` — `PRIMARY KEY (id)` **uniquement**. Aucun `CHECK`,
aucune `FOREIGN KEY` (y compris sur `created_by`/`updated_by`, qui ne référencent
formellement rien), aucune contrainte `UNIQUE` sur `slug`. Ce constat est noté ici comme un
**fait**, pas encore comme une recommandation de correction — voir §3.5.1 sur la distinction
entre rétro-versionnement à l'identique et durcissement ultérieur.

**Index** : `help_articles_pkey` (id), `idx_help_articles_module` (module, sort_order),
`idx_help_articles_published` (is_published, module).

**Trigger** : `trg_help_articles_updated` (BEFORE UPDATE) → `trg_help_articles_updated_at()` :
`NEW.updated_at = now()`.

**Grants table-level actuels** : `anon`, `authenticated`, `service_role`, `postgres` ont tous
`INSERT/SELECT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER`.

#### 2.5.3 Fonctions et helpers associés

- `support_set_ticket_number()`, `support_set_updated_at()`, `trg_help_articles_updated_at()`
  — trois fonctions trigger, `LANGUAGE plpgsql`, `SET search_path TO 'pg_catalog','public'`,
  **aucune n'est `SECURITY DEFINER`** (elles s'exécutent avec les droits du rôle appelant, pas
  de contournement de privilège possible via ces triggers).
- `platform_admin_role()` — **déjà existante**, créée hors du périmètre Support (probablement
  en même temps que `platform_admins`), réutilisée telle quelle par la policy d'écriture de
  `help_articles`. `STABLE SECURITY DEFINER`, retourne le `role` de l'admin connecté ou `NULL`.
- `is_platform_admin()` — déjà existante (ADR-009), réutilisée par les policies de
  `support_tickets`.
- **Aucune RPC `admin_*` ne référence ni `support_tickets` ni `help_articles`** — confirmé par
  recherche exhaustive sur la définition de toutes les fonctions `public.*`. Le portail
  interagirait aujourd'hui, s'il était câblé, en accès table direct — ce qui contredit la
  doctrine RPC-only de la Phase 1 (§1).

#### 2.5.4 Matrice ACL/RLS — test réel exécuté

**Policies RLS existantes** (`relrowsecurity = true` sur les deux tables) :

| Table | Policy | Commande | Rôles | Condition |
|---|---|---|---|---|
| `help_articles` | `help_articles_select` | SELECT | public | `is_published = true OR is_platform_admin()` |
| `help_articles` | `help_articles_write` | ALL (donc INSERT/UPDATE/DELETE, et SELECT en supplément) | public | `platform_admin_role() = ANY('{super_admin,support_agent}')` |
| `support_tickets` | `platform_admin_read_tickets` | SELECT | public | `is_platform_admin()` |
| `support_tickets` | `platform_admin_update_tickets` | UPDATE | public | `is_platform_admin()` |
| `support_tickets` | `support_select` | SELECT | public | `hotel_id IN (SELECT hotel_id FROM user_hotels WHERE user_id = auth.uid())` |
| `support_tickets` | `support_update` | UPDATE | public | idem |
| `support_tickets` | `support_insert` | INSERT | public | idem (`WITH CHECK`) |

**Test réel** (rôle Postgres `anon`, en transaction, annulée — `sql/tests/` reprendra ce
scénario) :

| # | Action testée | Résultat observé | Interprétation |
|---|---|---|---|
| 1 | `SELECT` sur `help_articles` (anon) | 8 lignes visibles | Les 8 articles publiés sont lisibles — **conforme à la policy `is_published = true`**, comportement voulu par la clause elle-même |
| 2 | `SELECT` sur `help_articles` où `is_published = false` (anon) | 0 ligne visible | Les brouillons restent invisibles à un utilisateur non admin |
| 3 | `INSERT` sur `help_articles` (anon) | **Bloqué** — `42501 new row violates row-level security policy` | La RLS neutralise le grant table-level trop large |
| 4 | `UPDATE` sur un article publié (anon) | 0 ligne affectée (pas d'erreur, filtrage silencieux) | La RLS neutralise le grant ; comportement Postgres normal pour un `UPDATE` dont la clause `USING` ne matche aucune ligne |
| 5 | `DELETE` sur un article publié (anon) | 0 ligne affectée | Idem |
| 6 | `SELECT` sur `support_tickets` (anon), avec une ligne marqueur insérée par `postgres` juste avant | 0 ligne visible malgré la ligne existante côté serveur | La RLS filtre intégralement — aucune fuite, même en présence de données réelles |
| 7 | `INSERT` sur `support_tickets` avec un `hotel_id` réel (anon) | **Bloqué** — `42501 new row violates row-level security policy` | Le `WITH CHECK` sur `user_hotels`/`auth.uid()` bloque toute insertion anonyme |
| 8 | `UPDATE` sur la ligne marqueur (anon) | 0 ligne affectée | Idem #4 |

**Conclusion, par la classification demandée** :

- **`support_tickets`** : *privilèges inutilement larges mais bloqués par RLS.* Les grants
  table-level (`anon` a INSERT/SELECT/UPDATE/DELETE) sont plus larges que nécessaire, mais
  **aucune donnée n'est lisible ni modifiable par un utilisateur anonyme** — testé, pas
  supposé. Aucun contournement `SECURITY DEFINER` n'existe (aucune RPC ne touche cette table).
- **`help_articles`, écriture (INSERT/UPDATE/DELETE)** : *privilèges inutilement larges mais
  bloqués par RLS* — même conclusion que `support_tickets`, testé et confirmé.
- **`help_articles`, lecture des articles publiés** : *configuration conforme.* La policy
  `is_published = true OR is_platform_admin()` est explicitement écrite pour rendre le contenu
  publié lisible sans authentification — c'est un centre d'aide, une lecture publique du
  contenu publié est un choix de conception légitime pour ce type d'objet, pas une fuite.
  Aucune donnée sensible n'est exposée par cette policy (pas de PII, pas de donnée hôtel).

**Verdict global : aucune exposition effectivement exploitable détectée.** Le durcissement
proposé en §3.5.1/§6-PR03 (`REVOKE` des grants `anon` en excès) reste recommandé au nom du
principe de moindre privilège et de la doctrine déjà en vigueur ailleurs dans le projet (« ne
jamais reposer sur la RLS seule »), **mais uniquement comme mesure de défense en profondeur,
pas comme correctif d'urgence** — et dans une PR séparée du rétro-versionnement à l'identique
(§3.5.1), pour ne jamais mélanger « remettre sous contrôle du dépôt » et « changer un
comportement ».

**Effet de bord du test, transparence complète** : la séquence `support_ticket_seq` a
probablement avancé d'une unité pendant le test (voir §2.5.1) — sans conséquence, sans donnée
créée ni exposée en production (vérifié après coup : `support_tickets` = 0 ligne,
`help_articles` = 8 lignes inchangées, aucun titre `ANON*`).

#### 2.5.5 Comparaison dépôt / production

| Objet | Dans `sql/` | En production | Action |
|---|---|---|---|
| Table `support_tickets` | Absente | Présente (0 ligne) | À verser à l'identique (§3.5.1) |
| Table `help_articles` | Absente | Présente (8 lignes publiées) | À verser à l'identique |
| Séquence `support_ticket_seq` | Absente | Présente | À verser à l'identique |
| 3 fonctions trigger (§2.5.3) | Absentes | Présentes | À verser à l'identique |
| 7 policies RLS (§2.5.4) | Absentes | Présentes | À verser à l'identique |
| Rôle `support_agent` dans `platform_admins.role` CHECK | Présent (`sql/73`) | Présent | Déjà cohérent, aucune action |
| `STUB_INFO.support` dans `admin.html:755` | — | — | Description inexacte (« lecture seule ») à corriger dans la PR RPC de triage, pas dans le rétro-versionnement |

**Non liés, confirmés hors-sujet** (inchangé) : `portal_requests`/`portal_messages` (RH
interne), `aide.html` (statique, RH), `maintenance_tickets` (PMS/Housekeeping).

### 2.6 Supervision avancée — inchangé depuis le round 1

`admin_supervision_status()` honnête, `admin_list_platform_audit_log()`. Pas de monitoring
d'erreurs réel, pas d'historique d'incidents, `webhooks_configured` toujours `false`.

### 2.7 Infrastructure transverse déjà disponible

Resend (`RESEND_API_KEY`, pattern `supabase/functions/sig-send`) — à réutiliser pour tout
envoi d'email Phase 2, jamais un second prestataire.

---

## 3. Architecture proposée, par domaine

### 3.0 Fondation transverse — `platform_notifications`

**Nature** : une file métier de notifications, pas une file de tâches générique. Chaque ligne
représente une notification à envoyer à un destinataire identifié, pour une raison métier
identifiée, jamais une tâche différée arbitraire.

**Schéma proposé** :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `category` | `text NOT NULL CHECK IN ('dunning','trial_ending','support_ticket_update','support_ticket_new')` | Catégorie métier fermée — toute nouvelle catégorie = migration explicite, jamais une valeur libre |
| `reference_type` | `text NOT NULL` | Type de l'objet source (`platform_invoice`, `hotel_subscription`, `support_ticket`) |
| `reference_id` | `uuid NOT NULL` | Id de l'objet source |
| `dedupe_key` | `text NOT NULL UNIQUE` | Clé d'idempotence métier — ex. `dunning:<invoice_id>:<offset>`, `trial:<subscription_id>:<jours>`, `support:<ticket_id>:<status>:<updated_at ISO>` |
| `channel` | `text NOT NULL DEFAULT 'email' CHECK IN ('email')` | Un seul canal en V1, colonne prête pour en ajouter sans migration de schéma |
| `recipient_email` | `text NOT NULL` | Snapshot de l'adresse au moment de la création — jamais résolu dynamiquement à l'envoi (cohérent avec la doctrine `bill_to_*`/snapshot déjà appliquée aux factures) |
| `template` | `text NOT NULL` | Identifiant du gabarit de contenu (ex. `dunning_reminder`, `trial_ending_soon`, `ticket_status_changed`) — le contenu HTML/texte n'est pas stocké en base, il vit dans l'Edge Function, versionné avec le code |
| `template_payload` | `jsonb NOT NULL DEFAULT '{}'` | Variables injectées dans le gabarit (montant, date, nom d'hôtel…) — snapshot au moment de la création, jamais recalculé à l'envoi |
| `status` | `text NOT NULL DEFAULT 'pending' CHECK IN ('pending','sending','sent','failed','abandoned')` | `sending` distingue explicitement « en cours d'envoi » de `pending`, pour la gestion de la concurrence (voir plus bas) |
| `attempts` | `integer NOT NULL DEFAULT 0` | Nombre de tentatives d'envoi déjà effectuées |
| `max_attempts` | `integer NOT NULL DEFAULT 3` | Borne — au-delà, `status` passe à `abandoned`, jamais de boucle infinie |
| `next_attempt_at` | `timestamptz` | `NULL` si pas de nouvelle tentative prévue ; sinon date/heure du prochain essai (backoff, ex. 5 min / 30 min / 2 h) |
| `last_error` | `text` | Message d'erreur de la dernière tentative échouée |
| `final_error` | `text` | Rempli seulement quand `status = 'abandoned'` — distinct de `last_error` pour ne jamais perdre la cause d'abandon même si une tentative ultérieure était encore tentée entre-temps |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `processed_at` | `timestamptz` | Horodatage du dernier traitement (tentative, réussie ou non) |
| `sent_at` | `timestamptz` | Rempli uniquement en cas de succès effectif |
| `failed_at` | `timestamptz` | Rempli uniquement au passage en `abandoned` |

**Statuts et transitions** : `pending → sending → (sent | pending-avec-next_attempt_at | abandoned)`.
Jamais de transition directe `pending → sent` sans passer par `sending` (voir concurrence
ci-dessous).

**Concurrence** : le passage à `sending` se fait par un `UPDATE ... SET status='sending'
WHERE id = ? AND status = 'pending' RETURNING id` — si deux exécutions concurrentes du
traitement des notifications tentent la même ligne, une seule obtient la ligne mise à jour (la
seconde `UPDATE` ne matche plus rien, `RETURNING` vide, elle passe à la suivante). Aucun verrou
consultatif nécessaire, le motif `UPDATE ... WHERE status='pending'` suffit — plus simple que
`FOR UPDATE SKIP LOCKED` pour ce cas (pas de boucle de traitement séquentielle par ligne
nécessaire ici, contrairement au traitement des essais expirés).

**Comportement en cas de nouvel envoi** (ex. un ticket change deux fois de statut avant que la
première notification ne soit traitée) : le `dedupe_key` inclut la valeur qui change
(`support:<ticket_id>:<status>:<updated_at>`) — deux changements de statut produisent deux
`dedupe_key` distincts, donc deux notifications légitimes, pas une collision. Une tentative de
notifier deux fois *le même* événement (même clé) échoue sur la contrainte `UNIQUE
(dedupe_key)` — l'insertion est absorbée silencieusement (`ON CONFLICT (dedupe_key) DO
NOTHING`), pas une erreur remontée à l'appelant.

**RLS et grants** : aucun accès client, ni `anon` ni `authenticated`. Uniquement `service_role`
(Edge Function) en écriture et un accès admin en lecture seule via une future RPC
`admin_list_notifications` si un écran de supervision des envois est utile (non prioritaire,
pas dans le lot initial). `REVOKE ALL FROM PUBLIC, anon, authenticated` — grant `service_role`
uniquement pour l'écriture, pas de RLS nécessaire tant qu'aucun rôle client n'y accède
directement.

**Politique de rétention** : proposition — conserver 90 jours en table active, au-delà un
archivage ou une purge (à trancher lors de la PR, pas dans cet ADR, car cela dépend d'une
politique de conservation des données personnelles — `recipient_email` est une donnée
personnelle — qui doit rester cohérente avec la politique déjà appliquée ailleurs dans le
projet, ex. GDPR purge déjà existante pour les documents invités, migration `r3_gdpr_purge_guest_documents`).
Pas de suppression automatique proposée dans la première PR — la table démarre sans purge, la
purge est un chantier explicite ultérieur si le volume le justifie.

**Edge Function `platform-send-notification`** : point d'appel unique à Resend, `service_role`
uniquement, jamais invocable depuis le client. Marque `sending` avant l'appel réseau, `sent`/
`pending`+`next_attempt_at`/`abandoned` après, selon le résultat.

### 3.1 Paiements — décisions métier avant choix de prestataire

Avant tout choix de prestataire (Stripe ou autre — décision CTO différée, §5), les questions
métier suivantes doivent être tranchées, avec le contexte déjà connu de l'architecture
existante :

| Question | Contexte déjà existant | Statut |
|---|---|---|
| Client facturé : hôtel ou groupe ? | `hotel_subscriptions` a `UNIQUE(hotel_id)` — **un abonnement par hôtel**, pas par groupe. La facturation consolidée par groupe (roadmap #26) impliquerait une refonte du modèle. | **Non tranché** — la Phase 2 conserve par défaut la facturation par établissement (aucun changement de modèle proposé) sauf décision contraire explicite |
| Facturation consolidée ou par établissement ? | Découle directement de la ligne précédente | Par établissement, par défaut |
| Périodicité | `platform_invoices.period_start/period_end` existent déjà, génériques (pas de fréquence imposée en base) | **Non tranché** — mensuel, trimestriel, annuel ? |
| Engagement (durée minimale) | Aucune notion de durée d'engagement dans `hotel_subscriptions` aujourd'hui | **Non tranché** |
| Prorata (changement de plan en cours de période) | `admin_change_subscription_plan` applique le changement **immédiatement**, sans proratisation ni régularisation de facture | **Non tranché** — la Phase 2 introduit-elle un prorata, ou le changement de plan reste-t-il un nouveau départ de facturation propre ? |
| TVA | `platform_invoices.tva_rate/tva_amount` déjà gérés (taux unique par facture) | Déjà couvert, pas de nouvelle décision nécessaire sauf TVA multi-taux |
| Changement de plan | RPC déjà existante (`admin_change_subscription_plan`), immédiat, sans lien automatique avec la facturation | Voir prorata ci-dessus |
| Impayé | `admin_suspend_subscription_for_nonpayment` déjà existant (wrapper au-dessus de `admin_suspend_subscription`) | Déjà couvert |
| Suspension | `admin_suspend_subscription`/`admin_reactivate_subscription` déjà existants | Déjà couvert |
| Résiliation | `admin_cancel_subscription_immediate`/`admin_schedule_subscription_cancellation` déjà existants | Déjà couvert |
| Avoirs | `platform_credit_notes` déjà existant, jamais fusionné dans la facture | Déjà couvert |
| Remboursements | Aucun mécanisme aujourd'hui — un avoir documente une créance annulée, pas un flux d'argent sortant réel | **Non tranché** — un remboursement réel (vers le moyen de paiement d'origine) est-il dans le périmètre Phase 2, ou seulement l'avoir documentaire ? Dépend directement du choix de prestataire |
| Export comptable | Rien n'existe aujourd'hui (pas de format FEC, pas d'export vers un outil comptable) | **Non tranché**, hors du périmètre des 3 PR Paiements déjà esquissées (§6), à cadrer séparément si prioritaire |
| Source de vérité | `platform_invoices`/`platform_payments` = source de vérité de la facturation plateforme ; `hotel_subscriptions` = source de vérité de l'accès/droit, volontairement distincte (même principe que la séparation déjà actée par ADR-011 entre accès et facturation) | Déjà couvert, à confirmer que la Phase 2 ne mélange pas les deux |

**Position de cet ADR** : ne pas construire d'abstraction multi-prestataires en V1. Le schéma
`platform_payment_intents`/`platform_payment_provider_events` proposé au round 1 reste
volontairement simple (un `provider` texte, pas une couche d'adaptateurs), mais son
*implémentation* (Edge Function, format de webhook) sera spécifique au prestataire choisi —
pas généraliste par anticipation. Détail technique inchangé depuis le round 1, résumé en §3.1
et non redupliqué ici.

### 3.2 Licences — décidé : observation, comptage et alertes uniquement

Confirmé par décision CTO (§5) : aucun blocage automatique en V1. Architecture inchangée
depuis le round 1 — `admin_list_license_usage()` (comptage réel vs `snapshot_limits`) +
nouveau type d'alerte `license_quota_exceeded` dans `admin_platform_alerts()`. Aucune nouvelle
table. Ne touche jamais `hotel_app_subscriptions`.

### 3.3 Périodes d'essai — décidé : cron non activé pour le moment

Confirmé par décision CTO (§5) : **le cron d'expiration des essais n'est pas activé dans ce
cycle de Phase 2.** La PR-09 du round 1 (« activation du cron ») est retirée du plan de
réalisation (§6) — elle redevient un simple chantier futur documenté (comme il l'était déjà
avant le round 1, cf. ADR-010 §3), pas une PR planifiée. Seule reste au plan : la notification
« essai bientôt expiré » (§3.0, réutilise `trial_ending_soon` déjà détecté par
`admin_platform_alerts`), qui ne nécessite aucun cron — elle peut être déclenchée manuellement
ou lors de la consultation du dashboard, exactement comme le traitement des essais expirés
reste aujourd'hui 100 % manuel.

### 3.4 Statistiques — définitions formelles

Toutes les métriques ci-dessous partagent : **fuseau horaire proposé Europe/Paris** pour la
définition du « jour métier » (siège Flowtym en France, ancré sur les données déjà observées) —
**à confirmer explicitement par le CTO**, ce n'est pas un point purement technique. **Fréquence
de calcul V1 : à la demande** (déclenchement manuel via `admin_recompute_platform_metrics`,
pas de cron — cohérent avec la décision §3.3 de ne pas activer de nouveau cron dans ce cycle).
**Recalcul historique** : la RPC de recalcul accepte une date passée en paramètre et
reconstitue l'état à cette date à partir de `hotel_subscription_events` (event-sourcing), pas
seulement l'état courant — condition nécessaire pour que `platform_metrics_daily` reste
corrigible si un bug de calcul est détecté après coup, sans jamais retoucher silencieusement
une ligne déjà écrite (nouvel appel = nouvelle ligne recalculée, `UPDATE` explicite et
journalisé, jamais un `UPDATE` muet).

| Métrique | Source | Formule | Traitement annulations/avoirs/changements de plan |
|---|---|---|---|
| **MRR contractuel** | `hotel_subscriptions` (`status='active'`) + `snapshot_price` + `hotel_addon_subscriptions` actifs | Somme des prix récurrents figés (snapshot) des abonnements actifs à la date calculée | Une résiliation/suspension sort immédiatement le montant du MRR à sa date d'effet réelle (`hotel_subscription_events`) ; un changement de plan applique le nouveau `snapshot_price` à sa date d'effet, sans proratisation (mesure de rythme, pas un montant facturé) ; les avoirs n'affectent pas le MRR contractuel (il ne dépend pas de la facturation réelle) |
| **MRR facturé** | `platform_invoices` (`status='issued'`) | Montant HT des factures émises sur la période, ramené à une base mensuelle si la périodicité n'est pas mensuelle (proratisation sur `period_start`/`period_end`) | Reflète la facturation réelle, peut diverger du contractuel en cas de décalage de date d'émission |
| **MRR encaissé** | `platform_payments` (`status='recorded'`) | Somme des paiements enregistrés dans le mois, indépendamment de la période qu'ils soldent (comptabilité de caisse) | Un avoir réduit le montant net du **mois d'émission de l'avoir** (proposition par défaut, à confirmer CTO si une autre convention est préférée) |
| **ARR** | Dérivé du MRR contractuel | `MRR contractuel × 12` | Recalculé à chaque recalcul du MRR contractuel, pas une mesure indépendante |
| **Churn logo** | `hotel_subscription_events` (événements de résiliation) | Nombre d'hôtels résiliés (pas suspendus) sur la période ÷ nombre d'hôtels actifs en début de période | Ne compte que la résiliation définitive, pas la suspension temporaire pour impayé |
| **Churn revenu** | `hotel_subscription_events` + `snapshot_price` avant/après | MRR contractuel perdu (résiliations + rétrogradations de plan) sur la période ÷ MRR contractuel en début de période | Distingue explicitement du churn logo — un gros client qui rétrograde pèse dans le churn revenu sans compter dans le churn logo |
| **Conversion des essais** | `hotel_subscription_events` (événement de conversion, écrit par `admin_convert_trial_to_active`) | Essais convertis en actif sur la période ÷ (essais convertis + essais expirés) sur la même période | — |
| **Hôtels actifs** | Réutilise **exactement** la définition déjà utilisée par `admin_platform_overview_kpis` | — | Volontairement pas de seconde définition — évite deux chiffres « hôtels actifs » divergents dans deux écrans |
| **Utilisateurs actifs** | Idem — réutilise la définition déjà utilisée par `admin_platform_overview_kpis` | — | Idem |

Score de santé hôtel (§3.4 round 1, inchangé), rapport de divergence de droits (frontend seul,
inchangé), anomalies et facturation consolidée par groupe (hors périmètre v1, inchangé).

### 3.5 Support — lot de fondation détaillé (premier chantier technique de la Phase 2)

**3.5.1 — Rétro-versionnement à l'identique** (PR-01, aucun changement de comportement) :
verse dans `sql/80_...` la reproduction exacte de l'existant décrit en §2.5.1/§2.5.2/§2.5.3 —
tables (`CREATE TABLE IF NOT EXISTS`, colonnes et types identiques), toutes les contraintes
listées, tous les index, tous les triggers et leurs fonctions, la séquence, les 7 policies RLS
mot pour mot, **et les grants actuels reproduits tels quels** (y compris les grants `anon`
larges — ce n'est pas le rôle de cette PR de les changer). Objectif unique : que `sql/` décrive
exactement ce qui tourne en production, ni plus ni moins.

**3.5.2 — Tests de reconstruction** (PR-02) : fichier `sql/tests/support_retro_versioning.sql`
qui (a) reconstruit le schéma depuis zéro dans une transaction et vérifie qu'il est identique
(colonnes, contraintes, index) à ce qui est observé en production ; (b) rejoue le test de
rôle `anon` du §2.5.4 de façon versionnée et répétable (les 8 scénarios du tableau), pour que
toute régression future sur ces deux tables soit détectée automatiquement ; (c) vérifie que les
`INSERT`/`UPDATE` d'un utilisateur hôtel lié via `user_hotels` fonctionnent bien sur ses propres
tickets et échouent sur ceux d'un autre hôtel.

**3.5.3 — Durcissement ACL, si nécessaire** (PR-03, distincte, justifiée par le §2.5.4) :
`REVOKE ALL ... FROM anon` sur les deux tables et sur la séquence (garde `authenticated`, qui
en a besoin légitimement pour les hôtels et pour les admins). Ne change **aucune** policy RLS
(elles sont déjà correctes). Test de non-régression : le scénario §2.5.4 rejoué doit donner
exactement les mêmes résultats côté `authenticated` légitime, et confirmer qu'`anon` n'a même
plus le grant table-level pour tenter quoi que ce soit (erreur `permission denied for table`
au lieu de `new row violates row-level security policy` — un signal plus tôt dans la chaîne,
défense en profondeur).

**3.5.4 — RPC de triage** (PR-09 au plan reordonné, §6) : inchangé depuis le round 1 —
`admin_list_support_tickets`, `admin_get_support_ticket_detail`, `admin_update_support_ticket`,
chaque mutation journalisée via `_platform_log`, correction de `STUB_INFO.support`.

**3.5.5 — RPC CMS `help_articles`** : inchangé depuis le round 1, même doctrine ACL.

**3.5.6 — Création de ticket côté hôtel** (PR-10, décidée distincte — §5, décision Support V1) :
point d'entrée dans `index.html`/`portal.html` permettant à un utilisateur hôtel de créer un
ticket. Explicitement une PR séparée de la précédente (triage), livrée après, jamais dans le
même lot — décision CTO confirmée en §5.

**3.5.7 — Notification de changement de statut** : inchangé depuis le round 1, réutilise §3.0.

### 3.6 Supervision avancée — décidé : Sentry ne bloque pas la supervision native

Confirmé par décision CTO (§5) : la supervision native déjà en place
(`admin_supervision_status`, `admin_list_platform_audit_log`) continue d'évoluer
indépendamment de Sentry. La mise à jour honnête de `admin_supervision_status()` (signaux
`mutation_error_monitoring_available`/`edge_function_error_monitoring_available` passés à
`true`) n'est effectuée **que** le jour où Sentry (ou équivalent) est réellement câblé — tant
que ce n'est pas le cas, les signaux restent `false`, honnêtes, et rien dans la Phase 2 ne
dépend de Sentry pour livrer de la valeur de supervision. `platform_incidents` (stretch, Could)
inchangé.

---

## 4. Preuve de non-duplication

Inchangée depuis le round 1 (voir tableau complet du document précédent) — aucune ligne n'est
invalidée par cette révision. Deux lignes précisées :

| Nouvelle brique | Domaine | S'appuie sur | Ne duplique pas |
|---|---|---|---|
| Migration `sql/80` (rétro-versionnement) | Support | `support_tickets`/`help_articles` (schéma production, reproduit à l'identique) | Ne recrée rien — recopie ce qui existe, grants inclus, sans aucune amélioration cachée |
| `REVOKE anon` (PR-03 Support) | Support | Le test réel du §2.5.4, pas une supposition | N'est plus fusionné avec le rétro-versionnement — décision distincte, justifiée par preuve |

---

## 5. Les 7 décisions CTO — statut après ce round

Reprise exacte des 7 décisions listées au round 1, pour vérification qu'aucune n'a été oubliée :

1. **Prestataire de paiement** (Stripe ou autre) — **toujours différée**, confirmé
   explicitement : « décision différée jusqu'à validation du modèle commercial et
   contractuel ». Bloque toujours PR-Paiements (§6). Les questions métier préalables sont
   maintenant listées en §3.1.
2. **Licences — alerte seule ou blocage réel ?** — **Tranché : observation, comptage et
   alertes uniquement, aucun blocage automatique en V1.**
3. **Activation du cron essais expirés** — **Tranché : ne pas l'activer pour le moment.**
   Retiré du plan de réalisation (§6), reste un chantier futur documenté par ADR-010 §3.
4. **Activation d'un cron pour le dunning / le recalcul quotidien des métriques** — cohérent
   avec la décision 3 : **aucun cron n'est activé dans ce cycle**, dunning et métriques restent
   à déclenchement manuel en V1 (§3.1, §3.4).
5. **Compte de monitoring d'erreurs (Sentry)** — **Tranché : Sentry ne doit pas bloquer la
   supervision native.** Reste une PR indépendante et optionnelle, sans dépendance du reste de
   la Supervision avancée sur son activation.
6. **Support — périmètre V1** — **Tranché : triage Super Admin d'abord, puis création de
   ticket côté hôtel dans une PR distincte** (§3.5.6, §6-PR10).
7. **`platform_incidents` (#35, Could)** — **Non explicitement tranché dans les instructions de
   ce round.** Reste optionnelle, en fin de plan (§6), sans blocage du reste. À confirmer
   explicitement si le CTO souhaite l'inclure ou la retirer du batch initial.

**Décision supplémentaire actée ce round** : `platform_notifications` — fondation transverse
validée **sous réserve** d'idempotence (portée par `dedupe_key UNIQUE`), de gestion des
tentatives (`attempts`/`max_attempts`/`next_attempt_at`), de rétention (proposition 90 jours,
non automatisée en V1) et de traçabilité (`created_at`/`processed_at`/`sent_at`/`failed_at`,
`last_error`/`final_error`) — toutes ces exigences sont désormais couvertes par le schéma
détaillé en §3.0.

**Décision supplémentaire actée ce round** : `hotel_app_subscriptions` — confirmé qu'aucune
nouvelle lecture, écriture ou dépendance n'est introduite par la Phase 2 (déjà le cas au round
1, §3.2 et §4 — reconfirmé explicitement ici sans changement d'architecture).

---

## 6. Plan de réalisation — PR détaillées, ordre imposé

Ordre respecté : (1) ADR-012 finalisée, (2) rétro-versionnement Support à l'identique, (3)
tests reconstruction/RLS Support, (4) durcissement ACL si nécessaire, (5) fondation
`platform_notifications`, (6) licences en observation, (7) notifications d'essais, (8)
statistiques fondamentales, (9) support triage, (10) création ticket hôtel, (11) supervision
native, (12) paiements après décisions métier.

### PR-00 — ADR-012 finalisée
- **Objectif** : obtenir la validation explicite de cette architecture.
- **Fichiers concernés** : `docs/adr/ADR-012-super-admin-phase2-plateforme-saas.md` (ce
  document).
- **Dépendances** : aucune.
- **Migrations** : aucune.
- **Risques** : aucun (documentaire).
- **Tests** : aucun.
- **Critères d'acceptation** : validation explicite reçue du CTO, décision 7 (§5) tranchée.
- **Rollback** : sans objet.

### PR-01 — Rétro-versionnement Support à l'identique
- **Objectif** : remettre `support_tickets`/`help_articles` sous contrôle du dépôt, sans
  aucun changement de comportement.
- **Fichiers concernés** : nouveau `sql/80_support_retro_versioning.sql`.
- **Dépendances** : PR-00.
- **Migrations** : `CREATE TABLE IF NOT EXISTS` (colonnes/contraintes/index identiques à
  §2.5.1/§2.5.2), recréation idempotente des 3 triggers/fonctions, de la séquence, des 7
  policies RLS, et des grants actuels reproduits tels quels.
- **Risques** : très faible — la migration doit être un **no-op** en production (les objets
  existent déjà) ; le risque réel est une divergence entre ce qui est écrit et ce qui existe
  réellement, d'où le PR-02 immédiatement après.
- **Tests** : application en transaction `ROLLBACK` sur la production réelle (doctrine
  standard du projet), vérification qu'aucun objet n'est recréé avec une définition différente
  de l'existant (comparaison DDL avant/après).
- **Critères d'acceptation** : migration appliquée sans erreur, `pg_get_functiondef`/
  `pg_get_constraintdef` identiques avant/après sur les deux tables.
- **Rollback** : `DROP` des objets nouvellement créés par la migration si elle a créé quoi que
  ce soit qui n'existait pas déjà (ne devrait rien créer de nouveau par construction).

### PR-02 — Tests de reconstruction et de RLS Support
- **Objectif** : garantir la non-régression future sur ces deux tables, versionner le test
  d'intrusion `anon` du §2.5.4.
- **Fichiers concernés** : nouveau `sql/tests/support_retro_versioning.sql`.
- **Dépendances** : PR-01.
- **Migrations** : aucune (fichier de test seul).
- **Risques** : aucun (lecture/écriture en transaction annulée).
- **Tests** : le fichier lui-même — 8 scénarios `anon` (§2.5.4) + scénarios `authenticated`
  hôtel légitime (accès à ses propres tickets, refus sur ceux d'un autre hôtel) + scénario
  admin (accès complet).
- **Critères d'acceptation** : tous les scénarios PASS, exécutés en `BEGIN...ROLLBACK` sur la
  production réelle.
- **Rollback** : sans objet (fichier de test, pas de modification durable).

### PR-03 — Durcissement ACL Support (si confirmé nécessaire)
- **Objectif** : appliquer le principe de moindre privilège sur `support_tickets`/
  `help_articles`, justifié par le test réel du §2.5.4 (pas par supposition).
- **Fichiers concernés** : nouveau `sql/81_support_acl_hardening.sql`.
- **Dépendances** : PR-01, PR-02 (le test de non-régression doit exister avant de durcir).
- **Migrations** : `REVOKE ALL ... FROM anon` sur les deux tables + la séquence
  `support_ticket_seq`. Aucune policy RLS modifiée.
- **Risques** : faible — aucun flux légitime ne passe aujourd'hui par `anon` sur ces tables
  (confirmé par §2.5.4), donc aucune régression fonctionnelle attendue.
- **Tests** : rejeu du fichier PR-02, en vérifiant que le résultat `anon` passe de « bloqué par
  RLS » à « bloqué par grant » (erreur différente, plus précoce), et que le comportement
  `authenticated`/admin est strictement inchangé.
- **Critères d'acceptation** : tests PASS, `has_table_privilege('anon', 'support_tickets',
  'INSERT')` = `false` après migration.
- **Rollback** : `GRANT` inverse si un usage légitime d'`anon` était découvert a posteriori
  (jugé très improbable au vu du test, mais la stratégie de rollback doit rester explicite).

### PR-04 — Fondation `platform_notifications`
- **Objectif** : livrer la file de notifications transverse spécifiée en §3.0.
- **Fichiers concernés** : nouveau `sql/82_platform_notifications.sql`,
  `supabase/functions/platform-send-notification/index.ts`.
- **Dépendances** : PR-00.
- **Migrations** : `CREATE TABLE platform_notifications` (schéma §3.0), `REVOKE ALL FROM
  PUBLIC, anon, authenticated`, grant `service_role` uniquement.
- **Risques** : faible — aucune brique existante n'en dépend encore à ce stade (les PR
  consommatrices viennent après).
- **Tests** : insertion directe + appel de l'Edge Function en environnement de test (clé
  Resend de test), vérification de l'idempotence via `dedupe_key` (deux insertions avec la
  même clé → une seule ligne, `ON CONFLICT DO NOTHING`), vérification du passage
  `pending → sending → sent/abandoned`.
- **Critères d'acceptation** : idempotence démontrée par test, `attempts`/`max_attempts`
  respectés (pas de tentative au-delà de la borne), aucun accès `anon`/`authenticated`
  possible sur la table.
- **Rollback** : `DROP TABLE platform_notifications` si aucune brique n'en dépend encore (à
  vérifier avant tout rollback si des PR consommatrices ont déjà été mergées).

### PR-05 — Licences en observation
- **Objectif** : `admin_list_license_usage()` + alerte `license_quota_exceeded`.
- **Fichiers concernés** : nouveau `sql/83_admin_license_usage.sql`.
- **Dépendances** : PR-00 (aucune dépendance technique sur les PR Support/notifications).
- **Migrations** : nouvelle RPC `admin_list_license_usage()`, extension de
  `admin_platform_alerts()` avec le nouveau type d'alerte.
- **Risques** : faible — lecture seule, aucun blocage (décision §5 confirmée).
- **Tests** : scénarios avec un hôtel sous quota, un hôtel au-dessus, un hôtel sans limite
  définie (`snapshot_limits` vide) — comportement attendu explicité pour chaque cas.
- **Critères d'acceptation** : RPC gardée `is_platform_admin()`, aucune écriture, aucun
  comportement bloquant démontrable par les tests.
- **Rollback** : `DROP FUNCTION admin_list_license_usage()`, retrait du nouveau type d'alerte
  dans `admin_platform_alerts()` (nouvelle version de la fonction sans ce cas).

### PR-06 — Notification « essai bientôt expiré »
- **Objectif** : notifier un hôtel avant l'expiration de son essai, sans cron (décision §5).
- **Fichiers concernés** : nouvelle RPC dans `sql/84_trial_ending_notification.sql`.
- **Dépendances** : PR-04 (`platform_notifications`).
- **Migrations** : RPC qui lit `trial_ending_soon` (déjà détecté par `admin_platform_alerts`)
  et insère dans `platform_notifications` avec `dedupe_key = 'trial:<subscription_id>:<jours>'`.
  Déclenchement manuel en V1 (bouton admin ou appel lors de la consultation du dashboard) —
  **pas de cron**.
- **Risques** : faible.
- **Tests** : un essai à J-7/J-3/J-1 ne génère qu'une seule notification par palier (test de
  l'idempotence via `dedupe_key`).
- **Critères d'acceptation** : aucune notification dupliquée sur relance manuelle répétée.
- **Rollback** : `DROP FUNCTION`, aucune donnée `hotel_subscriptions` affectée (lecture seule
  sur cette table).

### PR-07 — Statistiques fondamentales
- **Objectif** : `platform_metrics_daily` + `admin_recompute_platform_metrics` (manuel,
  rejouable historiquement) + `admin_platform_metrics_series`, selon les définitions
  formelles du §3.4.
- **Fichiers concernés** : nouveau `sql/85_platform_metrics.sql`.
- **Dépendances** : PR-00.
- **Migrations** : nouvelle table `platform_metrics_daily`, deux nouvelles RPC.
- **Risques** : moyen — le calcul du MRR/ARR/churn touche une logique métier nouvelle et
  potentiellement disputée (voir divergences possibles entre MRR contractuel/facturé/encaissé,
  §3.4) ; risque principal = un chiffre incorrect affiché au CTO, pas un risque de sécurité.
- **Tests** : jeux de données synthétiques avec résiliations, changements de plan et avoirs
  à des dates connues, vérifiant que chaque métrique du §3.4 produit le résultat attendu selon
  sa formule exacte.
- **Critères d'acceptation** : les 9 métriques du §3.4 correspondent à un calcul manuel de
  référence sur un jeu de données de test.
- **Rollback** : `DROP TABLE platform_metrics_daily`, `DROP FUNCTION` des deux RPC — aucune
  autre table n'est modifiée par ce lot (lecture seule sur les tables sources).

### PR-08 — Écran divergence de droits (frontend seul)
- **Objectif** : exposer `admin_rights_divergence_report()` (déjà existante) à l'écran.
- **Fichiers concernés** : `admin.html` uniquement.
- **Dépendances** : aucune (backend déjà livré en Phase 2A).
- **Migrations** : aucune.
- **Risques** : nul (lecture seule, backend inchangé).
- **Tests** : Jest sur le helper d'affichage, smoke test visuel.
- **Critères d'acceptation** : l'écran affiche exactement ce que retourne la RPC existante,
  aucune logique métier dupliquée côté frontend.
- **Rollback** : retrait de l'écran, aucun impact backend.

### PR-09 — Support triage Super Admin
- **Objectif** : RPC `admin_list_support_tickets`/`admin_get_support_ticket_detail`/
  `admin_update_support_ticket` + correction `STUB_INFO.support` + écran `admin.html`.
- **Fichiers concernés** : nouveau `sql/86_admin_support_triage.sql`, `admin.html`.
- **Dépendances** : PR-01, PR-02, PR-03 (le lot de fondation Support doit être fermé avant
  d'ajouter des RPC dessus).
- **Migrations** : 3 nouvelles RPC, ACL standard, écriture `_platform_log` sur chaque mutation.
- **Risques** : faible — aucune nouvelle table, ACL standard déjà maîtrisée par le projet.
- **Tests** : scénarios triage complet (liste, détail, changement de statut, assignation),
  vérification que chaque mutation produit une ligne `platform_logs`, rejet non-admin.
- **Critères d'acceptation** : tests PASS, `STUB_INFO.support` corrigé.
- **Rollback** : `DROP FUNCTION` des 3 RPC, aucune donnée `support_tickets` affectée par le
  rollback (les RPC ne changent pas le schéma).

### PR-10 — Création de ticket côté hôtel
- **Objectif** : point d'entrée `index.html`/`portal.html` pour qu'un utilisateur hôtel crée
  un ticket (décision §5 : distincte du triage, livrée après).
- **Fichiers concernés** : `index.html` ou `portal.html` (à confirmer selon l'écran cible),
  éventuellement une RPC `submit_support_ticket()` dédiée si l'accès table direct actuel
  (RLS `support_insert`) est jugé insuffisant une fois PR-03 appliquée.
- **Dépendances** : PR-01, PR-02, PR-03, PR-09 (le triage doit exister pour qu'un ticket créé
  soit traité).
- **Migrations** : éventuelle nouvelle RPC si nécessaire (à trancher pendant la PR).
- **Risques** : faible.
- **Tests** : un utilisateur hôtel peut créer un ticket pour son propre hôtel, pas pour un
  autre ; Jest sur le formulaire.
- **Critères d'acceptation** : ticket visible immédiatement côté triage Super Admin (PR-09).
- **Rollback** : retrait du point d'entrée frontend ; si une RPC dédiée a été créée,
  `DROP FUNCTION`.

### PR-11 — Supervision native (RPC CMS `help_articles` + Sentry optionnel)
- **Objectif** : RPC CMS `help_articles` (inchangé §3.5.5) ; en parallèle, Sentry frontend +
  Edge Functions comme lot **indépendant et non bloquant** (décision §5).
- **Fichiers concernés** : nouveau `sql/87_admin_help_articles_cms.sql`, `admin.html`,
  optionnellement `supabase/functions/_shared/sentry.ts` si le compte Sentry est fourni avant
  cette PR.
- **Dépendances** : PR-01, PR-02, PR-03 pour la partie CMS ; aucune dépendance pour la partie
  Sentry (peut être découplée dans le temps, décision §5).
- **Migrations** : 4 nouvelles RPC CMS, ACL standard.
- **Risques** : faible pour le CMS ; la partie Sentry dépend d'une décision CTO externe (§5,
  point 5) non tranchée dans ce round.
- **Tests** : scénarios CMS (créer/publier/archiver un article, rejet non-`support_agent`).
- **Critères d'acceptation** : tests PASS ; `admin_supervision_status()` n'est mise à jour
  (signaux passés à `true`) que si Sentry est réellement câblé, jamais avant.
- **Rollback** : `DROP FUNCTION` des 4 RPC CMS ; retrait du SDK Sentry si intégré, sans impact
  sur `admin_supervision_status()` qui revient à ses valeurs honnêtes par défaut.

### PR-12 — Paiements (après décisions métier)
- **Objectif** : les 3 livrables du §3.1 (round 1) — PDF réel, dunning réel, passerelle de
  paiement — **une fois** les questions métier du §3.1 tranchées et le prestataire choisi.
- **Fichiers concernés** : `sql/88+`, buckets Storage, Edge Functions dédiées.
- **Dépendances** : PR-04 (`platform_notifications`, pour le dunning), décisions CTO §5 point 1
  (prestataire) et les questions métier §3.1.
- **Migrations** : détaillées au round 1 (§3.1) — `platform_dunning_log`,
  `platform_payment_intents`, `platform_payment_provider_events`.
- **Risques** : le plus élevé du plan (flux financier réel, webhook public, prestataire
  externe) — à scinder en sous-PR au moment de l'exécution (PDF seul, puis dunning seul, puis
  passerelle de paiement en dernier, la plus encadrée).
- **Tests** : idempotence webhook stricte (`event_id` unique), vérification de signature
  obligatoire, tests en transaction sur données réelles comme pour toutes les migrations
  financières passées du projet.
- **Critères d'acceptation** : à définir précisément une fois le prestataire choisi — pas
  figés dans cet ADR.
- **Rollback** : stratégie à détailler par sous-PR au moment de l'exécution, vu le niveau de
  risque — pas de rollback générique acceptable pour un flux financier réel.

---

## 7. Points encore réellement bloquants

1. **Choix du prestataire de paiement** — bloque PR-12 dans son intégralité. Différé
   explicitement par le CTO (§5), pas une omission.
2. **Compte de monitoring d'erreurs (Sentry ou équivalent)** — bloque uniquement la partie
   Sentry de PR-11, ne bloque plus le reste de la Supervision avancée (décision §5).
3. **`platform_incidents` (#35)** — inclusion ou non dans ce batch, non tranchée
   explicitement dans les instructions reçues (§5, point 7) — à confirmer.
4. **Questions métier Paiements du §3.1** (périodicité, engagement, prorata, remboursements,
   export comptable) — non tranchées, préalables à toute écriture de code sur PR-12, même une
   fois le prestataire choisi.
5. **Politique de rétention de `platform_notifications`** — proposition à 90 jours en §3.0,
   non validée, sans impact bloquant sur le développement (peut démarrer sans purge, la purge
   est un ajout ultérieur non structurant).

Aucun autre point du round 1 ne reste ouvert sans réponse : les décisions 2, 3, 5, 6 du §5 sont
tranchées, la décision 4 (dérivée de la 3) est cohérente, `platform_notifications` et
`hotel_app_subscriptions` ont reçu une confirmation explicite.

---

## Prochaine étape

Ce document reste soumis pour validation. Conformément à l'instruction reçue, aucun
développement n'est démarré et aucune PR technique n'est ouverte avant autorisation explicite
— y compris pour PR-01 (rétro-versionnement), qui ne modifie pourtant le comportement d'aucun
système existant.
