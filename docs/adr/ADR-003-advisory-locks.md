# ADR-003 — Les déplacements utilisent des advisory locks transactionnels

**Statut** : Accepté.

## Contexte
`group_move_apply` écrit des segments et la grille pour un `(employee_id, jour)`. Deux
managers peuvent appliquer simultanément des déplacements pour le même salarié.

## Problème
Sérialiser les écritures concurrentes **même quand aucune ligne n'existe encore** (un
`SELECT ... FOR UPDATE` ne verrouille rien s'il n'y a pas de ligne).

## Décision
Poser `pg_advisory_xact_lock(hashtextextended(employee_id || '|' || jour))` au début de
la RPC, pour chaque jour concerné, en plus de `FOR UPDATE` et de la PK d'idempotence.

## Alternatives étudiées
1. `FOR UPDATE` seul → insuffisant sans ligne préexistante (prouvé : scénario E).
2. `SERIALIZABLE` → surcoût et retries applicatifs plus complexes.
3. Verrou applicatif externe (Redis…) → dépendance hors base, moins fiable.
4. **Advisory xact lock (retenu)** → sérialise par clé logique, libéré au commit/rollback.

## Avantages
- Sérialise par `(salarié, jour)` sans dépendre de l'existence de lignes.
- Portée transaction : libération automatique (commit **ou** rollback).
- Prouvé : blocage réel ~2 s (A/B/C/E), non-sérialisation inter-jours (D).

## Inconvénients
- Clé de hachage à choisir avec soin (collision improbable mais théorique).
- Invisible aux outils classiques de verrous de lignes.

## Impacts futurs
- Tout nouveau chemin d'écriture inter-hôtels doit réutiliser la **même clé** d'avis.
