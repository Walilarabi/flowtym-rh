# ADR-012 — Phase 2 du Super Admin : plateforme SaaS de gestion commerciale et opérationnelle

**Statut** : **Round 6 — les 6 lots + l'écran de divergence des droits sont implémentés,
testés et poussés sur 10 PR ouvertes et empilées (#21 à #30). Aucune PR mergée, aucune
migration appliquée en production, aucun cron activé, aucune donnée réelle modifiée.**
Rounds 1 à 5 (ci-dessous, inchangés) documentent l'architecture validée avant tout code. Le
**§9 (nouveau)** documente ce qui a réellement été construit, les écarts découverts et
corrigés pendant l'implémentation, et les déviations assumées par rapport à ce round 4/5 —
notamment sur la pondération et la doctrine de donnée manquante du score de santé (§9.6),
suite à des instructions CTO ultérieures plus strictes sur l'anti-fabrication de données.
Round 5 (rappel, addendum documentaire) : correction du traitement antivirus des pièces
jointes Support (§3.5.8, §1, §7) — sans fournisseur antivirus réel, une pièce jointe ne peut
jamais passer automatiquement à `clean` ; statut honnête `scan_pending`. **Cette correction a
bien été implémentée telle quelle** (§9.4).

**Portée** : six lots, dans l'ordre de développement imposé par le CTO — Lot 1 (fondations
Support, désormais 2 PR strictement séparées), Lot 2 (`platform_notifications`), Lot 3
(Licences), Lot 4 (Essais), Lot 5 (Support — back-office puis portail hôtel), Lot 6
(Statistiques, y compris le score de santé **client**, distinct de la santé **technique**).
Paiements reporté, note d'architecture métier maintenue comme livrable obligatoire de la
Phase 2.

**Ce qui change dans ce round (round 3 → round 4)** — cinq révisions demandées, toutes
documentaires :

1. **Lot 1 scindé en exactement 2 PR** (round 3 en comptait 3) — PR-01 rétro-versionnement
   à l'identique (fusionne l'ancien PR-01 « migration » et l'ancien PR-02 « tests de
   reconstruction » en une seule PR, car reconstruction et comparaison dépôt/production font
   partie intégrante de ce que « remettre sous contrôle du dépôt » signifie) et PR-02
   durcissement ACL/RLS, strictement postérieure et indépendante — §3.5.1/§3.5.2, §6.
2. **« Score de santé plateforme » retiré** — remplacé par deux concepts explicitement
   séparés, jamais combinés en un seul indicateur : **(A) Score de santé client/hôtel**
   (adoption, activité, licences, support, paiement, rétention — commercial/usage, par hôtel,
   Lot 6, §3.4) et **(B) Santé technique de la plateforme** (erreurs RPC, Edge Functions,
   notifications échouées, cron, latence, disponibilité, migrations, incidents — opérationnel,
   plateforme entière, hors périmètre de ce lancement, documenté en annexe §8 pour ne jamais
   être développé comme un score composite mélangeant les deux audiences).
3. **`support_ticket_attachments` et le bucket Storage reçoivent un contrat de sécurité
   complet et précis** — plus une référence à « suit le modèle `portal-documents` » : flux
   d'upload en deux temps (demande signée → confirmation vérifiée serveur), noms de fichiers
   générés côté serveur, URLs signées à durée limitée pour la lecture comme pour l'écriture,
   aucune policy Storage directe pour un rôle client, statuts de quarantaine réservés (pas de
   fournisseur antivirus choisi, documenté comme point ouvert), soft-delete uniquement,
   comportement après fermeture du ticket, journal d'accès dédié — §3.5.8.
