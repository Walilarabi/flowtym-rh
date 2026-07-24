# ADR-001 — `staff_planning_segments` est la source de vérité des heures

**Statut** : Accepté · **Date** : 2026-07 · **Décideurs** : équipe RH/Planning.

## Contexte
Un collaborateur peut être présent sur **plusieurs hôtels le même jour** (déplacement
inter-hôtels), avec des tranches horaires partielles. La grille historique
(`staff_planning`) ne modélise qu'**une ligne par hôtel/jour** avec des bornes de shift.

## Problème
Calculer les heures depuis la grille produit des erreurs : (a) `fin − début` sur un jour
fractionné surestime la présence, (b) cumuler des jours travaillés **entre hôtels**
double-compte un jour partagé. Impact **paie** direct.

## Décision
Les **segments** (`staff_planning_segments`, un intervalle `[seg_start_min, seg_end_min)`
par présence, avec `hotel_id`, `kind`, `status`, `service_id`) sont **l'unique source de
vérité des heures et durées**. Une contrainte d'exclusion GiST interdit tout chevauchement
`(employee_id, day, intervalle)`.

## Alternatives étudiées
1. Garder la grille + colonnes d'heures ad hoc → fragile, double compte non résolu.
2. Table d'heures agrégées par jour → perd la répartition par hôtel/tranche.
3. **Segments (retenu)** → présence réelle, additive, sans chevauchement.

## Avantages
- Aucun double compte ; ventilation exacte par hôtel et par `service_id`.
- Contrainte d'exclusion = invariant DB (deux présences chevauchantes impossibles).
- Modèle extensible (couverture par tranche, futur).

## Inconvénients
- Deux représentations à maintenir cohérentes (segments + projection grille).
- Migration des consommateurs d'heures nécessaire (progressive, par flag).

## Impacts futurs
- Base du moteur de couverture par tranche (P1).
- Tout nouveau calcul d'heures **doit** passer par les segments (ADR-006).
