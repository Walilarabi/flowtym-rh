# Cartographie des consommateurs de `staff_planning` & décision d'architecture

Colonnes réelles : `status`, `shift_start`, `shift_end`, `hours`, `duration`
(pas `start_time/end_time`). Le nouveau modèle : **grille = marqueur de couverture
(bornes)**, **segments = source de vérité (heures exactes)**.

## Cartographie

| Consommateur | Table/colonnes utilisées | Compatible multi-segments ? | Risque | Correction requise |
|---|---|---|---|---|
| `group_planning` (Planning Groupe, couverture) | `status` | **Oui** — présence par hôtel/jour via statut (PE dest / MAD origine) | Faible | Aucune |
| `v_staff_month_summary` (résumé mensuel) | `status` (pas heures) | Oui pour la couverture ; total employé cross-hôtel à dédupliquer par jour | Faible | Dédupe par jour si total employé |
| Compteurs légaux (index.html) | jours travaillés × `hpd` + colonne `hours` (par hôtel) | **Partiel** — vue par hôtel OK ; **total cross-hôtel sur-compte** un jour fractionné (1 jour dans 2 hôtels) | **Moyen** | Utiliser `staff_day_hours` / segments pour les jours de déplacement |
| Grille planning (affichage horaires) | `shift_start/end` | **Non pour l'affichage exact** d'un jour fractionné (bornes) | Moyen (visuel) | Afficher les segments pour les jours `source_proposal_id` |
| Export PDF/Excel (index.html) | grille (`status`, horaires) | Non exact pour jours fractionnés | Moyen | Annoter/exporter les segments |
| Portail salarié (portal.html) | `status`, horaires (par hôtel/jour) | Non exact (salarié voit 08-16 à FO alors qu'il est partiellement à VO) | Moyen | Afficher les segments |
| `check_replacement_constraints` | `shift_start/end`, `hours` | Heures hebdo potentiellement inexactes sur jours fractionnés | Faible-Moyen | Heures via segments |
| `find_replacement_candidates` | `status` (disponibilité) | Oui (statut) | Faible | Disponibilité partielle via segments (option) |
| Paie (module RH) | `hours` / jours travaillés | **Sur-compte cross-hôtel** un jour fractionné | **Moyen-Élevé** | Calcul via `staff_day_hours` (segments) |
| `pl_portal_hotels`, `portal_request_decide`, `portal_leave_balances` | `status` | Oui | Faible | Aucune |
| Edge Functions / cron | Aucune ne calcule d'heures depuis `staff_planning` | — | Nul | — |

**Constat clé** : la **couverture** (basée sur le statut) est sûre. Le **risque
réel** est le **calcul d'heures** (a) via `end-start` sur la grille d'un jour
fractionné, ou (b) en cumulant les jours travaillés **entre hôtels** (double
compte). Ces consommateurs doivent passer par les segments.

## Décision d'architecture : **Modèle A** (recommandé, retenu)

`staff_planning_segments` est **l'unique source opérationnelle des heures et des
durées**. `staff_planning` est un **résumé/cache dérivé** = marqueur de
couverture et de statut, jamais utilisé pour calculer des heures sur un jour
fractionné.

Conditions (accord avec votre préférence) :
- **Heures & durées** : toujours via `staff_day_hours` / `staff_segment_hours`
  (segments). Prouvé : FO 08-10 + VO 10-12 + FO 12-16 ⇒ **FO=6h, VO=2h, total=8h**,
  aucune période continue 08-16 comptée 8h, aucun double compte.
- **Bornes de la grille** : union min/max (résumé), non contractuelles pour un
  jour fractionné.
- **Jour avec interruption** : plusieurs segments même hôtel (ex. FO 8-10 & 12-16).
- **Jour multi-hôtels** : un segment par présence (contrainte d'exclusion :
  aucun chevauchement).
- **Statuts différents par segment** : portés au niveau segment (`kind`,
  `status`) ; la grille garde le statut de couverture (PE/MAD).
- **Consommateurs à migrer** : compteurs légaux, paie, exports, affichage grille,
  portail salarié (chantier séparé, listé ci-dessus). **Non conflé avec le
  Drag & Drop.**

## Intégrité (anti-divergence)
Trigger `trg_staff_planning_move_guard` : une ligne `source_proposal_id` non nul
ne peut être **modifiée ni supprimée** manuellement (hors RPC posant
`flowtym.allow_move_write='on'`). Le résumé ne peut donc pas diverger des
segments sans passer par le déplacement. Vérifié (modif réelle bloquée,
suppression bloquée, no-op et lignes normales autorisées).

## Calcul des heures — cas testés
- Multi-segments même hôtel : FO 8-10 + 12-16 = 6h ✓
- Multi-hôtels même jour : FO 6h + VO 2h = 8h, total 8h ✓ (pas de double compte)
- Pause entre segments : non comptée (somme des durées de présence) ✓
- Segments adjacents : additionnés sans trou ✓ (par construction)
- Nuit / passage à minuit : représentés par **deux segments sur deux jours**
  (chaque segment borné 0..1440) — à modéliser explicitement côté saisie ;
  un segment ne franchit pas minuit.
- Changement de statut entre segments : `status` par segment.
- Segment rogné/supprimé : via le déplacement (RPC) ; recalcul immédiat depuis
  les segments.
- Arrondis : `round(minutes/60, 2)`.

## Niveau de validation explicite
La réponse de `group_move_apply` et l'événement d'audit `applied` contiennent :
```json
{ "validation": { "level": "valide_sur_donnees_disponibles" | "validation_partielle",
  "checks_run": ["planning","couverture","absences","trajet","chevauchement","expiration","concurrence","derogations"],
  "checks_unavailable": ["competences","disponibilites","regles_rh_variables"],
  "missing": [ ... ] } }
```
Les dimensions **non modélisées** (compétences, disponibilités, règles RH
variables) sont explicitement listées comme **contrôles non disponibles** — une
proposition n'est jamais présentée comme « totalement conforme ». La panneau de
simulation affiche déjà « Données manquantes / hypothèses · confiance X% » avant
l'application.

## Concurrence — statut HONNÊTE
Un test à **deux connexions réellement concurrentes n'a PAS pu être exécuté**
dans cet environnement : le réseau sortant vers Postgres est bloqué et `dblink`
exige le mot de passe de la base (TCP et sockets testés : « password required »),
`pg_background` indisponible. **Je ne qualifie donc pas la concurrence comme
validée.** Sont garantis et prouvés en revanche :
- **Invariant data-level** (indépendant des connexions) : contrainte d'exclusion
  des segments ⇒ deux présences chevauchantes le même jour **impossibles** ;
  double-application ⇒ **une seule effective** (prouvé).
- **Verrou** `pg_advisory_xact_lock(employee||jour)` (sérialise même sans ligne)
  + `FOR UPDATE` + **PK d'idempotence**.
Le test réel à deux sessions doit être joué sur **staging avec identifiants** via
`scripts/concurrency/two-session-apply.sql`. À exécuter avant tout GO Drag & Drop.
