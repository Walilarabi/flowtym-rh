/**
 * Tests du moteur de simulation de déplacement inter-hôtels (v2).
 * node tests/simulation/move-simulator.test.mjs
 */
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { simulateMove } = require('../../js/move-simulator.js');

let pass = 0, fail = 0;
const ok = (c, l) => { if (c) { pass++; console.log('  ✅ ' + l); } else { fail++; console.log('  ❌ ' + l); } };
const has = (r, code) => r.checks.some(c => c.code === code);
const section = t => console.log('\n' + t);

const DAY = '2026-07-24', WD = 5;
const hotels = [
  { id: 'FO', name: 'Folkestone', hotel_code: 'FO001', active: true },
  { id: 'VO', name: 'Vendôme', hotel_code: 'VO001', active: true },
  { id: 'WO', name: 'Washington', hotel_code: 'WO001', active: true },
];
const cell = (h, e, status, day = DAY) => ({ hotel_id: h, employee_id: e, day, status, is_extra: false, origin_hotel_id: h });
const travel = { minutesBetween: { 'FO|VO': 25 }, defaultMinutes: 30 };

section('1. Trajet impossible entre deux shifts');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P'), cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1', shifts: [{ hotel_id: 'FO', date: DAY, start: '07:00', end: '11:00' }] },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '11:15', end: '16:00' }] }, context: ctx });
  ok(r.decision === 'blocked' && has(r, 'TRAVEL_TIME_INSUFFICIENT'), 'TRAVEL_TIME_INSUFFICIENT (gap 15 < 25+10)');
}

section('2. Trajet possible avec marge suffisante');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P'), cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1', shifts: [{ hotel_id: 'FO', date: DAY, start: '07:00', end: '11:00' }] },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '12:00', end: '16:00' }] }, context: ctx });
  ok(r.decision !== 'blocked' && has(r, 'TRAVEL_TIME_OK'), 'trajet compatible (gap 60 ≥ 35)');
}

section('3. Chevauchement partiel');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    // vacation conservée à WO 10-14 ; le créneau VO 11-15 chevauche WO
    employee: { id: 'e1', shifts: [{ hotel_id: 'WO', date: DAY, start: '10:00', end: '14:00' }] },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '11:00', end: '15:00' }] }, context: ctx });
  ok(r.decision === 'blocked' && has(r, 'SHIFT_OVERLAP'), 'SHIFT_OVERLAP');
}

section('4. Déplacement de quelques heures seulement');
{
  const ctx = {
    hotels, travel,
    cells: [cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1' },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '12:00', end: '16:00' }] }, context: ctx });
  ok(r.decision !== 'blocked' && r.slots[0].destination.prevuAfter === 2, 'renfort partiel VO 1→2');
}

section('5. Déplacement sur plusieurs jours');
{
  const D2 = '2026-07-25';
  const ctx = {
    hotels, travel,
    cells: [cell('VO', 'v1', 'P'), cell('VO', 'v1', 'P', D2)],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: 6, shift: null, required: 3 }],
    employee: { id: 'e1', shifts: [{ hotel_id: 'VO', date: DAY, start: '09:00', end: '13:00' }, { hotel_id: 'VO', date: D2, start: '09:00', end: '13:00' }] },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '09:00', end: '13:00' }, { date: D2, start: '09:00', end: '13:00' }] }, context: ctx });
  ok(r.slots.length === 2 && r.slots.every(s => s.destination.prevuAfter === 2), 'couverture recalculée sur 2 jours');
}

section('6. Origine devenue sous-effectif après le déplacement');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('FO', 'e3', 'P'), cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 1 }],
    employee: { id: 'e1' },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY }] }, context: ctx });
  ok(has(r, 'ORIGIN_UNDERSTAFFED_AFTER_MOVE') && r.impact.groupUnderstaffingAfter > r.impact.groupUnderstaffingBefore, 'origine passe sous-effectif');
}

section('7. Destination améliorée mais toujours sous-effectif');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 5 }],
    employee: { id: 'e1' },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY }] }, context: ctx });
  ok(has(r, 'DESTINATION_COVERAGE_IMPROVED') && has(r, 'DESTINATION_STILL_UNDERSTAFFED'), 'améliorée + encore sous-effectif');
}

