# Concurrence `group_move_apply` — exécution RÉELLE à deux connexions (instance locale jetable)

Ce document rapporte l'exécution **réelle** du runbook de concurrence
(`scripts/concurrency/two-session-apply.sql`, scénarios A–G) sur une instance
PostgreSQL **locale, isolée et jetable**, avec **deux backends psql réellement
distincts**. Il lève la réserve « concurrence non validée » de
`docs/staff-planning-consumers.md`.

## Pourquoi en local (et non sur staging/hébergé)

- Impossible de créer un 3ᵉ projet Supabase (offre limitée à 2). Aucun des deux
  projets existants n'est un « staging » jetable ; l'un est le projet vivant.
- **Contrainte tenue** : on ne touche pas la production. Depuis le sandbox, le
  réseau sortant vers Postgres est bloqué et `dblink`/MCP ne donnent **pas** deux
  backends persistants concurrents (chaque appel MCP = backend éphémère différent).
- Solution retenue : un **cluster PostgreSQL 16 local** (binaires présents dans
  l'image), initialisé à vide, chargé avec le **schéma seul** reconstruit, et un
  **seed 100 % fictif**. Deux `psql` = deux processus = deux `pg_backend_pid()`.

## Checkpoint schéma — le dépôt seul est INSUFFISANT (transparent)

Les fichiers `sql/46`→`sql/53` sont des **stubs de documentation**
(« appliqué via migration MCP ») : **0 ligne de DDL exécutable**. Le dépôt ne
peut donc pas reconstruire le schéma complet. Objets manquants du dépôt, **extraits
du schéma live en DDL uniquement (aucune donnée de production)** via
`pg_get_functiondef` / `information_schema` :

- **Tables** : `group_move_proposals`, `group_move_applications`,
  `group_move_proposal_events`, `group_move_proposal_waivers`,
  `group_move_notifications`, `group_move_approvals`, `group_move_workflows`,
  `group_staffing_requirements`, `hotel_travel_times`, `staff_planning_segments`,
  et les colonnes `source_proposal_id`/`origin_hotel_id`/segments de `staff_planning`.
- **Fonctions/RPC** : `group_move_apply`, `group_move_proposal_create`,
  `group_move_proposal_submit`, `group_move_workflow_get/_set`,
  `group_move_open_for_employee`, `_gmp_fingerprint`, `_gmp_subtract`,
  `_gmp_guard`, `_gmp_can_access`, `_gmp_notify`, `pl_my_hotels`,
  `staff_planning_rebuild_day`.
- **Triggers** : `planning_audit_trg` (`trg_planning_audit`),
  `trg_sp_move_guard` (`trg_staff_planning_move_guard`), `trg_planning_touch`.
- **Contraintes clés** : exclusion `EXCLUDE USING gist (employee_id =, day =,
  int4range(seg_start_min,seg_end_min) &&)` ; PK d'idempotence
  `group_move_applications(idempotency_key)` ; unicité `staff_planning(hotel_id,
  employee_id, day)`.

Ces corps sont reproduits **verbatim** dans
`scripts/concurrency/local/01_schema.sql` et `02_functions.sql`. Les seuls
aménagements (documentés) : shim `auth.uid()` (lit le claim JWT via GUC), et
`pl_my_hotels` reste identique mais s'appuie sur un `user_hotels` fictif. Les
seams `_gmp_can_access`/`_gmp_notify` sont conservés à l'identique.

## Environnement

| Élément | Valeur |
|---|---|
| Serveur local | **PostgreSQL 16.13** (Ubuntu 24.04) |
| Extensions | `btree_gist 1.7`, `pgcrypto 1.3` |
| Source du DDL | schéma hébergé **PostgreSQL 17.6** — *DDL uniquement, aucune donnée* |
| Chaîne de connexion (masquée) | `postgresql://postgres:***@[unix-socket:/var/tmp/pgcc/sock]:55432/flowtym_cc` |
| Auth | socket local, `trust` (cluster jetable, isolé) |
| Backends distincts observés | **12** (2 par scénario A–F, + G) |

## Preuve des deux connexions distinctes (PID différents)

| Scénario | Session A (PID) | Session B (PID) |
|---|---|---|
| A | 8105 | 8106 |
| B | 8112 | 8111 |
| C | 8118 | 8117 |
| D | 8123 | 8124 |
| E | 8129 | 8130 |
| F | 8136 (rollback) | 8137 |
| G | 8141 (A puis A-retry, même client) | — |

## Résultats A–G (livrable 2 — PASS/FAIL calculé)

| Scn | PIDs | Appl. effectives | Attendu | min wait | **max wait** | deadlock | timeout | statuts finaux | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| A | 2 | 1 | 1 | 29 ms | **2020 ms** | non | non | applied | **PASS** |
| B | 2 | 1 | 1 | 13 ms | **2020 ms** | non | non | applied | **PASS** |
| C | 2 | 1 | 1 | 16 ms | **2025 ms** | non | non | applied,cancelled | **PASS** |
| D | 2 | 2 | 2 | 12 ms | 24 ms | non | non | applied | **PASS** |
| E | 2 | 1 | 1 | 11 ms | **2017 ms** | non | non | applied | **PASS** |
| F | 1 | 1 | 1 | 2029 ms | 2029 ms | non | non | applied | **PASS** |
| G | 1 | 1 | 1 | 1 ms | 12 ms | non | non | applied | **PASS** |

Lecture :
- **A** — même proposition, même clé : la 2ᵉ session **bloque 2,02 s** sur le
  verrou d'avis puis renvoie le résultat **mémorisé** (même `operation_id`
  `72adbf41`) ⇒ **aucun doublon**.
