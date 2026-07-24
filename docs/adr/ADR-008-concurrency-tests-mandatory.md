# ADR-008 — Les tests de concurrence sont obligatoires (gate CI)

**Statut** : Accepté.

## Contexte
`group_move_apply` est un point critique : plusieurs managers peuvent l'invoquer
simultanément pour le même salarié. Les bugs de concurrence sont non déterministes et
dangereux (double application, chevauchement, perte).

## Problème
Empêcher toute régression de concurrence d'atteindre la production.

## Décision
Un runbook de concurrence à **deux connexions réelles** (scénarios A–G) doit passer
**7/7** (0 deadlock, 0 chevauchement, 0 orphelin) et est **rejoué en CI** sur une base
reconstruite depuis le dépôt. Une PR qui casse ces invariants est **non fusionnable**.

## Alternatives étudiées
1. Tests unitaires mono-connexion → ne prouvent pas la sérialisation réelle.
2. Revue de code seule → insuffisant pour la concurrence.
3. **Tests 2 connexions + gate CI (retenu)**.

## Avantages
- Preuve runtime des invariants (advisory locks, idempotence, exclusion).
- Non-régression garantie à chaque PR.

## Inconvénients
- Tests plus lents (verrous + `pg_sleep`) ; nécessite un PostgreSQL en CI.

## Impacts futurs
- Tout nouveau chemin d'écriture concurrent doit être couvert par un scénario équivalent.
