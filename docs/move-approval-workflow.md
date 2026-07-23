# Workflow d'approbation des propositions de renfort

Étape de validation humaine entre le brouillon et l'application. **N'exécute
aucun déplacement** et n'écrit ni dans `staff_planning` ni dans `planning_audit`.
S'arrête à `approved` / `scheduled`. `applied` est réservé à la phase suivante.

## Statuts
`draft → pending_review → approved → scheduled` (+ `rejected`, `cancelled`,
`expired`, `applied`). L'application ne sera autorisée que depuis `approved`
ou `scheduled`.

## Workflow paramétrable (`group_move_workflows`)
`steps` = tableau ordonné `[{key,label,approver_type,hotel_scope}]`.
- `approver_type` : `origin_director | dest_director | group_director | rh | any`
- `hotel_scope` : `origin | dest | both | any`
- Exemples : aucun approbateur (`[]` → approbation auto) ; directeur origine ;
  directeur destination (défaut) ; directeur groupe ; RH ; plusieurs validations
  successives.

## Étapes (`group_move_approvals`)
À la soumission, une instance par étape (statut `pending`). L'approbation avance
étape par étape ; la dernière fait passer la proposition en `approved`. Un rejet
la met en `rejected`.

## Programmation
Une proposition **approuvée** peut être **programmée** (`group_move_schedule`)
à une date/heure future (`scheduled_at`) — statut `scheduled`, **sans exécution**.

## Timeline & notifications
- `group_move_timeline(id)` renvoie `events` + `approvals` + `notifications`.
- `group_move_notifications` : notifications **préparées** (review_requested,
  approved, rejected, scheduled) avec `sent_at = NULL` (aucun envoi dans cette phase).

## Droits ajoutés (modules)
`group_move_review`, `group_move_approve`, `group_move_reject`,
`group_move_schedule`, `group_move_apply` (apply = phase suivante).
> Note : la RLS garantit déjà l'accès aux deux hôtels ; la distinction fine
> directeur/RH est portée par ces droits applicatifs (et l'`approver_type` de
> l'étape), la base garantissant l'accès.

## Écrans
Panneau « Propositions de renfort » enrichi : actions **Approuver l'étape**,
**Rejeter**, **Programmer** (selon statut + droit) ; vue détail avec **circuit
d'approbation** + **timeline** complète + compteur de notifications préparées.

## Tests réellement exécutés (rolled-back, auth manager réel)
13/13 : aucun approbateur → approuvé auto ; 2 validations successives (étape 1
laisse `pending_review`, étape 2 → `approved`) ; programmation future OK / passée
refusée ; timeline (6 événements, 2 approbations) ; 4 notifications préparées
(`sent_at` NULL) ; rejet à une étape ; `back_to_draft` efface les approbations ;
annulation depuis `scheduled` ; **staff_planning inchangé (14502→14502)** ;
**planning_audit inchangé (7→7)**.

## Prérequis restants pour `group_move_apply`
1. Droit `group_move_apply` (déjà déclaré) + gate stricte : uniquement depuis
   `approved`/`scheduled`.
2. RPC transactionnelle `group_move_apply(id)` : re-simulation serveur (refus si
   `blocked`/obsolète), écriture `staff_planning` en UNE transaction, journal
   `planning_audit` (`operation_id`/`source='group_planning'`/`reason`), verrou,
   idempotence/rollback, passage en `applied`.
3. Exécuteur des déplacements `scheduled` (job à l'échéance `scheduled_at`).
4. Envoi réel des notifications (worker consommant `group_move_notifications`).