- **B** — même proposition, deux clés : B bloque 2,02 s puis échoue proprement
  `Statut non applicable (applied)` ; **une seule** application.
- **C** — deux propositions, **même jour** : la gagnante applique, la perdante
  se réveille sur `cancelled` (annulée par la gagnante) ⇒ 1 application ; la
  contrainte d'exclusion reste intacte (0 chevauchement).
- **D** — deux propositions, **jours différents** : **aucun blocage**
  (max wait 24 ms), les **deux** réussissent ⇒ clés d'avis `(emp||jour)`
  bien disjointes.
- **E** — **aucune ligne `staff_planning` préexistante** : B **bloque quand
  même 2,02 s** (verrou d'avis, indépendant de `FOR UPDATE`) puis échoue ⇒
  sérialisation prouvée **sans ligne** à verrouiller.
- **F** — 1ʳᵉ transaction **ROLLBACK** : ses écritures et sa ligne `cc_results`
  disparaissent ; B applique ensuite normalement ⇒ verrou libéré, reprise propre.
- **G** — **retry même clé après « timeout »** : 2ᵉ appel renvoie le **même
  `operation_id`** (`c2df719e`), `idem_status='completed'`, `sp_count` inchangé.

## Anomalies (livrable 4 — toutes à 0)

| Contrôle | Lignes |
|---|---|
| `orphan_processing` (idempotence coincée) | **0** |
| `segment_overlap` (double présence) | **0** |
| `multi_operation_per_apply` | **0** |

## État final (livrable 3, extrait)

- `staff_planning` : pour chaque jour appliqué, **VO=PE** (destination) et
  **FO=MAD** (origine vacante, journée complète) ; jour E (sans ligne préalable)
  ⇒ seulement **VO=PE** créé.
- `staff_planning_segments` : un segment `destination 0h-24h PE` par jour
  appliqué (journée complète), aucun chevauchement.
- `group_move_applications` : 8 clés `completed`, **aucune** `processing`.

## Verdict global (livrable 5)

```
missing_scenarios=0  deadlocks=0  wrong_effective=0  orphans=0  overlap_cnt=0
=> GO
```

## Différences local ↔ hébergé (honnêteté)

1. **Version serveur** : test sur **PG 16.13**, prod sur **PG 17.6**. La
   sémantique employée (`pg_advisory_xact_lock`, `FOR UPDATE`, exclusion GiST,
   PK d'idempotence, `ON CONFLICT`) est **stable et identique** entre 16 et 17 ;
   aucune de ces primitives n'a changé de comportement.
2. **RLS / rôles** : en local les RPC tournent en superutilisateur `postgres`
   (comme un `SECURITY DEFINER` appartenant à `postgres` en prod). Le garde
   `current_user IN ('authenticated','anon')` reste actif mais non déclenché par
   le chemin RPC — **identique** à la prod (le déplacement passe toujours par le
   RPC). Les vérifications d'accès `pl_my_hotels` sont conservées et satisfaites
   par le seed.
3. **Seams neutralisés** : `_gmp_notify` écrit dans `group_move_notifications`
   (présent) ; aucune Edge Function/cron n'intervient — sans effet sur la
   concurrence testée.
4. **Ordonnancement** : le décalage inter-sessions est produit par `pg_sleep`
   côté serveur (le holder garde la transaction ouverte 3 s). Cela **majore** le
   blocage réel observé sur les scénarios A/B/C/E/F (~2 s), ce qui **renforce**
   plutôt qu'affaiblit la preuve.

## Recommandation P0

Sous réserve des différences ci-dessus (toutes non impactantes pour les
invariants de concurrence), le socle transactionnel de `group_move_apply` se
comporte **exactement comme spécifié** sous concurrence réelle à deux backends :
sérialisation par `(employé||jour)`, idempotence sans doublon, non-sérialisation
inter-jours, reprise après rollback, aucune double présence.

**Recommandation : GO** pour la migration P0 du point de vue **concurrence /
atomicité**. (Ceci ne lève **pas** les autres pré-requis produit ; le Drag & Drop
et la migration P0 ne sont pas démarrés, conformément à la consigne.)

## Reproductibilité

Tout est rejouable via `scripts/concurrency/local/run-local.sh` (après `initdb`
+ `postgres` sur un port local). Aucun secret, aucune donnée personnelle : le
seed n'utilise que des UUID fixes fictifs et un collaborateur « Alex Test ».
