# Moteur de simulation de déplacement inter-hôtels

Module **pur et indépendant de l'interface** : `js/move-simulator.js`
(exposé en CommonJS `module.exports` et en global navigateur `window.FlowtymMoveSim`).

Il **ne déplace jamais** un collaborateur : il calcule les conséquences d'un
déplacement proposé et renvoie un verdict structuré. Réutilisable par le
Drag & Drop, les suggestions IA, les simulations RH et les propositions
automatiques de renfort.

## API

```js
const { simulateMove } = FlowtymMoveSim;
const result = simulateMove({ move, context, config });
```

### Entrée

- `move` : `{ employeeId, service, day 'YYYY-MM-DD', fromHotelId, toHotelId, requiredSkills? }`
- `context` :
  - `hotels` : `[{ id, name, hotel_code, active }]`
  - `cells` : cellules de planning du jour `[{ hotel_id, employee_id, day, status, is_extra, origin_hotel_id, ... }]`
  - `requirements` : `[{ hotel_id, weekday, shift, required }]` (shift null = jour, V1)
  - `employee` : `{ id, skills?, availability?{unavailableDays[],available?,reason?}, plannedThisWeek?{hours,consecutiveDays}, lastRestHours? }`
  - `serviceSkills?` : `{ [service]: [compétences requises] }`
- `config` (tout est surchargeable, aucune valeur métier codée en dur dans la logique) :
  - `coverage` : `{ redBelow, limiteUpTo, conformeUpTo }` (ratios prévu/requis — **même logique que le Planning Groupe**)
  - `regulatory` : `{ maxWeeklyHours, maxConsecutiveDays, minRestHours, shiftHours }`
  - `workingStatuses`, `blockOnMissingSkill`, `blockOnUnavailable`

### Sortie (`SimulationResult`)

| Champ | Contenu |
|---|---|
| `ok` | `false` si au moins un blocage dur |
| `blockers` | blocages empêchant le déplacement `[{code,message}]` |
| `warnings` | avertissements non bloquants |
| `conflicts` | conflits (ex. double affectation) |
| `from` / `to` | impact hôtel départ / arrivée : `before`/`after` = `{prevu,requis,ecart,level,label,tauxCouverture}` |
| `coverageChange` | évolution des niveaux de couverture aux 2 hôtels |
| `sousEffectif` | `{before, after, delta}` |
| `skills` | `{required, have, missing}` |
| `regulatory` | dépassements `[{code,message,severity}]` |
| `availability` | `{available, reason}` |
| `summary` | résumé lisible |

### Codes

- Blocages : `BLK_INVALID_INPUT`, `BLK_SAME_HOTEL`, `BLK_DEST_INACTIVE`,
  `BLK_NOT_PRESENT_AT_SOURCE`, `BLK_ALREADY_AT_DEST`, `BLK_MISSING_SKILLS` (opt.),
  `BLK_UNAVAILABLE` (opt.)
- Avertissements : `WARN_CREATES_UNDERSTAFF_SOURCE`, `WARN_OVERSTAFF_DEST`,
  `WARN_DEST_REQ_NOT_CONFIGURED`, `WARN_MISSING_SKILLS`, `WARN_UNAVAILABLE`,
  `WARN_REG_*`
- Réglementaire : `REG_WEEKLY_HOURS`, `REG_CONSECUTIVE_DAYS`, `REG_REST`
- Conflit : `CFL_ALREADY_AT_DEST`

## Tests

`node tests/simulation/move-simulator.test.mjs` — 22 assertions, couvrant les
9 dimensions demandées + la paramétrabilité des seuils + la pureté (aucune
mutation des entrées).

## Phase suivante (non développée ici)

**Drag & Drop intelligent** : la couche UI construira l'objet `move` à partir
du glisser-déposer, appellera `simulateMove`, **affichera** le `SimulationResult`
(impacts, couverture, blocages, avertissements) et ne déclenchera l'écriture
réelle qu'après confirmation — toute écriture posant `operation_id` / `source =
group_planning` / `reason` (journal déjà prêt).