4. **`support_ticket_replies` précisé** — distinction explicite réponse publique / note
   interne (déjà présente, reformulée), auteur `system` ajouté (réservé, non utilisé en V1),
   correction d'une réponse erronée par une nouvelle réponse liée (jamais un `UPDATE`),
   masquage administratif audité (projection, jamais une suppression), absence de suppression
   physique ordinaire confirmée explicitement, ordre déterministe garanti par un compteur de
   séquence (et non l'horodatage), traitement des données personnelles documenté — §3.5.7.
5. **Paiements** : développement toujours reporté, menu `admin.html` reste « À venir » — la
   note d'architecture métier (§3.1) est explicitement reconfirmée comme **livrable
   obligatoire de la Phase 2**, distincte du développement lui-même, déjà produite et à jour.

**Renumérotation résultant du point 1** : le Lot 1 passant de 3 à 2 PR, toutes les fiches PR
suivantes (Lot 2 à Paiements) décalent d'un cran par rapport au round 3 — voir table de
correspondance round 3 → round 4 en tête de §6. Les numéros de migration `sql/NN` restent
inchangés (aucune migration n'a jamais été appliquée) : seul le libellé `PR-NN` se décale.

---

## 0. Méthode

Round 1 : audit factuel par 5 recherches parallèles + lecture directe des ADR/RC1/roadmap.
Round 2 : introspection ciblée `support_tickets`/`help_articles` + test d'intrusion réel en base
(§2.5.4). Round 3 : lancement officiel, structuration en 6 lots, introspection ciblée des tables
de réponses/pièces jointes et des buckets Storage existants (aucune reprise nécessaire ici).
Round 4 (cette révision) : aucune nouvelle introspection de production n'était nécessaire — les
5 points demandés sont des clarifications et extensions architecturales sur des objets déjà
inventoriés (Lot 1 : §2.5 inchangé), des choix de conception explicitement demandés comme non
composites (santé client vs technique), et un contrat de sécurité détaillé pour des objets
encore non créés (`support_ticket_attachments`) — conçu par référence à des patterns déjà en
production identifiés au round 3 (`ota_dispute_messages`/`ota_dispute_attachments`,
`communication_attachments`, `attachment_access_log`), avec un choix délibérément plus strict
que ces patterns existants là où le CTO a demandé un niveau de détail supérieur (§3.5.8).

---

## 1. Doctrine héritée de la Phase 1 (inchangée, à respecter à l'identique)

- **ACL des RPC `admin_*`** : `SECURITY DEFINER`, `SET search_path TO 'public','pg_temp'`,
  garde interne (`IF NOT public.is_platform_admin() THEN RAISE EXCEPTION ... '42501'`), puis
  `REVOKE ALL ... FROM PUBLIC, anon, service_role` + `GRANT EXECUTE ... TO authenticated`.
  Helpers internes (`_`-préfixés) : aucun grant client.
- **Audit** : `platform_logs` via `_platform_log()` (admin) ou `_platform_log_system()`
  (système/trigger/cron) ; table événementielle métier dédiée quand un cycle de vie le
  justifie.
- **Tables sensibles / soft-delete** : jamais de `DELETE` physique sur une entité journalisée.
  Étendu aux tables conversationnelles et documentaires du Support (§3.5.7/§3.5.8) : une
  réponse de ticket est **append-only strict** (aucune suppression, même soft — une correction
  ou un masquage sont des opérations distinctes, jamais une suppression) ; une pièce jointe
  admet un **soft-delete** (`deleted_at`) mais jamais de `DELETE` physique via une action
  utilisateur ordinaire.
- **Tests** : `sql/tests/<domaine>.sql`, `BEGIN` / fixtures `pg_temp.zz_*` / blocs
  `DO $$...EXCEPTION WHEN OTHERS...END $$` / `RAISE EXCEPTION` si FAIL / `ROLLBACK`.
- **Nommage migrations** : `sql/NN_<domaine>_<description>.sql`. Dernier existant : `sql/79`.
  **La Phase 2 commence à `sql/80`.**
- **Numérotation ADR** : dernier existant `ADR-011`. Ce document est **ADR-012**.
- **Doctrine cron** (ADR-010 §3) : jamais activé dans la même migration que la fonctionnalité.
  Migration séparée + validation CTO explicite et distincte. Le cron reste désactivé pour le
  Lot 4.
- **Leçon du P0 (PR #18)** : toute action de traitement par lot doit exposer une RPC de
  prévisualisation dont le prédicat est strictement identique à celui de l'exécution — appliqué
  au Lot 4 (§3.3).
- **Principe du moindre privilège** : un écart entre grants et RLS ne se corrige qu'après avoir
  démontré, par un test réel, ce que l'écart permet effectivement — jamais par supposition.
  Voir §2.5.4. **Reformulé par ce round (point 1) : ce principe justifie une PR de durcissement
  distincte du rétro-versionnement, jamais fusionnée avec lui** (§3.5.1/§3.5.2).
- **Doctrine snapshot** : déjà appliquée aux factures (`bill_to_*`), reprise pour
  `platform_notifications.recipient_email`/`template_payload` et pour
  `support_ticket_replies.author_label` — un auteur ou destinataire historique ne doit jamais
  dépendre d'une résolution différée par jointure.
- **Doctrine des signaux honnêtes** (déjà appliquée à `admin_supervision_status()`) : un signal
  ou une capacité non réellement câblée reste explicitement `false`/absente plutôt que
  simulée. **Corrigée par le round 5** (§3.5.8) : sans fournisseur antivirus réellement câblé,
  une pièce jointe **ne passe jamais automatiquement** à `clean` — `clean` signifie
  exclusivement « scannée réellement et jugée saine », jamais « uploadée avec succès ». Tant
  qu'aucun scanner n'est câblé, une pièce jointe reste indéfiniment `scan_pending`, statut
  honnête à part entière, pas une étape transitoire vers un `clean` simulé.
- **Séparation des audiences décisionnelles** (nouvelle formulation explicite, round 4) : un
  indicateur destiné à une décision commerciale (état de santé d'un client) et un indicateur
  destiné à une décision opérationnelle (disponibilité technique de la plateforme) ne sont
  **jamais fusionnés dans un score composite unique** — deux RPC distinctes, deux écrans
  distincts, même si les deux peuvent un jour cohabiter dans le même dashboard (§3.4, §8).

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
notification avant expiration — objet du Lot 4 (§3.3).

### 2.4 Statistiques — inchangé depuis le round 1

`admin_platform_overview_kpis`/`admin_platform_alerts`/`admin_rights_divergence_report`
(`sql/76`). Aucun agrégat ni série temporelle — tout est recalculé à la volée. Pas de
MRR/ARR/churn réel, pas de delta période, pas de score de santé d'aucune sorte — objet du
Lot 6 (§3.4) pour la partie client, hors périmètre pour la partie technique (§8).

### 2.5 Support — inventaire technique complet (rétro-versionnement, Lot 1)

**Rappel du constat central** : `support_tickets` et `help_articles` existent réellement en
production (introspection directe de `hzrzkvdebaadditvbqis`) mais **ne sont versionnées dans
aucun fichier `sql/`**. C'est le **Lot 1, priorité absolue** de la Phase 2, avant tout
développement nouveau — désormais explicitement **2 PR séparées** (§3.5.1/§3.5.2, §6).

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

**Note** : la colonne `attachment_url text` (singulier) et le champ libre `claude_response
text` restent **inchangés par le rétro-versionnement à l'identique** (Lot 1 PR-01). Le Lot 5
les complète par des tables dédiées (pièces jointes multiples, réponses structurées) sans les
supprimer ni les réinterpréter.

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
`postgres`. Non transactionnelle (standard Postgres) — un saut de numérotation sans conséquence
a été observé pendant le test §2.5.4 (`ROLLBACK`).

**Grants table-level actuels** (à reproduire à l'identique dans la migration de
rétro-versionnement, §3.5.1) : `anon`, `authenticated`, `service_role`, `postgres` ont tous
`INSERT/SELECT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER`.

#### 2.5.2 `help_articles` — inventaire exact

**Colonnes** : `id uuid PK`, `module text NOT NULL`, `title text NOT NULL`, `slug text`,
`excerpt text`, `body text NOT NULL`, `tags text[] NOT NULL`, `sort_order integer NOT NULL`,
`is_published boolean NOT NULL`, `view_count integer NOT NULL`, `created_by uuid`,
`updated_by uuid`, `created_at timestamptz NOT NULL`, `updated_at timestamptz NOT NULL`.

**Contraintes** : `help_articles_pkey` — `PRIMARY KEY (id)` **uniquement**. Aucun `CHECK`,
aucune `FOREIGN KEY`, aucune contrainte `UNIQUE` sur `slug` — fait constaté, pas encore une
recommandation de correction.

**Index** : `help_articles_pkey` (id), `idx_help_articles_module` (module, sort_order),
`idx_help_articles_published` (is_published, module).

**Trigger** : `trg_help_articles_updated` (BEFORE UPDATE) → `trg_help_articles_updated_at()` :
`NEW.updated_at = now()`.

**Grants table-level actuels** : `anon`, `authenticated`, `service_role`, `postgres` ont tous
`INSERT/SELECT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER`.

#### 2.5.3 Fonctions et helpers associés

- `support_set_ticket_number()`, `support_set_updated_at()`, `trg_help_articles_updated_at()`
  — trois fonctions trigger, **aucune n'est `SECURITY DEFINER`**.
- `platform_admin_role()`, `is_platform_admin()` — déjà existantes, réutilisées.
- **Aucune RPC `admin_*` ne référence ni `support_tickets` ni `help_articles`** — confirmé par
  recherche exhaustive. Le Lot 5 introduit les premières RPC de ce domaine.

#### 2.5.4 Matrice ACL/RLS — test réel exécuté

**Policies RLS existantes** (`relrowsecurity = true` sur les deux tables) :

| Table | Policy | Commande | Rôles | Condition |
|---|---|---|---|---|
| `help_articles` | `help_articles_select` | SELECT | public | `is_published = true OR is_platform_admin()` |
| `help_articles` | `help_articles_write` | ALL | public | `platform_admin_role() = ANY('{super_admin,support_agent}')` |
| `support_tickets` | `platform_admin_read_tickets` | SELECT | public | `is_platform_admin()` |
| `support_tickets` | `platform_admin_update_tickets` | UPDATE | public | `is_platform_admin()` |
| `support_tickets` | `support_select` | SELECT | public | `hotel_id IN (SELECT hotel_id FROM user_hotels WHERE user_id = auth.uid())` |
| `support_tickets` | `support_update` | UPDATE | public | idem |
| `support_tickets` | `support_insert` | INSERT | public | idem (`WITH CHECK`) |

**Test réel** (rôle Postgres `anon`, en transaction, annulée) :

| # | Action testée | Résultat observé | Interprétation |
|---|---|---|---|
| 1 | `SELECT` sur `help_articles` (anon) | 8 lignes visibles | Conforme à `is_published = true` |
| 2 | `SELECT` sur `help_articles` où `is_published = false` (anon) | 0 ligne visible | Brouillons invisibles |
| 3 | `INSERT` sur `help_articles` (anon) | **Bloqué** — `42501` | RLS neutralise le grant large |
| 4 | `UPDATE` sur un article publié (anon) | 0 ligne affectée | RLS neutralise le grant |
| 5 | `DELETE` sur un article publié (anon) | 0 ligne affectée | Idem |
| 6 | `SELECT` sur `support_tickets` (anon), ligne marqueur présente | 0 ligne visible | Aucune fuite |
| 7 | `INSERT` sur `support_tickets` avec `hotel_id` réel (anon) | **Bloqué** — `42501` | `WITH CHECK` bloque |
| 8 | `UPDATE` sur la ligne marqueur (anon) | 0 ligne affectée | Idem #4 |

**Conclusion** : *privilèges inutilement larges mais bloqués par RLS* sur les deux tables (sauf
lecture publique de `help_articles` publiés, conforme). **Aucune exposition effectivement
exploitable détectée.** Le durcissement (Lot 1 PR-02, §3.5.2) reste recommandé au nom du
moindre privilège, en défense en profondeur — **jamais mélangé au rétro-versionnement**
(point 1 de ce round).

**Effet de bord du test** : la séquence `support_ticket_seq` a probablement avancé d'une unité
— sans conséquence, zéro résidu vérifié en production après coup.

#### 2.5.5 Comparaison dépôt / production

| Objet | Dans `sql/` | En production | Action |
|---|---|---|---|
| Table `support_tickets` | Absente | Présente (0 ligne) | À verser à l'identique (Lot 1 PR-01) |
| Table `help_articles` | Absente | Présente (8 lignes publiées) | À verser à l'identique (Lot 1 PR-01) |
| Séquence `support_ticket_seq` | Absente | Présente | À verser à l'identique (Lot 1 PR-01) |
| 3 fonctions trigger (§2.5.3) | Absentes | Présentes | À verser à l'identique (Lot 1 PR-01) |
| 7 policies RLS (§2.5.4) | Absentes | Présentes | À verser à l'identique (Lot 1 PR-01) |
| Grants `anon` larges (§2.5.1/§2.5.2) | — | Présents | Reproduits à l'identique en PR-01 ; réduits séparément en PR-02 si confirmé nécessaire |
| Rôle `support_agent` (`platform_admins.role` CHECK) | Présent (`sql/73`) | Présent | Déjà cohérent |
| `STUB_INFO.support` (`admin.html:755`) | — | — | Corrigé au Lot 5, pas au Lot 1 |
| Table `support_ticket_replies` | Absente | **Absente aussi** | Nouvelle création, Lot 5 PR-06 (§3.5.7) — pas un rétro-versionnement |
| Table `support_ticket_attachments` | Absente | **Absente aussi** | Nouvelle création, Lot 5 PR-07 (§3.5.8) |
| Table `support_ticket_attachment_access_log` | Absente | **Absente aussi** | Nouvelle création, Lot 5 PR-07 (§3.5.8) |
| Bucket Storage `support-ticket-attachments` | Absent | **Absent aussi** | Nouvelle création, Lot 5 PR-07 (§3.5.8) |

**Non liés, confirmés hors-sujet** : `portal_requests`/`portal_messages` (RH interne),
`aide.html` (statique, RH), `maintenance_tickets` (PMS/Housekeeping),
`ota_dispute_messages`/`ota_dispute_attachments`/`communication_attachments`/
`attachment_access_log` (autres domaines, réutilisés uniquement comme **référence de
conception** — §3.5.7/§3.5.8).

### 2.6 Supervision avancée — hors périmètre de ce lancement (voir §8)

`admin_supervision_status()` honnête, `admin_list_platform_audit_log()`. Pas de monitoring
d'erreurs réel, pas d'historique d'incidents, `webhooks_configured` toujours `false`. **Ce
domaine — qui inclut désormais explicitement la « santé technique de la plateforme » (point 2
de ce round) — ne fait pas partie des 6 lots communiqués pour ce lancement.**

### 2.7 Infrastructure transverse déjà disponible

Resend (`RESEND_API_KEY`, pattern `supabase/functions/sig-send`) — à réutiliser pour tout envoi
d'email Phase 2. Buckets Storage privés déjà en production comme référence de pattern pour le
Lot 5 : `hr-documents` (10 Mo, PDF/JPEG/PNG/HEIC/WEBP), `portal-documents` (20 Mo,
PDF/images/Word) — **référence de configuration uniquement** (taille, types MIME) ; le round 4
retient un modèle d'accès plus strict que ces deux buckets pour `support-ticket-attachments`
(§3.5.8, point 3 de ce round).

---

## 3. Architecture proposée, par lot

### 3.0 Fondation transverse — `platform_notifications` (Lot 2)

**Nature** : une file métier de notifications, pas une file de tâches générique.

**Schéma proposé** :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `category` | `text NOT NULL CHECK IN ('dunning','trial_ending','support_ticket_update','support_ticket_new')` | Catégorie métier fermée |
| `reference_type` | `text NOT NULL` | Type de l'objet source |
| `reference_id` | `uuid NOT NULL` | Id de l'objet source |
| `dedupe_key` | `text NOT NULL UNIQUE` | Clé d'idempotence métier |
| `channel` | `text NOT NULL DEFAULT 'email' CHECK IN ('email')` | Un seul canal en V1 |
| `recipient_email` | `text NOT NULL` | Snapshot au moment de la création |
| `template` | `text NOT NULL` | Identifiant du gabarit — contenu versionné dans l'Edge Function |
| `template_payload` | `jsonb NOT NULL DEFAULT '{}'` | Variables snapshot |
| `status` | `text NOT NULL DEFAULT 'pending' CHECK IN ('pending','sending','sent','failed','abandoned')` | |
| `attempts` | `integer NOT NULL DEFAULT 0` | |
| `max_attempts` | `integer NOT NULL DEFAULT 3` | |
| `next_attempt_at` | `timestamptz` | |
| `last_error` | `text` | |
| `final_error` | `text` | Rempli seulement à `abandoned` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `processed_at` | `timestamptz` | |
| `sent_at` | `timestamptz` | |
| `failed_at` | `timestamptz` | |

**Statuts** : `pending → sending → (sent | pending+next_attempt_at | abandoned)`.
**Concurrence** : `UPDATE ... SET status='sending' WHERE id=? AND status='pending' RETURNING id`.
**Idempotence** : `UNIQUE(dedupe_key)`, `ON CONFLICT DO NOTHING`.
**RLS/grants** : aucun accès client — `service_role` uniquement.
**Rétention** : proposition 90 jours, purge non automatisée en V1.
**Edge Function `platform-send-notification`** : seul point d'appel Resend, `service_role`
uniquement. La table elle-même est le journal d'envoi.

### 3.1 Paiements — note d'architecture métier, livrable obligatoire de la Phase 2 (développement reporté)

**Confirmé par ce round : le développement reste reporté, le menu `admin.html` reste « À venir »
tant que les décisions ci-dessous ne sont pas validées.** Le tableau suivant **est** la note
d'architecture métier demandée par le CTO — **maintenue explicitement comme livrable
obligatoire de la Phase 2**, distincte du code : ce document doit exister et rester à jour même
si aucune ligne de Paiements n'est jamais écrite dans ce cycle.

| Question | Contexte déjà existant | Statut |
|---|---|---|
| Client facturé : hôtel ou groupe ? | `hotel_subscriptions` a `UNIQUE(hotel_id)` — un abonnement par hôtel, pas par groupe | **Non tranché** — par défaut, facturation par établissement |
| Facturation consolidée ou par établissement ? | Découle de la ligne précédente | Par établissement, par défaut |
| Périodicité | `platform_invoices.period_start/period_end` génériques | **Non tranché** |
| Engagement (durée minimale) | Aucune notion aujourd'hui | **Non tranché** |
| Prorata (changement de plan) | `admin_change_subscription_plan` immédiat, sans prorata | **Non tranché** |
| TVA | `platform_invoices.tva_rate/tva_amount` déjà gérés | Déjà couvert |
| Impayé | `admin_suspend_subscription_for_nonpayment` déjà existant | Déjà couvert |
| Suspension | `admin_suspend_subscription`/`admin_reactivate_subscription` | Déjà couvert |
| Résiliation | `admin_cancel_subscription_immediate`/`admin_schedule_subscription_cancellation` | Déjà couvert |
| Avoirs | `platform_credit_notes` déjà existant | Déjà couvert |
| Remboursements | Aucun mécanisme aujourd'hui | **Non tranché** — dépend du prestataire |
| Export comptable | Rien n'existe aujourd'hui | **Non tranché** |
| Source de vérité | `platform_invoices`/`platform_payments` (facturation) vs `hotel_subscriptions` (accès), volontairement distinctes | Déjà couvert |

**Position de cet ADR** : pas d'abstraction multi-prestataires en V1 ; détail technique en §6
(PR-09), non développé tant que le prestataire n'est pas choisi et que le tableau ci-dessus
n'est pas tranché.

### 3.2 Licences — Lot 3 : observation, comptage et alertes uniquement

**Aucun blocage automatique en V1.** `admin_list_license_usage()` (comptage réel vs
`snapshot_limits`) + alerte `license_quota_exceeded` dans `admin_platform_alerts()`. Aucune
nouvelle table. Ne touche jamais `hotel_app_subscriptions`.

### 3.3 Essais — Lot 4 : notifications J-7/J-3/J-1, preview, run manuel, cron désactivé

Trois paliers explicites, RPC de prévisualisation, RPC d'exécution manuelle — **cron
désactivé**.

**Paliers** : J-7, J-3, J-1 avant `hotel_subscriptions.trial_ends_at` (`status='trial'`).
`dedupe_key` distinct par palier — `trial:<subscription_id>:{7,3,1}`.

**Prédicat partagé** (doctrine P0) : preview et exécution interrogent exactement la même
requête ; seule diffère l'action finale (`SELECT` vs `INSERT ... ON CONFLICT DO NOTHING`).

- **`admin_preview_trial_ending_notifications()`** — lecture seule, transparence sur les
  notifications déjà envoyées vs à envoyer.
- **`admin_run_trial_ending_notifications()`** — même prédicat, insertion réelle,
  `category='trial_ending'`, `template='trial_ending_soon'`.

**Déclenchement** : bouton admin manuel, pas de cron.

### 3.4 Statistiques — Lot 6 : définitions formelles, y compris le score de santé **client/hôtel**

**Séparation explicite actée par ce round (point 2)** : ce paragraphe traite uniquement des
métriques **commerciales et d'usage**. La **santé technique de la plateforme** (erreurs RPC,
Edge Functions, notifications échouées, cron, latence, disponibilité, migrations, incidents)
est un concept **distinct**, une audience différente (ops, pas commercial), un cycle de décision
différent — traitée séparément en §8, hors périmètre de ce lancement, **jamais fusionnée ici**.

Toutes les métriques ci-dessous partagent : fuseau horaire proposé Europe/Paris (à confirmer
CTO), fréquence de calcul V1 à la demande (`admin_recompute_platform_metrics`, pas de cron),
recalcul historique rejouable depuis `hotel_subscription_events`.

| Métrique | Source | Formule | Traitement annulations/avoirs/changements de plan |
|---|---|---|---|
| **MRR contractuel** | `hotel_subscriptions` (`status='active'`) + `snapshot_price` + addons actifs | Somme des prix récurrents figés | Résiliation/suspension sort immédiatement le montant ; changement de plan sans proratisation ; avoirs sans effet |
| **MRR facturé** | `platform_invoices` (`status='issued'`) | Montant HT émis, ramené au mois si périodicité ≠ mensuelle | Peut diverger du contractuel |
| **MRR encaissé** | `platform_payments` (`status='recorded'`) | Somme encaissée dans le mois (caisse) | Avoir réduit le mois d'émission (proposition, à confirmer) |
| **ARR** | Dérivé du MRR contractuel | `MRR contractuel × 12` | — |
| **Churn logo** | `hotel_subscription_events` | Hôtels résiliés ÷ hôtels actifs en début de période | Résiliation définitive seulement |
| **Churn revenu** | `hotel_subscription_events` + `snapshot_price` | MRR perdu (résiliations + rétrogradations) ÷ MRR début de période | Distinct du churn logo |
| **Conversion des essais** | `hotel_subscription_events` | Convertis ÷ (convertis + expirés) | — |
| **Hôtels actifs** | Réutilise `admin_platform_overview_kpis` | — | Pas de seconde définition |
| **Utilisateurs actifs** | Idem | — | Idem |

**A. Score de santé client / hôtel (nouveau nom, round 4 — remplace « score de santé
plateforme » du round 3, retiré)** — indicateur **par hôtel**, strictement commercial/usage,
proposition V1 à valider explicitement par le CTO :

| Sous-score | Poids | Calcul | Source |
|---|---|---|---|
| Adoption | 20 % | Modules souscrits (`plan_modules`/`hotel_addon_subscriptions`) avec au moins un utilisateur actif ayant un rôle dans ce module ÷ modules souscrits total | `plan_modules`, `hotel_addon_subscriptions`, `user_hotels` — **limitation documentée** : proxy faute de journal d'usage applicatif réel par module (absent du schéma actuel), voir §7 |
| Activité | 20 % | Utilisateurs actifs de l'hôtel (`is_active=true`) ÷ utilisateurs totaux de l'hôtel | `users` — déjà calculé par `buildHotelRows._userCount` (`admin.html`) |
| Licences | 15 % | 100 si aucune alerte `license_quota_exceeded` active pour cet hôtel, 0 sinon | Lot 3 |
| Support | 15 % | `100 − (tickets ouverts >5j ouvrés pour CET hôtel ÷ tickets ouverts total pour cet hôtel × 100)` | `support_tickets` (Lot 5) |
| Paiement | 15 % | 100 si aucune facture `platform_invoices` en retard pour cet hôtel, 0 sinon (V1 binaire — dégressif = amélioration ultérieure) | `platform_invoices` |
| Rétention | 15 % | 100 si `status='active'` sans suspension dans les 90 derniers jours ; 50 si `trial` ; 0 si `suspended` | `hotel_subscriptions`, `hotel_subscription_events` |

`score_hotel = 0.20×Adoption + 0.20×Activité + 0.15×Licences + 0.15×Support + 0.15×Paiement +
0.15×Rétention`, arrondi à l'entier. **RPC** : `admin_hotel_health_score(hotel_id)` (un hôtel)
et `admin_list_hotel_health_scores()` (tous, écran tableau) — **calcul à la demande, aucune
nouvelle table persistée** (cohérent avec `admin_platform_overview_kpis`, déjà recalculé à la
volée). **Dépendance explicite** : le sous-score Support dépend du Lot 5, le sous-score
Licences du Lot 3 — tant que non livrés, traités comme `100` par défaut (signal honnête :
absence de donnée ≠ mauvais signal), cohérent avec la doctrine `admin_supervision_status()`.

**B. Santé technique de la plateforme — concept distinct, non développé dans ce round.** Voir
§8. **Jamais combinée avec le score de santé client ci-dessus.**

Score de santé hôtel legacy (round 1, non repris — remplacé par la définition ci-dessus),
rapport de divergence de droits (frontend seul, inchangé), anomalies et facturation consolidée
par groupe (hors périmètre v1, inchangé).

### 3.5 Support — Lot 1 (fondation, 2 PR) et Lot 5 (fonctionnalités, 2 PR)

**3.5.1 — Lot 1, PR-01 : rétro-versionnement à l'identique, reconstruction et comparaison
(une seule PR, aucun changement de comportement).** Regroupe explicitement, dans une seule PR
livrée d'un bloc :
- la migration `sql/80_...` : reproduction exacte de l'existant (§2.5.1/§2.5.2/§2.5.3) — tables
  (`CREATE TABLE IF NOT EXISTS`, colonnes/types identiques), toutes les contraintes, tous les
  index, tous les triggers et leurs fonctions, la séquence, les 7 policies RLS mot pour mot, et
  **les grants actuels reproduits tels quels** (y compris les grants `anon` larges — leur
  réduction, si elle a lieu, appartient exclusivement à la PR-02, jamais à celle-ci) ;
- le fichier `sql/tests/support_retro_versioning.sql` : reconstruction du schéma depuis zéro en
  transaction, comparaison DDL avant/après (`pg_get_functiondef`/`pg_get_constraintdef`
  identiques), rejeu versionné des 8 scénarios `anon` du §2.5.4, scénarios `authenticated`
  hôtel légitime (accès à ses tickets, refus sur ceux d'un autre hôtel) ;
- la comparaison dépôt/production du §2.5.5, vérifiée après application.

Objectif unique de cette PR : que `sql/` décrive exactement ce qui tourne en production, ni
plus ni moins — **aucune permission, aucune policy, aucun grant n'est modifié**.

**3.5.2 — Lot 1, PR-02 : durcissement ACL/RLS — strictement postérieure et indépendante.**
Cette PR ne peut être ouverte qu'après la PR-01 (schéma versionné) et **après l'audit factuel**
déjà réalisé en §2.5.4 (jamais avant, jamais sur simple supposition) :
- **Tests par rôle, rejoués avant modification** : `anon` (8 scénarios §2.5.4),
  `authenticated` hôtel légitime (accès à ses propres tickets), `authenticated` hôtel non
  légitime (refus sur les tickets d'un autre hôtel), `authenticated` admin (accès complet) —
  les 4 profils doivent être testés, pas seulement `anon`.
- **Réduction des seuls privilèges réellement inutiles**, confirmés par le test §2.5.4 :
  `REVOKE ALL ... FROM anon` sur `support_tickets`, `help_articles` et la séquence
  `support_ticket_seq` (garde `authenticated`, qui en a un besoin légitime). **Aucune policy
  RLS n'est modifiée** — le test a démontré qu'elles sont déjà correctes (§2.5.4), seul le
  grant table-level en excès est réduit.
- **Correction de policy, si nécessaire** : réservée au cas où le rejeu des tests par rôle de
  cette PR révélerait une régression ou un écart non détecté au round 2 — non anticipée
  aujourd'hui (le test §2.5.4 n'en a trouvé aucune), mais la PR reste ouverte à cette
  possibilité plutôt que de l'exclure par construction.
- **Rollback explicite** : `GRANT` inverse (réattribution des privilèges `anon` retirés) si un
  usage légitime d'`anon` était découvert a posteriori — jugé très improbable au vu du test,
  mais la procédure de rollback doit rester écrite et testée avant merge, pas improvisée après
  coup.

**3.5.3 — RPC de triage, assignation, priorité** (Lot 5, PR-06 — back-office) :
`admin_list_support_tickets`, `admin_get_support_ticket_detail` (inclut le fil de réponses,
§3.5.7), `admin_update_support_ticket` (statut, priorité, `assigned_to`), chaque mutation
journalisée via `_platform_log`, correction de `STUB_INFO.support`.

**3.5.4 — RPC réponses back-office** (Lot 5, PR-06) :
`admin_reply_support_ticket(ticket_id, body, is_internal_note, corrects_reply_id DEFAULT
NULL)` — insère dans `support_ticket_replies` (§3.5.7) avec `author_type='super_admin'`. Si
`is_internal_note=false`, notifie via Lot 2 (`category='support_ticket_update'`,
`dedupe_key='support:<ticket_id>:reply:<reply_id>'`). Si `is_internal_note=true`, aucune
notification. `admin_hide_support_ticket_reply(reply_id, reason)` /
`admin_unhide_support_ticket_reply(reply_id)` — masquage administratif audité (§3.5.7),
jamais une notification (le masquage est silencieux côté hôtel, seul l'audit interne le trace).

**3.5.5 — Création de ticket, suivi et pièces jointes côté hôtel** (Lot 5, PR-07 — portail
hôtel, livrée après PR-06) : point d'entrée `index.html`/`portal.html` — création (accès table
direct conservé, RLS `support_insert` déjà suffisante, confirmée §2.5.4), suivi (lecture du fil
via une policy dédiée sur `support_ticket_replies` filtrant `is_internal_note=false AND
hidden_at IS NULL`, §3.5.7), pièces jointes (flux sécurisé dédié, §3.5.8, jamais un accès
table/bucket direct). `hotel_reply_support_ticket(ticket_id, body, corrects_reply_id DEFAULT
NULL)` — RPC obligatoire (pas d'accès table direct pour les réponses), fixe
`author_type='hotel_user'` côté serveur.

**3.5.6 — Notification de création/changement de statut/réponse** : réutilise le Lot 2 —
`support_ticket_new` à la création, `support_ticket_update` au changement de statut et à
chaque réponse non masquée (§3.5.4/§3.5.5). Le masquage d'une réponse (§3.5.7) et le
soft-delete d'une pièce jointe (§3.5.8) ne déclenchent **jamais** de notification — ce sont des
corrections silencieuses côté hôtel, uniquement tracées côté audit admin.

**3.5.7 — `support_ticket_replies` — schéma précisé (round 4)**

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `ticket_id` | `uuid NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE` | |
| `seq` | `bigserial NOT NULL` | **Ordre déterministe des échanges** — jamais `created_at` seul (deux réponses simultanées auraient un horodatage égal ou incohérent selon l'horloge) ; même pattern que `audit_logs.seq` déjà en production. `ORDER BY seq ASC` est l'ordre canonique du fil. |
| `author_type` | `text NOT NULL CHECK IN ('super_admin','hotel_user','system')` | `'system'` **réservé, non utilisé en V1** — prévu pour une future entrée automatique (ex. fermeture pour inactivité), sans consommateur aujourd'hui |
| `author_user_id` | `uuid REFERENCES auth.users(id)` | `NULL` uniquement si `author_type='system'` — `CHECK ((author_type='system') = (author_user_id IS NULL))` |
| `author_label` | `text NOT NULL` | Snapshot email/nom au moment de la réponse (doctrine snapshot, §1) ; constante `'Flowtym (automatique)'` si `system` |
| `body` | `text NOT NULL CHECK (char_length(body) <= 4000)` | |
| `is_internal_note` | `boolean NOT NULL DEFAULT false` | **Réponse publique** (`false`, visible côté hôtel) vs **note interne Super Admin** (`true`, jamais visible côté hôtel, même non masquée) |
| `corrects_reply_id` | `uuid REFERENCES support_ticket_replies(id)` | **Correction d'une réponse erronée** : jamais un `UPDATE` du contenu original — une nouvelle ligne référence la réponse qu'elle corrige ; un trigger vérifie que `corrects_reply_id` référence une réponse du **même** `ticket_id` (un `FOREIGN KEY` seul ne peut pas exprimer cette contrainte croisée) |
| `hidden_at` | `timestamptz` | **Masquage administratif audité** — `NULL` par défaut. Renseigné uniquement par `admin_hide_support_ticket_reply` |
| `hidden_by` | `uuid REFERENCES auth.users(id)` | Cohérent avec `hidden_at` : `CHECK ((hidden_at IS NULL) = (hidden_by IS NULL))` |
| `hidden_reason` | `text` | Obligatoire si `hidden_at IS NOT NULL` : `CHECK ((hidden_at IS NULL) = (hidden_reason IS NULL))` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Horodatage informatif, jamais utilisé pour l'ordre canonique (voir `seq`) |

**Contrainte** : `CHECK (NOT is_internal_note OR author_type = 'super_admin')`.

**Masquage administratif audité** — jamais une suppression, une **projection** : une réponse
masquée (`hidden_at IS NOT NULL`) disparaît de la lecture hôtel (§3.5.5, RLS) mais reste
**intégralement visible côté admin**, avec son historique de masquage (`hidden_by`/
`hidden_reason`/date), et génère une ligne `platform_logs` (`action='support_ticket_reply.hide'`
puis `'.unhide'` le cas échéant) à chaque transition. Cas d'usage : une réponse publique
contenant par erreur une information interne, retirée de la vue hôtel sans effacer la trace de
ce qui a été dit.

**Absence de suppression physique ordinaire, confirmée explicitement** : **aucune policy
`UPDATE`/`DELETE`, pour quiconque, y compris admin.** La seule voie de suppression physique est
une purge RGPD exceptionnelle, hors surface RPC ordinaire, suivant exactement la même doctrine
que la précédente purge documentée du projet (`r3_gdpr_purge_guest_documents`) — un processus
explicitement autorisé et journalisé, jamais une capacité client, jamais un bouton dans
`admin.html`.

**Rattachement des pièces jointes** : `support_ticket_attachments.reply_id` (§3.5.8) référence
optionnellement une réponse — une pièce jointe peut accompagner la création du ticket
(`reply_id NULL`) ou une réponse précise.

**Gestion des données personnelles** : `author_label` est un instantané de PII (nom/email),
même doctrine que `platform_notifications.recipient_email` — pas de purge séparée, alignée sur
le cycle de vie du ticket. `body` peut contenir des PII collées par l'utilisateur (ex. une
adresse email dans une description de bug) — **limitation héritée, pas un risque nouveau**
(déjà présente aujourd'hui dans `support_tickets.description`, non traitée spécifiquement). Une
demande d'effacement RGPD nécessiterait une **rédaction** de `author_label`/`body` (pas une
suppression de ligne, qui casserait `seq`/`corrects_reply_id`) via le même processus de purge
exceptionnel que ci-dessus — **point ouvert explicite** (§7), aucune procédure de rédaction
définie dans ce round.

**RLS** : `platform_admin_full_replies` (ALL, `is_platform_admin()`) ;
`hotel_select_own_visible_replies` (SELECT, `is_internal_note=false AND hidden_at IS NULL AND
ticket_id IN (SELECT id FROM support_tickets WHERE hotel_id IN (SELECT hotel_id FROM
user_hotels WHERE user_id=auth.uid()))`). **Aucune policy `INSERT` pour `authenticated`** —
toute écriture passe par RPC (`admin_reply_support_ticket`/`hotel_reply_support_ticket`/
`admin_hide_support_ticket_reply`/`admin_unhide_support_ticket_reply`), pour garantir que
`author_type`/`author_label`/`seq` sont fixés côté serveur.

**3.5.8 — `support_ticket_attachments` + bucket Storage — contrat de sécurité complet (round 4)**

Conçu par référence à `ota_dispute_attachments`/`communication_attachments`/
`attachment_access_log` déjà en production, avec un modèle d'accès **plus strict** que ces
patterns et que `portal-documents` là où ce round demande un niveau de détail supérieur : **tout
accès (lecture et écriture) passe exclusivement par des Edge Functions dédiées, aucune policy
Storage directe pour un rôle client.**

**Table `support_ticket_attachments`** :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `ticket_id` | `uuid NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE` | |
| `reply_id` | `uuid REFERENCES support_ticket_replies(id) ON DELETE CASCADE` | `NULL` si jointe à la création |
| `storage_bucket` | `text NOT NULL DEFAULT 'support-ticket-attachments'` | |
| `storage_path` | `text NOT NULL UNIQUE` | **Généré exclusivement côté serveur** — `<hotel_id>/<ticket_id>/<uuid>.<ext>`, `<ext>` dérivé d'une table de correspondance `mime_type → extension` fixe, **jamais** dérivé du nom de fichier fourni par le client |
| `original_filename` | `text NOT NULL` | Affichage uniquement, assaini (séparateurs de chemin/caractères de contrôle retirés) — **jamais utilisé pour construire `storage_path`** |
| `mime_type` | `text NOT NULL CHECK IN ('application/pdf','image/jpeg','image/png','image/heic','image/webp','image/gif','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document')` | Allowlist fermée, alignée sur `portal-documents` |
| `size_bytes` | `bigint NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760)` | 10 Mo, alignée sur `hr-documents` |
| `status` | `text NOT NULL DEFAULT 'pending_upload' CHECK IN ('pending_upload','uploaded','scan_pending','clean','quarantined','rejected')` | Voir cycle de vie ci-dessous — **corrigé round 5** : `clean` n'est atteignable que par un scan réel, jamais automatiquement |
| `uploaded_by` | `uuid NOT NULL REFERENCES auth.users(id)` | |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `confirmed_at` | `timestamptz` | Rempli quand le serveur a **vérifié** que l'objet existe réellement dans Storage (jamais sur la seule foi du client) |
| `deleted_at` | `timestamptz` | **Soft-delete uniquement** — jamais de `DELETE` physique via une action utilisateur ordinaire |
| `deleted_by` | `uuid REFERENCES auth.users(id)` | |
| `deletion_reason` | `text` | Obligatoire si `deleted_at IS NOT NULL` |

**Flux d'upload en deux temps (vérification serveur, noms générés, URLs signées à durée
limitée)** :
1. Edge Function `support-ticket-attachment-request-upload` (`service_role`) : reçoit
   `(ticket_id, reply_id?, original_filename, mime_type, size_bytes)` ; vérifie l'autorisation
   via une RPC unique `_can_access_support_ticket(ticket_id)` (admin, ou `hotel_user` de
   l'hôtel du ticket — même logique que les policies RLS, centralisée pour ne jamais diverger
   entre replies/attachments) ; vérifie `support_tickets.status != 'ferme'` (**aucun nouvel
   upload après fermeture du ticket** — rouvrir le ticket d'abord, jamais de contournement
   direct) ; vérifie `mime_type`/`size_bytes` contre l'allowlist/la limite ; génère
   `storage_path` côté serveur (jamais depuis le nom de fichier client) ; insère la ligne
   `status='pending_upload'` ; appelle l'API Storage `createSignedUploadUrl` (**TTL 5
   minutes**) ; retourne l'URL signée + l'id d'attachement.
2. Le client uploade directement les octets vers l'URL signée (jamais via la ligne SQL ni via
   le corps de l'Edge Function — pas de doublement de bande passante).
3. Edge Function `support-ticket-attachment-confirm` (`service_role`) : vérifie que l'appelant
   correspond à `uploaded_by` ; **interroge réellement l'API Storage** pour confirmer que
   l'objet existe à `storage_path` avec une taille cohérente avec `size_bytes` déclaré (jamais
   une confirmation aveugle) ; passe `status='uploaded'`, `confirmed_at=now()`, **puis
   immédiatement `status='scan_pending'`** — **corrigé round 5** : plus aucune transition
   automatique vers `clean`. `clean` signifie exclusivement « scannée réellement et jugée
   saine » ; tant qu'aucun scanner antivirus n'est câblé (aucun choisi dans ce round), une
   pièce jointe reste `scan_pending` **indéfiniment** — voir conséquence fonctionnelle
   explicite plus bas et point ouvert (§7).
4. Une ligne `pending_upload` dont l'URL signée a expiré sans confirmation reste orpheline,
   exclue de toute lecture (`WHERE status='clean'`), sans nettoyage automatique en V1 (pas de
   cron, volume jugé négligeable) — acceptable, documenté, pas un chantier de cette PR.

**Lecture — URLs signées à durée limitée, jamais d'URL publique** : Edge Function
`support-ticket-attachment-download-url(attachment_id)` — vérifie l'autorisation
(`_can_access_support_ticket`), vérifie `status='clean' AND deleted_at IS NULL` (un fichier
`pending_upload`/`uploaded`/`scan_pending`/`quarantined`/`rejected`/supprimé n'est **jamais**
téléchargeable), génère un `createSignedUrl` **TTL 10 minutes**, journalise l'accès (voir plus
bas), retourne l'URL. Aucun `storage_path` n'est jamais exposé tel quel comme lien direct côté
client. **Conséquence fonctionnelle directe de la correction round 5** : tant qu'aucun
fournisseur antivirus n'est câblé, `clean` n'est **jamais** atteint automatiquement — aucune
pièce jointe n'est donc téléchargeable en pratique tant que ce choix n'est pas fait. C'est un
compromis assumé (sécurité avant fonctionnalité), pas un oubli — voir §7 pour la décision à
prendre avant l'ouverture réelle du Lot 5 PR-07.

**Bucket Storage `support-ticket-attachments`** : `public=false`, `file_size_limit=10485760`,
`allowed_mime_types` = liste ci-dessus. **Aucune policy `storage.objects` pour `anon` ni
`authenticated`** — seul `service_role` (les 3 Edge Functions) accède au bucket. Choix
délibérément plus strict que le filtrage par préfixe envisagé au round 3 : un seul point de
contrôle (les Edge Functions) plutôt que deux surfaces (RLS Storage + RLS table) à maintenir
en cohérence.

**Contrôle d'accès par hôtel et par ticket** : centralisé dans `_can_access_support_ticket
(ticket_id)` (SECURITY DEFINER), appelée par les 3 Edge Functions et par les RPC de réponses
(§3.5.4/§3.5.5) — logique d'autorisation écrite une seule fois, jamais dupliquée entre
composants.

**Suppression** : **soft-delete uniquement**, jamais de `DELETE` physique via une action
utilisateur ordinaire. Qui peut soft-supprimer : l'auteur de l'upload (`uploaded_by=auth.uid()`)
dans les **15 minutes** suivant l'upload (fenêtre de correction d'une erreur d'envoi), ou un
admin à tout moment (`deletion_reason` obligatoire, journalisé). Jamais un `hotel_user` sur la
pièce jointe d'un autre utilisateur de son propre hôtel. Un fichier soft-supprimé disparaît
immédiatement des lectures (RPC filtrent `deleted_at IS NULL`) mais reste physiquement en
Storage et en base pour l'audit, jusqu'à une purge explicite ultérieure.

**Pièces jointes après fermeture du ticket** : lecture toujours autorisée (historique complet
conservé) ; **aucun nouvel upload** une fois `status='ferme'` (vérifié à l'étape 1 du flux) —
seule voie : rouvrir le ticket via `admin_update_support_ticket` (déjà audité), jamais un
contournement de la garde d'upload.

**Politique de rétention** : alignée sur la doctrine déjà actée pour `platform_notifications`
(§3.0) — **pas de purge automatisée en V1**, conservation indéfinie par défaut tant qu'une
politique de conservation formelle (probablement plus longue que 90 jours, pour valeur de
preuve en cas de litige support) n'est pas explicitement tranchée par le CTO — **point ouvert**
(§7).

**Traitement antivirus / quarantaine — corrigé round 5.** **Aucun fournisseur choisi dans ce
round.** Le schéma réserve désormais 6 statuts honnêtes, chacun correspondant à un fait réel,
jamais à une simulation :
- `pending_upload` — ligne créée, upload pas encore confirmé ;
- `uploaded` — objet Storage confirmé existant côté serveur (étape 3 ci-dessus), pas encore
  transmis à un scanner ;
- `scan_pending` — en attente d'un scan réel. **Statut par défaut et terminal en V1** tant
  qu'aucun fournisseur antivirus n'est câblé — jamais une étape transitoire vers `clean` ;
- `clean` — **atteint exclusivement après un scan réel positif.** Aucune transition
  automatique `uploaded`/`scan_pending` → `clean` n'existe dans ce round (correction explicite
  demandée : « sans véritable analyse antivirus, une pièce jointe ne doit jamais passer
  automatiquement à `clean` ») ;
- `quarantined` — atteint exclusivement après un scan réel négatif ;
- `rejected` — ligne orpheline (URL signée expirée sans confirmation, §3.5.8 étape 4).

Doctrine des signaux honnêtes (§1) appliquée strictement : `clean` n'est **jamais** une
capacité simulée. Si un fournisseur est choisi ultérieurement (ex. ClamAV via Edge Function, ou
service SaaS webhook), une nouvelle transition `scan_pending → clean|quarantined` est ajoutée
(déclenchée par le résultat réel du scan) — aucune migration de schéma nécessaire, le statut
`scan_pending` existe déjà pour l'accueillir.

**Journalisation des accès et suppressions** — nouvelle table `support_ticket_attachment_access_log`
(conçue par cohérence avec `attachment_access_log` déjà en production pour un autre domaine) :

| Colonne | Type |
|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` |
| `attachment_id` | `uuid NOT NULL REFERENCES support_ticket_attachments(id) ON DELETE CASCADE` |
| `ticket_id` | `uuid NOT NULL` |
| `user_id` | `uuid NOT NULL REFERENCES auth.users(id)` |
| `action` | `text NOT NULL CHECK IN ('download_url_issued','soft_deleted')` |
| `ip_address` | `inet` |
| `user_agent` | `text` |
| `occurred_at` | `timestamptz NOT NULL DEFAULT now()` |

Écrite exclusivement par les Edge Functions (`service_role`) — aucun accès `authenticated`,
lecture réservée à une future RPC d'audit admin si un écran dédié est jugé utile (non
prioritaire, hors périmètre V1).

