# ADR-009 — Architecture et modèle de sécurité du portail Super Admin

**Statut** : Accepté.

**Portée** : `/admin` (fichier `admin.html`), `sql/68_super_admin_phase1_foundation.sql`,
`sql/69_super_admin_phase1_security_hardening.sql`. Document de référence pour toute
évolution future du portail Super Admin (Phase 2 et au-delà).

## Contexte

La Phase 1 du portail Super Admin a révélé que l'essentiel du backend (tables, RPC,
triggers) existait déjà en production — bootstrappé directement en base, jamais
entièrement reflété dans `sql/` ni `db/reconstruct/` (même anti-pattern déjà documenté
pour `hotels`/`hotel_groups`/`platform_admins`). Un audit d'architecture complet puis un
hotfix de sécurité ont suivi la livraison initiale et ont fait émerger des règles de
conception qui n'étaient nulle part écrites. Cet ADR les consigne pour qu'elles ne
dépendent plus de la mémoire d'une seule session de travail.

---

## 1. Architecture générale du portail

**Décision** : `/admin` est un fichier statique **entièrement indépendant**
(`admin.html`), au même niveau que `index.html` (app hôtel) et `portal.html` (PWA
salarié) — même approche : HTML/CSS/JS mono-fichier, sans build, client Supabase chargé
en CDN (`@supabase/supabase-js@2/+esm`), routage par réécriture statique dans
`vercel.json`.

**Justification** : `index.html` est un monolithe de ~18 000 lignes déjà fragile (le
module Planning y est explicitement interdit de modification). Ajouter le portail Super
Admin comme un onglet supplémentaire aurait alourdi ce fichier et créé un risque de
régression sur l'app hôtel pour des changements qui ne la concernent pas. L'indépendance
totale — CSS dupliqué plutôt qu'importé, shell JS propre — élimine ce risque au prix
d'une petite dette de synchronisation visuelle (documentée en commentaire dans
`admin.html`).

**Alternatives rejetées** : nouvel onglet dans `index.html` (rejeté : couplage,
fragilité) ; framework séparé avec build (rejeté : rupture avec la convention
mono-fichier du reste du produit).

## 2. Modèle de sécurité

**Décision** : l'autorisation Super Admin repose sur un mécanisme **totalement
indépendant** du modèle RLS hôtel. `platform_admins` (colonnes `auth_id`, `role`,
`is_active`) et la fonction `is_platform_admin()` (`STABLE SECURITY DEFINER`, teste
`auth_id = auth.uid() AND is_active`) sont le **seul** point de vérité pour "cet
utilisateur est-il Super Admin ?". Aucune table hôtel (`user_hotels`, `admin_user_role`)
n'intervient dans cette décision.

