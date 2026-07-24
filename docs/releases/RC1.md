# RC1 — Certificat de naissance

**Produit** : Flowtym RH · **Version** : Release Candidate 1 (RC1) · **Statut** : **FIGÉE**
· **Branche** : `claude/admiring-hopper-4Rq1n` · **PR** : #2 (brouillon, non fusionnée)
· **Date de clôture** : 2026-07-24.

> RC1 est la première version candidate destinée à un **pilote interne**. Le code est
> **gelé** : plus aucune évolution fonctionnelle jusqu'à la fin du pilote.

## 1. Objectif de RC1

Livrer, de façon **prouvée et réversible**, le **moteur d'heures basé sur les segments**
(source de vérité) et le **déplacement inter-hôtels atomique**, activables sur **un seul
groupe pilote** via un feature flag, sans risque pour la paie ni pour les autres groupes.

## 2. Périmètre couvert

- **Déplacement inter-hôtels** : proposition → workflow d'approbation → application
  atomique (`group_move_apply`) avec verrous, idempotence et contrainte d'exclusion.
- **Modèle A des heures** : `staff_planning_segments` = source de vérité ;
  `staff_planning` = projection journalière reconstructible.
- **Fonction canonique unique** des heures (brut / pauses / net / ventilation
  hôtel + `service_id` / total jour + semaine).
- **Garde-fou paie clôturée** (`FL001`) sur tous les chemins d'écriture.
- **Feature flag** `hours.source` (par groupe, défaut legacy, journalisé).
- **Frontend** : écrans Paie (C1) et Suivi du temps (C2) branchés sur la fonction
  canonique derrière le flag.
- **Reproductibilité** : `db/reconstruct/` reconstruit la base pilote depuis le dépôt.
- **CI bloquante** + **dossier d'exploitation** complet.

## 3. Fonctionnalités incluses

| Domaine | Inclus |
|---|---|
| Planning Groupe (lecture) | ✅ multi-hôtels, couverture par service, indicateurs |
| Simulation de déplacement (pure) | ✅ classification blocking/warning/info/positive |
| Propositions + workflow d'approbation | ✅ statuts, timeline, notifications, droits distincts |
| Concurrence & conflits | ✅ réservations, verrous, expiration, recheck |
| Application atomique `group_move_apply` | ✅ idempotence, recheck, rollback, audit |
| Heures via segments (fonction canonique) | ✅ C1 (paie) + C2 (suivi) derrière flag |
| Garde-fou paie clôturée | ✅ `FL001`, atomique, 6 chemins |
| Feature flag `hours.source` | ✅ par groupe, réversible, journalisé |
| Sécurité (durcissement) | ✅ 0 ERROR advisor (après déploiement `sql/55`) |
| CI + reconstruction depuis le dépôt | ✅ |

## 4. Fonctionnalités volontairement exclues

- **Drag & Drop** utilisateur (déplacement par glisser-déposer).
- **Activation générale** du moteur segments (réservé au groupe pilote).
- **Migration P1** (service_id saisi nativement, moteur de couverture par tranche).
- **Facturation premium** / monétisation.
- **IA** / assistants.
- **Frontend C3–C5** : compteurs légaux de la grille d'édition (projection d'édition,
  non autoritaire), `v_staff_month_summary`, `check_replacement_constraints`
  (documentés, différés RC2).
- **Baseline produit complète** reproductible (au-delà du périmètre pilote).

## 5. Commits majeurs

| Hash | Objet |
|---|---|
| `9d95639` | Garde-fou anti-divergence non falsifiable (remplace le GUC) |
| `a3c3d99` | Reconstruction du résumé depuis les segments (preuve) |
| `54ab529` | Runbook concurrence instrumenté (livrables A–G) |
| `296283b` | **Concurrence exécutée réellement à 2 connexions — GO** |
| `71cc45f` | **Moteur d'heures segments** (fonction canonique, garde-fou paie, flag) |
| `6ba0ea6` | Revue de préparation au pilote (audit CTO) |
| `9544a05` | **LOT A** — dépôt auto-suffisant pour reconstruire la base |
| `ed58d43` | **LOT C+E** — 0 ERROR sécurité + CI bloquante |
| `cb2566b` | LOT B — C2 branché sur la fonction canonique |
| `5b65568` | Retrait des `console.log` (0 restant) |
| `d182435` | **Release Readiness Review v2 — GO pilote** |
| `84321bc` | Dossier d'exploitation `docs/operations/` |
| `4c33199` | Registre backlog RC2 (gel RC1) |

