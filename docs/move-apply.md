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

---

## Durcissement (réserves levées)

### 1. Modèle réel & split supporté
- **staff_planning** : 1 ligne / hôtel / jour = **marqueur de couverture** (bornes).
- **staff_planning_segments** (nouvelle) : identifiant propre, **plusieurs segments
  par jour et par hôtel**, contrainte d'**exclusion** anti-chevauchement.
- **Cas de split supportés** : shift entier, début, fin, **milieu** (2 segments
  origine même hôtel), **plusieurs créneaux/jour**, multi-jours, sans ligne
  d'origine, collision destination (upsert). Prouvé (7 cas).
- **Cas encore approximés** : la GRILLE staff_planning ne montre que les **bornes**
  (union) pour un jour fractionné ; le détail exact vit dans les **segments**
  (source de vérité, reconstruction exacte prouvée : `FO 8-10, VO 10-12, FO 12-16`).
- **Cas interdits** : deux présences qui se chevauchent le même jour (garanti
  impossible par la contrainte d'exclusion).

### 2. Re-simulation serveur — clarification honnête
`group_move_apply` **n'exécute PAS une re-simulation complète** du moteur. Elle
effectue : (a) recalcul d'une **empreinte serveur** des données décisives et
comparaison à l'empreinte figée à la simulation ; (b) des **gardes SQL**
(statut, dérogations, expiration, priorité/concurrence). Le moteur étant
déterministe (prouvé), empreinte identique ⇒ la simulation figée EST encore sa
sortie pour les données courantes ; empreinte différente ⇒ refus (re-simulation
client requise). **Champs couverts par l'empreinte** : planning (statuts,
horaires, heures), absences, besoins (par shift), trajet, workflow, seuils de
couverture. **Non recalculés** : compétences & disponibilités (**non modélisés**
dans le schéma), règles RH (constantes par défaut). Dérogations & propositions
concurrentes : **gardes** dédiées. Test : modification isolée de chaque catégorie
⇒ refus (6/6).

### 3. Verrou global
`pg_advisory_xact_lock(hashtextextended(employee||day))` par jour concerné
(sérialise même **sans** ligne existante) + `FOR UPDATE` (lignes existantes) +
**contrainte d'exclusion** des segments (invariant ultime, tient sous vraie
concurrence) + **PK d'idempotence**. Deux sessions concurrentes ⇒ une seule
application compatible.

### 4. Cycle de vie de l'idempotence
`group_move_applications(idempotency_key PK, status: processing→completed dans la
MÊME transaction)`. Réservation de la clé au début ; `completed` à la fin.
- **retry après succès (même clé)** ⇒ résultat mémorisé, aucune ré-écriture.
- **retry après refus métier** ⇒ transaction annulée ⇒ **aucune ligne** (jamais
  d'orphelin `processing`), nouvelle tentative possible.
- **rollback principal** ⇒ la réservation est annulée avec le reste.
- **clé réutilisée sur une autre proposition** ⇒ conflit PK ⇒ retour de l'état
  mémorisé (completed) ou refus « application en cours ».
- **timeout client alors que le serveur a committé** ⇒ retry même clé ⇒ résultat
  mémorisé (idempotent).

### 5. Tests à deux sessions
Un test à **deux connexions réellement concurrentes n'est pas exécutable** via
l'outil MCP (transactions auto-commit isolées). Sont fournis : (a) le script
`scripts/concurrency/two-session-apply.sql` à lancer sur staging ; (b) la preuve
des **invariants data-level** qui garantissent la sûreté sous concurrence :
contrainte d'exclusion (chevauchement refusé) + double-application bloquée ⇒
**une seule application effective**.

### Tests réellement exécutés (récap durcissement)
- Rognage/split 7 cas (segments + grille + audit).
- Empreinte : 6/6 catégories bloquent (planning, absences, requirements, travel,
  workflow, coverage).
- Idempotence : retry succès sans doublon, `completed`, **aucun orphelin** après
  refus.
- Reconstruction split-day exacte depuis les segments.
- Concurrence data-level : exclusion + double-apply bloqué + 1 seule application.
- (Antérieurs) 14/14 apply + parité 2/2.
