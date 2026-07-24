# Release Readiness Review — Flowtym RH (avant pilote interne)

**Rôle** : Release Manager / QA Lead, posture CTO (autoriser ou refuser la mise en
exploitation). **Objectif** : dire la vérité technique, signaler tout risque
bloquant — y compris ceux qui remettent en cause le travail déjà livré.

**Date** : 2026-07-24 · **Branche** : `claude/admiring-hopper-4Rq1n` (HEAD `71cc45f`)
· **PR** : #2 (brouillon, non fusionnée) · **Base de comparaison** : `main`.

**Méthode** : audit du dépôt (grep/statique), inspection du schéma live en lecture
seule (DDL + advisors Supabase), rejeu des harnais de test sur cluster PostgreSQL
16 local jetable. **Aucune modification en production. Aucun développement.**

---

## 1. Executive Summary

**État global** — Le **socle transactionnel** (déplacement inter-hôtels, concurrence,
application atomique) et le **moteur d'heures basé segments** sont **techniquement
solides et prouvés au niveau base de données** (concurrence 7/7, heures + paie 24/24).
En revanche, le produit **n'est pas déployé**, la **migration n'est pas reproductible
depuis le dépôt**, et la **couche frontend est incomplète et non testée en navigateur**.

**Niveau de maturité** : **Prototype avancé / pré-pilote**. Le cœur métier est mûr ;
la chaîne de livraison (déploiement, reproductibilité, QA end-to-end, CI) ne l'est pas.

**Principaux risques restants** (bloquants en gras) :
1. **La migration `sql/54` n'est PAS appliquée en production** (objets P0 absents du
   schéma live — vérifié). « Prêt » ≠ « déployé ».
2. **Le dépôt ne peut pas reconstruire le schéma** : `sql/46`→`53` sont des stubs
   documentaires (0 ligne exécutable). La vérité DDL du moteur déplacement vit
   **uniquement dans la base live**. Risque de reproductibilité / reprise après
   sinistre (DR).
3. **Frontend partiellement migré** : seul C1 (paie) est câblé derrière le flag, **non
   testé en navigateur** ; C2–C5 ne le sont pas.
4. **Aucune CI / aucun test automatisé** dans le dépôt ; les tests sont des harnais
   manuels locaux, joués sur **PostgreSQL 16** alors que la prod est **PostgreSQL 17**.
5. Sécurité : **1 ERROR** (vue `SECURITY DEFINER`) + fonctions à `search_path` mutable.

**Recommandation finale : `GO SOUS CONDITIONS`** — **uniquement** pour un **pilote
interne restreint à un seul groupe**, moteur segments activé manuellement, **défaut
legacy** partout ailleurs, garde-fou paie actif (réversibilité). **`NO-GO` pour la
production** tant que les conditions §12/§13 ne sont pas levées.

> Justification : le risque fonctionnel du pilote est **maîtrisé** (défaut legacy inerte
> + garde-fou paie + réversibilité prouvée), mais la **chaîne de release** (déploiement
> reproductible, QA navigateur, CI) est immature. Un pilote encadré est justifié ; une
> mise en production ne l'est pas.

---

## 2. Architecture

| Point | État | Explication |
|---|---|---|
| Architecture segments | **PASS** | `staff_planning_segments` avec contrainte d'exclusion GiST ; source de vérité des heures prouvée (24/24). |
| Projection `staff_planning` | **PASS** | Grille = projection journalière ; `staff_planning_rebuild_day` prouvé (égalité colonnes métier). |
| Séparation source de vérité | **PASS** | Règle explicite documentée ; fonction canonique unique lit les segments. |
| Feature flags | **WARNING** | `hours.source` implémenté, défaut legacy, journalisé — **mais non déployé** et **exercé côté frontend uniquement pour C1**. |
| Compatibilité legacy | **PASS** | Défaut legacy = comportement inchangé ; parité prouvée (T15). Repli silencieux si RPC indisponible. |
| Rollback | **PASS (concept)** | Réversible par flag ; garde-fou paie empêche l'altération rétroactive. **Non exercé en conditions réelles (pas de déploiement).** |
| Migrations | **FAIL** | `sql/46`→`53` = stubs (0 ligne exécutable). Le schéma du moteur déplacement **n'est pas reconstructible depuis le dépôt**. `sql/54` est runnable mais **non appliqué**. |

