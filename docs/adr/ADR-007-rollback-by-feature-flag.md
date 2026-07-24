# ADR-007 — Le rollback se fait d'abord par feature flag

**Statut** : Accepté.

## Contexte
Un incident pendant le pilote exige un retour arrière **rapide et sûr**.

## Problème
Minimiser le temps de rétablissement et le risque, sans restaurer de backup ni impacter
les données.

## Décision
Le **recours n°1** est la bascule du flag : `set_group_hours_source('<group>','legacy')`
(~1 s), qui remet les écrans au calcul historique **sans toucher aux données**. Le
rollback frontend (Vercel) et le rollback migrations ne viennent qu'ensuite, si nécessaire.

## Alternatives étudiées
1. Rollback migrations d'abord → lent, risqué, inutile dans la plupart des cas.
2. Restauration de backup → perte de données récentes, lourd.
3. **Flag d'abord (retenu)**.

## Avantages
- Rétablissement quasi instantané, réversible, sans perte de données.
- Les segments/grille restent intacts (on ne change que la source de lecture).

## Inconvénients
- Ne corrige pas un défaut structurel de migration (rare) → niveaux 2/3 en secours.

## Impacts futurs
- Tout futur moteur activable par flag hérite de la même stratégie de rollback.
