# ADR-012 — Phase 2 du Super Admin : plateforme SaaS de gestion commerciale et opérationnelle

**Statut** : Round 3 — **Phase 2 officiellement lancée par décision CTO** (2026-07-30), structurée
en **6 lots** dans un ordre imposé, plus un chantier Paiements explicitement reporté. Ce round
intègre les décisions de lancement reçues telles quelles. **Toujours en attente de validation
finale avant tout développement** — y compris le Lot 1, qui ne modifie pourtant le comportement
d'aucun système existant. Aucune migration, aucune RPC, aucun code frontend n'a été écrit à ce
stade, à aucun round.

**Portée** : six lots, dans l'ordre de développement imposé par le CTO — Lot 1 (fondations
Support), Lot 2 (`platform_notifications`), Lot 3 (Licences), Lot 4 (Essais), Lot 5 (Support —
back-office puis portail hôtel), Lot 6 (Statistiques). Paiements reporté, note d'architecture
métier seule dans ce round.

**Ce qui change dans ce round (round 2 → round 3)** :
1. Le document est réorganisé selon la structure en **6 lots** communiquée par le CTO, dans
   l'ordre exact demandé — les fiches PR du §6 sont regroupées et renumérotées en conséquence
   (voir table de correspondance round 2 → round 3 en tête de §6). Aucune migration n'ayant
   jamais été appliquée sous les anciens numéros, cette renumérotation n'a aucun effet sur la
   production.
2. **Lot 4 (Essais)** est complété : trois paliers de notification explicites (J-7/J-3/J-1),
   une RPC de prévisualisation et une RPC d'exécution manuelle au prédicat strictement
   identique — absent du round 2, qui ne spécifiait qu'un palier générique (§3.3).
3. **Lot 5 (Support)** est scindé, comme demandé, en **deux PR strictement indépendantes** —
   back-office (triage, assignation, priorité, **réponses**) et portail hôtel (création,
   **suivi**, **pièces jointes**). Les réponses et les pièces jointes n'existaient pas au round
   2 (qui ne couvrait que le triage de statut) : nouvelles tables `support_ticket_replies` et
   `support_ticket_attachments`, nouveau bucket Storage — §3.5.8/§3.5.9.
4. **Lot 6 (Statistiques)** reçoit la définition formelle du **score de santé plateforme**,
   laissée en suspens au round 2 (« inchangé depuis le round 1 », jamais redétaillée) — §3.4.
5. **Règle transverse ajoutée par le CTO** : chaque fiche PR doit désormais couvrir
   explicitement 8 champs obligatoires — objectif, dépendances, migration, **reconstruction**,
   tests, rollback, **smoke test**, **documentation**. Les deux premiers étaient déjà couverts
   implicitement (tests incluait parfois la reconstruction) ; les trois nouveaux sont désormais
   des champs séparés et systématiques dans toutes les fiches du §6 — voir gabarit en tête de
   §6.
6. **Paiements** : confirmé reporté. La note d'architecture métier demandée par le CTO
   (qui facture, hôtel ou groupe, périodicité, TVA, prorata, avoirs, remboursements,
   résiliation, export comptable) est déjà le contenu du §3.1 depuis le round 1 — ce round
   la reconfirme comme le livrable attendu et n'ajoute aucun choix de prestataire ni aucune
   migration.
7. **Supervision avancée** (round 2 §2.6/§3.6, PR-11 « CMS + Sentry ») **ne fait pas partie
   des 6 lots communiqués par le CTO pour ce lancement.** Ce n'est pas un retrait de contenu —
   la matière reste documentée en annexe (§8) — mais elle sort du plan actif tant qu'elle n'est
   pas explicitement reprogrammée. Aucun numéro de migration ne lui est réservé dans ce round.

---

## 0. Méthode