section('8. Compétence obligatoire absente');
{
  const ctx = {
    hotels, travel, cells: [cell('FO', 'e1', 'P')],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1', skills: ['reception'] }, serviceSkills: { 'Réception': { required: ['reception', 'night_audit'], recommended: [] } },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY }] }, context: ctx });
  ok(r.decision === 'blocked' && has(r, 'REQUIRED_SKILL_MISSING'), 'compétence obligatoire = blocage');
}

section('9. Compétence recommandée absente');
{
  const ctx = {
    hotels, travel, cells: [cell('FO', 'e1', 'P')],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1', skills: ['reception'] }, serviceSkills: { 'Réception': { required: ['reception'], recommended: ['anglais'] } },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY }] }, context: ctx });
  ok(r.decision !== 'blocked' && has(r, 'RECOMMENDED_SKILL_MISSING') && r.infos.some(c => c.code === 'RECOMMENDED_SKILL_MISSING'), 'recommandée = info non bloquante');
}

section('10. Dépassement autorisable avec avertissement');
{
  const ctx = {
    hotels, travel, cells: [cell('FO', 'e1', 'P')],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    employee: { id: 'e1', plannedThisWeek: { hours: 44 } },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '09:00', end: '16:00' }] }, context: ctx });
  ok(r.decision !== 'blocked' && has(r, 'WEEKLY_HOURS_EXCEEDED') && r.checks.find(c => c.code === 'WEEKLY_HOURS_EXCEEDED').waivable, 'heures sup = avertissement dérogeable');
}

section('11. Repos légal non respecté');
{
  const D2 = '2026-07-25';
  const ctx = {
    hotels, travel, cells: [cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    // le lendemain, vacation existante à FO 06:00 ; le créneau finit à 22:00 => repos 8h
    employee: { id: 'e1', shifts: [{ hotel_id: 'FO', date: D2, start: '06:00', end: '10:00' }] },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '16:00', end: '22:00' }] }, context: ctx });
  ok(r.decision === 'blocked' && has(r, 'MINIMUM_REST_NOT_RESPECTED'), 'repos < 11h = blocage');
}

section('12. Plusieurs avertissements sans blocage');
{
  const ctx = {
    hotels, travel,
    cells: [cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('FO', 'e3', 'P'), cell('VO', 'v1', 'P'), cell('VO', 'v2', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 5 }],
    employee: { id: 'e1', plannedThisWeek: { hours: 45 } },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '09:00', end: '16:00' }] }, context: ctx });
  ok(r.decision === 'allowed_with_warnings' && r.warnings.length >= 2, r.warnings.length + ' avertissements, aucun blocage');
}

section('13. Un blocage prioritaire parmi plusieurs contrôles');
{
  const ctx = {
    hotels, travel, cells: [cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('FO', 'e3', 'P'), cell('VO', 'v1', 'P')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 5 }],
    employee: { id: 'e1', skills: [], plannedThisWeek: { hours: 46 }, availability: { unavailableDays: [DAY] } },
    serviceSkills: { 'Réception': { required: ['reception'] } },
  };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '09:00', end: '16:00' }] }, context: ctx });
  ok(r.decision === 'blocked' && r.blockers.length >= 1 && r.warnings.length >= 1, 'blocage prioritaire malgré des avertissements');
}

section('14. Résultat déterministe avec les mêmes entrées');
{
  const mk = () => ({ move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '12:00', end: '16:00' }] }, context: { hotels, travel, cells: [cell('FO', 'e1', 'P'), cell('VO', 'v1', 'P')], requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 1 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 2 }], employee: { id: 'e1', shifts: [{ hotel_id: 'FO', date: DAY, start: '07:00', end: '11:00' }] } } });
  const a = JSON.stringify(simulateMove(mk())), b = JSON.stringify(simulateMove(mk()));
  ok(a === b, 'sorties identiques pour entrées identiques');
}

section('15. Aucune mutation des objets d\'entrée');
{
  const input = { move: { employeeId: 'e1', service: 'Réception', fromHotelId: 'FO', toHotelId: 'VO', slots: [{ date: DAY, start: '12:00', end: '16:00' }] }, context: { hotels, travel, cells: [cell('FO', 'e1', 'P'), cell('VO', 'v1', 'P')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }], employee: { id: 'e1', shifts: [{ hotel_id: 'FO', date: DAY, start: '07:00', end: '11:00' }] } } };
  const snap = JSON.stringify(input);
  simulateMove(input);
  ok(JSON.stringify(input) === snap, 'entrées inchangées après simulation');
}

console.log('\n=================================');
console.log('Résultat : ' + pass + ' réussis, ' + fail + ' échoués');
console.log('=================================');
if (fail) process.exit(1);
