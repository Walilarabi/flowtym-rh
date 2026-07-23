# Intégration du simulateur — Lot 1 (LECTURE SEULE)

Connecte le moteur de simulation (`js/move-simulator.js`) au Planning Groupe.
**Aucune écriture** : aucun `staff_planning`, extra, prime, publication, ni
`planning_audit`. Le flux s'arrête à l'affichage du panneau (étape 5/8).

## Fichiers créés / modifiés

| Fichier | Rôle |
|---|---|
| `js/move-simulator.js` | Moteur pur (v2) — ajout `config.time.missingTravelLevel` (politique trajet non configuré) |
| `js/sim-adapter.js` | **Couche d'adaptation pure** : `assessInputs()` (complétude + confiance), `buildContext()` (normalisation → contrat moteur), `buildTravel()` |
| `index.html` | Bouton « Simuler » par collaborateur ; `gpOpenSimForm` (sélection) ; `buildMoveSimulationContext` (récupération Supabase → helpers purs → moteur) ; `gpRenderSimPanel` (panneau lecture seule) ; BE `groupTravelTimes`, `listEmployeeShifts` ; includes des 2 modules |
| `sql/45_hotel_travel_times.sql` | Contrat des temps de trajet (table + RPC + RLS + durcissement) |
| `tests/simulation/sim-adapter.test.mjs` | 12 cas de validation du lot |
| `docs/simulation-panel-mockup.png` | Rendu réel du panneau |

## Couche d'adaptation (le moteur n'accède jamais à Supabase)

`buildMoveSimulationContext(params)` (index.html) :
1. `BE.groupPlanning(destService, from, to)` → cellules + besoins + hôtels autorisés (destination).
2. Idem service d'origine si différent, fusionné.
3. `BE.groupTravelTimes()` (RPC scopée) + `BE.listEmployeeShifts(empId, from, to)` (staff_planning : `shift_start/end`).
4. Seuils de couverture depuis `org features.coverage`.
5. → `FlowtymSimAdapter.assessInputs(raw)` (complétude) puis `buildContext(raw)` → `FlowtymMoveSim.simulateMove(...)`.

Aucune donnée manquante n'est remplacée silencieusement : `assessInputs` renvoie
pour chaque donnée `available | missing | assumption`, un **niveau de confiance**,
et l'autorisation d'accès à la destination.

## Contrat des temps de trajet (`hotel_travel_times`)

| Colonne | Type |
|---|---|
| `from_hotel_id`, `to_hotel_id` | uuid (FK hotels) |
| `duration_min` | int (durée habituelle) |
| `safety_margin_min` | int (marge de sécurité, défaut 10) |
| `transport_type` | text (ex. metro/voiture/marche) |
| `valid_from`, `valid_to` | date (période de validité) |

- Unicité par couple orienté + `valid_from`. RLS `htt_manager` : **les deux**
  hôtels dans `pl_my_hotels()`. Lecture via `group_travel_times()` (SECURITY DEFINER).
- Écritures clientes révoquées (durci) — configuration ultérieure via RPC dédiée.
- La marge par couple est **repliée dans la durée** fournie au moteur (marge
  globale = 0) pour respecter une marge par couple.
- **Politique trajet non configuré** : `config.time.missingTravelLevel`
  (`info | warning | blocking`), pilotée par `org features.missingTravelLevel`
  (défaut `warning`). Affichage : « Temps de trajet non configuré ».

## Panneau (lecture seule)

Collaborateur · Décision (`allowed`/`allowed_with_warnings`/`blocked`) ·
Impact origine · Impact destination · Impact groupe · Contrôles séparés
(blocages / avertissements / effets positifs / informations) · Score (avec
facteurs, jamais seul) · Zone « Données manquantes / hypothèses » + confiance.
Boutons : **Fermer la simulation** / **Préparer le déplacement** (désactivé, aucune écriture).

## Tests réellement exécutés

- `node tests/simulation/move-simulator.test.mjs` → **15/15** (moteur).
- `node tests/simulation/sim-adapter.test.mjs` → **12 cas / 14 assertions** :
  renfort pertinent, sous-effectif induit, déjà affecté (overlap), trajet
  insuffisant, trajet absent (warning ET blocking), compétence obligatoire,
  Extra sur autre service, quelques heures, multi-jours, accès destination refusé,
  besoin non configuré, multi-avertissements.
- DB : table + RPC créées, grants durcis (rolled-back check).

## Cas NON testés en runtime réel (hors sandbox)

- Rendu et interactions du panneau dans l'app manager (CDN/auth bloqués ici) —
  vérifié par `node --check` + maquette rendue.
- Parcours bout-en-bout avec un vrai compte manager sur staging.

## Données manquantes identifiées dans le modèle actuel

1. **Référentiel de compétences** par collaborateur et par service (obligatoires
   vs recommandées) : non modélisé → contrôle compétence en « hypothèse ».
2. **Règles RH structurées** (heures contractuelles hebdo, jours consécutifs,
   repos) par collaborateur/convention : non modélisées → défauts moteur.
3. **Disponibilités / indisponibilités** exploitables par le moteur (au-delà des
   statuts planning) : à relier (absences, souhaits).
4. **Amplitude/pauses réelles** dépendent de `shift_start/end` : présents mais
   pas toujours renseignés.
5. Temps de trajet : à saisir par couple (table prête, UI de configuration à venir).

## Prérequis pour l'écriture atomique (phase Drag & Drop)

- RPC transactionnelle unique `group_move_apply(...)` : (a) re-simule côté serveur
  (source de vérité), (b) refuse si `decision==='blocked'`, (c) applique les
  écritures `staff_planning` dans une seule transaction, (d) journalise avec
  `operation_id` commun + `source='group_planning'` + `reason`, (e) verrou
  anti-concurrence (FOR UPDATE / contrainte).
- Idempotence + rollback sur échec partiel.
- Journal `planning_audit` déjà prêt (operation_id / source / reason).
- Portage du moteur en logique serveur (ou appel edge) pour re-vérifier avant écriture.