Round 1 : audit factuel par 5 recherches parallèles + lecture directe des ADR/RC1/roadmap.
Round 2 : introspection complémentaire ciblée sur `support_tickets`/`help_articles` et un test
d'intrusion réel exécuté en base (§2.5.4, inchangé, non rejoué dans ce round).
Round 3 (cette révision) : aucune nouvelle introspection de l'existant n'était nécessaire pour
les Lots 1 à 3 et 6 (l'état de production n'a pas changé depuis le round 2, hors la fusion de la
PR #20 — correctif frontend pur, sans aucune migration, sans effet sur ce périmètre). Pour les
Lots 4 et 5, introspection ciblée effectuée : recherche exhaustive de tables `%ticket%`/
`%reply%`/`%message%`/`%attachment%` existantes (résultat : aucune table de réponses ni de
pièces jointes pour `support_tickets` — confirme que ce sont de vraies additions, pas une
duplication) et inventaire des buckets Storage existants (`communication-attachments`,
`contracts`, `hr-documents`, `hr-templates`, `portal-documents` — aucun dédié au Support), pour
concevoir §3.5.8/§3.5.9 par cohérence avec les patterns déjà en production (`ota_dispute_messages`/
`ota_dispute_attachments`, `communication_attachments`) plutôt que par improvisation.

---

## 1. Doctrine héritée de la Phase 1 (inchangée, à respecter à l'identique)

- **ACL des RPC `admin_*`** : `SECURITY DEFINER`, `SET search_path TO 'public','pg_temp'`,
  garde interne (`IF NOT public.is_platform_admin() THEN RAISE EXCEPTION ... '42501'`), puis
  `REVOKE ALL ... FROM PUBLIC, anon, service_role` + `GRANT EXECUTE ... TO authenticated`.
  Helpers internes (`_`-préfixés) : aucun grant client.
- **Audit** : `platform_logs` via `_platform_log()` (admin) ou `_platform_log_system()`
  (système/trigger/cron) ; table événementielle métier dédiée quand un cycle de vie le
  justifie.
- **Tables sensibles / soft-delete** : jamais de `DELETE` sur une entité journalisée. Étendu
  dans ce round aux tables conversationnelles (§3.5.8) : une réponse de ticket est elle-même
  une entité journalisée par nature — **append-only**, aucune policy `UPDATE`/`DELETE`.
- **Tests** : `sql/tests/<domaine>.sql`, `BEGIN` / fixtures `pg_temp.zz_*` / blocs
  `DO $$...EXCEPTION WHEN OTHERS...END $$` / `RAISE EXCEPTION` si FAIL / `ROLLBACK`.
- **Nommage migrations** : `sql/NN_<domaine>_<description>.sql`. Dernier existant : `sql/79`.
  **La Phase 2 commence à `sql/80`.**
- **Numérotation ADR** : dernier existant `ADR-011`. Ce document est **ADR-012**.
- **Doctrine cron** (ADR-010 §3) : jamais activé dans la même migration que la fonctionnalité.
  Migration séparée + validation CTO explicite et distincte. **Confirmé par le lancement de ce
  round : le cron reste désactivé pour le Lot 4** (instruction explicite du CTO).
- **Leçon du P0 (PR #18)** : toute action de traitement par lot doit exposer une RPC de
  prévisualisation dont le prédicat est strictement identique à celui de l'exécution. **Ce
  round applique ce principe explicitement au Lot 4** (§3.3) — c'est la même doctrine que
  `admin_preview_expired_trials_processing`/`admin_run_expired_trials_processing`, réappliquée
  aux notifications d'essai.
- **Principe du moindre privilège** : un écart entre grants et RLS ne se corrige qu'après avoir
  démontré, par un test réel, ce que l'écart permet effectivement — jamais par supposition.
  Voir §2.5.4.
- **Doctrine snapshot** (déjà appliquée aux factures — `bill_to_*`) : reprise pour
  `platform_notifications.recipient_email`/`template_payload` (round 2, inchangé) et pour
  `support_ticket_replies.author_label` (nouveau, round 3, §3.5.8) — un auteur ou destinataire
  historique ne doit jamais dépendre d'une résolution différée par jointure.

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
notification avant expiration — c'est précisément l'objet du Lot 4 (§3.3).

### 2.4 Statistiques — inchangé depuis le round 1

`admin_platform_overview_kpis`/`admin_platform_alerts`/`admin_rights_divergence_report`
(`sql/76`). Aucun agrégat ni série temporelle — tout est recalculé à la volée. Pas de
MRR/ARR/churn réel, pas de delta période, pas de score de santé — c'est précisément l'objet du
Lot 6 (§3.4).

### 2.5 Support — inventaire technique complet (rétro-versionnement, Lot 1)

**Rappel du constat central** : `support_tickets` et `help_articles` existent réellement en
production (introspection directe de `hzrzkvdebaadditvbqis`) mais **ne sont versionnées dans
aucun fichier `sql/`**. C'est le même type de dette que celle déjà documentée par ADR-011 pour
d'autres objets bootstrappés hors migration. C'est **le Lot 1, priorité absolue** de la Phase 2,
avant tout développement nouveau (voir §3.5, §6 — Lot 1).

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

**Note round 3** : la colonne `attachment_url text` (singulier) et le champ libre
`claude_response text` restent **inchangés par le rétro-versionnement** (Lot 1, à l'identique).
Le Lot 5 (§3.5.8/§3.5.9) les complète par des tables dédiées (pièces jointes multiples,
réponses structurées) sans les supprimer ni les réinterpréter — `attachment_url`/
`claude_response` restent lisibles pour l'historique des tickets créés avant le Lot 5.

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
**fait**, pas encore comme une recommandation de correction.

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
- `platform_admin_role()` — déjà existante, `STABLE SECURITY DEFINER`, retourne le `role` de
  l'admin connecté ou `NULL`.
- `is_platform_admin()` — déjà existante (ADR-009), réutilisée par les policies de
  `support_tickets` et par toutes les nouvelles RPC de ce document.
- **Aucune RPC `admin_*` ne référence ni `support_tickets` ni `help_articles`** — confirmé par
  recherche exhaustive. Le portail interagirait aujourd'hui, s'il était câblé, en accès table
  direct — ce qui contredit la doctrine RPC-only de la Phase 1 (§1). Le Lot 5 (back-office)
  introduit les premières RPC ; le Lot 5 (portail) évalue si l'accès table direct (RLS
  `support_insert`) reste suffisant ou si une RPC dédiée est préférable (§3.5.9).

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

**Test réel** (rôle Postgres `anon`, en transaction, annulée) :

| # | Action testée | Résultat observé | Interprétation |
|---|---|---|---|
| 1 | `SELECT` sur `help_articles` (anon) | 8 lignes visibles | Les 8 articles publiés sont lisibles — **conforme à la policy `is_published = true`**, comportement voulu par la clause elle-même |
| 2 | `SELECT` sur `help_articles` où `is_published = false` (anon) | 0 ligne visible | Les brouillons restent invisibles à un utilisateur non admin |
| 3 | `INSERT` sur `help_articles` (anon) | **Bloqué** — `42501 new row violates row-level security policy` | La RLS neutralise le grant table-level trop large |
| 4 | `UPDATE` sur un article publié (anon) | 0 ligne affectée (pas d'erreur, filtrage silencieux) | La RLS neutralise le grant ; comportement Postgres normal |
| 5 | `DELETE` sur un article publié (anon) | 0 ligne affectée | Idem |
| 6 | `SELECT` sur `support_tickets` (anon), avec une ligne marqueur insérée par `postgres` juste avant | 0 ligne visible malgré la ligne existante côté serveur | La RLS filtre intégralement — aucune fuite |
| 7 | `INSERT` sur `support_tickets` avec un `hotel_id` réel (anon) | **Bloqué** — `42501 new row violates row-level security policy` | Le `WITH CHECK` sur `user_hotels`/`auth.uid()` bloque toute insertion anonyme |
| 8 | `UPDATE` sur la ligne marqueur (anon) | 0 ligne affectée | Idem #4 |

**Conclusion, par la classification demandée** :

- **`support_tickets`** : *privilèges inutilement larges mais bloqués par RLS.* Aucune donnée
  n'est lisible ni modifiable par un utilisateur anonyme — testé, pas supposé.
- **`help_articles`, écriture** : *privilèges inutilement larges mais bloqués par RLS.*
- **`help_articles`, lecture des articles publiés** : *configuration conforme,* lecture
  publique volontaire d'un centre d'aide, aucune donnée sensible exposée.

**Verdict global : aucune exposition effectivement exploitable détectée.** Le durcissement
proposé en §3.5.1/§6 (Lot 1, PR-03) reste recommandé au nom du principe de moindre privilège,
**mais uniquement comme mesure de défense en profondeur**, dans une PR séparée du
rétro-versionnement à l'identique.

**Effet de bord du test, transparence complète** : la séquence `support_ticket_seq` a
probablement avancé d'une unité pendant le test — sans conséquence, sans donnée créée ni
exposée en production (vérifié après coup : `support_tickets` = 0 ligne, `help_articles` = 8
lignes inchangées, aucun titre `ANON*`).

#### 2.5.5 Comparaison dépôt / production

| Objet | Dans `sql/` | En production | Action |
|---|---|---|---|
| Table `support_tickets` | Absente | Présente (0 ligne) | À verser à l'identique (Lot 1) |
| Table `help_articles` | Absente | Présente (8 lignes publiées) | À verser à l'identique |
| Séquence `support_ticket_seq` | Absente | Présente | À verser à l'identique |
| 3 fonctions trigger (§2.5.3) | Absentes | Présentes | À verser à l'identique |
| 7 policies RLS (§2.5.4) | Absentes | Présentes | À verser à l'identique |
| Rôle `support_agent` dans `platform_admins.role` CHECK | Présent (`sql/73`) | Présent | Déjà cohérent, aucune action |
| `STUB_INFO.support` dans `admin.html:755` | — | — | Description inexacte (« lecture seule ») à corriger dans le Lot 5, pas dans le Lot 1 |
| Table `support_ticket_replies` | Absente | **Absente aussi** | Nouvelle création, Lot 5 (§3.5.8) — pas un rétro-versionnement |
| Table `support_ticket_attachments` | Absente | **Absente aussi** | Nouvelle création, Lot 5 (§3.5.9) — pas un rétro-versionnement |
| Bucket Storage `support-ticket-attachments` | Absent | **Absent aussi** | Nouvelle création, Lot 5 (§3.5.9) |

**Non liés, confirmés hors-sujet** : `portal_requests`/`portal_messages` (RH interne),
`aide.html` (statique, RH), `maintenance_tickets` (PMS/Housekeeping),
`ota_dispute_messages`/`ota_dispute_attachments`/`communication_attachments` (autres domaines,
réutilisés uniquement comme **référence de conception**, jamais comme dépendance — §3.5.8/§3.5.9).

### 2.6 Supervision avancée — hors périmètre de ce lancement (voir §8)

`admin_supervision_status()` honnête, `admin_list_platform_audit_log()`. Pas de monitoring
d'erreurs réel, pas d'historique d'incidents, `webhooks_configured` toujours `false`. **Ce
domaine ne fait pas partie des 6 lots communiqués pour ce lancement** — état inchangé, détail
technique conservé en annexe (§8), aucun développement prévu dans ce round.

### 2.7 Infrastructure transverse déjà disponible

Resend (`RESEND_API_KEY`, pattern `supabase/functions/sig-send`) — à réutiliser pour tout envoi
d'email Phase 2, jamais un second prestataire. Buckets Storage privés déjà en production comme
référence de pattern pour le Lot 5 (§3.5.9) : `hr-documents` (10 Mo, PDF/JPEG/PNG/HEIC/WEBP),
`portal-documents` (20 Mo, PDF/images/Word).

---

## 3. Architecture proposée, par lot

### 3.0 Fondation transverse — `platform_notifications` (Lot 2)

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
| `recipient_email` | `text NOT NULL` | Snapshot de l'adresse au moment de la création — jamais résolu dynamiquement à l'envoi |
| `template` | `text NOT NULL` | Identifiant du gabarit de contenu — le contenu HTML/texte vit dans l'Edge Function, versionné avec le code |
| `template_payload` | `jsonb NOT NULL DEFAULT '{}'` | Variables injectées dans le gabarit — snapshot au moment de la création |
| `status` | `text NOT NULL DEFAULT 'pending' CHECK IN ('pending','sending','sent','failed','abandoned')` | `sending` distingue explicitement « en cours d'envoi » de `pending` |
| `attempts` | `integer NOT NULL DEFAULT 0` | Nombre de tentatives d'envoi déjà effectuées |
| `max_attempts` | `integer NOT NULL DEFAULT 3` | Borne — au-delà, `status` passe à `abandoned` |
| `next_attempt_at` | `timestamptz` | `NULL` si pas de nouvelle tentative prévue ; sinon date/heure du prochain essai (backoff) |
| `last_error` | `text` | Message d'erreur de la dernière tentative échouée |
| `final_error` | `text` | Rempli seulement quand `status = 'abandoned'` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `processed_at` | `timestamptz` | Horodatage du dernier traitement |
| `sent_at` | `timestamptz` | Rempli uniquement en cas de succès effectif |
| `failed_at` | `timestamptz` | Rempli uniquement au passage en `abandoned` |

**Statuts et transitions** : `pending → sending → (sent | pending-avec-next_attempt_at | abandoned)`.
Jamais de transition directe `pending → sent` sans passer par `sending`.

**Concurrence** : le passage à `sending` se fait par un `UPDATE ... SET status='sending'
WHERE id = ? AND status = 'pending' RETURNING id` — aucun verrou consultatif nécessaire.

**Idempotence** : le `dedupe_key` inclut la valeur qui change — deux événements distincts
produisent deux clés distinctes ; une tentative de notifier deux fois le même événement échoue
sur `UNIQUE (dedupe_key)`, absorbée silencieusement (`ON CONFLICT (dedupe_key) DO NOTHING`).

**RLS et grants** : aucun accès client, ni `anon` ni `authenticated`. Uniquement `service_role`
(Edge Function) en écriture. `REVOKE ALL FROM PUBLIC, anon, authenticated`.

**Politique de rétention** : proposition — conserver 90 jours en table active, purge non
automatisée en V1 (chantier explicite ultérieur si le volume le justifie).

**Edge Function `platform-send-notification`** : point d'appel unique à Resend, `service_role`
uniquement, jamais invocable depuis le client. Marque `sending` avant l'appel réseau,
`sent`/`pending`+`next_attempt_at`/`abandoned` après, selon le résultat. **Journal d'envoi** :
la table elle-même (`status`/`attempts`/`sent_at`/`last_error`/`final_error`) constitue le
journal — pas de table séparée, pour ne jamais dissocier l'état d'une notification de son
historique de tentatives.

### 3.1 Paiements — décisions métier avant choix de prestataire (reporté)

**Confirmé par le lancement de ce round : ce chantier est reporté.** Le tableau ci-dessous
**est** la note d'architecture métier demandée par le CTO avant tout développement — déjà
produite depuis le round 1, reconfirmée ici comme le livrable attendu, sans qu'aucun choix de
prestataire ni aucune ligne de code ne soit ajouté dans ce round.

| Question | Contexte déjà existant | Statut |
|---|---|---|
| Client facturé : hôtel ou groupe ? | `hotel_subscriptions` a `UNIQUE(hotel_id)` — **un abonnement par hôtel**, pas par groupe. La facturation consolidée par groupe (roadmap #26) impliquerait une refonte du modèle. | **Non tranché** — la Phase 2 conserve par défaut la facturation par établissement sauf décision contraire explicite |
| Facturation consolidée ou par établissement ? | Découle directement de la ligne précédente | Par établissement, par défaut |
| Périodicité | `platform_invoices.period_start/period_end` existent déjà, génériques | **Non tranché** — mensuel, trimestriel, annuel ? |
| Engagement (durée minimale) | Aucune notion de durée d'engagement dans `hotel_subscriptions` aujourd'hui | **Non tranché** |
| Prorata (changement de plan en cours de période) | `admin_change_subscription_plan` applique le changement **immédiatement**, sans proratisation | **Non tranché** |
| TVA | `platform_invoices.tva_rate/tva_amount` déjà gérés (taux unique par facture) | Déjà couvert, sauf besoin de TVA multi-taux |
| Impayé | `admin_suspend_subscription_for_nonpayment` déjà existant | Déjà couvert |
| Suspension | `admin_suspend_subscription`/`admin_reactivate_subscription` déjà existants | Déjà couvert |
| Résiliation | `admin_cancel_subscription_immediate`/`admin_schedule_subscription_cancellation` déjà existants | Déjà couvert |
| Avoirs | `platform_credit_notes` déjà existant, jamais fusionné dans la facture | Déjà couvert |
| Remboursements | Aucun mécanisme aujourd'hui — un avoir documente une créance annulée, pas un flux d'argent sortant réel | **Non tranché** — dépend directement du choix de prestataire |
| Export comptable | Rien n'existe aujourd'hui (pas de format FEC, pas d'export) | **Non tranché**, à cadrer séparément |
| Source de vérité | `platform_invoices`/`platform_payments` = source de vérité de la facturation ; `hotel_subscriptions` = source de vérité de l'accès/droit, volontairement distincte | Déjà couvert |

**Position de cet ADR** : ne pas construire d'abstraction multi-prestataires en V1. Détail
technique (`platform_payment_intents`/`platform_payment_provider_events`) en §6 (PR-11),
volontairement non développé tant que le prestataire n'est pas choisi.

### 3.2 Licences — Lot 3 : observation, comptage et alertes uniquement

Confirmé par décision CTO (§5) et reconfirmé par ce lancement : **aucun blocage automatique en
V1.** `admin_list_license_usage()` (comptage réel vs `snapshot_limits`) + nouveau type d'alerte
`license_quota_exceeded` dans `admin_platform_alerts()`. Aucune nouvelle table. Ne touche jamais
`hotel_app_subscriptions`.

### 3.3 Essais — Lot 4 : notifications J-7/J-3/J-1, preview, run manuel, cron désactivé

**Confirmé par le lancement de ce round** : trois paliers de notification explicites, une RPC
de prévisualisation, une RPC d'exécution manuelle — **le cron reste désactivé**, cohérent avec
ADR-010 §3 et avec la doctrine « jamais de cron dans la même migration que la fonctionnalité ».

**Paliers** : J-7, J-3, J-1 avant `hotel_subscriptions.trial_ends_at` (essais actifs
uniquement, `status = 'trial'`). Chaque palier produit un `dedupe_key` distinct —
`trial:<subscription_id>:7`, `trial:<subscription_id>:3`, `trial:<subscription_id>:1` — de sorte
qu'un même essai reçoit au plus une notification par palier, jamais une répétition à chaque
exécution manuelle.

**Prédicat partagé** (doctrine P0, réappliquée ici) : preview et exécution interrogent
**exactement** la même requête — `hotel_subscriptions` en `status = 'trial'`, où
`trial_ends_at::date - current_date` vaut 7, 3 ou 1, et où le `dedupe_key` correspondant n'existe
pas encore dans `platform_notifications`. Seule diffère l'action finale : `SELECT` pour la
preview, `INSERT ... ON CONFLICT (dedupe_key) DO NOTHING` pour l'exécution.

- **`admin_preview_trial_ending_notifications()`** — lecture seule, retourne pour chaque essai
  concerné : hôtel, palier (7/3/1), `trial_ends_at`, email destinataire résolu, et si une
  notification pour ce `dedupe_key` existe déjà (auquel cas elle est listée comme « déjà
  envoyée », pas comme « à envoyer » — même logique de transparence que
  `admin_preview_expired_trials_processing`).
- **`admin_run_trial_ending_notifications()`** — même prédicat, insère réellement dans
  `platform_notifications` (`category = 'trial_ending'`, `template = 'trial_ending_soon'`),
  retourne le nombre de notifications effectivement créées (les doublons silencieusement
  absorbés par `ON CONFLICT` ne comptent pas comme des échecs).

**Déclenchement** : bouton admin manuel en V1 (dashboard ou écran Abonnements), **pas de cron**
— strictement identique en esprit à « Traiter les essais expirés », qui reste lui aussi 100 %
manuel après le P0.

### 3.4 Statistiques — Lot 6 : définitions formelles, y compris score de santé plateforme

Toutes les métriques ci-dessous partagent : **fuseau horaire proposé Europe/Paris** pour la
définition du « jour métier » — **à confirmer explicitement par le CTO**. **Fréquence de calcul
V1 : à la demande** (`admin_recompute_platform_metrics`, pas de cron, cohérent avec le Lot 4).
**Recalcul historique** : la RPC accepte une date passée et reconstitue l'état à cette date à
partir de `hotel_subscription_events` (event-sourcing) — condition nécessaire pour que
`platform_metrics_daily` reste corrigible sans jamais retoucher silencieusement une ligne déjà
écrite.

| Métrique | Source | Formule | Traitement annulations/avoirs/changements de plan |
|---|---|---|---|
| **MRR contractuel** | `hotel_subscriptions` (`status='active'`) + `snapshot_price` + `hotel_addon_subscriptions` actifs | Somme des prix récurrents figés des abonnements actifs à la date calculée | Résiliation/suspension sort immédiatement le montant à sa date d'effet réelle ; changement de plan applique le nouveau `snapshot_price` sans proratisation ; avoirs sans effet (indépendant de la facturation réelle) |
| **MRR facturé** | `platform_invoices` (`status='issued'`) | Montant HT des factures émises sur la période, ramené à une base mensuelle si périodicité ≠ mensuelle | Reflète la facturation réelle, peut diverger du contractuel |
| **MRR encaissé** | `platform_payments` (`status='recorded'`) | Somme des paiements enregistrés dans le mois (comptabilité de caisse) | Un avoir réduit le montant net du mois d'émission de l'avoir (proposition par défaut, à confirmer CTO) |
| **ARR** | Dérivé du MRR contractuel | `MRR contractuel × 12` | Recalculé à chaque recalcul du MRR contractuel |
| **Churn logo** | `hotel_subscription_events` (résiliations) | Hôtels résiliés (pas suspendus) sur la période ÷ hôtels actifs en début de période | Ne compte que la résiliation définitive |
| **Churn revenu** | `hotel_subscription_events` + `snapshot_price` avant/après | MRR contractuel perdu (résiliations + rétrogradations) ÷ MRR contractuel en début de période | Distinct du churn logo |
| **Conversion des essais** | `hotel_subscription_events` (conversion, écrit par `admin_convert_trial_to_active`) | Essais convertis ÷ (essais convertis + essais expirés) sur la période | — |
| **Hôtels actifs** | Réutilise **exactement** la définition déjà utilisée par `admin_platform_overview_kpis` | — | Pas de seconde définition — évite deux chiffres divergents |
| **Utilisateurs actifs** | Idem — réutilise la définition existante | — | Idem |
| **Score de santé plateforme** (nouveau, round 3) | Composite des 4 lignes ci-dessous | Voir détail immédiatement en dessous | Recalculé à chaque `admin_recompute_platform_metrics` |

**Score de santé plateforme — définition formelle (proposition V1, à valider explicitement par
le CTO — absente du round 2)**. Objectif : un seul indicateur 0–100 pour le dashboard, composé
de signaux déjà produits ailleurs dans ce document, sans inventer de nouvelle source de donnée :

| Sous-score | Poids | Calcul | Source |
|---|---|---|---|
| Rétention | 40 % | `100 − (churn_logo_période × 100)`, plancher 0 | Churn logo (ligne ci-dessus) |
| Croissance MRR | 25 % | `(MRR_contractuel_période − MRR_contractuel_période_précédente) / MRR_contractuel_période_précédente`, normalisé sur `[-1;+1] → [0;100]`, borné | MRR contractuel (ligne ci-dessus) |
| Support | 20 % | `100 − (tickets ouverts depuis plus de 5 jours ouvrés parmi les tickets non `resolu`/`ferme` ÷ tickets ouverts total × 100)` | `support_tickets` (Lot 5) |
| Conformité licences | 15 % | `100 − (hôtels avec alerte `license_quota_exceeded` active ÷ hôtels actifs × 100)` | Alertes Lot 3 |

`score = 0.40×Rétention + 0.25×CroissanceMRR + 0.20×Support + 0.15×Licences`, arrondi à
l'entier. **Dépendance explicite** : ce sous-score ne peut être calculé qu'une fois les Lots 3,
5 et 6 tous livrés (il agrège leurs signaux) — voir dépendances de la fiche PR-09 en §6. Tant
que le Lot 5 n'est pas livré, le sous-score Support est traité comme `100` par défaut (aucun
signal disponible ≠ mauvais signal) — même logique que les signaux honnêtes déjà appliqués à
`admin_supervision_status()`.

Score de santé hôtel (round 1, inchangé, hors périmètre v1), rapport de divergence de droits
(frontend seul, inchangé), anomalies et facturation consolidée par groupe (hors périmètre v1,
inchangé).

### 3.5 Support — Lot 1 (fondation) et Lot 5 (fonctionnalités, 2 PR indépendantes)

**3.5.1 — Rétro-versionnement à l'identique** (Lot 1, aucun changement de comportement) : verse
dans `sql/80_...` la reproduction exacte de l'existant décrit en §2.5.1/§2.5.2/§2.5.3 — tables
(`CREATE TABLE IF NOT EXISTS`, colonnes et types identiques), toutes les contraintes listées,
tous les index, tous les triggers et leurs fonctions, la séquence, les 7 policies RLS mot pour
mot, **et les grants actuels reproduits tels quels**. Objectif unique : que `sql/` décrive
exactement ce qui tourne en production, ni plus ni moins.

**3.5.2 — Tests de reconstruction** (Lot 1) : fichier `sql/tests/support_retro_versioning.sql`
qui (a) reconstruit le schéma depuis zéro dans une transaction et vérifie qu'il est identique à
ce qui est observé en production ; (b) rejoue le test de rôle `anon` du §2.5.4 de façon
versionnée et répétable ; (c) vérifie que les `INSERT`/`UPDATE` d'un utilisateur hôtel lié via
`user_hotels` fonctionnent bien sur ses propres tickets et échouent sur ceux d'un autre hôtel.

**3.5.3 — Durcissement ACL, si nécessaire** (Lot 1, PR distincte, justifiée par le §2.5.4) :
`REVOKE ALL ... FROM anon` sur les deux tables et sur la séquence (garde `authenticated`). Ne
change **aucune** policy RLS.

**3.5.4 — RPC de triage, assignation, priorité** (Lot 5, PR A — back-office) :
`admin_list_support_tickets`, `admin_get_support_ticket_detail` (inclut désormais le fil de
réponses non internes + internes, §3.5.8), `admin_update_support_ticket` (statut, priorité,
`assigned_to`), chaque mutation journalisée via `_platform_log`, correction de
`STUB_INFO.support`.

**3.5.5 — RPC réponses back-office** (Lot 5, PR A, nouveau détail round 3) :
`admin_reply_support_ticket(ticket_id, body, is_internal_note)` — insère dans
`support_ticket_replies` (§3.5.8) avec `author_type = 'super_admin'`. Si `is_internal_note =
false`, insère en plus une notification `platform_notifications`
(`category = 'support_ticket_update'`, `dedupe_key = 'support:<ticket_id>:reply:<reply_id>'`) à
destination de `support_tickets.user_email` — réutilise le Lot 2. Si `is_internal_note = true`,
aucune notification (note strictement interne, jamais visible côté hôtel).

**3.5.6 — Création de ticket, suivi et pièces jointes côté hôtel** (Lot 5, PR B — portail
hôtel, décidée distincte de PR A, livrée après) : point d'entrée dans `index.html`/`portal.html`
permettant à un utilisateur hôtel de créer un ticket, de consulter le fil de ses propres
tickets (« suivi », réutilise `support_select`/nouvelle policy de lecture sur
`support_ticket_replies` où `is_internal_note = false`), et d'ajouter des pièces jointes
(§3.5.9). Accès table direct conservé pour la création (RLS `support_insert` déjà suffisante,
confirmée par le test §2.5.4) ; une RPC `hotel_reply_support_ticket(ticket_id, body)` est en
revanche nécessaire pour les réponses hôtel (garantit `author_type = 'hotel_user'` et
déclenche la notification symétrique vers le Super Admin assigné — voir §3.5.8, RLS
« append-only » qui interdit toute correction a posteriori d'une réponse, cohérente avec un
accès table direct mais plus sûre en RPC pour fixer `author_type` et `author_label` côté
serveur plutôt que de faire confiance à la valeur envoyée par le client).

**3.5.7 — Notification de création/changement de statut** : inchangé depuis le round 1/2,
réutilise §3.0 — `category = 'support_ticket_new'` à la création, `support_ticket_update` au
changement de statut (déjà couvert), et maintenant aussi à chaque réponse (§3.5.5/§3.5.6).

**3.5.8 — `support_ticket_replies` (nouveau, round 3)** — schéma détaillé, conçu par cohérence
avec `ota_dispute_messages` déjà en production :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `ticket_id` | `uuid NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE` | |
| `author_type` | `text NOT NULL CHECK IN ('super_admin','hotel_user')` | |
| `author_user_id` | `uuid NOT NULL REFERENCES auth.users(id)` | |
| `author_label` | `text NOT NULL` | Snapshot email/nom au moment de la réponse — jamais résolu par jointure a posteriori (doctrine snapshot, §1) |
| `body` | `text NOT NULL CHECK (char_length(body) <= 4000)` | |
| `is_internal_note` | `boolean NOT NULL DEFAULT false` | Note strictement admin, jamais visible côté hôtel |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Contrainte** : `CHECK (NOT is_internal_note OR author_type = 'super_admin')` — une note
interne ne peut être créée que par un admin, jamais par un `hotel_user` (défense en profondeur,
en plus de la garde applicative dans `hotel_reply_support_ticket` qui ne permet même pas de
poser ce paramètre côté hôtel).

**RLS** : `platform_admin_full_replies` (`is_platform_admin()`, ALL) ;
`hotel_select_own_replies` (SELECT, `is_internal_note = false AND ticket_id IN (SELECT id FROM
support_tickets WHERE hotel_id IN (SELECT hotel_id FROM user_hotels WHERE user_id =
auth.uid()))`) ; pas de policy `INSERT` pour `authenticated` — **toute écriture passe par une
RPC** (`admin_reply_support_ticket`/`hotel_reply_support_ticket`), jamais par accès table
direct, pour garantir que `author_type`/`author_label` sont fixés côté serveur, pas par le
client. **Append-only** : aucune policy `UPDATE`/`DELETE`, pour quiconque, y compris admin —
une réponse envoyée fait partie de l'historique du ticket, elle ne se corrige pas, elle
s'complète par une nouvelle réponse.

**3.5.9 — `support_ticket_attachments` + bucket Storage (nouveau, round 3)** — schéma détaillé,
conçu par cohérence avec `communication_attachments`/`ota_dispute_attachments` déjà en
production, et avec le bucket privé `portal-documents` comme référence de configuration :

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `ticket_id` | `uuid NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE` | |
| `reply_id` | `uuid REFERENCES support_ticket_replies(id) ON DELETE CASCADE` | `NULL` si la pièce jointe est ajoutée à la création du ticket, renseigné si elle accompagne une réponse |
| `storage_bucket` | `text NOT NULL DEFAULT 'support-ticket-attachments'` | |
| `storage_path` | `text NOT NULL` | Convention `<hotel_id>/<ticket_id>/<uuid>-<filename>`, pour que la policy Storage puisse filtrer par préfixe sans jointure |
| `original_filename` | `text NOT NULL` | |
| `mime_type` | `text NOT NULL` | |
| `size_bytes` | `bigint NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760)` | Limite 10 Mo, alignée sur `hr-documents` |
| `uploaded_by` | `uuid NOT NULL REFERENCES auth.users(id)` | |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Bucket Storage `support-ticket-attachments`** : privé, `file_size_limit = 10485760`,
`allowed_mime_types` alignés sur `portal-documents` (PDF, JPEG, PNG, HEIC, WEBP, GIF, Word).
**Policies Storage** (écrites précisément pendant la PR, principe fixé ici) : upload/lecture
autorisés uniquement si le préfixe du chemin (`<hotel_id>/...`) correspond à un hôtel de
l'utilisateur (`user_hotels`) ou si l'appelant est `is_platform_admin()` — même logique de
filtrage par préfixe que les buckets existants du projet. **RLS table** (`support_ticket_attachments`) :
même structure que §3.5.8 (admin ALL, hôtel SELECT scoping par `ticket_id`/`hotel_id`, écriture
par RPC uniquement — `admin_add_support_ticket_attachment`/`hotel_add_support_ticket_attachment`
qui valident la ligne `storage.objects` correspondante existe avant d'insérer la ligne
métadonnée, pour ne jamais référencer un fichier qui n'a pas été effectivement uploadé).

### 3.6 Supervision avancée — hors périmètre de ce round (voir §8)

Non incluse dans les 6 lots communiqués par le CTO pour ce lancement. Contenu conservé sans
changement en annexe (§8), pour ne pas perdre la matière déjà produite au round 1/2.

---

## 4. Preuve de non-duplication

| Nouvelle brique | Lot | S'appuie sur | Ne duplique pas |
|---|---|---|---|
| Migration `sql/80` (rétro-versionnement) | Lot 1 | `support_tickets`/`help_articles` (schéma production, reproduit à l'identique) | Ne recrée rien — recopie ce qui existe, grants inclus |
| `REVOKE anon` (`sql/81`) | Lot 1 | Le test réel du §2.5.4 | Décision distincte du rétro-versionnement, justifiée par preuve |
| `platform_notifications` (`sql/82`) | Lot 2 | Rien d'existant — première file de notifications du projet | N'entre pas en collision avec Resend (reste le seul point d'envoi réel) |
| `admin_list_license_usage` (`sql/83`) | Lot 3 | `snapshot_limits`/`plan_modules` existants | Ne recrée aucune table de licence, lecture seule |
| `admin_{preview,run}_trial_ending_notifications` (`sql/84`) | Lot 4 | `hotel_subscriptions.trial_ends_at` existant + `platform_notifications` (Lot 2) | Ne touche jamais `hotel_app_subscriptions` (ADR-011), aucun cron |
| `support_ticket_replies`/`support_ticket_attachments` (`sql/85`, `sql/86`) | Lot 5 | `support_tickets` existant, patterns `ota_dispute_messages`/`communication_attachments` | N'étend pas `support_tickets` elle-même (append-only séparé), ne remplace pas `attachment_url`/`claude_response` déjà versionnés au Lot 1 |
| `platform_metrics_daily` (`sql/87`) | Lot 6 | `hotel_subscription_events`, `platform_invoices`, `platform_payments`, alertes Lot 3, tickets Lot 5 | Aucun recalcul de logique déjà exposée par `admin_platform_overview_kpis` pour hôtels/utilisateurs actifs |

---

## 5. Décisions CTO — statut après ce round

1. **Prestataire de paiement** — **toujours différé**, confirmé explicitement par ce
   lancement (Paiements reporté). Bloque toujours PR-11 (§6).
2. **Licences — alerte seule ou blocage réel ?** — **Tranché et reconfirmé : observation,
   comptage et alertes uniquement, aucun blocage automatique en V1** (Lot 3).
3. **Activation du cron essais expirés** — **Tranché et reconfirmé : non activé.**
4. **Cron dunning / recalcul quotidien des métriques** — cohérent avec la décision 3 :
   **aucun cron activé dans ce cycle**, tout reste à déclenchement manuel.
5. **Compte de monitoring d'erreurs (Sentry)** — **sans objet dans ce round** : la Supervision
   avancée n'est pas incluse dans les 6 lots communiqués (§8).
6. **Support — périmètre V1** — **Tranché et précisé par ce lancement : Lot 5 scindé en deux PR
   strictement indépendantes** — PR A back-office (triage, assignation, priorité, réponses),
   PR B portail hôtel (création, suivi, pièces jointes), PR B livrée après PR A.
7. **`platform_incidents` (#35, Could)** — **sans objet dans ce round**, non inclus dans les 6
   lots communiqués (§8).

**Nouvelles décisions actées par ce lancement (round 3)** :

8. **Lot 4 — 3 paliers de notification (J-7/J-3/J-1)** avec RPC `preview`/`run` au prédicat
   identique, cron toujours désactivé — détaillé §3.3, seule décision explicitement chiffrée
   par le CTO dans les instructions de lancement.
9. **Lot 5 — réponses et pièces jointes** ajoutées au périmètre (absentes du round 2, qui ne
   couvrait que le statut/assignation/priorité) — deux nouvelles tables + un bucket Storage,
   détaillé §3.5.8/§3.5.9.
10. **Lot 6 — score de santé plateforme** formellement défini (proposition V1, pondération à
    valider explicitement par le CTO — §3.4) — absent du round 2.
11. **Règle de fiche PR étendue** — chaque PR doit désormais documenter explicitement 8 champs :
    objectif, dépendances, migration, **reconstruction**, tests, rollback, **smoke test**,
    **documentation** — appliqué à toutes les fiches du §6.
12. **Ordre imposé confirmé** : Lot 1 → Lot 2 → Lot 3 → Lot 4 → Lot 5 (PR A puis PR B) → Lot 6 →
    Paiements (note seule, pas de développement).

**Décisions round 2 reconfirmées sans changement** : `platform_notifications` (schéma détaillé
§3.0), `hotel_app_subscriptions` (aucune nouvelle dépendance introduite par la Phase 2).

---

## 6. Plan de réalisation — PR détaillées, par lot, ordre imposé

**Gabarit obligatoire de fiche PR (round 3)** — chaque PR ci-dessous documente explicitement les
8 champs exigés par le CTO, dans cet ordre : **Objectif, Dépendances, Migration, Reconstruction,
Tests, Rollback, Smoke test, Documentation** — complétés par deux champs de contexte hérités du
gabarit round 2, **Fichiers concernés** et **Risques**, conservés car utiles à la revue mais non
exigés explicitement par le CTO.

**Table de correspondance round 2 → round 3** (renumérotation, aucune migration n'a jamais été
appliquée sous les anciens numéros — sans effet sur la production) :

| Round 2 | Round 3 | Changement |
|---|---|---|
| PR-00 | PR-00 | Inchangée |
| PR-01/02/03 (`sql/80`/`sql/81`) | Lot 1 — PR-01/02/03 | Inchangées, regroupées sous « Lot 1 » |
| PR-04 (`sql/82`) | Lot 2 — PR-04 | Inchangée |
| PR-05 (`sql/83`) | Lot 3 — PR-05 | Inchangée |
| PR-06 (`sql/84`) | Lot 4 — PR-06 | **Étendue** : 3 paliers + preview/run (§3.3) |
| PR-07 (`sql/85`, Statistiques) | Lot 6 — PR-09 (`sql/87`) | **Déplacée après le Lot 5** (ordre CTO), **étendue** avec le score de santé |
| PR-08 (écran divergence, frontend) | PR-10 | Inchangée, hors lot |
| PR-09 (`sql/86`, triage) | Lot 5 — PR-07 (`sql/85`) | **Renommée « Lot 5 PR A »**, **étendue** avec les réponses |
| PR-10 (création ticket hôtel) | Lot 5 — PR-08 (`sql/86`) | **Renommée « Lot 5 PR B »**, **étendue** avec suivi + pièces jointes |
| PR-11 (CMS + Sentry, Supervision) | Retirée du plan actif | Voir §8, non incluse dans les 6 lots communiqués |
| PR-12 (Paiements) | PR-11 | Renumérotée, toujours reportée |

### PR-00 — ADR-012 finalisée
- **Objectif** : obtenir la validation explicite de cette architecture, round 3, avant tout
  développement.
- **Dépendances** : aucune.
- **Migration** : aucune.
- **Reconstruction** : sans objet (document seul, aucun schéma modifié).
- **Tests** : aucun.
- **Rollback** : sans objet.
- **Smoke test** : sans objet.
- **Documentation** : ce document lui-même ; entrée `CHANGELOG.md` à ajouter au moment de la
  validation finale (pas avant, pour ne pas documenter une décision non encore actée).
- **Fichiers concernés** : `docs/adr/ADR-012-super-admin-phase2-plateforme-saas.md`.
- **Critères d'acceptation** : validation explicite reçue du CTO sur ce round 3.

### Lot 1 — Fondations Support (priorité absolue)

#### Lot 1 — PR-01 — Rétro-versionnement Support à l'identique
- **Objectif** : remettre `support_tickets`/`help_articles` sous contrôle du dépôt, sans aucun
  changement de comportement.
- **Dépendances** : PR-00.
- **Migration** : nouveau `sql/80_support_retro_versioning.sql` — `CREATE TABLE IF NOT EXISTS`
  (colonnes/contraintes/index identiques à §2.5.1/§2.5.2), recréation idempotente des 3
  triggers/fonctions, de la séquence, des 7 policies RLS, et des grants actuels reproduits tels
  quels.
- **Reconstruction** : la migration est ajoutée à la séquence rejouée par la reconstruction
  versionnée du dépôt ; le job CI « DB — reconstruction dépôt + tests » doit rester vert après
  ajout, avec ces deux tables désormais couvertes.
- **Tests** : application en transaction `ROLLBACK` sur la production réelle, vérification
  qu'aucun objet n'est recréé avec une définition différente de l'existant (comparaison DDL
  avant/après, `pg_get_functiondef`/`pg_get_constraintdef` identiques).
- **Rollback** : `DROP` des objets nouvellement créés si la migration a créé quoi que ce soit
  qui n'existait pas déjà (ne devrait rien créer de nouveau par construction, puisque
  `CREATE TABLE IF NOT EXISTS`).
- **Smoke test** : lecture réelle en production (comme pratiqué pour la PR #20) confirmant que
  `support_tickets`/`help_articles` restent interrogeables sans erreur après application.
- **Documentation** : entrée `CHANGELOG.md`, mise à jour de ce document marquant Lot 1 PR-01
  comme livré.
- **Fichiers concernés** : nouveau `sql/80_support_retro_versioning.sql`.
- **Risques** : très faible — la migration doit être un **no-op** en production.

#### Lot 1 — PR-02 — Tests de reconstruction et de RLS Support
- **Objectif** : garantir la non-régression future sur ces deux tables, versionner le test
  d'intrusion `anon` du §2.5.4.
- **Dépendances** : Lot 1 PR-01.
- **Migration** : aucune (fichier de test seul).
- **Reconstruction** : ce fichier **est** le test de reconstruction — exécuté par la CI dédiée
  à chaque modification future de ces deux tables.
- **Tests** : nouveau `sql/tests/support_retro_versioning.sql` — 8 scénarios `anon` (§2.5.4) +
  scénarios `authenticated` hôtel légitime (accès à ses propres tickets, refus sur ceux d'un
  autre hôtel) + scénario admin (accès complet).
- **Rollback** : sans objet (fichier de test, pas de modification durable).
- **Smoke test** : exécution du fichier en `BEGIN...ROLLBACK` sur la production réelle,
  confirmation zéro résidu après coup.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : nouveau `sql/tests/support_retro_versioning.sql`.
- **Risques** : aucun (lecture/écriture en transaction annulée).

#### Lot 1 — PR-03 — Durcissement ACL Support (si confirmé nécessaire)
- **Objectif** : appliquer le principe de moindre privilège sur `support_tickets`/
  `help_articles`, justifié par le test réel du §2.5.4.
- **Dépendances** : Lot 1 PR-01, PR-02.
- **Migration** : nouveau `sql/81_support_acl_hardening.sql` — `REVOKE ALL ... FROM anon` sur
  les deux tables + la séquence `support_ticket_seq`. Aucune policy RLS modifiée.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : rejeu du fichier PR-02, vérifiant que le résultat `anon` passe de « bloqué par
  RLS » à « bloqué par grant » (erreur différente, plus précoce).
- **Rollback** : `GRANT` inverse si un usage légitime d'`anon` était découvert a posteriori.
- **Smoke test** : `has_table_privilege('anon', 'support_tickets', 'INSERT')` = `false` vérifié
  directement en production après application, comportement `authenticated`/admin inchangé.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : nouveau `sql/81_support_acl_hardening.sql`.
- **Risques** : faible — aucun flux légitime ne passe aujourd'hui par `anon` sur ces tables.

### Lot 2 — Fondation `platform_notifications`
- **Objectif** : livrer la file de notifications transverse spécifiée en §3.0, utilisée par tous
  les domaines (Lot 4, Lot 5).
- **Dépendances** : PR-00.
- **Migration** : nouveau `sql/82_platform_notifications.sql` (schéma §3.0), `REVOKE ALL FROM
  PUBLIC, anon, authenticated`, grant `service_role` uniquement ; nouvelle Edge Function
  `supabase/functions/platform-send-notification/index.ts`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : insertion directe + appel de l'Edge Function en environnement de test (clé Resend
  de test), vérification de l'idempotence via `dedupe_key` (deux insertions avec la même clé →
  une seule ligne), vérification du passage `pending → sending → sent/abandoned`.
- **Rollback** : `DROP TABLE platform_notifications` si aucune brique n'en dépend encore (à
  vérifier avant tout rollback une fois les PR consommatrices — Lot 4, Lot 5 — mergées).
- **Smoke test** : idempotence démontrée par test réel (deux appels identiques, une seule
  notification effectivement envoyée), aucun accès `anon`/`authenticated` possible sur la
  table, vérifié directement.
- **Documentation** : entrée `CHANGELOG.md`, documentation de l'Edge Function.
- **Fichiers concernés** : `sql/82_platform_notifications.sql`,
  `supabase/functions/platform-send-notification/index.ts`.
- **Risques** : faible — aucune brique existante n'en dépend encore à ce stade.

### Lot 3 — Licences en observation
- **Objectif** : `admin_list_license_usage()` + alerte `license_quota_exceeded`, lecture seule.
- **Dépendances** : PR-00.
- **Migration** : nouveau `sql/83_admin_license_usage.sql` — nouvelle RPC
  `admin_list_license_usage()`, extension de `admin_platform_alerts()`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : scénarios avec un hôtel sous quota, un hôtel au-dessus, un hôtel sans limite
  définie (`snapshot_limits` vide).
- **Rollback** : `DROP FUNCTION admin_list_license_usage()`, retrait du nouveau type d'alerte.
- **Smoke test** : RPC appelée en production (lecture seule), résultat comparé à un comptage
  manuel de référence sur un hôtel connu.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `sql/83_admin_license_usage.sql`.
- **Risques** : faible — lecture seule, aucun blocage.

### Lot 4 — Notifications d'essai (J-7/J-3/J-1), cron désactivé
- **Objectif** : notifier un hôtel avant l'expiration de son essai, aux trois paliers, avec
  preview et exécution manuelle au prédicat identique — voir §3.3.
- **Dépendances** : Lot 2 (`platform_notifications`).
- **Migration** : nouveau `sql/84_trial_ending_notifications.sql` — RPC
  `admin_preview_trial_ending_notifications()` et `admin_run_trial_ending_notifications()`,
  prédicat partagé (§3.3). **Pas de cron.**
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : un essai à J-7/J-3/J-1 ne génère qu'une seule notification par palier (idempotence
  `dedupe_key`) ; preview et run retournent la même liste d'hôtels concernés avant exécution ;
  relance manuelle répétée ne produit aucun doublon.
- **Rollback** : `DROP FUNCTION` des deux RPC, aucune donnée `hotel_subscriptions` affectée
  (lecture seule sur cette table).
- **Smoke test** : preview appelée en production (lecture seule) sur les essais réels en cours,
  comparée manuellement à `trial_ends_at` de chaque hôtel concerné.
- **Documentation** : entrée `CHANGELOG.md`, section « Essais » de ce document marquée livrée.
- **Fichiers concernés** : `sql/84_trial_ending_notifications.sql`.
- **Risques** : faible.

### Lot 5 — Support (2 PR indépendantes)

#### Lot 5 — PR A — Back-office (triage, assignation, priorité, réponses)
- **Objectif** : `admin_list_support_tickets`/`admin_get_support_ticket_detail`/
  `admin_update_support_ticket`/`admin_reply_support_ticket` + écran `admin.html` + correction
  `STUB_INFO.support` — voir §3.5.4/§3.5.5/§3.5.8.
- **Dépendances** : Lot 1 (PR-01/02/03 fermées), Lot 2 (notifications de réponse).
- **Migration** : nouveau `sql/85_admin_support_triage.sql` — table `support_ticket_replies`
  (§3.5.8), 4 nouvelles RPC, ACL standard, écriture `_platform_log` sur chaque mutation.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : scénarios triage complet (liste, détail, changement de statut, assignation,
  réponse visible, note interne invisible côté hôtel), vérification que chaque mutation produit
  une ligne `platform_logs`, rejet non-admin, rejet d'une note interne créée par un `hotel_user`
  (contrainte CHECK).
- **Rollback** : `DROP FUNCTION` des 4 RPC, `DROP TABLE support_ticket_replies` si aucune
  donnée réelle n'y a encore été écrite.
- **Smoke test** : triage réel testé en production (lecture) + une réponse de test créée et
  supprimée uniquement en transaction annulée (jamais en écriture réelle sans autorisation).
- **Documentation** : entrée `CHANGELOG.md`, `STUB_INFO.support` corrigé dans `admin.html`.
- **Fichiers concernés** : `sql/85_admin_support_triage.sql`, `admin.html`.
- **Risques** : faible — ACL standard déjà maîtrisée par le projet, une seule table nouvelle.

#### Lot 5 — PR B — Portail hôtel (création, suivi, pièces jointes)
- **Objectif** : point d'entrée `index.html`/`portal.html` pour créer un ticket, suivre ses
  tickets et joindre des fichiers — voir §3.5.6/§3.5.9. Livrée après PR A (décision §5).
- **Dépendances** : Lot 1 (PR-01/02/03 fermées), Lot 5 PR A (le triage doit exister pour qu'un
  ticket créé côté hôtel soit traité).
- **Migration** : nouveau `sql/86_hotel_support_portal.sql` — table
  `support_ticket_attachments` (§3.5.9), bucket Storage `support-ticket-attachments` + policies,
  RPC `hotel_reply_support_ticket(ticket_id, body)`,
  `hotel_add_support_ticket_attachment(ticket_id, reply_id, storage_path, ...)`.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : un utilisateur hôtel peut créer un ticket pour son propre hôtel, pas pour un
  autre ; peut répondre et joindre un fichier à son propre ticket, pas à celui d'un autre hôtel ;
  ne voit jamais une note interne ; Jest sur le formulaire de création/réponse/upload.
- **Rollback** : retrait du point d'entrée frontend, `DROP FUNCTION` des 2 RPC, `DROP TABLE
  support_ticket_attachments` et suppression du bucket si aucune pièce jointe réelle n'a encore
  été uploadée.
- **Smoke test** : ticket visible immédiatement côté triage Super Admin (Lot 5 PR A) après
  création côté hôtel, testé en production avec un ticket de test explicitement marqué et
  nettoyé après vérification.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `index.html` ou `portal.html` (à confirmer selon l'écran cible),
  `sql/86_hotel_support_portal.sql`.
- **Risques** : faible — nouvelle table + bucket, mais RLS/policies calquées sur des patterns
  déjà en production (`portal-documents`, `ota_dispute_attachments`).

### Lot 6 — Statistiques fondamentales (y compris score de santé plateforme)
- **Objectif** : `platform_metrics_daily` + `admin_recompute_platform_metrics` (manuel,
  rejouable historiquement) + `admin_platform_metrics_series`, selon les définitions formelles
  du §3.4, y compris le score de santé plateforme.
- **Dépendances** : PR-00 techniquement seule requise pour les métriques financières (MRR/ARR/
  churn/conversion) ; **le sous-score Support du score de santé dépend du Lot 5** et **le
  sous-score Licences dépend du Lot 3** (défaut `100` tant qu'ils ne sont pas livrés, §3.4) —
  livré en dernier dans l'ordre imposé précisément pour cette raison.
- **Migration** : nouveau `sql/87_platform_metrics.sql` — nouvelle table
  `platform_metrics_daily`, RPC de recalcul et de série temporelle, RPC de score de santé.
- **Reconstruction** : intégrée à la séquence rejouée par la reconstruction du dépôt.
- **Tests** : jeux de données synthétiques avec résiliations, changements de plan et avoirs à
  des dates connues, vérifiant que chaque métrique du §3.4 (y compris chaque sous-score de
  santé) produit le résultat attendu selon sa formule exacte.
- **Rollback** : `DROP TABLE platform_metrics_daily`, `DROP FUNCTION` des RPC — aucune autre
  table modifiée (lecture seule sur les tables sources).
- **Smoke test** : recalcul réel en production comparé à un calcul manuel de référence sur les
  données réelles (MRR, hôtels actifs).
- **Documentation** : entrée `CHANGELOG.md`, formule du score de santé documentée dans l'écran
  Dashboard (`admin.html`) pour que le CTO puisse la vérifier à l'œil.
- **Fichiers concernés** : `sql/87_platform_metrics.sql`, `admin.html`.
- **Risques** : moyen — le calcul du MRR/ARR/churn et du score de santé touche une logique
  métier nouvelle et potentiellement disputée ; risque principal = un chiffre incorrect affiché
  au CTO, pas un risque de sécurité.

### PR-10 — Écran divergence de droits (frontend seul, hors lot)
- **Objectif** : exposer `admin_rights_divergence_report()` (déjà existante) à l'écran.
- **Dépendances** : aucune (backend déjà livré en Phase 2A) — peut être fait à tout moment, non
  bloquant pour les 6 lots.
- **Migration** : aucune.
- **Reconstruction** : sans objet (frontend seul).
- **Tests** : Jest sur le helper d'affichage, smoke test visuel.
- **Rollback** : retrait de l'écran, aucun impact backend.
- **Smoke test** : écran ouvert en Preview, comparé à un appel RPC direct de référence.
- **Documentation** : entrée `CHANGELOG.md`.
- **Fichiers concernés** : `admin.html` uniquement.
- **Risques** : nul (lecture seule, backend inchangé).

### PR-11 — Paiements (reporté, après décisions métier et choix de prestataire)
- **Objectif** : les 3 livrables du §3.1 — PDF réel, dunning réel, passerelle de paiement —
  **une fois** les questions métier du §3.1 tranchées et le prestataire choisi. **Non planifié
  dans ce round.**
- **Dépendances** : Lot 2 (`platform_notifications`, pour le dunning), décision CTO sur le
  prestataire, réponses aux questions métier §3.1.
- **Migration** : détaillée au round 1 (§3.1 historique) — `platform_dunning_log`,
  `platform_payment_intents`, `platform_payment_provider_events`, numérotation `sql/88+` au
  moment du déblocage.
- **Reconstruction** : à traiter au moment de l'exécution.
- **Tests** : idempotence webhook stricte (`event_id` unique), vérification de signature
  obligatoire, tests en transaction sur données réelles.
- **Rollback** : stratégie à détailler par sous-PR au moment de l'exécution, vu le niveau de
  risque — pas de rollback générique acceptable pour un flux financier réel.
- **Smoke test** : à définir avec le prestataire choisi.
- **Documentation** : ce document sera amendé (round 4+) une fois le prestataire choisi, avant
  toute migration.
- **Fichiers concernés** : `sql/88+`, buckets Storage, Edge Functions dédiées.
- **Risques** : le plus élevé du plan (flux financier réel, webhook public, prestataire
  externe) — à scinder en sous-PR au moment de l'exécution.

---

## 7. Points encore réellement bloquants

1. **Choix du prestataire de paiement** — bloque PR-11 dans son intégralité. Différé
   explicitement par le CTO, confirmé par ce lancement.
2. **Questions métier Paiements du §3.1** (périodicité, engagement, prorata, remboursements,
   export comptable) — non tranchées, préalables à toute écriture de code sur PR-11, même une
   fois le prestataire choisi.
3. **Politique de rétention de `platform_notifications`** — proposition à 90 jours en §3.0, non
   validée, sans impact bloquant sur le développement (peut démarrer sans purge).
4. **Pondération du score de santé plateforme** (§3.4) — proposition V1 (40/25/20/15), non
   validée explicitement, sans impact bloquant sur le Lot 6 (les poids sont une constante
   modifiable sans migration de schéma, uniquement dans le corps de la RPC).
5. **Fuseau horaire du « jour métier »** (Europe/Paris, §3.4) — proposition non confirmée
   explicitement, sans impact bloquant (valeur par défaut raisonnable, changeable avant Lot 6).

Aucun autre point des rounds précédents ne reste ouvert sans réponse : les décisions listées en
§5 sont toutes tranchées ou explicitement reportées avec leur raison.

---

## 8. Annexe — Supervision avancée (hors périmètre de ce lancement)

Conservé sans changement depuis le round 2, pour mémoire — **non inclus dans les 6 lots
communiqués par le CTO pour ce lancement**, ne pas développer tant que ce domaine n'est pas
explicitement reprogrammé :

`admin_supervision_status()` honnête (signaux `mutation_error_monitoring_available`/
`edge_function_error_monitoring_available` actuellement `false`, correctement — aucun Sentry ou
équivalent n'est câblé), `admin_list_platform_audit_log()` déjà livré (Phase 1). Chantiers
identifiés mais non planifiés : RPC CMS `help_articles` (créer/publier/archiver un article,
même doctrine ACL que le reste du Support), intégration Sentry frontend + Edge Functions
(dépend d'un compte externe non fourni), `platform_incidents` (stretch, Could, historique
d'incidents). Si ce domaine est repris dans un round futur, il consommera les prochains numéros
de migration disponibles après `sql/87` (ou après `sql/88+` si Paiements a été débloqué entre
temps) — aucun numéro n'est réservé à l'avance pour ne pas figer un ordre non confirmé.

---

## Prochaine étape

Ce document (round 3) reste soumis pour validation. Conformément à l'instruction reçue, aucun
développement n'est démarré et aucune PR technique n'est ouverte avant autorisation explicite —
y compris pour le Lot 1 (rétro-versionnement), qui ne modifie pourtant le comportement d'aucun
système existant. Dès validation, l'ordre d'exécution est : Lot 1 (PR-01 → PR-02 → PR-03) → Lot
2 → Lot 3 → Lot 4 → Lot 5 (PR A → PR B) → Lot 6 → Paiements (note seule, pas de code).
