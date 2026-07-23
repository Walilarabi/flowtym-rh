# Moteur de simulation de déplacement inter-hôtels (v2)

Module **pur, indépendant de l'interface** : `js/move-simulator.js`
(CommonJS `module.exports` + global navigateur `window.FlowtymMoveSim`).
Aucune dépendance DOM/réseau/écriture. **Aucune API cartographique** : le temps
de trajet est fourni dans le contexte (moteur déterministe).

Il **ne déplace jamais** un collaborateur : il calcule les conséquences et
renvoie une **décision explicable**. Cœur métier commun au Drag & Drop, aux
suggestions IA, aux simulations RH et aux propositions de renfort.

```js
const { simulateMove } = FlowtymMoveSim;
const result = simulateMove({ move, context, config });
```

## 1. Contrat d'entrée

### `move`
```js
{
  employeeId, employeeName?,
  fromHotelId, toHotelId,
  service | serviceId,                 // clé de service (couverture)
  requiredSkills?, recommendedSkills?, // override du référentiel
  slots: [ { date:'YYYY-MM-DD', start?:'HH:MM', end?:'HH:MM' } ]  // 1..n
}
```
- `slots` supporte : journée complète (sans `start`/`end`), shift complet, plage
  horaire partielle, plusieurs jours, plusieurs créneaux.
- Rétro-compat : `move.day` (sans `slots`) = journée complète.

### `context`
```js
{
  hotels: [{ id, name, hotel_code, active }],
  cells:  [{ hotel_id, employee_id, day, status, is_extra, origin_hotel_id }],
  requirements: [{ hotel_id, weekday, shift, required }],   // shift null = jour (V1)
  employee: {
    id, skills?:[],
    availability?: { unavailableDays?:[...], available?:bool, reason? },
    shifts?: [{ hotel_id, date, start:'HH:MM', end:'HH:MM' }],  // vacations existantes
    plannedThisWeek?: { hours?, consecutiveDays? }
  },
  serviceSkills?: { [service]: { required:[], recommended:[] } },
  travel: { minutesBetween: { 'FROM|TO': minutes, ... }, defaultMinutes? }  // fourni, pas d'API
}
```

### `config` (tout surchargeable — aucune valeur métier codée en dur)
```js
{
  coverage:   { redBelow:1.0, limiteUpTo:1.0, conformeUpTo:1.3 },        // ratios prévu/requis (= Planning Groupe)
  regulatory: { maxWeeklyHours:48, maxConsecutiveDays:6, shiftHours:7 },
  time:       { travelSafetyMarginMin:10, minBreakMin:20, maxDailyAmplitudeHours:13, minRestBetweenDaysHours:11 },
  workingStatuses: ['P','PE'],
  blockOnMissingRequiredSkill:true, blockOnUnavailable:true,
  score: { enabled:true, weights:{ base:50, destImproved:20, destFullyCovered:15, originSafe:20, groupReduced:15, warningPenalty:8 } }
}
```

## 2. Contrat de sortie (`SimulationResult`)
```js
{
  decision: 'blocked' | 'allowed_with_warnings' | 'allowed',
  score: number|null,                 // null si bloqué ; jamais prioritaire sur un blocage
  scoreBreakdown: [{ label, points }],
  summary: string,
  reasons: [ '…' ],                    // lisibles UI / IA
  impact: {
    groupUnderstaffingBefore, groupUnderstaffingAfter,
    originCoverageBefore, originCoverageAfter,          // ratios (ou null)
    destinationCoverageBefore, destinationCoverageAfter
  },
  checks:    [ Check ],               // TOUS les contrôles, classification uniforme
  blockers:  [ Check ], warnings:[ Check ], infos:[ Check ], positives:[ Check ],
  slots:     [ { date, origin:{before,after,prevuBefore,prevuAfter,requis}, destination:{…} } ],
  skills:    { required, recommended, have, missingRequired, missingRecommended },
  ok: boolean                          // miroir de decision !== 'blocked'
}
```
### `Check` (structure uniforme)
```js
{ code, level:'blocking'|'warning'|'info'|'positive', message, details, field, waivable }
```

