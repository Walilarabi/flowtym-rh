/**
 * Preuve de PARITÉ pour group_move_apply.
 * node tests/simulation/apply-parity.test.mjs
 *
 * 1. Déterminisme du moteur : même entrée -> même sortie (base de la garantie
 *    serveur). Le garde-fou serveur n'exécute PAS une 2e implémentation ; il
 *    vérifie que les données décisives sont INCHANGÉES depuis la simulation
 *    (empreinte serveur). Le moteur étant déterministe, empreinte identique =>
 *    la simulation stockée EST encore la sortie du moteur pour les données
 *    courantes. C'est la parité par construction.
 * 2. Parité de la décision d'applicabilité entre conflict-engine.assess (client)
 *    et un miroir de la garde plpgsql (serveur).
 */
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { simulateMove } = require('../../js/move-simulator.js');
const CE = require('../../js/conflict-engine.js');

let pass = 0, fail = 0;
const ok = (c, l) => { if (c) { pass++; console.log('  ✅ ' + l); } else { fail++; console.log('  ❌ ' + l); } };

console.log('\n1. Déterminisme du moteur (parité re-simulation)');
{
  const input = { move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: '2026-07-24' }] },
    context: { hotels: [{ id: 'FO', name: 'FO', active: true }, { id: 'VO', name: 'VO', active: true }], travel: { minutesBetween: { 'FO|VO': 25 } },
      cells: [{ hotel_id: 'FO', employee_id: 'e1', day: '2026-07-24', status: 'P' }, { hotel_id: 'VO', employee_id: 'v1', day: '2026-07-24', status: 'P' }],
      requirements: [{ hotel_id: 'FO', weekday: 5, shift: null, required: 3 }, { hotel_id: 'VO', weekday: 5, shift: null, required: 3 }], employee: { id: 'e1' } } };
  const a = JSON.stringify(simulateMove(input)), b = JSON.stringify(simulateMove(input));
  ok(a === b, 'sortie identique pour entrées identiques (déterministe)');
}

console.log('\n2. Parité décision client (assess) vs miroir de la garde serveur');
// Miroir EXACT de la précédence de group_move_apply : bloqué OU expiré OU données
// changées OU non-prioritaire (conflit) => refus ; sinon application.
function sqlGuardAllows(x) {
  if (x.decision === 'blocked' || x.unwaivedBlockers > 0) return false;
  if (x.expired) return false;
  if (x.dataChanged) return false;
  if (x.notPriority) return false;
  return true;
}
// assess (client) : applicable = valid && decision!=blocked. On construit les
// mêmes conditions et on vérifie que les deux décisions binaires coïncident.
function clientApplicable(x) {
  const base = CE.categoryHashes({ cells: [1] });
  const r = CE.assess({
    storedHashes: base,
    currentHashes: x.dataChanged ? CE.categoryHashes({ cells: [9] }) : base,
    conflicts: x.notPriority ? [{ id: 'o' }] : [],
    expiresAt: x.expired ? '2026-01-01T00:00:00Z' : null,
    now: '2026-07-10T00:00:00Z',
    decision: (x.decision === 'blocked' || x.unwaivedBlockers > 0) ? 'blocked' : 'allowed',
  });
  return r.applicable;
}
const matrix = [];
for (const decision of ['allowed', 'blocked'])
  for (const unwaivedBlockers of [0, 1])
    for (const expired of [false, true])
      for (const dataChanged of [false, true])
        for (const notPriority of [false, true])
          matrix.push({ decision, unwaivedBlockers, expired, dataChanged, notPriority });
let mismatch = 0;
for (const x of matrix) if (sqlGuardAllows(x) !== clientApplicable(x)) mismatch++;
ok(mismatch === 0, matrix.length + ' combinaisons : garde serveur ≡ applicabilité client (0 divergence)');

console.log('\n=================================');
console.log('Résultat : ' + pass + ' réussis, ' + fail + ' échoués');
console.log('=================================');
if (fail) process.exit(1);
