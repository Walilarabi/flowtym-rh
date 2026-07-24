# ADR-002 — `staff_planning` est une projection journalière (pas la vérité)

**Statut** : Accepté.

## Contexte
La grille `staff_planning` est utilisée partout (affichage, couverture au statut,
exports, compteurs) et par de nombreux consommateurs historiques.

## Problème
Faire coexister le nouveau modèle segments (ADR-001) avec l'existant sans tout réécrire,
tout en garantissant qu'aucune source ne diverge silencieusement.

## Décision
`staff_planning` devient une **projection/cache dérivé** = marqueur de **couverture** et
de **statut** journalier. Pour toute journée segmentée, elle est **reconstructible** par
`staff_planning_rebuild_day` (égalité exacte sur les colonnes métier/opérationnelles ;
champs cosmétiques exclus). Elle **n'est jamais** utilisée pour calculer des heures sur un
jour fractionné.

## Alternatives étudiées
1. Supprimer la grille → casserait tous les consommateurs existants.
2. Dupliquer les heures dans la grille → risque de divergence.
3. **Projection reconstructible (retenu)**.

## Avantages
- Rétro-compatibilité : les écrans de couverture (au statut) restent sûrs et inchangés.
- Divergence impossible : garde d'intégrité (ADR-004) + reconstruction prouvée.

## Inconvénients
- Un lecteur naïf peut croire la grille « vraie » pour les heures → règle explicite requise.

## Impacts futurs
- Les migrations de consommateurs (paie, suivi) lisent la vérité (segments), pas la grille.