**Conséquence assumée** : `index.html` (l'app hôtel) n'a **aucune connaissance** de
`platform_admins` — son modèle RLS est entièrement basé sur
`user_hotels`/`get_user_hotel_id()`. Un Super Admin sans ligne `user_hotels` a un accès
complet via `/admin` mais **aucun accès** aux données opérationnelles d'un hôtel via
`index.html`. C'est un choix délibéré de séparation des périmètres, pas un oubli — voir
§11 pour le mécanisme qui comble ce manque pour les besoins existants.

## 3. Politique des RPC admin

**Décision** : toute action Super Admin passe par une RPC nommée `admin_<verbe>_<objet>`
(ex. `admin_create_hotel`, `admin_set_hotel_status`, `admin_update_hotel_full`),
`SECURITY DEFINER`, dont la **première instruction** est :

```sql
IF NOT public.is_platform_admin() THEN
  RAISE EXCEPTION 'Accès refusé : réservé au super administrateur' USING errcode = '42501';
END IF;
```

Les mutations complexes acceptent un payload `jsonb` unique (`p jsonb`) plutôt qu'une
longue liste de paramètres positionnels, avec extraction via `coalesce(p->>'champ',
défaut)` — permet d'ajouter des champs sans changer la signature.

**Constat accepté (linter sécurité Supabase)** : PostgreSQL accorde `EXECUTE` à `PUBLIC`
par défaut à la création d'une fonction. Le linter Supabase signale donc `anon`/
`authenticated` comme techniquement capables d'appeler **toutes** les RPC `admin_*` —
constat vérifié concernant **615 fonctions** dans la base, pas spécifique à ce portail.
C'est un motif accepté du codebase : la garde interne `is_platform_admin()` neutralise le
risque quel que soit le rôle appelant. **Ce n'est PAS une raison de fermer l'ACL de ces
RPC** — voir §5 pour la distinction avec les fonctions internes.

## 4. Utilisation de `SECURITY DEFINER`

**Décision** : toute RPC `admin_*` est `SECURITY DEFINER`, propriétaire `postgres` — elle
**contourne RLS par conception** sur les tables qu'elle touche. C'est le mécanisme qui
permet à un Super Admin sans `user_hotels` d'agir sur n'importe quel hôtel/groupe/
utilisateur.

**Règle obligatoire (tirée de l'incident `_platform_log`, voir §9)** : `SECURITY DEFINER`
n'est sûr **que** si l'une de ces deux conditions est vraie :
- (a) la fonction est **appelable par un client** → elle doit vérifier
  `is_platform_admin()` (ou une autre condition d'autorisation explicite) en première
  ligne ; **ou**
- (b) la fonction est un **helper interne**, jamais censée être appelée directement par
  un client → son `EXECUTE` doit être explicitement révoqué de `PUBLIC`, `anon`,
  `authenticated` et `service_role` (voir §5).

Une fonction `SECURITY DEFINER` qui ne remplit **ni (a) ni (b)** est une vulnérabilité —
c'était le cas de `_platform_log` avant le hotfix.

## 5. Politique des ACL

**Décision** :

| Type de fonction | ACL requise | Vérification |
|---|---|---|
| RPC `admin_*` (client-facing) | `GRANT EXECUTE ... TO authenticated` **explicite** (ne pas se fier au grant `PUBLIC` implicite) + garde interne `is_platform_admin()` | `has_function_privilege('authenticated', ..., 'EXECUTE')` = true dans les tests |
| Helper interne (préfixe `_`) | `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role` — aucun rôle client n'y accède jamais directement | `has_function_privilege('anon'/'authenticated'/'service_role', ..., 'EXECUTE')` = **false** dans les tests |

**Justification du `REVOKE` explicite même quand un `GRANT` semble redondant** : ne
jamais compter sur le fait qu'"aucun code ne l'appelle directement aujourd'hui" — un
helper interne doit être **structurellement** inappelable de l'extérieur, pas seulement
par convention. Toute nouvelle fonction préfixée `_` doit être auditée avant merge avec
la question : *si un client l'appelle directement en RPC, que se passe-t-il ?*

## 6. Politique RLS

**Décision** : RLS reste une **seconde ligne de défense**, jamais la seule. Elle sert
principalement pour les **lectures directes** que `admin.html` effectue sans passer par
une RPC (ex. `sb.from('hotels').select(...)`) — d'où les policies
`hotel_groups_admin_all`, `audit_logs_admin_read`, `invoices_admin_read`,
`payments_admin_read` (`is_platform_admin()`), ajoutées en Phase 1 pour combler
l'absence totale de policy `platform_admin` sur `hotel_groups`. Les **écritures**
passent systématiquement par une RPC gardée (§3), même sur des tables où une policy RLS
`ALL` permettrait techniquement une écriture directe (ex. `hotel_subscriptions`) — la RPC
garantit en plus l'atomicité (§10) et la journalisation (§7).

**Règle** : toute nouvelle table consultée directement depuis `admin.html` doit avoir une
policy `is_platform_admin()` explicite avant d'être utilisée — ne pas supposer qu'elle
existe déjà (l'audit Phase 1 a montré que ce n'était pas toujours le cas, y compris sur
des tables déjà partiellement admin-conscientes).

## 7. Journalisation utilisateur (actions Super Admin)

**Décision** : toute RPC `admin_*` qui **écrit** doit journaliser via `_platform_log`
(§9), dans la **même transaction** que l'écriture métier — jamais en différé, jamais
best-effort. Convention de nommage des actions : `<entité>.<verbe>` (ex.
`hotel.create`, `hotel.update`, `hotel.status_change`, `user.suspend`,
`user.reactivate`, `group.attach_hotel`). Le payload inclut systématiquement un état
`before`/`after` suffisant pour reconstituer le changement sans requête supplémentaire.

**Convention explicitement tranchée** : seules les **écritures** sont journalisées, pas
les lectures (`admin_list_user_access`, `platform_dashboard_kpis`, etc.). C'était
ambigu dans le cahier des charges initial ("toutes les opérations") — cet ADR fixe
l'interprétation retenue.

## 8. Journalisation système

**Décision** : les événements déclenchés par un **trigger** ou une **automatisation**
(pas par un appel RPC Super Admin explicite) journalisent via `_platform_log_system`
(§9), pas `_platform_log`. Cas identifié : `grant_superadmin_on_new_hotel` (trigger
`AFTER INSERT ON hotels`) — l'utilisateur à l'origine de l'INSERT peut être un directeur
en self-service (`org_create_hotel`), pas un Super Admin ; exiger `is_platform_admin()`
pour journaliser cet événement casserait le flux self-service.

**Règle** : toute nouvelle automatisation (trigger, cron, fonction système) qui doit
laisser une trace dans `platform_logs` utilise `_platform_log_system`, jamais
`_platform_log`.

## 9. Fonctions `_platform_log` et `_platform_log_system`

Deux fonctions internes, jamais appelées directement par un client (§5), toutes deux
`SECURITY DEFINER`, toutes deux résolvant **côté serveur uniquement** :
- l'IP et le user-agent, depuis `current_setting('request.headers', true)` (jamais
  acceptés en paramètre — un client ne peut pas falsifier ces valeurs) ;
- l'horodatage, via le défaut `created_at = now()` de la table ;
- l'acteur, différemment selon la fonction (voir tableau).

| | `_platform_log` | `_platform_log_system` |
|---|---|---|
| Garde interne | `is_platform_admin()` obligatoire | Aucune — l'acteur peut être n'importe quel utilisateur authentifié légitime |
| Résolution de l'acteur | `platform_admins` (via `auth.uid()`) | `public.users` (via `auth.uid()`) — fonctionne pour un directeur non-admin |
| Appelée depuis | RPC `admin_*` gardées | Triggers / automatisations système |
| ACL | `REVOKE ALL FROM PUBLIC, anon, authenticated, service_role` | Identique |

**Règle absolue** : ni l'une ni l'autre n'accepte l'identité de l'auteur, l'IP, le
user-agent, le rôle ou le nom en paramètre client. Toute nouvelle fonction de
journalisation doit suivre le même principe — aucune donnée d'audit ne provient d'une
valeur envoyée par le frontend.

## 10. Politique d'atomicité

**Décision** : **une action utilisateur = une RPC = une transaction.** Si une action du
portail modifie plusieurs entités logiquement liées (ex. les champs d'un hôtel *et* son
rattachement à un groupe), elle doit être portée par **une seule** fonction PL/pgSQL,
jamais par une séquence de plusieurs appels RPC depuis le JavaScript client.

**Origine de la règle** : la première version de l'édition hôtel appelait
`admin_update_hotel` puis, séparément, `admin_attach_hotel_to_group`/
`admin_detach_hotel_from_group` — un échec du second appel après succès du premier
laissait un état partiel visible en UI. Corrigé par `admin_update_hotel_full`, qui valide
tout (hôtel existe, groupe existe) **avant** d'écrire quoi que ce soit, et journalise
dans la même transaction que la mutation.

**Règle pour Phase 2** : avant d'écrire un nouveau flux d'édition, se poser la question
*"si le deuxième appel échoue après le premier, l'UI peut-elle afficher un succès
partiel ?"* — si oui, fusionner en une seule RPC.

## 11. Gestion des soft delete

**Décision** : **aucune suppression physique** d'une ligne référencée (directement ou par
clé étrangère) par une table d'audit immuable. Les entités concernées (`hotels`,
`hotel_groups`) utilisent une colonne `status` (`'archived'`) plutôt qu'un `DELETE`.

