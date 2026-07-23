# Moteur de conflits & concurrence

Dernière brique métier avant `group_move_apply`. Détermine si une proposition
est toujours applicable. **N'exécute aucun déplacement** ; n'écrit ni
`staff_planning` ni `planning_audit`.

## Module pur `js/conflict-engine.js`
Déterministe, sans I/O.
- `categoryHashes(raw)` / `diffCategories(old,new)` — obsolescence par catégorie :
  planning, requirements, absences, skills, hours, rhRules, travel, workflow.
- `slotsOverlap(a,b)` — chevauchement de créneaux (date + horaires ; journée
  complète chevauche tout).
- `detectConflicts(target, others)` — propositions ouvertes du même collaborateur
  aux créneaux chevauchants.
- `resolvePriority(proposals)` — prioritaire / à revalider / à annuler.
  Règle : statut le plus avancé (rang applied>scheduled>approved>pending>draft),
  puis la plus ancienne, puis meilleur score. Perdantes approved/scheduled →
  `revalidate` ; draft/pending_review → `cancel`.
- `assess({storedHashes,currentHashes,expiresAt,now,decision,conflicts})` →
  `valid | to_refresh | conflict | expired` (+ applicabilité). Expiration
  prioritaire, puis conflit, puis obsolescence.

## Support DB (RPC)
- `group_move_reservations(from,to)` — collaborateurs **réservés** par une
  proposition approved/scheduled sur la période (badge « RÉSERVÉ / Proposition
  en attente » dans le Planning Groupe).
- `group_move_open_for_employee(emp,exclude)` — propositions concurrentes ouvertes.
- `group_move_expire_run()` — expiration auto des demandes non approuvées au délai
  dépassé ; repérage des programmées en retard (notif).
- `group_move_recheck(id,current_hashes,conflicts)` — met à jour `staleness` et
  prépare les notifications (`to_revalidate`, `conflict_detected`, `expired`).

## Réservation
Une proposition approuvée/programmée réserve visuellement le collaborateur dans
le Planning Groupe pour éviter qu'un autre directeur prépare un déplacement
incompatible.

## Délais préparés
- expiration automatique d'une demande non approuvée (`expire_run`) ;
- obsolescence d'une simulation (`recheck` → `to_refresh`) ;
- détection des programmées non exécutées (`expire_run` → notif `deadline_passed`).

## Notifications préparées (sent_at NULL)
`expired`, `to_revalidate`, `conflict_detected`, `deadline_passed`
(+ `review_requested`, `approved`, `rejected`, `scheduled` des phases précédentes).
`reservation_exists` / `deadline_near` : signaux calculables côté moteur
(`deadlineNear`) — à émettre par le futur worker de notifications.

## Tests réellement exécutés
- `node tests/simulation/conflict-engine.test.mjs` → **18/18** (chevauchement,
  détection de concurrentes, priorité/revalidate/cancel, empreintes+diff, assess
  valid/to_refresh/conflict/expired, priorité de l'expiration, déterminisme).
- DB (rolled-back, auth réel) → **11/11** : réservation détectée, concurrence,
  recheck to_refresh/conflict/valid, notif to_revalidate, expiration + notif,
  programmée en retard + notif, **staff_planning inchangé (14502→14502)**,
  **planning_audit inchangé (7→7)**.

## Prérequis restants pour `group_move_apply`
1. RPC transactionnelle `group_move_apply(id)` : re-simulation serveur + **recheck
   obligatoire** (refus si `to_refresh`/`conflict`/`expired`/`blocked`), écriture
   `staff_planning` en UNE transaction, journal `planning_audit`
   (`operation_id`/`source='group_planning'`/`reason`), verrou, idempotence/rollback,
   passage `applied` + résolution des concurrentes (annulation des perdantes).
2. Droit `group_move_apply` (déjà déclaré).
3. Jobs planifiés : `group_move_expire_run` (délais) + exécuteur des `scheduled`
   à échéance + worker d'envoi des notifications.
