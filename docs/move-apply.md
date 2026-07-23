# Application atomique du déplacement — `group_move_apply`

Dernière étape métier avant le Drag & Drop. Une **seule RPC transactionnelle**
applique un déplacement approuvé, avec re-vérification serveur, verrous,
idempotence, audit atomique et rollback intégral.

## Modèle staff_planning — confirmation
`(hotel_id, employee_id, day)` unique **par hôtel** ⇒ un collaborateur peut avoir
des lignes sur deux hôtels le même jour ⇒ affectation temporaire inter-hôtels
(y compris split-day) **représentable**. `employee_id` non contraint à un hôtel.
Statuts `PE` (destination) / `MAD` (origine). `shift_start/end` pour les partiels.

## Migration minimale
- `staff_planning.source_proposal_id`, `staff_planning.origin_hotel_id` (traçabilité/réversibilité).
- `group_move_proposals.server_fingerprint` (empreinte serveur), `applied_at`, `applied_operation_id`.
- `group_move_applications(idempotency_key PK, proposal_id, operation_id, applied_by, applied_at, result)`.
- `_gmp_fingerprint(...)` : empreinte SQL déterministe des données décisives
  (planning collaborateur période + besoins destination + trajet couple + workflow).

## RPC `group_move_apply(p_id, p_idempotency_key)`
1. **Verrou** de la proposition (`FOR UPDATE`).
2. **Idempotence** : clé déjà vue ⇒ retourne le résultat mémorisé (aucune ré-écriture).
3. **Statut** : `approved` ou `scheduled` **arrivée à échéance** uniquement.
4. **Re-simulation / recheck serveur AVANT écriture** — refus si : bloquée,
   dérogation manquante, expirée, **données modifiées** (empreinte serveur ≠
   stockée ⇒ passe `to_refresh`), **concurrente prioritaire** (rang/ancienneté).
5. **Verrou** du planning du collaborateur (jours concernés, `FOR UPDATE`).
6. **Audit** : `set_config` `flowtym.audit_source='group_planning'`, `audit_reason`,
   `operation_id` commun — le trigger `planning_audit` journalise dans la même transaction.
7. **Écriture atomique** : destination `PE` (+ `shift_start/end` si créneau),
   origine `MAD` si journée complète (splits/partiels ⇒ origine conservée) ; multi-jours géré.
8. **`applied`** — `employees` intact : hôtel & service principaux **conservés**.
9. **Résolution des concurrentes** ouvertes perdantes ⇒ `cancelled`.
10. **Enregistrement idempotent**.
Toute exception ⇒ **rollback intégral** (atomicité de la fonction plpgsql).

## Droit
`group_move_apply` (module frontend) ; l'accès aux deux hôtels est garanti par
`_gmp_guard` (RLS). Aucune logique métier distincte : un futur scheduler
appellera **exactement** cette RPC (statut `scheduled` à échéance).

## Preuves (tests réellement exécutés)
### DB (rolled-back, auth manager réel) — 14/14
`1 apply_ok · 2 status=applied · 3 destination PE écrite (source_proposal_id) ·
4 origine MAD · 5 audit atomique via operation_id · 5b source=group_planning + reason ·
6 idempotence sans doublon · 7 ré-application interdite · 8 refus non-approuvé ·
9 refus expirée · 10 refus données modifiées (empreinte serveur) · 11 refus bloquée ·
12 refus concurrente prioritaire · 13 concurrente perdante annulée · 14 ROLLBACK
intégral (slot poison ⇒ 0 ligne persistée, statut reste approved)`.

### Parité (node) — 2/2
- **Déterminisme** du moteur : même entrée ⇒ même sortie (base de la garantie).
  La garde serveur ne ré-exécute pas un 2e moteur : elle vérifie que les données
  décisives sont **inchangées** (empreinte serveur). Moteur déterministe +
  empreinte identique ⇒ la simulation stockée EST encore la sortie du moteur pour
  les données courantes = **parité par construction**.
- **32 combinaisons** (bloquée × dérogation × expirée × données modifiées ×
  concurrente) : la garde serveur ≡ l'applicabilité client (`conflict-engine.assess`),
  **0 divergence**.

### Rollback
Test 14 : un créneau invalide (date nulle) provoque une exception **après** la
première écriture ⇒ la transaction de la fonction est intégralement annulée
(0 ligne `source_proposal_id`), la proposition reste `approved`.

## Idempotence
`group_move_applications.idempotency_key` (PK). Ré-appel avec la même clé ⇒
retour du résultat mémorisé, aucune ré-écriture. Ré-appel avec une autre clé sur
une proposition déjà `applied` ⇒ refus (statut non applicable).

## Non développé (conformément au cadrage)
Drag & Drop visuel, primes, IA, envoi réel des notifications, modifications
contractuelles. Le scheduler des `scheduled` et le worker de notifications
appelleront la RPC / consommeront les notifications sans logique métier propre.
