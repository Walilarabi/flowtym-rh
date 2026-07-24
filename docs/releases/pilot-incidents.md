# Registre des incidents du pilote — Flowtym RH

Tout incident détecté (checklist quotidienne, signalement utilisateur, alerte) est
consigné ici. Procédure de traitement : `docs/operations/incident-runbook.md`.

## Convention
- **Gravité** : Critique / Élevé / Moyen / Faible.
- **Reproductible** : Oui / Non / Partiel.
- **Statut** : Ouvert / En cours / Corrigé / Fermé / Reporté RC2.
- Un incident **Critique** peut déclencher le kill-switch (flag → legacy).

| Date | Hôtel | Utilisateur | Description | Gravité | Reproductible | Diagnostic | Cause | Correctif | Statut |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | |

## Rappels
- Retour legacy immédiat : `SELECT set_group_hours_source('<GROUP>','legacy');`
- Invariants à vérifier : orphelins `processing`, chevauchements, double compte, `FL001`
  sur période ouverte (voir `daily-checklist.md`).
