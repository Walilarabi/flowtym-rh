# Dossier d'exploitation — Flowtym RH (RC1)

Ce dossier permet à une **équipe d'exploitation** de déployer, exploiter, surveiller
et dépanner le pilote Flowtym RH **sans dépendance à l'auteur du code**. Code **gelé**
(RC1) : corrections critiques / sécurité / stabilité / QA uniquement.

## Contenu

| Fichier | Usage |
|---|---|
| [`deployment.md`](deployment.md) | Procédure complète PR→merge→CI→staging→prod→flag→vérifs, avec commandes. |
| [`rollback.md`](rollback.md) | 3 niveaux de retour arrière (flag / front / migrations). |
| [`pilot-checklist.md`](pilot-checklist.md) | Checklists avant/pendant/après, GO/NO-GO, **QA fonctionnelle** (E1–E10). |
| [`incident-runbook.md`](incident-runbook.md) | Qui intervient, diagnostic, retour legacy, cohérence des données. |
| [`feature-flags.md`](feature-flags.md) | Le flag `hours.source` (lecture, activation, journal, garanties). |
| [`daily-checklist.md`](daily-checklist.md) | Contrôles quotidiens des invariants pendant le pilote. |

## Le pilote en 6 idées

1. **Périmètre** : moteur d'heures basé **segments** (source de vérité) + garde-fou
   **paie clôturée**, activé pour **un seul groupe** via le flag `hours.source=segments`.
2. **Défaut = legacy** : tant que le flag n'est pas basculé, **rien ne change** pour
   les utilisateurs. Aucun autre groupe n'est impacté.
3. **Réversible** : rollback par flag en ~1 s (`set_group_hours_source(...,'legacy')`),
   sans perte de données.
4. **Sûr pour la paie** : toute écriture sur une période close est refusée (`FL001`),
   sans écriture partielle.
5. **Prouvé** : reconstruction depuis le dépôt + tests **P0 24/24** et **concurrence
   A–G 7/7** (CI bloquante `.github/workflows/ci.yml`).
6. **Surveillé** : checklist quotidienne + runbook d'incident + kill-switch.

## Artefacts techniques référencés
- Migrations : `sql/54_p0_hours_canonical.sql`, `sql/55_security_hardening.sql`.
- Reconstruction : `db/reconstruct/` (`rebuild.sh`).
- Tests : `scripts/p0/`, `scripts/concurrency/local/`, `scripts/ci/run-db-tests.sh`.
- Projet Supabase prod : `hzrzkvdebaadditvbqis`. Front : Vercel (`flowtym-rh`).

## Objets & signaux clés à connaître
- Flag : `hotel_groups.features.hours.source ∈ {legacy, segments}`.
- RPC : `set_group_hours_source`, `group_hours_source`, `staff_hours_day`,
  `staff_hours_week`, `staff_hotel_hours_range`, `group_move_apply`.
- Garde-fou paie : table `staff_payroll_periods` (statut `closed`) → erreur **`FL001`**.
- Journal flag : `hotel_group_flag_audit`. Audit planning : `planning_audit`.
- Invariants (doivent rester à 0) : orphelins `processing`, chevauchements de segments,
  multi-`operation_id`, audit manquant.

## Hors périmètre RC1 (interdits)
Drag & Drop, IA, activation générale, migration P1, facturation premium, toute
nouvelle fonctionnalité.

## Ordre de lecture recommandé
`README` → `feature-flags` → `deployment` → `pilot-checklist` → `daily-checklist`
→ `incident-runbook` → `rollback`.
