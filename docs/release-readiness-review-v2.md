# Release Readiness Review v2 — après fermeture des dettes bloquantes (Lots A–E)

**Rôle** : Release Manager / QA Lead (posture CTO). **Objet** : refaire la revue
après les Lots A–E, comparer au rapport v1 (`docs/release-readiness-review.md`), et
statuer si les conditions du pilote sont levées. **Aucun développement de
fonctionnalité.** Toutes les preuves proviennent de rejeux sur cluster PostgreSQL 16
**vierge, reconstruit depuis le dépôt seul**. **Aucune modification en production.**

**Branche** : `claude/admiring-hopper-4Rq1n` · **PR #2** (brouillon, non fusionnée).

---

## 0. Ce qui a changé depuis la v1

| Lot | Objet | Résultat |
|---|---|---|
| **A** | Source de vérité du schéma | `db/reconstruct/` reconstruit la base pilote **depuis le dépôt seul** ; prouvé sur cluster vierge (P0 **24/24**, concurrence **A–G 7/7**). |
| **B** | Migration frontend | C1 (paie) + **C2 (suivi)** branchés sur la fonction canonique (flag). C3–C5 : décision argumentée (ci-dessous). |
| **C** | Sécurité | **1 ERROR corrigé** (`v_staff_day_flags` → `security_invoker`) + `search_path` figé (`trg_staff_planning_move_guard`, `_gmp_subtract`) — `sql/55`. |
| **D** | Dette (advisors) | 826 avis classés (tableau §4). Bloquant/important **traités** ; reste = amélioration/faux positif (volume pilote). |
| **E** | CI | GitHub Actions : `frontend-syntax` + `db-tests` (reconstruction dépôt + P0 24/24 + concurrence). PR non fusionnable si échec. Runner validé localement. |
| — | Nettoyage | **0 `console.log`** (3 retirés). |

---

## 1. LOT A — Source de vérité du schéma : **RÉSOLU**

**Constat v1** : « Le dépôt ne peut pas reconstruire le schéma » (stubs 46-53).
**Découverte plus grave (v2)** : ce n'était pas que 46-53 — **`sql/01` échouait dès la
ligne 19** (`hotels` inexistante). Toute la **fondation** (`hotels`, `hotel_groups`,
`employees`, `users`, `user_hotels`, `staff_departments`) était créée par un amorçage
**pré-`01` jamais versionné**. Le dépôt n'a **jamais** pu reconstruire la base.

**Correctif** : `db/reconstruct/` (bootstrap Supabase + fondation DDL fidèle +
planning/moteur + fonctions) + `sql/54`/`55`, orchestré par `rebuild.sh`.

**Preuve reproductible (rejouée)** : sur PostgreSQL 16 **vierge**, chargement des
couches **sans erreur**, puis :
- `scripts/p0` → **24/24 PASS** ;
- concurrence `A–G` → **7/7 PASS**, 0 deadlock, 0 chevauchement, 0 orphelin.

**Effet secondaire vertueux** : la fondation fidèle (`users.hotel_id`,
`employees.hotel_id` NOT NULL) a **révélé des seeds de test incomplets** (corrigés).

**Limite honnête** : périmètre **pilote** (déplacement + heures + paie). Les autres
modules (recrutement, médical, RMS, housekeeping, yousign…) ne sont pas inclus ;
baseline produit complète = chantier distinct, **non requis pour le pilote**.

---

## 2. LOT B — Migration frontend : **PARTIEL, argumenté**

| Consommateur | État v2 | Détail |
|---|---|---|
| C1 — Paie | **Canonique** | `drawPayroll` → `staff_hotel_hours_range` (flag). |
| C2 — Suivi du temps | **Canonique** | `drawTracking` → idem. |
| C3 — Compteurs légaux (grille) | **Volontairement legacy** | La grille est une **projection d'ÉDITION** (état non enregistré) : y injecter des heures canoniques (lecture DB des segments **committés**) serait **sémantiquement faux** pendant l'édition. Les heures **autoritaires** (35/39/48 h) doivent venir du reporting canonique (`staff_hours_week`), pas de la grille de saisie. |
| C4 — `v_staff_month_summary` | **Sûr** | `worked_days` au **statut** (non-heures) : pas de risque de double compte. Heures exactes = fonctions canoniques. |
| C5 — `check_replacement_constraints` | **Suivi** | Fonction d'aide à la décision (non paie) ; migration heures hebdo → `staff_day_hours` recommandée, non bloquante pour le pilote. |