**Origine de la règle — découverte empirique en production** : une tentative de
`DELETE FROM hotels` (nettoyage d'un hôtel de test après vérification du hotfix) a
échoué avec `audit_logs are immutable`. Cause : `platform_logs.hotel_id` référence
`hotels.id` par clé étrangère ; supprimer la ligne hôtel aurait nécessité que PostgreSQL
mette à `NULL` la colonne `hotel_id` des lignes `platform_logs` associées (action `ON
DELETE SET NULL` implicite) — un `UPDATE`, bloqué par le trigger d'immuabilité. C'est le
mécanisme d'immuabilité qui fonctionne **correctement**, mais il rend tout `DELETE`
impossible dès qu'une ligne a été journalisée (donc quasiment toujours).

**Règle pour Phase 2** : ne jamais concevoir un flux de suppression physique pour une
entité journalisée dans `platform_logs`/`audit_logs`. Prévoir `status='archived'` (ou
équivalent) **dès la conception du schéma**, pas en correctif après coup.

## 12. Politique d'audit

**Décision** : deux systèmes d'audit distincts, à ne pas confondre :

- **`audit_logs`** — scope hôtel (`hotel_id` obligatoire), chaînage cryptographique
  (`seq`/`prev_hash`/`entry_hash`), préexistant, alimente l'audit **opérationnel** d'un
  hôtel (actions des rôles hôtel). Le portail Super Admin y a un accès lecture
  cross-hôtel (`audit_logs_admin_read`, §6) mais n'écrit jamais dedans directement.
- **`platform_logs`** — scope plateforme (`hotel_id` optionnel), pas de chaînage
  cryptographique mais immuabilité garantie par trigger (`BEFORE UPDATE/DELETE → RAISE
  EXCEPTION`, réutilise `app.audit_logs_immutable()`), alimenté exclusivement par
  `_platform_log`/`_platform_log_system`. **C'est le journal du portail Super Admin.**

**Règle** : une nouvelle fonctionnalité Super Admin qui doit être auditée écrit dans
`platform_logs` via `_platform_log`/`_platform_log_system` — jamais directement par
`INSERT`, jamais dans `audit_logs`.

## 13. Contraintes pour les futurs développements

- `admin_update_hotel`, `admin_attach_hotel_to_group`, `admin_detach_hotel_from_group`
  restent utilisables indépendamment (vue Groupes) — ne pas les faire disparaître au
  profit de `admin_update_hotel_full`, qui sert un cas d'usage différent (édition
  combinée depuis le drawer Hôtel).
