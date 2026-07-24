# Critères de succès du pilote — Flowtym RH

Document de **référence pour la revue CTO de clôture**. Il définit, de façon
**strictement objective**, ce qui constitue un succès ou un échec du pilote. Il **ne
propose aucune évolution produit** : il ne sert qu'à **évaluer**.

- **Périmètre évalué** : moteur d'heures basé segments + déplacement inter-hôtels +
  garde-fou paie, activé via `hours.source=segments` sur **le seul groupe pilote**.
- **Sources de mesure** : `docs/operations/kpi-product.md`, `daily-checklist.md`,
  registres `pilot-incidents.md` / `user-feedback.md` / `pilot-decisions.md`, synthèses
  hebdomadaires. **Aucune nouvelle instrumentation** (RC1 figée).
- **Convention** : un critère est *Atteint* / *Acceptable* / *Échec* selon les seuils.
  Le verdict global suit la règle de décision §5.

---

## 1. Objectifs du pilote

| # | Objectif | Intention |
|---|---|---|
| O1 | **Fiabilité du calcul des heures** | Les heures reflètent la présence réelle (segments), sans double compte ni perte. |
| O2 | **Stabilité du planning** | Aucune corruption ni divergence entre segments et projection grille. |
| O3 | **Sécurité des déplacements** | Concurrence maîtrisée (aucune double application, aucun chevauchement). |
| O4 | **Qualité de la paie** | Éléments variables justes ; aucune modification d'une période clôturée. |
| O5 | **Adoption utilisateur** | Le produit est réellement utilisé pour les cas cibles (planning, déplacement). |
| O6 | **Robustesse des procédures** | Déploiement, surveillance, rollback et incident fonctionnent en conditions réelles. |

---

## 2. Critères mesurables

Pour chaque objectif : indicateur · valeur **cible** · **seuil acceptable** · **seuil
d'échec**. (Détail de calcul dans `kpi-product.md`.)

### O1 — Fiabilité du calcul des heures
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Écarts d'heures confirmés faux en paie (jour déplacé) | 0 | 0 | ≥ 1 |
| Rapprochements paie « heures = réel » (échantillon hebdo) | 100 % | ≥ 95 % | < 95 % |
| Cas de **double compte** cross-hôtel | 0 | 0 | ≥ 1 |

### O2 — Stabilité du planning
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Jours « verts » (invariants à 0 : chevauchements, orphelins) | 100 % | ≥ 98 % | < 98 % ou 1 jour rouge non résolu |
| Divergence segments ↔ projection (reconstruction) | 0 | 0 | ≥ 1 |

### O3 — Sécurité des déplacements
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Chevauchements de segments (double présence) | 0 | 0 | ≥ 1 |
| Applications concurrentes en double (même déplacement appliqué 2×) | 0 | 0 | ≥ 1 |
| Enregistrements d'idempotence orphelins (`processing`) | 0 | 0 | ≥ 1 persistant |

### O4 — Qualité de la paie
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Écriture aboutie sur une **période close** (garde-fou `FL001`) | 0 | 0 | ≥ 1 |
| Refus `FL001` **faux positifs** (période ouverte bloquée) | 0 | ≤ 1 corrigé | > 1 |
| Exports paie exploitables sans retouche manuelle des heures | 100 % | ≥ 95 % | < 95 % |

### O5 — Adoption utilisateur
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Déplacements inter-hôtels appliqués (durée pilote) | usage régulier | ≥ 1/semaine | 0 sur le pilote |
| Jours ouvrés avec activité planning | tous | ≥ 80 % | < 50 % |
| Délai médian création → application d'un remplacement | ≤ 1 j | ≤ 3 j | > 3 j récurrent |

### O6 — Robustesse des procédures
| Indicateur | Cible | Acceptable | Échec |
|---|---|---|---|
| Déploiement (staging→prod) sans incident bloquant | oui | oui | non |
| Rollback par flag testé en réel (au moins 1×) | réussi | réussi | non testé / échoué |
| Incidents traités selon le runbook (traçabilité) | 100 % | ≥ 90 % | < 90 % |
| Sécurité : ERROR advisor en production | 0 | 0 | ≥ 1 |

---

## 3. Critères qualitatifs

Recueillis par mini-enquête hebdomadaire + synthèse `user-feedback.md` (échelle 1–5 sauf
mention). Non bloquants **isolément**, mais un score bas répété est un signal fort.