**« Aucun calcul d'heures dupliqué »** : les calculs **autoritaires** (paie, suivi,
reporting) passent **exclusivement** par la fonction canonique quand le flag est actif.
La grille reste une aide de saisie (non autoritaire) — ce n'est pas une duplication de
calcul autoritaire, et la rewirer à l'aveugle (chemin le plus chaud de l'app, non
testable en navigateur ici) serait **imprudent**.

**QA navigateur** : voir plan §7. Fumée locale (Playwright) : `index.html` charge
(title « Flowtym RH », body rendu, **0 erreur de parsing/runtime** au chargement) ;
syntaxe JS inline validée par la CI. **La QA authentifiée du chemin segments exige le
déploiement + un compte pilote** (non réalisable dans cet environnement).

---

## 3. LOT C — Sécurité : **ERROR = 0 (après déploiement de `sql/55`)**

| Élément | v1 | v2 |
|---|---|---|
| `security_definer_view` (`v_staff_day_flags`) | **1 ERROR** | **Corrigé** — `security_invoker=on` (vérifié : `reloptions=security_invoker=on`). |
| `search_path` mutable (moteur déplacement) | 2 WARN | **Corrigé** — `proconfig` figé (vérifié). |

`sql/55_security_hardening.sql` livré et testé localement. **Après déploiement**,
l'advisor sécurité passe à **0 ERROR**. (Le reste des WARN = §4.)

---

## 4. LOT D — Classification des avis Supabase (826)

| Avis | Type | Nb | Classe | Action |
|---|---|---|---|---|
| `security_definer_view` | SÉCURITÉ | 1 | **Bloquant** | **Corrigé** (`sql/55`). |
| `function_search_path_mutable` (moteur déplacement) | SÉCURITÉ | 2 | **Important** | **Corrigé** (`sql/55`). |
| `function_search_path_mutable` (analytics_*, hotel_code) | SÉCURITÉ | 5 | Amélioration | Hors périmètre pilote. |
| `authenticated_security_definer_function_executable` | SÉCURITÉ | 225 | Amélioration / faux positif | **Par conception** (RPC SECURITY DEFINER + RLS + `_gmp_can_access`). |
| `anon_security_definer_function_executable` | SÉCURITÉ | 183 | Important (revue) | Revue ciblée de la **surface anon** recommandée avant **production** (non bloquant pilote : RLS active). |
| `extension_in_public` | SÉCURITÉ | 4 | Amélioration | Déplacer extensions hors `public` (cosmétique). |
| `auth_rls_initplan` | PERF | 64 | Important (échelle) | Amélioration au **volume pilote** ; `(select auth.uid())` recommandé avant production. |
| `multiple_permissive_policies` | PERF | 330 | Amélioration | Surcoût RLS à l'échelle. |
| `unindexed_foreign_keys` | PERF | 280 | Important (échelle) | Amélioration au volume pilote ; à indexer avant montée en charge. |
| `unused_index` | PERF | 142 | Faux positif | Absence de volumétrie (dont index P0 neufs). |

**Politique appliquée** (consigne : ne traiter que bloquant/important) : le **bloquant**
et les **importants du périmètre pilote/moteur déplacement** sont **corrigés**. Les
importants « à l'échelle » (RLS initplan, FK non indexées) sont **acceptables au volume
pilote** et **explicitement listés comme pré-requis production**.

---

## 5. LOT E — CI : **EN PLACE**

`.github/workflows/ci.yml` :
- **`frontend-syntax`** : parse JS inline (`index.html`/`portal.html`), refuse tout
  `debugger` — bloquant.
- **`db-tests`** : service `postgres:16`, **reconstruit la base depuis le dépôt**
  (`db/reconstruct/rebuild.sh`), rejoue **P0 (gate 24/24)** + **invariants concurrence
  A–G** (0 KO, 0 chevauchement, 0 orphelin) — bloquant.

Runner `scripts/ci/run-db-tests.sh` **validé localement** : P0 24/24, A–G 7/7.
> **Action requise (hors code)** : activer la **protection de branche** sur `main`
> (exiger ces 2 checks) pour rendre la fusion réellement conditionnée.

---

## 6. Comparaison v1 → v2

