/**
 * Tests de la couche d'adaptation (pure) + moteur, sur les 12 cas de validation
 * du lot d'intégration. node tests/simulation/sim-adapter.test.mjs
 */
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { assessInputs, buildContext } = require('../../js/sim-adapter.js');
const { simulateMove } = require('../../js/move-simulator.js');

let pass = 0, fail = 0;
const ok = (c, l) => { if (c) { pass++; console.log('  ✅ ' + l); } else { fail++; console.log('  ❌ ' + l); } };
const has = (r, code) => r.checks.some(c => c.code === code);
const section = t => console.log('\n' + t);

const DAY = '2026-07-24', D2 = '2026-07-25', WD = 5;
const hotels = [
  { id: 'FO', name: 'Folkestone', hotel_code: 'FO001', active: true },
  { id: 'VO', name: 'Vendôme', hotel_code: 'VO001', active: true },
  { id: 'WO', name: 'Washington', hotel_code: 'WO001', active: true },
];
const cell = (h, e, day = DAY, status = 'P') => ({ hotel_id: h, employee_id: e, day, status });
const travelTimes = [
  { from_hotel_id: 'FO', to_hotel_id: 'VO', duration_min: 25, safety_margin_min: 10 },
  { from_hotel_id: 'VO', to_hotel_id: 'FO', duration_min: 25, safety_margin_min: 10 },
];
const accessAll = ['FO', 'VO', 'WO'];

function run(raw, cfgOverride) {
  const built = buildContext(raw, cfgOverride || {});
  return simulateMove(built);
}

section('1. Renfort améliore Vendôme sans fragiliser Folkestone');
{
  const raw = {
    employee: { id: 'e1', name: 'Amir', skills: ['reception'] }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'e1'), cell('FO', 'e2'), cell('FO', 'e3'), cell('FO', 'e4'), cell('VO', 'v1'), cell('VO', 'v2')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 3 }],
    serviceSkills: { 'Réception': { required: ['reception'] } },
  };
  const r = run(raw);
  ok(r.decision === 'allowed' && r.impact.groupUnderstaffingAfter < r.impact.groupUnderstaffingBefore, 'autorisé, sous-effectifs groupe réduits');
}

section('2. Renfort créant un sous-effectif à l\'origine');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'e1'), cell('FO', 'e2'), cell('FO', 'e3'), cell('VO', 'v1')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 1 }],
  };
  const r = run(raw);
  ok(has(r, 'ORIGIN_UNDERSTAFFED_AFTER_MOVE'), 'ORIGIN_UNDERSTAFFED_AFTER_MOVE');
}

section('3. Collaborateur déjà affecté sur le même créneau');
{
  const raw = {
    employee: { id: 'e1', shifts: undefined }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY, start: '10:00', end: '14:00' }], hotels, accessibleHotelIds: accessAll, travelTimes,
    employeeShifts: [{ hotel_id: 'VO', date: DAY, start: '09:00', end: '13:00' }], // déjà à VO 9-13
    cells: [cell('FO', 'e1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
  };
  const r = run(raw);
  ok(r.decision === 'blocked' && has(r, 'SHIFT_OVERLAP'), 'SHIFT_OVERLAP (déjà affecté)');
}

section('4. Temps de trajet insuffisant');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY, start: '11:15', end: '16:00' }], hotels, accessibleHotelIds: accessAll, travelTimes,
    employeeShifts: [{ hotel_id: 'FO', date: DAY, start: '07:00', end: '11:00' }],
    cells: [cell('VO', 'v1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
  };
  const r = run(raw);
  ok(r.decision === 'blocked' && has(r, 'TRAVEL_TIME_INSUFFICIENT'), 'TRAVEL_TIME_INSUFFICIENT');
}

