# Brouillon de déplacement inter-hôtels (phase proposition)

Écrit uniquement dans de **nouvelles tables** de propositions. **Aucune écriture**
dans `staff_planning` ni `planning_audit`. Le flux s'arrête à l'étape 3
(révision), avant toute application réelle.

## Modèle de données

- **`group_move_proposals`** — collaborateur, from/to hôtel + service, période,
  `slots`, motif, `status`, `decision`/`score`/`confidence`, `simulation` (snapshot
  lisible : summary, reasons, impact, blockers, warnings, positives, données
  manquantes), `simulation_created_at`, `simulation_input_hash`,
  `simulation_result_hash`, `staleness`, `expires_at`, `created_by`, `group_id`.
- **`group_move_proposal_events`** — historique propre (created, updated,
  submitted, back_to_draft, rejected, cancelled, expired, resimulated,
  waiver_added, marked_stale) : actor, action, old/new status, comment, metadata.
- **`group_move_proposal_waivers`** — dérogations : check_code, justification
  (obligatoire), value_before, overage_value, waived_by.

## Migrations
`sql/46_group_move_proposals.sql` (tables) + RPCs (migration group_move_proposal_rpcs).

## RLS
`gmp_access` (ALL) : `from_hotel_id ∈ pl_my_hotels() AND to_hotel_id ∈ pl_my_hotels()`.
Événements/dérogations : SELECT via jointure ; écritures via RPC SECURITY DEFINER
uniquement (INSERT/UPDATE/DELETE révoqués aux rôles clients).

## Droits ajoutés
- `group_move_prepare` (module) — créer/consulter les brouillons (direction/admin
  par défaut ; override DB possible). Réservé pour plus tard : `group_move_apply`.

## Écrans créés
- Bouton **« Préparer le déplacement »** activé dans le panneau de simulation
  (si `decision != blocked` et droit) → crée un brouillon.
- Panneau **« Propositions de renfort »** (bouton dans la barre Planning Groupe) :
  filtres (statut, recherche) ; par proposition : collaborateur, origine,
  destination, dates, décision, confiance, avertissements, statut, fraîcheur ;
  actions : ouvrir, soumettre, rejeter, annuler, retour brouillon. **Aucune
  application réelle.**

## Tests réellement exécutés (rolled-back, sous auth manager réel)
15/15 : création autorisée ; refus blocage non dérogeable ; création avec
avertissements ; justification de dérogation obligatoire ; soumission exigeant
dérogation ; accès destination refusé ; obsolescence `to_refresh` ; deux
propositions concurrentes ; annulation ; rejet ; historique complet (≥3
événements) ; **staff_planning inchangé (14502→14502)** ; **planning_audit
inchangé (7→7)** ; **isolation/RLS (un tiers ne voit rien)**.

## Preuve d'absence de modification du planning
Comptes `staff_planning` et `planning_audit` identiques avant/après le scénario
complet (voir test 12/13). Aucune RPC de cette phase n'écrit dans ces tables.

## Re-validation obligatoire (obsolescence)
Le snapshot de simulation est informatif. `simulation_input_hash` /
`simulation_result_hash` + `simulation_created_at` (+ `expires_at`) permettront à
la phase d'application d'imposer une **re-simulation avec les données à jour**.
Si les données changent, le brouillon passe `to_refresh` / `conflict` / `expired`.

## Prérequis restants pour l'écriture atomique (phase suivante)
1. RPC transactionnelle `group_move_apply(proposal_id)` : (a) RE-simuler côté
   serveur (source de vérité), (b) refuser si `blocked` ou snapshot obsolète,
   (c) écrire `staff_planning` en UNE transaction, (d) journaliser dans
   `planning_audit` avec `operation_id` commun + `source='group_planning'` +
   `reason`, (e) verrou anti-concurrence (FOR UPDATE), idempotence + rollback.
2. Droit `group_move_apply` (distinct de `group_move_prepare`).
3. Portage/duplication du moteur en logique serveur (ou appel edge) pour la
   re-vérification avant écriture.
4. Détecteur d'obsolescence automatique (comparaison de hash au chargement /
   avant application).