## 6. Preuves techniques obtenues

- **Concurrence réelle** à deux backends PostgreSQL distincts (PID différents),
  scénarios A–G.
- **Reconstruction depuis le dépôt seul** sur cluster PostgreSQL 16 vierge (sans
  dépendance à la production).
- **Non-régression concurrence** après correctif `group_move_apply` (préservation des
  heures « journée entière »).
- **Garde-fou paie** : refus `FL001` atomique sur 6 chemins d'écriture, période ouverte
  autorisée.
- **Sécurité** : vue `security_invoker`, `search_path` figé.

## 7. Résultats des tests

| Suite | Résultat |
|---|---|
| Concurrence A–G (2 connexions) | **7/7 PASS** · 0 deadlock · 0 chevauchement · 0 orphelin |
| Heures + paie (`scripts/p0`) | **24/24 PASS** (15 cas heures + 6 chemins paie + atomicité + service + semaine + parité) |
| Reconstruction depuis le dépôt | P0 24/24 + A–G 7/7 sur base reconstruite |
| Moteurs purs (node) | tests simulation OK |

## 8. État de la sécurité

- **1 ERROR** advisor (vue SECURITY DEFINER) **corrigé** dans `sql/55` → **0 ERROR
  après déploiement**.
- `search_path` figé sur les fonctions du moteur déplacement.
- RLS active sur les tables sensibles ; `service_role` jamais exposée au front.
- Avis restants (anon surface, perf RLS/FK à l'échelle) **classés** et **différés RC2**
  (non bloquants au volume pilote).

## 9. État de la CI

`.github/workflows/ci.yml` — 2 jobs **bloquants** :
- `frontend-syntax` (parse JS, refuse `debugger`) ;
- `db-tests` (reconstruction depuis le dépôt + P0 24/24 + invariants concurrence).
Runner `scripts/ci/run-db-tests.sh` validé. **Action d'exploitation** : activer la
protection de branche `main` (checks requis).

## 10. État de la documentation

- Architecture & preuves : `docs/staff-planning-consumers.md`, `docs/move-*.md`,
  `docs/coverage-engine-design.md`, `docs/p0-migration-*.md`.
- Revues : `docs/release-readiness-review.md` (v1), `-v2.md`.
- Exploitation : `docs/operations/` (deployment, rollback, pilot-checklist,
  incident-runbook, feature-flags, daily-checklist, rc2-backlog).
- Gouvernance : `docs/releases/`, `docs/adr/` (ce lot).

## 11. Dette technique restante

Voir `docs/operations/rc2-backlog.md`. Principaux : baseline produit **complète**
reproductible (P1 prod), `auth_rls_initplan` + FK non indexées (perf à l'échelle),
revue surface `anon`, migration frontend C3–C5, découpe du monolithe `index.html`,
observabilité runtime.

## 12. Conditions du pilote

- Déployer `sql/54` + `sql/55` (staging → prod, migration revue).
- Activer `hours.source=segments` sur **le seul** groupe pilote.
- Dérouler la QA fonctionnelle (`docs/operations/pilot-checklist.md` §E).
- Armer la checklist quotidienne + runbook d'incident ; kill-switch prêt (flag legacy).
- Défaut legacy partout ailleurs (isolation).

## 13. Critères de sortie du pilote

Voir `docs/releases/rc2-entry-criteria.md`. En résumé : pilote mené à terme, **0 bug
critique ouvert**, sécurité validée (0 ERROR en prod), stabilité et performance
confirmées au volume pilote, retours utilisateurs recueillis et priorisés, décisions du
pilote documentées, backlog RC2 priorisée.

---

**Certifié** : RC1 est une version **prouvée, réversible et documentée**, prête pour un
pilote interne encadré. Ce document fait foi de l'état du produit à la clôture de RC1.