**Verdict architecture** : conception **PASS**, **chaîne de migration FAIL** (bloquant DR).

---

## 3. Base de données

**Contrôles**
- **Intégrité référentielle** : PASS — FK cohérentes (proposals→hotels/employees,
  segments→hotels/departments, applications→proposals ON DELETE CASCADE).
- **Index** : PASS sur le chemin chaud — `staff_planning_segments` porte
  `idx_sps_emp_day`, `idx_sps_hotel_day`, `idx_sps_source`, + index d'exclusion ;
  `group_move_applications` : PK idempotence + `idx_gmapp_proposal`.
- **Performances** : WARNING (voir §10) — dette RLS/FK au niveau plateforme.
- **Contraintes** : PASS — CHECK statut/heures, exclusion GiST, unicité
  `(hotel_id,employee_id,day)`, PK idempotence.
- **Triggers** : PASS — audit, move-guard, garde-fou paie, remplissage `service_id`.
- **Exclusion constraints** : PASS — `EXCLUDE USING gist (employee_id, day, int4range &&)`
  prouvée (0 chevauchement sous concurrence).
- **Advisory locks** : PASS — `pg_advisory_xact_lock(employé||jour)` (sérialise même
  sans ligne, prouvé scénario E).
- **Idempotence** : PASS — PK `idempotency_key`, cycle processing→completed atomique.
- **Reconstruction** : PASS — `staff_planning_rebuild_day` (T14).

**Dette technique restante**
- `sql/46`→`53` stubs ⇒ **schéma non reproductible depuis le dépôt** (dette majeure).
- **Fonctions d'heures multiples** : `staff_day_hours` (existant), `staff_hours_day`
  (canonique P0), `staff_hotel_hours_range` (P0), + calcul JS legacy dans le frontend.
  Ce **n'est pas** une duplication accidentelle (rôles distincts : total salarié /
  décomposé / plage-par-hôtel / legacy), mais **4 chemins de calcul coexistent** tant
  que le frontend legacy n'est pas retiré ⇒ **WARNING R7 partiellement atteint**.
- **Vue obsolète / à risque** : `v_staff_day_flags` déclenche l'unique **ERROR** de
  sécurité (SECURITY DEFINER, §4).
- **Tables inutilisées** : non détectées côté moteur déplacement ; l'audit `unused_index`
  (142) reflète surtout l'absence de volumétrie, pas des tables mortes.

---

## 4. Sécurité

**Score : 6.5 / 10** (acceptable pour un pilote encadré, insuffisant pour la production).