section('5. Temps de trajet absent (politique configurable)');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'WO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes, // pas de couple FO|WO
    cells: [cell('WO', 'w1')], requirements: [{ hotel_id: 'WO', weekday: WD, shift: null, required: 2 }],
  };
  const a = assessInputs(raw);
  ok(a.fields.find(f => f.key === 'travel_time').status === 'missing', 'donnée trajet marquée manquante');
  const rWarn = run(raw); // politique par défaut = warning
  ok(rWarn.decision !== 'blocked' && has(rWarn, 'TRAVEL_TIME_NOT_CONFIGURED'), 'politique warning : non bloquant');
  const rBlock = run(raw, { time: { missingTravelLevel: 'blocking' } });
  ok(rBlock.decision === 'blocked' && has(rBlock, 'TRAVEL_TIME_NOT_CONFIGURED'), 'politique blocking : bloquant');
}

section('6. Compétence obligatoire manquante');
{
  const raw = {
    employee: { id: 'e1', skills: ['reception'] }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'e1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    serviceSkills: { 'Réception': { required: ['reception', 'night_audit'] } },
  };
  const r = run(raw);
  ok(r.decision === 'blocked' && has(r, 'REQUIRED_SKILL_MISSING'), 'REQUIRED_SKILL_MISSING');
}

section('7. Extra affecté à un service différent de son service principal');
{
  const raw = {
    employee: { id: 'gh', name: 'Ghizlaine', skills: ['petit_dejeuner'], principalService: 'Étage' },
    origin: { hotelId: 'FO', service: 'Étage' }, destination: { hotelId: 'VO', service: 'Petit-déjeuner' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'gh'), cell('VO', 'v1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
    serviceSkills: { 'Petit-déjeuner': { required: ['petit_dejeuner'] } },
  };
  const built = buildContext(raw, {});
  const r = simulateMove(built);
  ok(built.move.service === 'Petit-déjeuner' && r.decision !== 'blocked', 'service destination = Petit-déjeuner, autorisé');
}

section('8. Déplacement de quelques heures');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY, start: '12:00', end: '16:00' }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('VO', 'v1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
  };
  const r = run(raw);
  ok(r.decision !== 'blocked' && r.slots[0].destination.prevuAfter === 2, 'renfort partiel VO 1→2');
}

section('9. Déplacement sur plusieurs jours');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY, start: '09:00', end: '13:00' }, { date: D2, start: '09:00', end: '13:00' }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('VO', 'v1'), cell('VO', 'v1', D2)],
    requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: 6, shift: null, required: 3 }],
  };
  const r = run(raw);
  ok(r.slots.length === 2, 'simulation sur 2 jours');
}

section('10. Utilisateur sans accès à l\'hôtel de destination');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: ['FO'], travelTimes, // pas VO
    cells: [cell('FO', 'e1')], requirements: [{ hotel_id: 'VO', weekday: WD, shift: null, required: 2 }],
  };
  const a = assessInputs(raw);
  ok(a.authorized === false && a.fields.find(f => f.key === 'dest_authorized').status === 'missing', 'destination non autorisée détectée');
}

section('11. Besoin de couverture non configuré');
{
  const raw = {
    employee: { id: 'e1' }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'e1'), cell('VO', 'v1')], requirements: [], // aucun besoin
  };
  const a = assessInputs(raw);
  const r = run(raw);
  ok(a.fields.find(f => f.key === 'dest_requirement').status === 'missing' && r.impact.destinationCoverageAfter === null, 'besoin non configuré, couverture non évaluée');
}

section('12. Plusieurs avertissements sans blocage');
{
  const raw = {
    employee: { id: 'e1', plannedThisWeek: { hours: 45 } }, origin: { hotelId: 'FO', service: 'Réception' }, destination: { hotelId: 'VO', service: 'Réception' },
    slots: [{ date: DAY, start: '09:00', end: '16:00' }], hotels, accessibleHotelIds: accessAll, travelTimes,
    cells: [cell('FO', 'e1'), cell('FO', 'e2'), cell('FO', 'e3'), cell('VO', 'v1'), cell('VO', 'v2')],
    requirements: [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 5 }],
  };
  const r = run(raw);
  ok(r.decision === 'allowed_with_warnings' && r.warnings.length >= 2, r.warnings.length + ' avertissements, aucun blocage');
}

console.log('\n=================================');
console.log('Résultat : ' + pass + ' réussis, ' + fail + ' échoués');
console.log('=================================');
if (fail) process.exit(1);