- Le rôle `direction` accordé automatiquement par `grant_superadmin_on_new_hotel` reste
  large (accès complet à l'hôtel via `index.html`). Conservé tel quel en Phase 1
  (décision documentée dans le rapport de hotfix) — sa portée reste une question ouverte
  pour une itération future, pas un problème à corriger silencieusement.
- `platform_logs` n'a qu'un index (`created_at DESC`, ajouté et justifié par `EXPLAIN`
  lors du hotfix). Toute nouvelle requête fréquente sur cette table (filtrage par
  `action`, `entity`, `admin_id`…) doit être mesurée par `EXPLAIN ANALYZE` avant d'ajouter
  un index — pas par anticipation non prouvée (voir §14).
- Les tables déjà prêtes mais non exploitées par la Phase 1 (`platform_invoices`,
  `platform_contracts`, `hotel_app_subscriptions`, `hotel_addon_subscriptions`,
  `dunning_templates/logs`) n'ont **aucune RPC** aujourd'hui — la Phase 2 doit leur
  appliquer exactement les règles de cet ADR (§3 à §10), pas un nouveau motif.

## 14. Règles obligatoires à respecter pendant la Phase 2

1. Toute nouvelle fonction `SECURITY DEFINER` doit satisfaire §4(a) ou §4(b) — vérifié
   par `has_function_privilege` dans les tests **avant** merge, jamais après.
2. Toute RPC `admin_*` d'écriture appelle `_platform_log` (ou `_platform_log_system` si
   l'acteur peut être non-admin) dans la **même transaction** que la mutation.
3. Une action utilisateur = une RPC = une transaction (§10) — pas de séquence de RPC
   composée côté client pour représenter une seule action logique.
4. Aucune suppression physique d'une entité journalisée — `status='archived'` prévu dès
   la conception (§11).
5. Toute nouvelle migration touchant RLS/ACL/RPC admin est testée sous simulation de rôle
   (`anon`, `authenticated` non-admin, `platform_admin`) avant application en
   production — via une transaction `BEGIN...ROLLBACK` sur la base réelle si le
   branching Supabase n'est pas disponible.
6. Réutiliser une table/RPC existante avant d'en créer une nouvelle (discipline qui a
   fonctionné en Phase 1 comme au hotfix — la majorité des besoins Phase 2 sont déjà
   couverts côté schéma).
7. Toute nouvelle fonction interne (préfixe `_`) est fermée par défaut (`REVOKE ALL FROM
   PUBLIC, anon, authenticated, service_role`) — l'ouverture est l'exception justifiée,
   pas la valeur par défaut.
8. Aucune donnée d'audit (acteur, IP, user-agent, date) n'est acceptée en paramètre
   client — toujours résolue côté serveur (§9).

---

## Historique d'implémentation

| Migration | Contenu |
|---|---|
| `sql/68_super_admin_phase1_foundation.sql` | Fondations Phase 1 : RLS `is_platform_admin()` manquantes, RPC `admin_create_hotel`/`admin_update_hotel`/`admin_set_hotel_status`/`admin_create_group`/`admin_update_group`/`admin_delete_group`/`admin_attach_hotel_to_group`/`admin_detach_hotel_from_group`/`admin_list_unlinked_auth_users`, `platform_dashboard_kpis`, `_platform_log` (version initiale), `_generate_hotel_code`. |
| `sql/69_super_admin_phase1_security_hardening.sql` | Hotfix : fermeture ACL `_platform_log`, création `_platform_log_system`, historisation `admin_set_user_status`, durcissement audit de `grant_superadmin_on_new_hotel`, `admin_update_hotel_full` (atomicité), index `platform_logs(created_at)`. |

Statut en production au moment de la rédaction de cet ADR : **appliqué et vérifié
stable** (hotfix validé CTO).