| Contrôle | État | Détail |
|---|---|---|
| RLS | **PASS** | Activée sur `staff_planning`, `staff_planning_segments`, `group_move_proposals`, `group_move_applications` (vérifié). |
| SECURITY DEFINER | **WARNING** | Modèle assumé (RPC = definer/postgres). **1 ERROR** : vue `v_staff_day_flags` en SECURITY DEFINER (contourne la RLS de l'appelant) — à corriger avant prod. |
| `search_path` | **WARNING** | 7 fonctions à `search_path` mutable, dont **`_gmp_subtract`** (IMMUTABLE, faible risque) et **`trg_staff_planning_move_guard`** (garde d'intégrité — devrait figer `search_path`). |
| Privilèges | **WARNING** | 408 avis « SECURITY DEFINER exécutable par anon/authenticated ». Majoritairement par conception, mais la **surface `anon`** mérite une revue ciblée avant prod. |
| Injection SQL | **PASS** | RPC en requêtes paramétrées ; pas de concaténation d'entrée utilisateur détectée dans les fonctions P0. |
| `service_role` | **PASS** | Jamais exposée au navigateur ; lue via variables d'environnement (Edge Functions). Vérifié : aucune valeur littérale de service_role dans le dépôt. |
| Secrets | **PASS** | Seules valeurs littérales = **clé anon publishable + ref public** (pré-existantes, protégées par RLS). Aucun secret dans les fichiers livrés (`scripts/`, `docs/`). |
| Migrations | **WARNING** | `set_group_hours_source` valide l'entrée (`FL002`) ; garde-fou paie non contournable par le flag. Mais migrations non reproductibles (§2). |
| Accès Front | **PASS** | GRANTs limités à `authenticated` ; `service_role` non utilisée côté front. |

**Bloquant prod** : l'ERROR `security_definer_view` et le durcissement `search_path` du
garde d'intégrité doivent être traités **avant production** (pas bloquant pour un pilote
lecture-dominante, mais à planifier).

---

## 5. Concurrence

Rejeu réel à deux backends `psql` distincts (cluster local), **avec le
`group_move_apply` corrigé P0** (non-régression).

| Scén. | Objet | Attendu | Obtenu | Verdict |
|---|---|---|---|---|
| A | même prop., même clé | 1 appli., blocage | 1 appli., ~2,0 s, idempotent | **PASS** |
| B | même prop., 2 clés | 1 appli., 2e refus propre | 1 appli., ~2,0 s | **PASS** |
| C | 2 prop., même jour | 1 appli. (autre annulée) | 1 appli. (`cancelled`) | **PASS** |
| D | 2 prop., jours différents | 2 appli., pas de blocage | 2 appli., max 26 ms | **PASS** |
| E | sans ligne préexistante | blocage advisory + refus | ~2,0 s puis refus | **PASS** |
| F | rollback puis reprise | seule B appliquée | confirmé | **PASS** |
| G | retry même clé | même `operation_id` | idempotent | **PASS** |

- **advisory locks** : PASS · **rollback** : PASS · **deadlock** : PASS (aucun) ·
  **timeout** : PASS (aucun) · **idempotence** : PASS · **opération atomique** : PASS ·
  **cohérence `operation_id`** : PASS (0 anomalie multi-operation, 0 orphelin `processing`).

**Verdict concurrence : PASS** (7/7, 0 deadlock, 0 chevauchement, 0 orphelin).
*Réserve honnête* : joué sur **PostgreSQL 16 local** ; la prod est **PostgreSQL 17**
(primitives identiques 16↔17, mais non rejoué sur PG17).

---

## 6. Calcul des heures

Fonction canonique `staff_hours_day` / `staff_hours_week` — **24/24 tests PASS**.

| Dimension | Verdict | Preuve |
|---|---|---|
| Fonction canonique | PASS | source unique DB (`staff_hours_day`). |
| Pauses | PASS | T3 (2h), T7, T8 (multiples, 4h). |
| Multi-hôtels | PASS | T4 (FO 4h + VO 4h = 8h, pas 16). |
| Minuit | PASS | T9 (2 segments / 2 jours). |
| Segments | PASS | net = somme des présences. |
| Journée complète | PASS | T1 (8h), T10 (déplacement complet = 8h, pas 24). |
| Heures nettes | PASS | net distinct du brut/pauses. |
| Ventilation hôtel | PASS | `by_hotel` (T4/T5/T6). |
| Ventilation `service_id` | PASS | T-SVC (2 services, total 8h). |
| Semaine | PASS | T-WEEK (7 jours agrégés). |
| Absence | PASS | T11 (matin travaillé = 4h). |
| Reconstruction | PASS | T14 (net inchangé après rebuild). |

**« Plus aucun calcul divergent » ? — NON, pas encore (WARNING).** La fonction
canonique est unique **côté base**, mais le **frontend legacy** (`presenceH += hpd`,
compteurs légaux, suivi du temps) **coexiste toujours** : seul **C1** consomme la
fonction canonique, et **seulement quand le flag = segments**. Tant que C2–C5 ne sont
pas branchés, **des chemins de calcul divergents subsistent en production legacy**.

---

## 7. Paie

| Contrôle | Verdict | Détail |
|---|---|---|
| Périodes clôturées | PASS | `staff_payroll_periods` (open/closed). |
| Protection | PASS | triggers sur grille **et** segments. |
| Refus d'écriture | PASS | SQLSTATE stable **`FL001`**, message explicite. |
| Rollback | PASS | refus = rollback de transaction, **aucune écriture partielle**. |
| Atomicité déplacement | PASS | `group_move_apply` sur période close → refusé **sans** application (P5/P5b). |
| Reconstruction bloquée | PASS | `staff_planning_rebuild_day` refusé (P6). |
| Période ouverte | PASS | écriture autorisée (P7). |
| Exports | **WARNING** | l'export CSV paie recalcule via `plannedH` (C1) — **non testé en navigateur**. |
| Calcul heures / variables | **WARNING** | HS 25/50 % = règle simplifiée déclarée « à valider par cabinet paie » ; hors périmètre P0. |

**Verdict paie : PASS au niveau moteur/garde-fou** (6/6 chemins d'écriture) ;
**WARNING sur l'export et les variables** (validation navigateur + métier requise).

---

## 8. Frontend

**Audit statique** (pas d'exécution navigateur possible dans cet environnement — c'est
en soi une limite majeure de cette revue, cf. §13).

| Écran | État | Remarque |
|---|---|---|
| Planning | WARNING | non re-vérifié en navigateur ; affichage des jours fractionnés (segments) non migré (P0-bis). |
| Collaborateurs | NON AUDITÉ (navigateur) | hors périmètre P0. |
| Paie | **WARNING** | C1 câblé derrière le flag (défaut legacy) — **jamais exécuté en navigateur**. |
| Exports | WARNING | dépend de C1 (paie) / affichage segments non migré. |
| Remplacements | WARNING | `check_replacement_constraints` non branché sur la fonction canonique. |
| Portail salarié | WARNING | affichage per-hôtel non migré (jours déplacés) — P0-bis. |
| Responsive | NON AUDITÉ | non mesurable ici. |
| Accessibilité | NON AUDITÉ | non mesurable ici. |
| Performance | WARNING | monolithe `index.html` **16 702 lignes** (voir §9/§10). |

**Détections**
- **Code de debug** : 3 `console.log` (`index.html:9143-9144` debug PDF ; `15759`
  message de test de cycle). Aucun `debugger`.
- **Doublons/mort** : calcul d'heures legacy JS **coexiste** avec la fonction canonique
  (dette de transition, à retirer une fois C2–C5 migrés).
- **Composants inutilisés** : plusieurs modules « à venir » (`renderStub`) présents pour
  la roadmap — intentionnels, non bloquants.

**Verdict frontend : WARNING/NO-GO pour activation** — la migration UI est **partielle
et non vérifiée end-to-end**.

---

## 9. Qualité du code

**Score : 6 / 10.**

- **Duplication** : modérée mais **présente** (4 chemins d'heures pendant la transition).
- **Complexité** : élevée dans `index.html` (**16 702 lignes**, un seul fichier), et
  `group_move_apply` (~90 lignes, logique dense mais testée).
- **Dette** : chaîne de migrations non reproductible (§2) = **dette structurelle #1**.
- **TODO/FIXME/HACK/XXX** : **0 réel** dans le code (1 faux positif documentaire
  `CTR-XXX` dans `aide.html`). Excellent.
- **console.log** : 3 (à retirer avant prod). **debugger** : 0.
- **Fichiers/fonctions/imports inutilisés** : pas de fichier orphelin détecté ; modules
  stub intentionnels.
- **Taille excessive** : `index.html` monolithique = **risque de maintenabilité** (pas
  bloquant pour un pilote, mais à planifier).
- **Architecture** : bonne séparation **DB** (source de vérité/projection) ; **faible**
  séparation **frontend** (monolithe).

---

## 10. Performances

**Advisors Supabase (prod)** : 404 WARN perf.
- **`auth_rls_initplan` (64)** : politiques RLS ré-évaluant `auth.uid()` par ligne —
  anti-pattern connu ; à corriger (`(select auth.uid())`) avant montée en charge.
- **`multiple_permissive_policies` (330)** : surcoût d'évaluation RLS — pré-existant.
- **`unindexed_foreign_keys` (280)** : FK sans index couvrant — dette à volume élevé.
- **`unused_index` (142)** : surtout absence de volumétrie (dont certains index P0).

**Chemin P0** :
- `staff_hotel_hours_range` : 1 requête ensembliste par écran (agrégation par emp/jour)
  — **pas de N+1** ; index `idx_sps_hotel_day` couvre le filtre.
- `staff_hours_day` : plusieurs sous-requêtes sur le même (emp,jour) — acceptable à
  l'unité, **potentiel N+1 si appelé par cellule** ; le frontend utilise à raison la
  **version plage** (une requête / mois). **PASS pour le pilote (faible volume).**
- Reconstruction / projections : O(segments du jour), négligeable.
- **Cache / mémoire** : pas de cache applicatif des heures ; recalcul à chaque rendu —
  acceptable au volume pilote, à surveiller.

**Verdict : PASS au volume pilote, WARNING à l'échelle** (dette RLS/FK plateforme).

---

## 11. Observabilité

| Élément | État | Détail |
|---|---|---|
| Logs | WARNING | pas de logging structuré applicatif ; 3 `console.log` résiduels. |
| Audit | **PASS** | `planning_audit` (trigger, `operation_id`, source, motif) ; `group_move_proposal_events` (timeline) ; `hotel_group_flag_audit` (changements de flag). |
| Erreurs | PASS | codes stables : **`FL001`** (paie close), **`FL002`** (flag invalide) ; messages explicites. |
| Messages | PASS | refus métier explicites (statut, expiration, dérogation…). |
| Diagnostics | WARNING | pas de tableau de bord/observabilité runtime ; diagnostic via SQL ad hoc. |
| Journalisation flag | PASS | toute bascule `hours.source` tracée (auteur, avant/après). |

**Verdict : PASS sur l'audit métier**, **WARNING sur l'observabilité runtime**
(logs/alerting à prévoir avant production).

---

## 12. Plan de pilote

**Étape 1 — Activation ciblée**
1. **Déployer `sql/54` en staging puis prod** via migration revue (pré-requis : le
   moteur déplacement — `sql/46`→`53` — doit d'abord exister en prod ; il y est déjà,
   mais **backfiller les migrations dans le dépôt** avant tout, cf. §13).
2. Choisir **1 groupe** contenant **≥1 hôtel** pilote.
3. Vérifier `hours.source = legacy` partout (défaut).
4. Activer **uniquement** pour ce groupe : `SELECT set_group_hours_source('<group>','segments');`
   (journalisé). Aucun autre groupe impacté.

**Étape 2 — Checklist quotidienne**
- [ ] `SELECT * FROM group_move_applications WHERE status='processing';` → **0 ligne**.
- [ ] Requête anti-chevauchement segments → **0 ligne**.
- [ ] Écart paie legacy vs segments sur un échantillon (doit correspondre au réel).
- [ ] Journal `hotel_group_flag_audit` → aucune bascule non planifiée.
- [ ] `planning_audit` cohérent (operation_id unique par application).
- [ ] Aucun `FL001` inattendu (hors périodes réellement closes).

**Étape 3 — Critères de réussite (2–4 semaines)**
- 0 double compte d'heures sur jours déplacés (rapproché manuellement).
- 0 chevauchement de segments, 0 orphelin `processing`, 0 deadlock.
- Écarts paie expliqués à 100 % (segments = réel).
- Retour utilisateur paie/planning positif sur la justesse des heures.

**Étape 4 — Critères d'arrêt immédiat (kill-switch)**
- Tout **double compte** d'heures constaté en paie.
- Toute **écriture sur période close** ayant abouti (garde-fou défaillant).
- Tout **chevauchement de segments** ou **orphelin `processing`**.
- Toute **divergence** paie non explicable, ou incident bloquant utilisateur.

**Étape 5 — Rollback complet**
- `SELECT set_group_hours_source('<group>','legacy');` → **retour immédiat** au calcul
  legacy (journalisé). Réversibilité prouvée (défaut legacy = comportement d'origine).
- Les segments/données restent intacts (aucune destruction) ; seule la **source de
  lecture** bascule. Aucune migration inverse nécessaire.

---

## 13. Critères GO Production

| Domaine | État |
|---|---|
| Architecture (conception) | **PASS** |
| Chaîne de migrations (reproductibilité dépôt) | **NO-GO** (stubs `46`→`53`) |
| Déploiement `sql/54` en prod | **NON RÉALISÉ** |
| Concurrence | **PASS** (7/7, PG16 local) |
| Calcul heures (moteur DB) | **PASS** (24/24) |
| Paie — garde-fou | **PASS** (6/6) |
| Frontend C1 (paie) | **WARNING** (câblé, non testé navigateur) |
| Frontend C2–C5 | **NON RÉALISÉ** |
| QA navigateur end-to-end | **EN ATTENTE** |
| Sécurité (1 ERROR + search_path) | **WARNING** |
| Performance (RLS/FK à l'échelle) | **WARNING** |
| CI / tests automatisés | **ABSENT** |
| Observabilité runtime | **WARNING** |
| Pilote interne | **NON RÉALISÉ** |

### Verdict Production : **NO-GO**

Justification : trois éléments **bloquants** interdisent la production aujourd'hui —
(1) migration **non déployée**, (2) schéma **non reproductible depuis le dépôt**,
(3) frontend **incomplet et non testé en navigateur** — auxquels s'ajoutent l'absence
de CI et une dette de sécurité/perf à traiter.

### Verdict Pilote interne : **GO SOUS CONDITIONS**

Conditions **préalables** au démarrage du pilote :
1. **Backfiller les migrations `46`→`53`** dans le dépôt (DDL réel extrait du schéma
   live) **ou** adopter formellement « prod = source de vérité DDL » avec procédure
   documentée. *(Reproductibilité / DR.)*
2. **Déployer `sql/54`** en staging puis prod via migration **revue** (idempotente,
   testée). *(Le moteur ne fait rien tant que le flag n'est pas basculé.)*
3. **QA navigateur de C1** (paie) sur le groupe pilote avant bascule du flag.
4. **Corriger l'ERROR** `security_definer_view` (`v_staff_day_flags`) et figer le
   `search_path` de `trg_staff_planning_move_guard`.
5. Retirer les 3 `console.log` résiduels.

Conditions **pendant** le pilote : checklist quotidienne (§12), kill-switch armé,
rollback par flag testé au moins une fois à blanc.

> **Le pilote est justifié** parce que le risque est **encadré** : défaut legacy inerte,
> garde-fou paie prouvé, réversibilité par flag. **La production ne l'est pas** tant que
> la chaîne de release (déploiement reproductible, QA end-to-end, CI, sécurité) n'est pas
> assainie.

---

## Annexe — Audit automatique du dépôt

| Recherche | Résultat |
|---|---|
| `TODO` | 0 (code) — 1 faux positif doc (`aide.html`, « CTR-XXX »). |
| `FIXME` / `HACK` / `XXX` | 0 réel. |
| `console.log` / `console.debug` | **3** (`index.html:9143`, `:9144`, `:15759`). |
| `debugger` | 0. |
| Imports inutilisés | non détectés (pas de bundler ; scripts inline). |
| Fonctions jamais appelées | modules `renderStub` (roadmap, intentionnels). |
| Fichiers orphelins | aucun détecté côté moteur déplacement. |
| Code mort | calcul d'heures **legacy JS** (transition — à retirer post-migration C2–C5). |
| Migrations incomplètes | **`sql/46`→`53` = stubs (0 ligne exécutable)** — dette #1. |
| Feature flags oubliés | `hours.source` non déployé (attendu) ; `features.coverage` utilisé en lecture. |
| Legacy oublié | chemins d'heures legacy **actifs par défaut** (voulu tant que non migré). |
| `service_role` en littéral | **0** (seule la clé anon publishable, pré-existante, apparaît). |

**Constat de l'audit automatique** : le dépôt est **propre en dette de surface**
(quasi 0 TODO/FIXME, 0 debugger, pas de secret), mais porte **une dette structurelle
forte** : **migrations non reproductibles** et **frontend monolithique partiellement
migré**. Ce sont ces deux points, avec l'absence de CI, qui pèsent le plus sur la
décision.