| Dimension | Définition | Cible | Signal d'alerte |
|---|---|---|---|
| **Satisfaction utilisateur** | Utilité et justesse perçues | ≥ 4/5 | < 3/5 |
| **Facilité d'utilisation** | Effort pour réaliser les tâches cibles | ≥ 4/5 | < 3/5 |
| **Compréhension** | Le produit est clair (pas d'ambiguïté d'usage) | ≥ 4/5 | signalements récurrents « je ne comprends pas » |
| **Confiance** | Confiance dans les heures/paie produites | ≥ 4/5 | tout doute exprimé sur la justesse paie |
| **Perception de la stabilité** | Sentiment de fiabilité au quotidien | ≥ 4/5 | perception « ça bug » même sans incident DB |

> Un écart entre stabilité **mesurée** (O2/O3 verts) et stabilité **perçue** basse est
> lui-même un constat à documenter (souvent UX/compréhension → RC2, pas un échec technique).

---

## 4. Critères d'arrêt immédiat (kill-switch)

Toute situation ci-dessous impose l'**arrêt immédiat** du pilote : bascule flag →
`legacy` (`rollback.md` Niveau 1), gel des déplacements sur le groupe, escalade, et
consignation en incident **Critique**.

| # | Situation | Détection |
|---|---|---|
| S1 | **Perte / corruption de données** planning ou segments | invariants, signalement, reconstruction divergente |
| S2 | **Calcul de paie erroné** confirmé (double compte, heures fausses) | rapprochement paie, signalement référent paie |
| S3 | **Corruption du planning** (divergence segments/projection non reconstructible) | `staff_planning_rebuild_day` diverge |
| S4 | **Chevauchement de segments** persistant (double présence) | `daily-checklist` Bloc 1b ≠ 0 |
| S5 | **Garde-fou paie défaillant** (écriture aboutie sur période close) | test `FL001`, audit |
| S6 | **Faille de sécurité** exploitable identifiée | revue sécurité / signalement |
| S7 | **Rollback obligatoire** décidé par le Release Manager (incident non maîtrisé) | décision tracée |

> Après un arrêt, aucune reprise sans : cause racine identifiée, correctif validé
> (exception au gel), invariants revenus à 0, et décision explicite du Release Manager.

---

## 5. Critères GO Version 1.0

Conditions **minimales et objectives** pour proposer officiellement un **GO Version
1.0** en revue CTO de clôture. **Toutes** doivent être satisfaites.

| # | Condition | Mesure objective |
|---|---|---|
| G1 | Pilote mené à terme | Durée planifiée atteinte, clôture tracée (`pilot-decisions.md`) |
| G2 | **Aucun critère d'arrêt (§4) survenu** non résolu | 0 situation S1–S7 ouverte |
| G3 | **Objectifs mesurables §2 : aucun en « Échec »** | O1–O6 tous *Atteint* ou *Acceptable* |
| G4 | Fiabilité heures (O1) & paie (O4) | *Atteint* (0 écart faux, 0 écriture sur période close) |
| G5 | Stabilité (O2/O3) | ≥ 98 % de jours verts, 0 chevauchement/orphelin persistant |
| G6 | Sécurité | 0 ERROR advisor en production |
| G7 | Robustesse procédures (O6) | déploiement OK + **rollback flag testé en réel** |
| G8 | Adoption réelle (O5) | usage effectif du déplacement (≥ 1/semaine) + activité planning régulière |
| G9 | Qualitatif (§3) | satisfaction & confiance ≥ 3/5, sans alerte majeure non traitée |
| G10 | Traçabilité complète | registres incidents/décisions/retours tenus ; rapport de clôture factuel produit |

**Règle de décision globale (revue CTO de clôture)** :
- **GO Version 1.0** si **G1–G10 tous satisfaits**.
- **RC2 (sans 1.0)** si aucun critère d'arrêt, mais un ou plusieurs mesurables en
  *Acceptable* (non *Échec*) ou qualitatif faible → reprise du développement pour lever
  les écarts avant 1.0.
- **Prolongation du pilote** si données insuffisantes (durée/adoption trop faibles pour
  conclure : G1 ou G8 non atteints).
- **Retour arrière** si **≥ 1 critère d'arrêt §4** est survenu et non maîtrisé.

> Rappel : ces critères **évaluent** le pilote. Ils n'autorisent **pas** à eux seuls la
> **production générale**, qui reste conditionnée aux pré-requis production distincts
> (baseline produit complète, perf à l'échelle, revue surface `anon` — voir
> `release-readiness-review-v2.md` et `RC2-roadmap.md`).