### 3.6 Supervision avancée, y compris la santé technique de la plateforme — hors périmètre de ce round (voir §8)

Non incluse dans les 6 lots communiqués. Contenu conservé sans changement en annexe (§8).

---

## 4. Preuve de non-duplication

| Nouvelle brique | Lot | S'appuie sur | Ne duplique pas |
|---|---|---|---|
| Migration `sql/80` (Lot 1 PR-01 : rétro-versionnement + reconstruction + comparaison) | Lot 1 | `support_tickets`/`help_articles` (schéma production, reproduit à l'identique) | Ne recrée rien — recopie ce qui existe, grants inclus |
| `sql/81` (Lot 1 PR-02 : durcissement ACL/RLS) | Lot 1 | Le test réel du §2.5.4 | Décision distincte de PR-01, jamais fusionnée avec le rétro-versionnement (point 1) |
| `platform_notifications` (`sql/82`) | Lot 2 | Rien d'existant | N'entre pas en collision avec Resend |
| `admin_list_license_usage` (`sql/83`) | Lot 3 | `snapshot_limits`/`plan_modules` existants | Lecture seule, aucune nouvelle table |
| `admin_{preview,run}_trial_ending_notifications` (`sql/84`) | Lot 4 | `hotel_subscriptions.trial_ends_at` + `platform_notifications` | Ne touche jamais `hotel_app_subscriptions`, aucun cron |
| `support_ticket_replies` (`sql/85`) | Lot 5 PR-06 | `support_tickets` existant, pattern `audit_logs.seq` | N'étend pas `support_tickets`, ne remplace pas `claude_response` déjà versionné au Lot 1 |
| `support_ticket_attachments`/`support_ticket_attachment_access_log` (`sql/86`) | Lot 5 PR-07 | Patterns `ota_dispute_attachments`/`attachment_access_log`, buckets `hr-documents`/`portal-documents` (référence de configuration seule) | Ne remplace pas `attachment_url` déjà versionné au Lot 1 ; modèle d'accès délibérément distinct des buckets de référence (plus strict) |
| `platform_metrics_daily` + `admin_hotel_health_score` (`sql/87`) | Lot 6 | `hotel_subscription_events`, `platform_invoices`, `platform_payments`, alertes Lot 3, tickets Lot 5 | Score client strictement distinct de toute future santé technique (§8) — aucun recalcul de logique déjà exposée par `admin_platform_overview_kpis` |

---

## 5. Décisions CTO — statut après ce round

1. **Prestataire de paiement** — toujours différé. Bloque toujours PR-09 (§6).
2. **Licences — alerte seule ou blocage réel ?** — Tranché : observation uniquement (Lot 3).
3. **Activation du cron essais expirés** — Tranché : non activé.
4. **Cron dunning / recalcul quotidien des métriques** — Aucun cron activé dans ce cycle.
5. **Compte de monitoring d'erreurs (Sentry)** — sans objet, Supervision avancée hors périmètre.
6. **Support — périmètre V1** — Tranché : Lot 5 en 2 PR indépendantes (back-office puis
   portail hôtel).
7. **`platform_incidents`** — sans objet dans ce round, non inclus dans les 6 lots.
8. **Lot 4 — 3 paliers J-7/J-3/J-1**, preview/run, cron désactivé — §3.3.
9. **Lot 5 — réponses et pièces jointes** ajoutées au périmètre, contrat de sécurité complet
   pour les pièces jointes (round 4, point 3) — §3.5.7/§3.5.8.
10. **Ordre imposé confirmé** : Lot 1 (PR-01 puis PR-02) → Lot 2 → Lot 3 → Lot 4 → Lot 5
    (PR-06 puis PR-07) → Lot 6 → Paiements (note seule).

**Nouvelles décisions actées par ce round (round 4)** :

11. **Lot 1 scindé en exactement 2 PR** — rétro-versionnement (incluant reconstruction et
    comparaison dépôt/production) strictement séparé du durcissement ACL/RLS. Aucune PR ne
    mélange remise sous version et changement de sécurité (point 1).
12. **« Score de santé plateforme » retiré**, remplacé par deux concepts explicitement
    séparés — score de santé **client/hôtel** (Lot 6, commercial/usage, par hôtel) et santé
    **technique** de la plateforme (hors périmètre, §8, ops). Jamais un score composite unique
    (point 2).
13. **Contrat de sécurité complet pour `support_ticket_attachments`** — flux d'upload en deux
    temps, URLs signées à durée limitée en lecture et en écriture, vérification serveur
    systématique, noms de fichiers générés côté serveur, aucune policy Storage directe pour un
    rôle client, soft-delete uniquement, comportement après fermeture, statuts de quarantaine
    réservés (fournisseur non choisi, point ouvert), journal d'accès dédié (point 3).
14. **`support_ticket_replies` précisé** — auteur `system` réservé, correction par nouvelle
    réponse liée (jamais un `UPDATE`), masquage administratif audité (projection, jamais une
    suppression), absence de suppression physique ordinaire confirmée, ordre déterministe par
    `seq` (pas `created_at`), traitement des données personnelles documenté avec point ouvert
    sur la procédure de rédaction RGPD (point 4).
15. **Paiements** : développement toujours reporté, menu `admin.html` reste « À venir » ; la
    note d'architecture métier (§3.1) reconfirmée comme **livrable obligatoire de la Phase 2**,
    à maintenir à jour indépendamment du calendrier de développement (point 5).

**Décisions rounds précédents reconfirmées sans changement** : `platform_notifications`
(schéma détaillé §3.0), `hotel_app_subscriptions` (aucune nouvelle dépendance).

---

## 6. Plan de réalisation — PR détaillées, par lot, ordre imposé

**Gabarit obligatoire de fiche PR** — chaque PR documente explicitement les 8 champs exigés par
le CTO, dans cet ordre : **Objectif, Dépendances, Migration, Reconstruction, Tests, Rollback,
Smoke test, Documentation** — complétés par **Fichiers concernés** et **Risques** (contexte,
hérités du gabarit round 2/3).

**Table de correspondance round 3 → round 4** (renumérotation résultant du point 1 — Lot 1
passe de 3 à 2 PR, tout ce qui suit décale d'un cran ; les numéros de migration `sql/NN` ne
changent pas, aucune migration n'ayant jamais été appliquée) :

| Round 3 | Round 4 | Changement |
|---|---|---|
| PR-00 | PR-00 | Inchangée |
| Lot 1 PR-01 (`sql/80`) + PR-02 (tests, aucune migration) | **Lot 1 PR-01** (`sql/80`, fusionnée) | **Fusion explicite** — reconstruction et comparaison intégrées à la PR de rétro-versionnement (point 1) |
| Lot 1 PR-03 (`sql/81`) | **Lot 1 PR-02** (`sql/81`) | Renommée, contenu précisé (tests par rôle explicites, point 1) |
| Lot 2 PR-04 (`sql/82`) | **Lot 2 PR-03** (`sql/82`) | Renumérotée seulement |
| Lot 3 PR-05 (`sql/83`) | **Lot 3 PR-04** (`sql/83`) | Renumérotée seulement |
| Lot 4 PR-06 (`sql/84`) | **Lot 4 PR-05** (`sql/84`) | Renumérotée seulement |
| Lot 5 « PR A » (`sql/85`) | **Lot 5 PR-06** (`sql/85`) | Renommée, contenu étendu (masquage, correction, `seq`) |
| Lot 5 « PR B » (`sql/86`) | **Lot 5 PR-07** (`sql/86`) | Renommée, contenu étendu (contrat de sécurité complet, table de journal supplémentaire) |
| Lot 6 PR-09 (`sql/87`, score « plateforme ») | **Lot 6 PR-08** (`sql/87`, score « client/hôtel ») | Renumérotée, **redéfinie** (point 2) |
| PR-10 (écran divergence) | **PR-09** | Renumérotée seulement |
| PR-11 (Paiements) | **PR-10** | Renumérotée seulement |

### PR-00 — ADR-012 finalisée
- **Objectif** : obtenir la validation explicite finale de cette architecture, round 4.
- **Dépendances** : aucune.
- **Migration** : aucune.
- **Reconstruction** : sans objet.
- **Tests** : aucun.
- **Rollback** : sans objet.
- **Smoke test** : sans objet.
- **Documentation** : ce document ; entrée `CHANGELOG.md` au moment de la validation finale.
- **Fichiers concernés** : `docs/adr/ADR-012-super-admin-phase2-plateforme-saas.md`.
- **Critères d'acceptation** : validation explicite reçue du CTO sur ce round 4.

### Lot 1 — Fondations Support (priorité absolue, 2 PR strictement séparées)

#### Lot 1 — PR-01 — Rétro-versionnement à l'identique (schéma + reconstruction + comparaison)
- **Objectif** : remettre `support_tickets`/`help_articles` sous contrôle du dépôt — tables,
  colonnes, contraintes, index, triggers, grants, policies RLS, fonctions associées — **sans
  aucun changement de comportement ni de permission**, avec la reconstruction et la comparaison
  dépôt/production comme partie intégrante de cette même PR (fusion round 4, point 1).
- **Dépendances** : PR-00.
- **Migration** : nouveau `sql/80_support_retro_versioning.sql` — `CREATE TABLE IF NOT EXISTS`
  (colonnes/contraintes/index identiques à §2.5.1/§2.5.2), recréation idempotente des 3
  triggers/fonctions, de la séquence, des 7 policies RLS mot pour mot, des grants actuels
  reproduits tels quels (y compris `anon`, non réduits ici).
- **Reconstruction** : nouveau `sql/tests/support_retro_versioning.sql` dans la même PR —
  reconstruit le schéma depuis zéro en transaction, compare au DDL de production
  (`pg_get_functiondef`/`pg_get_constraintdef` identiques) ; ajouté à la séquence rejouée par
  la reconstruction versionnée du dépôt ; le job CI « DB — reconstruction dépôt + tests » doit
  rester vert.
- **Tests** : application en transaction `ROLLBACK` sur la production réelle ; rejeu versionné
  des 8 scénarios `anon` (§2.5.4) ; scénarios `authenticated` hôtel légitime (accès à ses
  propres tickets, refus sur ceux d'un autre hôtel).
- **Rollback** : `DROP` des objets nouvellement créés si la migration a créé quoi que ce soit
  qui n'existait pas déjà (ne devrait rien créer de nouveau, `CREATE TABLE IF NOT EXISTS`).
- **Smoke test** : lecture réelle en production confirmant que `support_tickets`/
  `help_articles` restent interrogeables sans erreur, comparaison dépôt/production du §2.5.5
  intégralement vérifiée après application.
- **Documentation** : entrée `CHANGELOG.md`, mise à jour de ce document marquant Lot 1 PR-01
  comme livré.
- **Fichiers concernés** : `sql/80_support_retro_versioning.sql`,
  `sql/tests/support_retro_versioning.sql`.
- **Risques** : très faible — la migration doit être un **no-op** en production ; **aucune
  permission n'est modifiée par cette PR** (garde-fou explicite du point 1).

#### Lot 1 — PR-02 — Durcissement ACL/RLS (strictement postérieure, indépendante)
- **Objectif** : appliquer le principe de moindre privilège sur `support_tickets`/
  `help_articles`, uniquement après l'audit factuel déjà réalisé (§2.5.4) — jamais mélangée à
  la remise sous version du schéma (point 1).
- **Dépendances** : Lot 1 PR-01 (le schéma doit être versionné et testé avant d'être durci).
- **Migration** : nouveau `sql/81_support_acl_hardening.sql` — `REVOKE ALL ... FROM anon` sur
  les deux tables + la séquence `support_ticket_seq`. Aucune policy RLS modifiée sauf
  régression détectée par les tests par rôle ci-dessous (non anticipée).
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests par rôle, rejoués avant et après** : `anon` (8 scénarios §2.5.4, résultat attendu :
  passage de « bloqué par RLS » à « bloqué par grant », erreur plus précoce) ; `authenticated`
  hôtel légitime (accès à ses tickets, inchangé) ; `authenticated` hôtel non légitime (refus
  sur les tickets d'un autre hôtel, inchangé) ; `authenticated` admin (accès complet,
  inchangé) — les 4 profils, pas seulement `anon`.
- **Rollback explicite** : `GRANT` inverse (réattribution des privilèges retirés) si un usage
  légitime d'`anon` était découvert a posteriori — écrit et testé avant merge, pas improvisé
  après coup.
- **Smoke test** : `has_table_privilege('anon', 'support_tickets', 'INSERT')` = `false` vérifié
  directement en production après application ; comportement des 3 autres profils strictement
  inchangé, vérifié par rejeu du même fichier de test.
- **Documentation** : entrée `CHANGELOG.md`, mise à jour de ce document marquant Lot 1 PR-02
  comme livré.
- **Fichiers concernés** : `sql/81_support_acl_hardening.sql`.
- **Risques** : faible — aucun flux légitime ne passe aujourd'hui par `anon` sur ces tables
  (confirmé par test réel, §2.5.4).

### Lot 2 — Fondation `platform_notifications`
- **Objectif** : livrer la file de notifications transverse (§3.0), utilisée par les Lots 4 et 5.
- **Dépendances** : PR-00.
- **Migration** : `sql/82_platform_notifications.sql` (schéma §3.0), `REVOKE ALL FROM PUBLIC,
  anon, authenticated`, grant `service_role` uniquement ; Edge Function
  `supabase/functions/platform-send-notification/index.ts`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : insertion directe + appel Edge Function en environnement de test (clé Resend de
  test) ; idempotence `dedupe_key` (deux insertions identiques → une seule ligne) ; passage
  `pending → sending → sent/abandoned`.
- **Rollback** : `DROP TABLE platform_notifications` si aucune brique consommatrice n'est
  encore mergée.
- **Smoke test** : idempotence démontrée par test réel, aucun accès `anon`/`authenticated`
  possible sur la table, vérifié directement.
- **Documentation** : entrée `CHANGELOG.md`, documentation de l'Edge Function.
- **Fichiers concernés** : `sql/82_platform_notifications.sql`,
  `supabase/functions/platform-send-notification/index.ts`.
- **Risques** : faible.

### Lot 3 — Licences en observation
- **Objectif** : `admin_list_license_usage()` + alerte `license_quota_exceeded`, lecture seule.
- **Dépendances** : PR-00.
- **Migration** : `sql/83_admin_license_usage.sql`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : hôtel sous quota, hôtel au-dessus, hôtel sans limite définie.
- **Rollback** : `DROP FUNCTION admin_list_license_usage()`, retrait du type d'alerte.
- **Smoke test** : RPC appelée en production (lecture seule), comparée à un comptage manuel.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `sql/83_admin_license_usage.sql`.
- **Risques** : faible.

### Lot 4 — Notifications d'essai (J-7/J-3/J-1), cron désactivé
- **Objectif** : notifier un hôtel avant expiration d'essai, 3 paliers, preview/run au prédicat
  identique — §3.3.
- **Dépendances** : Lot 2.
- **Migration** : `sql/84_trial_ending_notifications.sql` — `admin_preview_trial_ending_notifications()`,
  `admin_run_trial_ending_notifications()`, prédicat partagé. Pas de cron.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : un essai à J-7/J-3/J-1 ne génère qu'une notification par palier ; preview = run
  avant exécution ; relance manuelle répétée sans doublon.
- **Rollback** : `DROP FUNCTION` des deux RPC, aucune donnée `hotel_subscriptions` affectée.
- **Smoke test** : preview appelée en production sur les essais réels, comparée manuellement.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `sql/84_trial_ending_notifications.sql`.
- **Risques** : faible.

### Lot 5 — Support (2 PR indépendantes)

#### Lot 5 — PR-06 — Back-office (triage, assignation, priorité, réponses)
- **Objectif** : `admin_list_support_tickets`/`admin_get_support_ticket_detail`/
  `admin_update_support_ticket`/`admin_reply_support_ticket`/`admin_{hide,unhide}_support_ticket_reply`
  + écran `admin.html` + correction `STUB_INFO.support` — §3.5.3/§3.5.4/§3.5.7.
- **Dépendances** : Lot 1 (PR-01 **et** PR-02 fermées), Lot 2.
- **Migration** : `sql/85_admin_support_triage.sql` — table `support_ticket_replies` (§3.5.7),
  6 nouvelles RPC, ACL standard, `_platform_log` sur chaque mutation.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : triage complet, réponse visible/note interne (invisible côté hôtel), correction
  d'une réponse (nouvelle ligne, jamais un `UPDATE`), masquage/démasquage audité, ordre
  déterministe (`seq`) vérifié avec des insertions simultanées simulées, rejet non-admin, rejet
  d'une note interne créée par un `hotel_user` (CHECK).
- **Rollback** : `DROP FUNCTION` des 6 RPC, `DROP TABLE support_ticket_replies` si aucune
  donnée réelle n'y a encore été écrite.
- **Smoke test** : triage réel testé en production (lecture) ; une réponse de test créée
  uniquement en transaction annulée.
- **Documentation** : entrée `CHANGELOG.md`, `STUB_INFO.support` corrigé.
- **Fichiers concernés** : `sql/85_admin_support_triage.sql`, `admin.html`.
- **Risques** : faible.

#### Lot 5 — PR-07 — Portail hôtel (création, suivi, pièces jointes)
- **Objectif** : point d'entrée `index.html`/`portal.html` — création, suivi, pièces jointes
  avec contrat de sécurité complet — §3.5.5/§3.5.8. Livrée après PR-06.
- **Dépendances** : Lot 1 (PR-01 **et** PR-02 fermées), Lot 5 PR-06.
- **Migration** : `sql/86_hotel_support_portal.sql` — tables `support_ticket_attachments` et
  `support_ticket_attachment_access_log` (§3.5.8), bucket Storage `support-ticket-attachments`
  (aucune policy `authenticated`/`anon`), 3 Edge Functions (`request-upload`, `confirm`,
  `download-url`), RPC `hotel_reply_support_ticket`, RPC interne
  `_can_access_support_ticket(ticket_id)`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : un hôtel crée/répond/joint un fichier à son propre ticket, jamais à celui d'un
  autre hôtel ; upload refusé sur ticket fermé ; upload refusé hors allowlist MIME ou au-delà
  de 10 Mo ; confirmation refusée si l'objet Storage n'existe pas réellement ; URL de
  téléchargement refusée si `status != 'clean'` ; soft-delete refusé après 15 minutes pour un
  non-admin ; note interne jamais visible ; réponse masquée jamais visible côté hôtel ; chaque
  accès et suppression génère une ligne `support_ticket_attachment_access_log`.
- **Rollback** : retrait du point d'entrée frontend, `DROP FUNCTION` des RPC/Edge Functions,
  `DROP TABLE` des deux nouvelles tables et suppression du bucket si aucune pièce jointe réelle
  n'a encore été uploadée.
- **Smoke test** : ticket visible immédiatement côté triage (PR-06) après création côté hôtel ;
  cycle complet upload → confirmation → téléchargement testé en production avec un fichier de
  test explicitement marqué, soft-supprimé après vérification.
- **Documentation** : entrée `CHANGELOG.md`, contrat de sécurité des pièces jointes documenté
  dans `admin.html`/`portal.html` pour les futurs contributeurs.
- **Fichiers concernés** : `index.html` ou `portal.html` (à confirmer), `sql/86_hotel_support_portal.sql`,
  3 nouvelles Edge Functions.
- **Risques** : moyen — nouvelle surface d'upload de fichiers, contrat de sécurité détaillé
  mais jamais testé en conditions réelles avant cette PR (raison du niveau de détail exigé par
  le CTO, point 3).

### Lot 6 — Statistiques fondamentales, y compris le score de santé client/hôtel
- **Objectif** : `platform_metrics_daily` + `admin_recompute_platform_metrics` +
  `admin_platform_metrics_series` + `admin_hotel_health_score`/`admin_list_hotel_health_scores`
  — définitions formelles du §3.4, **score de santé client/hôtel uniquement, jamais un
  composite technique** (point 2).
- **Dépendances** : PR-00 pour les métriques financières ; **le sous-score Support du score de
  santé client dépend du Lot 5**, **le sous-score Licences du Lot 3** (défaut `100` sinon,
  §3.4) — livré en dernier précisément pour cette raison.
- **Migration** : `sql/87_platform_metrics.sql` — table `platform_metrics_daily`, RPC de
  recalcul et de série temporelle, RPC de score de santé client (aucune table persistée pour
  le score, calcul à la demande).
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : jeux de données synthétiques (résiliations, changements de plan, avoirs à dates
  connues) vérifiant chaque métrique et chaque sous-score de santé client selon sa formule
  exacte ; vérification qu'aucun signal technique (erreurs RPC, latence, disponibilité)
  n'apparaît dans le calcul (garde-fou explicite du point 2).
- **Rollback** : `DROP TABLE platform_metrics_daily`, `DROP FUNCTION` des RPC.
- **Smoke test** : recalcul réel en production comparé à un calcul manuel de référence (MRR,
  hôtels actifs, score d'un hôtel connu).
- **Documentation** : entrée `CHANGELOG.md`, formule du score de santé client documentée dans
  l'écran Dashboard (`admin.html`).
- **Fichiers concernés** : `sql/87_platform_metrics.sql`, `admin.html`.
- **Risques** : moyen — logique métier nouvelle ; risque principal = un chiffre incorrect
  affiché au CTO, pas un risque de sécurité.

### PR-09 — Écran divergence de droits (frontend seul, hors lot)
- **Objectif** : exposer `admin_rights_divergence_report()` (déjà existante) à l'écran.
- **Dépendances** : aucune — non bloquant pour les 6 lots.
- **Migration** : aucune.
- **Reconstruction** : sans objet.
- **Tests** : Jest sur le helper d'affichage.
- **Rollback** : retrait de l'écran, aucun impact backend.
- **Smoke test** : écran ouvert en Preview, comparé à un appel RPC direct.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `admin.html`.
- **Risques** : nul.

### PR-10 — Paiements (développement reporté ; note d'architecture métier maintenue à jour)
- **Objectif** : les 3 livrables du §3.1 — PDF réel, dunning réel, passerelle de paiement —
  **une fois** les questions métier tranchées et le prestataire choisi. **Non planifié dans ce
  round.** Le menu `admin.html` reste « À venir ».
- **Dépendances** : Lot 2 (dunning), décision CTO sur le prestataire, réponses au §3.1.
- **Migration** : `platform_dunning_log`, `platform_payment_intents`,
  `platform_payment_provider_events`, numérotation `sql/88+` au déblocage.
- **Reconstruction** : à traiter au moment de l'exécution.
- **Tests** : idempotence webhook stricte, vérification de signature, tests en transaction.
- **Rollback** : stratégie à détailler par sous-PR, pas de rollback générique pour un flux
  financier réel.
- **Smoke test** : à définir avec le prestataire choisi.
- **Documentation** : **le §3.1 de ce document reste le livrable obligatoire de la Phase 2**,
  maintenu à jour indépendamment du calendrier — sera complété (round 5+) au fur et à mesure
  que les décisions métier sont tranchées, même sans code écrit.
- **Fichiers concernés** : `sql/88+`, buckets Storage, Edge Functions dédiées.
- **Risques** : le plus élevé du plan.

---

## 7. Points encore réellement bloquants

1. **Choix du prestataire de paiement** — bloque PR-10 dans son intégralité.
2. **Questions métier Paiements du §3.1** — non tranchées, préalables à toute écriture de code.
3. **Politique de rétention de `platform_notifications`** — proposition 90 jours, non validée,
   sans impact bloquant.
4. **Pondération du score de santé client/hôtel** (§3.4) — proposition V1
   (20/20/15/15/15/15), non validée explicitement, sans impact bloquant sur le Lot 6 (constante
   modifiable sans migration).
5. **Proxy d'adoption du score de santé client** (§3.4) — faute de journal d'usage applicatif
   par module, le sous-score Adoption utilise un proxy (présence d'un utilisateur actif dans le
   module) — limitation documentée, pas un blocage, mais un chiffre potentiellement peu
   discriminant à améliorer ultérieurement.
6. **Fuseau horaire du « jour métier »** (Europe/Paris, §3.4) — non confirmé explicitement,
   sans impact bloquant.
7. **Fournisseur antivirus pour `support_ticket_attachments`** (§3.5.8, **corrigé round 5**) —
   aucun choisi. Depuis la correction round 5, `clean` n'est plus jamais atteint automatiquement
   — toute pièce jointe reste `scan_pending` indéfiniment tant qu'aucun scanner n'est câblé, ce
   qui signifie **qu'aucune pièce jointe n'est téléchargeable en pratique** (la RPC de lecture
   exige `status='clean'`). **Devient bloquant pour la valeur livrée par le Lot 5 PR-07**
   (pas pour sa sécurité, qui est le but recherché) : le CTO doit trancher avant l'ouverture
   réelle de cette PR entre (a) choisir et câbler un fournisseur antivirus dans le même lot,
   (b) accepter explicitement de livrer une PR-07 où l'upload fonctionne mais la lecture reste
   bloquée jusqu'à un scanner ultérieur, ou (c) reporter PR-07 après ce choix. Le schéma
   (`scan_pending`) est prêt à accueillir un scan asynchrone sans migration future dans les
   trois cas.
8. **Politique de rétention des pièces jointes Support** (§3.5.8) — pas de purge automatisée en
   V1, conservation indéfinie par défaut ; une politique formelle (probablement plus longue que
   les 90 jours de `platform_notifications`, pour valeur de preuve en cas de litige) reste à
   trancher explicitement.
9. **Procédure de rédaction RGPD pour `support_ticket_replies`** (§3.5.7) — une demande
   d'effacement nécessiterait une rédaction de `author_label`/`body` (jamais une suppression de
   ligne, qui casserait `seq`/`corrects_reply_id`) ; aucune procédure définie dans ce round.

Aucun autre point des rounds précédents ne reste ouvert sans réponse.

---

## 8. Annexe — Supervision avancée, y compris la santé technique de la plateforme (hors périmètre de ce lancement)

Conservé pour mémoire — **non inclus dans les 6 lots communiqués**, ne pas développer tant que
ce domaine n'est pas explicitement reprogrammé.

`admin_supervision_status()` honnête (signaux `mutation_error_monitoring_available`/
`edge_function_error_monitoring_available` actuellement `false`, correctement),
`admin_list_platform_audit_log()` déjà livré (Phase 1). Chantiers identifiés mais non planifiés :
RPC CMS `help_articles`, intégration Sentry frontend + Edge Functions (dépend d'un compte
externe non fourni), `platform_incidents` (stretch, Could).

**B. Santé technique de la plateforme (round 4, point 2 — concept désormais explicitement
nommé et scopé, toujours non développé)** : si ce domaine est repris, il couvrirait, en une RPC
**strictement distincte** de `admin_hotel_health_score` (§3.4) — jamais un score composite
unique mélangeant les deux :
- **Erreurs RPC** — signal déjà disponible en germe : `platform_logs.level` existe en
  production (colonne déjà présente), jamais agrégé par aucune RPC aujourd'hui.
- **Edge Functions** — taux d'échec d'invocation, nécessiterait une exploitation des Logs/
  Analytics Supabase, non câblée.
- **Notifications échouées** — `platform_notifications.status='abandoned'` (Lot 2) : signal
  disponible dès que le Lot 2 est livré, mais volontairement non agrégé dans un score tant que
  ce domaine n'est pas repris.
- **Cron** — 0 job `pg_cron` aujourd'hui ; « santé cron » = « aucun cron actif », trivialement
  vrai, sans objet tant qu'aucun cron n'est activé (ADR-010 §3).
- **Latence** — aucune mesure actuelle, nécessiterait une instrumentation dédiée.
- **Disponibilité** — dépend d'un fournisseur de monitoring externe, non choisi (cf. point 7
  round 2, Sentry différé).
- **Migrations** — nombre appliquées vs en attente, trivialement dérivable de `sql/`, non
  exposé par aucune RPC actuellement.
- **Incidents techniques** — `platform_incidents` (stretch, Could), déjà noté non planifié.

Si repris, produirait sa propre RPC `admin_platform_technical_health()`, indépendante de
`admin_hotel_health_score()` (§3.4) — deux écrans, deux audiences, jamais un seul chiffre.
Consommerait les prochains numéros de migration disponibles après `sql/87` (ou après `sql/88+`
si Paiements a été débloqué entre-temps) — aucun numéro réservé à l'avance.

---

## 9. Rapport d'implémentation réel — passe de stabilisation (round 6)

Cette section documente ce qui a **réellement** été construit, testé et poussé, par
opposition à ce que les rounds 1–5 ci-dessus avaient seulement conçu. Elle couvre aussi les
écarts assumés par rapport à ce qui avait été décidé aux rounds précédents, avec leur
justification — jamais une substitution silencieuse.

### 9.1 État réel des PR

Dix PR de Phase 2 sont ouvertes et empilées (#21 à #30), plus une PR de sécurité P0 (#31,
voir §9.2), plus les correctifs de stabilisation décrits ci-dessous. Aucune n'est mergée.
Aucune migration n'est appliquée en production. Aucun cron n'est activé. Voir le rapport CTO
final de la passe de stabilisation pour la table complète PR/SHA/base/dépendances (§12 de ce
document — audit d'empilement).

### 9.2 P0 ACL — 7 tables (nouvelle PR #31)

Audit réel des grants (`PUBLIC`/`anon`/`authenticated`/`service_role`/`postgres`) sur
`rms_decisions`, `salon_events`, `lighthouse_imports`, `lighthouse_days`, `rms_settings`,
`onboarding_tasks`, `mi_imported_events` — TRUNCATE exposé à `anon` confirmé exploitable en
production (transaction annulée, aucune donnée modifiée). Corrigé par `sql/88`
(`REVOKE ALL FROM anon`, `REVOKE TRUNCATE/REFERENCES/TRIGGER/DELETE FROM authenticated`),
**aucune policy RLS modifiée** — l'audit distingue deux situations réelles : `lighthouse_days`/
`lighthouse_imports` ont une policy de repli correcte (OR RLS, code mort inoffensif) ; les 5
autres n'ont aucun repli et sont aujourd'hui verrouillées en fonctionnement pour tout
utilisateur hôtel réel (défaut fonctionnel fail-closed, pas une fuite) — correction de policy
hors périmètre de cette PR de sécurité. PR #31, branche `fix/p0-seven-tables-acl-grants`,
basée sur `main` (pas empilée sur les lots Phase 2).

### 9.3 Canal de notification — email seul, confirmé conforme au schéma

Le schéma `platform_notifications` (§3.0, `sql/82`) porte `channel text NOT NULL DEFAULT
'email' CHECK (channel = 'email')` depuis le round 4 — un seul canal en V1 est une décision
d'architecture explicite de ce document, pas un oubli. Aucun canal « interne » (notification
listable/marquable-lue/filtrable/isolée par RLS) n'a été construit ni n'était prévu pour ce
round. Le périmètre livré (email uniquement) correspond exactement au schéma décidé ici.

### 9.4 Pièces jointes Support — stratégie A retenue, suppression logique ajoutée

`sql/86` (Lot 5 PR-07) implémentait déjà honnêtement l'absence de scanner antivirus (round 5,
rappelé ci-dessus §1/§7) : `status='clean'` n'est jamais atteint automatiquement, donc
`support-ticket-attachment-download-url` refuse toujours le téléchargement tant qu'aucun
scanner réel n'est câblé. Le vrai défaut trouvé pendant la stabilisation : le bouton d'upload
restait fonctionnel côté portail hôtel (`support-portal.html`) sans jamais prévenir l'usager
que le fichier envoyé ne sera jamais consultable. Corrigé par la **stratégie A** (upload
désactivé côté UI hôtel, message « Pièces jointes bientôt disponibles ») — cohérente avec
l'architecture déjà honnête du backend, sans introduire un nouveau mode d'accès aux fichiers
non scannés (la stratégie B envisagée dans l'instruction de stabilisation n'a pas été retenue).
Les Edge Functions d'upload restent déployées et fonctionnelles pour réactivation future.

Ajout de `admin_delete_support_ticket_attachment(p_attachment_id, p_reason)` — suppression
logique réservée au staff Support, motif obligatoire, journalisée. Comble un manque réel :
les colonnes `deleted_at`/`deleted_by`/`deletion_reason` existaient déjà dans `sql/86` sans
aucune RPC pour les utiliser. Périmètre assumé : pas d'auto-retrait par l'uploader hôtel dans
une fenêtre de 15 minutes (§3.5.8 v1) — sans utilité tant que l'upload hôtel reste désactivé
par la stratégie A ; à construire quand l'upload sera réactivé.

### 9.5 Doctrine trois états — `sql/85` et `sql/86`

`CREATE TABLE IF NOT EXISTS` masquerait silencieusement toute divergence de schéma sur un
replay. Remplacé dans `sql/85` (`support_ticket_replies`) et `sql/86`
(`support_ticket_attachments`, `support_ticket_attachment_access_log`) par : absent →
création complète ; présent et conforme (colonnes, contraintes avec prédicat exact vérifié
contre le rendu réel de `pg_get_constraintdef()` en production, index, commentaire,
propriétaire) → no-op ; présent et divergent → `RAISE EXCEPTION`, aucune correction
automatique. Validé en production via `BEGIN...ROLLBACK`, les trois états couverts. Une
divergence a été trouvée et corrigée pendant cette validation elle-même (rendu canonique réel
d'un prédicat CHECK différent de ce qui avait été deviné) — preuve que la vérification stricte
a une valeur réelle, pas seulement théorique.

### 9.6 Lot 6 — score de santé : déviations assumées par rapport aux rounds 1–4

Trois écarts entre ce que ce document (rounds 1–4, §3.4) envisageait et ce qui a été
implémenté (`sql/87`), documentés ici comme des déviations **raisonnées**, jamais des
substitutions silencieuses :

- **Pondération** : ce document envisageait Adoption 20/Activité 20/Licences 15/Support
  15/Paiement 15/Rétention 15 (总 100). L'implémentation utilise Adoption 20/Activité
  20/Licences 20/Support 15/Rétention 15/Paiement 10. Choix fait pendant l'implémentation,
  non reporté ici avant ce round — à traiter comme provisoire (`weights_provisional: true`
  dans la réponse JSON), pas une vérité métier définitive.
- **Donnée manquante** : ce document envisageait de neutraliser un sous-score indisponible à
  100 (« absence de donnée ≠ mauvais signal », explicitement un pis-aller « tant que non
  livrés »). L'implémentation **exclut et renormalise** plutôt que de neutraliser — un
  sous-score indisponible (`available: false`) est retiré du calcul, jamais remplacé par une
  valeur par défaut. Ce choix a été fait en application d'instructions CTO ultérieures, plus
  strictes sur l'anti-fabrication de données, reçues après ce round 4 et qui priment sur la
  doctrine V1 ici — neutraliser à 100 aurait fabriqué un signal positif inexistant sur des
  hôtels sans historique (Support, Paiement).
- **Pas de persistance** : ce document envisageait `platform_metrics_daily` +
  `admin_recompute_platform_metrics` + `admin_platform_metrics_series` (historique, recalcul
  manuel). L'implémentation est un calcul à la volée pur, zéro persistance — plus simple,
  cohérent avec le précédent `admin_platform_overview_kpis` (Lot 5), mais architecturalement
  différent : aucun historique de série temporelle n'est disponible aujourd'hui.

**Source unique de calcul licences** (item 9 de la passe de stabilisation) : la duplication à
l'identique du calcul quota/consommation (`rooms.active`, `user_hotels`/`users.is_active`,
`snapshot_limits`, seuil 90 %), présente dans 4 endroits écrits indépendamment sur des
branches non empilées (`admin_list_license_usage()` et `admin_platform_alerts()` de `sql/83` ;
`admin_platform_statistics()` et `_hotel_health_subscores()` de `sql/87`, via l'ancien helper
dupliqué `_hotel_license_usage_rows()`), a été éliminée par `sql/89` :
`public._hotel_license_usage_snapshot()`, source unique strictement interne (aucun `GRANT
EXECUTE`, y compris `service_role`), utilisée par les 4 consommateurs. Validé en production
via `BEGIN...ROLLBACK` sur un hôtel réel avec quota chiffré : les 4 consommateurs retournent
une interprétation identique avant et après le passage à la source unique.

### 9.7 Idempotence des notifications d'essai — correction du cycle réel

Ce document (§391, round 1) mandatait `dedupe_key = 'trial:<subscription_id>:{7,3,1}'` — un
palier PAR ABONNEMENT, jamais un cycle d'échéance réel. Une prolongation ou un
raccourcissement de `trial_ends_at` après un premier envoi ne redonnait alors jamais lieu à un
nouveau J-7/J-3/J-1 pour la nouvelle date. Corrigé dans `sql/84` : la clé intègre désormais
`trial_ends_at` normalisé en jour civil Europe/Paris (même calcul que `days_remaining`, pour
ne jamais diverger de la fenêtre d'éligibilité). Validé en production via
`BEGIN...ROLLBACK` (8 scénarios : premier envoi, non-doublon, prolongation, raccourcissement,
transition de statut, bord de fuseau Europe/Paris — tous PASS). Cet écart par rapport au
format §391 ci-dessus est assumé ; le format initial est obsolète et remplacé par celui décrit
ici.

### 9.8 Notifications — parcours d'envoi réel : état à date de ce document

`admin_run_trial_ending_notifications()`, `admin_update_support_ticket()` et
`admin_reply_support_ticket()` insèrent une ligne `platform_notifications` (statut `pending`),
idempotente par `dedupe_key`. Aucune de ces trois RPC n'invoque l'Edge Function
`platform-send-notification` — le passage `pending` → `sending` → `sent`/`failed`/`retry`/
`abandoned` n'est aujourd'hui déclenché par aucun mécanisme automatique ni action manuelle
existante. L'Edge Function elle-même (garde de concurrence par `UPDATE ... WHERE
status='pending'`, retries bornés avec backoff, `x-internal-key`, registre de templates
versionné) est écrite et son code a été relu, mais son exécution réelle (déploiement hors
production, appel HTTP réel, vérification des transitions de statut) n'a pas pu être
démontrée dans cette passe — une branche de développement Supabase (ressource facturée à
l'heure) était nécessaire pour un test réel hors production, et sa création a été soumise à
validation explicite avant d'engager une dépense récurrente sur l'organisation, conformément à
la politique de confirmation des actions coûteuses. Voir le rapport CTO final pour l'état de
cette décision au moment de la remise de ce document. Le dispatcher manuel par lots (batch
borné, `SKIP LOCKED`, comptage sent/failed/retried/abandoned) n'existe pas encore.

### 9.9 Motif récurrent — default privileges Supabase

Trouvé et corrigé indépendamment **quatre fois** dans cette Phase 2 (`sql/83`, `sql/84`,
`sql/85`, `sql/86` avant merge) : `ALTER DEFAULT PRIVILEGES` du rôle `postgres` sur le
schéma `public` accorde automatiquement `EXECUTE` sur toute nouvelle fonction et
`arwdDxtm` (tout DML) sur toute nouvelle table à `anon`/`authenticated`/`service_role`. Sans
un `REVOKE ALL ... FROM PUBLIC, anon, [authenticated,] service_role` explicite avant chaque
`GRANT` ciblé, toute nouvelle fonction ou table de cette Phase 2 aurait une fuite de privilège
par défaut. Devenu une règle standing pour tout objet neuf, y compris `sql/88` et `sql/89`
(passe de stabilisation).

### 9.10 Écran de divergence des droits

Aucune nouvelle migration. `admin_rights_divergence_report()` existe en production depuis
Phase 2A (`sql/70`, déjà mergé sur `main`, déjà granté à `authenticated`, déjà gated par
`is_platform_admin()`). Écran 100 % frontend, strictement en lecture seule : le mode
`enforce` du résolveur sous-jacent (`admin_resolve_app_access`) reste verrouillé en dur
(`RAISE EXCEPTION`, cf. ADR-010 §1) — aucune réparation automatique, silencieuse ou non,
n'est possible depuis cet écran ni ailleurs tant que ce verrou n'est pas levé par une décision
CTO explicite.

### 9.11 Dette de reconstruction du socle Super Admin — non corrigée dans cette Phase 2

`db/reconstruct/` (mécanisme de reconstruction depuis Git seul, sur instance PostgreSQL
vierge) couvre **exclusivement le périmètre pilote** (déplacement inter-hôtels, moteur
d'heures segments, garde-fou paie — `00_bootstrap.sql` à `sql/54`). **Aucun objet du portail
Super Admin (`sql/68` à `sql/89`, Phase 1 et Phase 2 entières) n'est couvert par ce
mécanisme.**

**Impact réel** : une reconstruction from-scratch de la base ne recrée aujourd'hui ni
`hotel_subscriptions`, ni `platform_admins`, ni `support_tickets`/`support_ticket_replies`/
`support_ticket_attachments`, ni `platform_notifications`, ni aucune RPC `admin_*` du portail
Super Admin. Le job CI « DB — reconstruction dépôt + tests » (vérifié vert sur toutes les PR
de cette Phase 2) ne teste que le périmètre pilote — **il ne prouve pas la reconstructibilité
du socle Super Admin**, malgré son nom.

**Non corrigée dans cette Phase 2**, par choix assumé : construire un mécanisme de
reconstruction propre pour ~22 fichiers couvrant 6+ domaines fonctionnels (facturation,
support, notifications, licences, statistiques) est un chantier à part entière, comparable en
ampleur à `db/reconstruct/` lui-même — le faire correctement dans le temps de cette Phase 2
aurait signifié soit le bâcler (stubs non exécutables, la dette originelle que
`db/reconstruct/` a justement fermée une première fois), soit retarder la livraison
fonctionnelle demandée.

**Plan de traitement recommandé** (PR dédiée, hors Phase 2) :
1. Inventorier tous les objets bootstrappés directement en production sans jamais être passés
   par une migration versionnée pour le domaine Super Admin (même anti-pattern déjà documenté
   deux fois dans ce dépôt pour `hotels`/`hotel_groups`/`platform_admins` — probablement pas
   isolé à ces trois tables).
2. Étendre `db/reconstruct/` avec un nouveau fichier ordonné (ex. `40_super_admin_
   foundation.sql`) rejouant `sql/68` à `sql/89` dans l'ordre, sur le modèle exact de
   `10_foundation.sql`/`30_functions.sql`.
3. Ajouter un job CI dédié (ou étendre le job existant) qui reconstruit ce périmètre sur une
   instance vierge et rejoue les suites `sql/tests/*` de la Phase 2.
4. Ne pas renommer le job CI actuel tant que ce travail n'est pas fait — son nom
   (« reconstruction dépôt ») est aujourd'hui trompeur sur son périmètre réel.

---

## Prochaine étape

Ce document (round 4) reste soumis pour validation finale. Conformément à l'instruction reçue,
aucun développement n'est démarré et aucune PR technique n'est ouverte avant autorisation
explicite — y compris pour le Lot 1 PR-01 (rétro-versionnement), qui ne modifie pourtant le
comportement d'aucun système existant. Dès validation, l'ordre d'exécution est : Lot 1
(PR-01 → PR-02) → Lot 2 → Lot 3 → Lot 4 → Lot 5 (PR-06 → PR-07) → Lot 6 → Paiements (note §3.1
maintenue à jour, pas de code).