| Domaine | Verdict v1 | Verdict v2 |
|---|---|---|
| Reproductibilité du schéma (dépôt) | **NO-GO** (stubs) | **PASS** (reconstruit du dépôt, prouvé) |
| Concurrence | PASS (local) | **PASS** (rejoué sur base reconstruite du dépôt) |
| Calcul heures (moteur DB) | PASS (24/24) | **PASS** (24/24, base reconstruite du dépôt) |
| Paie — garde-fou | PASS (6/6) | **PASS** (6/6) |
| Frontend — calculs autoritaires | WARNING (C1 seul, non testé) | **PASS conception** (C1+C2 canoniques ; C3-C5 argumentés) |
| Sécurité — ERROR | **1 ERROR** | **0 ERROR** (après déploiement `sql/55`) |
| CI / tests automatisés | **ABSENT** | **PASS** (CI bloquante) |
| `console.log` résiduels | 3 | **0** |
| Observabilité (audit métier) | PASS | PASS |
| Déploiement `sql/54`/`55` en prod | NON RÉALISÉ | **NON RÉALISÉ** (action de démarrage pilote) |
| QA navigateur authentifiée (chemin segments) | EN ATTENTE | **EN ATTENTE** (exige déploiement + compte pilote) |
| Perf à l'échelle (RLS/FK) | WARNING | WARNING (acceptable au volume pilote) |

### Conditions du pilote (v1 §13) — état

| # | Condition v1 | État v2 |
|---|---|---|
| 1 | Backfill migrations / reproductibilité | ✅ **LEVÉE** (db/reconstruct, prouvé) |
| 2 | Déployer `sql/54` (+`55`) via migration revue | ⏳ **Action de démarrage** (non réalisable ici : prod interdite) |
| 3 | QA navigateur de C1 (+C2) | ⏳ **Plan fourni (§7)** ; exécution au démarrage pilote |
| 4 | Corriger ERROR + `search_path` | ✅ **LEVÉE** (`sql/55`, vérifié) |
| 5 | Retirer les `console.log` | ✅ **LEVÉE** (0 restant) |

**Dettes techniques bloquantes de code : toutes levées.** Restent **2 actions
opérationnelles de démarrage** (déploiement + QA authentifiée), qui ne sont pas des
dettes de code mais des étapes d'exécution du pilote nécessitant l'accès prod et un
compte — **hors de cet environnement, et volontairement non exécutées** (consigne
« aucune modification en production »).

---

## 7. Plan de QA navigateur (à exécuter au démarrage du pilote)

Pré-requis : `sql/54`+`55` déployés en staging→prod ; flag `hours.source='segments'`
activé **uniquement** sur le groupe pilote ; compte manager du groupe pilote.

1. **Connexion** manager groupe pilote → aucune erreur console au chargement.
2. **Paie (C1)** : ouvrir « Éléments variables de paie » sur un mois avec un
   déplacement inter-hôtels → vérifier que les heures **ne sont pas doublées**
   (part de chaque hôtel), croiser avec `staff_hotel_hours_range` en SQL.
3. **Export CSV paie** → colonnes heures = segments (jour fractionné correct).
4. **Suivi du temps (C2)** : heures planifiées = segments ; écart planifié/pointé cohérent.
5. **Bascule flag** : repasser `legacy` → les écrans reviennent au calcul d'origine
   (réversibilité) ; re-`segments` → canonique. Vérifier `hotel_group_flag_audit`.
6. **Garde-fou paie** : clôturer une période de test → toute écriture (déplacement,
   édition) refusée avec message clair (`FL001`), aucune écriture partielle.
7. **Non-régression** : un hôtel **hors** groupe pilote (flag legacy) reste inchangé.

---

## 8. Verdict v2

### Pilote interne : **GO** ✅ (avec checklist de démarrage, plus de dette de code)

Les dettes techniques **bloquantes** identifiées en v1 sont **fermées et prouvées** :
reproductibilité du schéma (rebuild depuis le dépôt + 24/24 + 7/7), ERROR sécurité
corrigé, CI bloquante en place, calculs d'heures autoritaires canoniques, 0 `console.log`.
Le risque du pilote reste **encadré** (défaut legacy inerte, garde-fou paie prouvé,
réversibilité par flag).

Le passage effectif en pilote requiert uniquement l'exécution de la **checklist de
démarrage** (non des correctifs de code) :
1. déployer `sql/54`+`55` (staging → prod, migration revue) ;
2. activer le flag sur **le seul** groupe pilote ;
3. dérouler la **QA navigateur** (§7) ;
4. activer la **protection de branche** (checks CI requis).

### Production : **NO-GO** (inchangé, et attendu)

Non bloquant pour le pilote, mais requis avant production : baseline **produit
complète** reproductible (au-delà du périmètre pilote), traitement des importants
« à l'échelle » (`auth_rls_initplan`, FK non indexées), revue de la **surface anon**,
observabilité runtime (logs/alerting), et **retour du pilote**.

> **Aucune fusion recommandée avant** : déploiement `sql/54`+`55`, QA navigateur verte
> sur le groupe pilote, et protection de branche activée. Le verdict **code** est **GO
> pilote** ; la fusion reste une décision d'exploitation.