## 3. Codes de contrôle

| Code | Niveau | Dérogeable |
|---|---|---|
| `INVALID_INPUT` | blocking | non |
| `SAME_HOTEL` | blocking | non |
| `DESTINATION_INACTIVE` | blocking | non |
| `EMPLOYEE_UNAVAILABLE` | blocking* | selon config |
| `REQUIRED_SKILL_MISSING` | blocking* | **oui** |
| `SHIFT_OVERLAP` | blocking | non |
| `TRAVEL_TIME_INSUFFICIENT` | blocking | non |
| `MINIMUM_REST_NOT_RESPECTED` | blocking | **oui** |
| `WEEKLY_HOURS_EXCEEDED` | warning | oui |
| `BREAK_TOO_SHORT` | warning | oui |
| `DAILY_AMPLITUDE_EXCEEDED` | warning | oui |
| `ORIGIN_UNDERSTAFFED_AFTER_MOVE` | warning | oui |
| `DESTINATION_STILL_UNDERSTAFFED` | warning | oui |
| `RECOMMENDED_SKILL_MISSING` | info | — |
| `TRAVEL_TIME_UNKNOWN` | info | — |
| `TRAVEL_TIME_OK` | positive | — |
| `DESTINATION_COVERAGE_IMPROVED` | positive | — |
| `GROUP_UNDERSTAFFING_REDUCED` | positive | — |

\* Niveau `blocking` par défaut, abaissé en `warning` selon `config`
(`blockOnUnavailable`, `blockOnMissingRequiredSkill`).

## 4. Règles bloquantes vs dérogeables

- **Bloquantes non dérogeables** : entrée invalide, même hôtel, hôtel inactif,
  chevauchement de présence, temps de trajet insuffisant.
- **Bloquantes dérogeables** (`waivable:true`) : compétence obligatoire manquante,
  repos minimal, (indisponibilité si configurée bloquante). La dérogation est
  portée par l'appelant — le moteur signale seulement la possibilité.
- **Avertissements** : dépassements réglementaires « autorisables », pause courte,
  amplitude, sous-effectif induit / résiduel.
- Le **score** n'écrase jamais un blocage : `decision='blocked'` ⇒ `score=null`.

## 5. Score (documenté & paramétrable)

`score = base + destImproved? + destFullyCovered? + originSafe? + groupReduced? − warningPenalty×(#warnings)`,
borné [0,100], calculé seulement si non bloqué. Chaque composante est explicitée
dans `scoreBreakdown`. Poids dans `config.score.weights`.

## 6. Tests réellement exécutés

`node tests/simulation/move-simulator.test.mjs` — **15/15** :
trajet impossible / suffisant, chevauchement, déplacement partiel, multi-jours,
origine sous-effectif après, destination améliorée mais encore sous-effectif,
compétence obligatoire (blocage) / recommandée (info), dépassement dérogeable,
repos légal (blocage), multi-avertissements sans blocage, blocage prioritaire,
déterminisme, non-mutation des entrées.

## 7. Limites réglementaires encore NON couvertes (à cadrer)

- Majorations/contingent d'heures supplémentaires (seuil simple hebdo uniquement).
- Repos hebdomadaire de 35h consécutives et jours de repos obligatoires.
- Travail de nuit (contreparties, durée max nuit) et coupures HCR spécifiques.
- Temps de pause légal détaillé (≥20 min après 6h) — approché par `minBreakMin`.
- Conventions/accords d'entreprise et statuts particuliers (mineurs, temps partiel).
- Trajet dépendant de l'heure/trafic (le moteur consomme une valeur fournie fixe).

## Phase suivante (non développée)

**Drag & Drop intelligent** : la couche UI construit `move` depuis le glisser-
déposer, appelle `simulateMove`, **affiche** le `SimulationResult`, et n'écrit
qu'après confirmation — écriture posant `operation_id` / `source=group_planning`
/ `reason` (journal déjà prêt).
