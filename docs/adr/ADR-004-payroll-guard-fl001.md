# ADR-004 — La paie clôturée est protégée par le code d'erreur `FL001`

**Statut** : Accepté.

## Contexte
Une fois une période de paie **clôturée** et transmise, toute modification rétroactive
des heures est inacceptable (risque légal/financier).

## Problème
Empêcher **toute** écriture (segment, grille, déplacement, reconstruction) impactant une
période close, quel que soit le chemin, **sans écriture partielle**, avec un signal stable.

## Décision
Table `staff_payroll_periods` (statut `closed`) + triggers `BEFORE INSERT/UPDATE/DELETE`
sur `staff_planning` **et** `staff_planning_segments`, appelant `_assert_payroll_open`,
qui lève `RAISE EXCEPTION ... USING ERRCODE='FL001'`. Le refus **annule la transaction**
(atomicité) ; `group_move_apply` refuse donc **atomiquement**.

## Alternatives étudiées
1. Vérification applicative (frontend/RPC) → contournable, non atomique.
2. Colonne `locked` par ligne → ne couvre pas les lignes futures/inexistantes.
3. **Triggers + code stable (retenu)** → défense en profondeur, non contournable.

## Avantages
- Couvre les 6 chemins d'écriture ; refus atomique, code `FL001` machine-lisible.
- Indépendant du feature flag (ne peut être contourné par `segments`).
- Inerte tant qu'aucune période n'est close (comportement inchangé).

## Inconvénients
- Un refus `FL001` doit être correctement présenté à l'utilisateur (message clair).

## Impacts futurs
- La clôture de période (mise en `closed`) reste un acte métier à outiller (RC2).
