# Architecture Decision Records (ADR) — Flowtym RH

Décisions structurantes du produit, documentées pour qu'un nouveau
développeur / PO / QA / CTO comprenne les choix sans l'historique des échanges.

| ADR | Décision | Statut |
|---|---|---|
| [ADR-001](ADR-001-segments-source-of-truth.md) | `staff_planning_segments` = source de vérité des heures | Accepté |
| [ADR-002](ADR-002-staff-planning-projection.md) | `staff_planning` = projection journalière | Accepté |
| [ADR-003](ADR-003-advisory-locks.md) | Advisory locks pour les déplacements | Accepté |
| [ADR-004](ADR-004-payroll-guard-fl001.md) | Paie protégée par `FL001` | Accepté |
| [ADR-005](ADR-005-feature-flags-per-group.md) | Feature flags par groupe | Accepté |
| [ADR-006](ADR-006-canonical-hours-function.md) | Fonction canonique unique des heures | Accepté |
| [ADR-007](ADR-007-rollback-by-feature-flag.md) | Rollback d'abord par feature flag | Accepté |
| [ADR-008](ADR-008-concurrency-tests-mandatory.md) | Tests de concurrence obligatoires | Accepté |

Format : Contexte · Problème · Décision · Alternatives · Avantages · Inconvénients · Impacts futurs.
