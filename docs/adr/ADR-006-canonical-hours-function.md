# ADR-006 — Une fonction canonique unique calcule les heures

**Statut** : Accepté.

## Contexte
Historiquement, les heures étaient recalculées dans plusieurs modules (paie, suivi,
compteurs légaux, remplacements), avec des formules dupliquées.

## Problème
Éviter la divergence entre modules et garantir un calcul **explicable et testable**,
unique, au-dessus des segments.

## Décision
`staff_hours_day(emp, jour, hpd)` renvoie un JSON explicable
(`gross`/`break`/`net`/`by_hotel`/`by_service`/`total`) ; `staff_hours_week` agrège la
semaine ; `staff_hotel_hours_range` fournit la part par hôtel pour les écrans. Tous les
calculs **autoritaires** (paie, suivi, reporting) passent par ces fonctions. Règles :
net = somme des présences (pas de double compte) ; marqueur « journée entière » = `hpd`.

## Alternatives étudiées
1. Calcul dans chaque module → duplication, divergence (état constaté avant P0).
2. Vue matérialisée → moins souple pour l'explicabilité par appel.
3. **Fonction canonique (retenu)**.

## Avantages
- Une seule vérité, testée (24/24) ; sortie explicable pour l'audit paie.
- La grille d'édition reste une aide de saisie, non un calcul autoritaire.

## Inconvénients
- Pendant la transition, le chemin legacy coexiste (contrôlé par le flag).

## Impacts futurs
- Tout nouveau consommateur d'heures **doit** appeler la fonction canonique.
