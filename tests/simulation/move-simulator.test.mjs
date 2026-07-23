/**
 * Tests du moteur de simulation de déplacement inter-hôtels.
 * Exécution : node tests/simulation/move-simulator.test.mjs
 * Pur, déterministe, aucune dépendance externe.
 */
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { simulateMove } = require('../../js/move-simulator.js');

let pass = 0, fail = 0;
function ok(cond, label) { if (cond) { pass++; console.log('  ✅ ' + label); } else { fail++; console.log('  ❌ ' + label); } }
function section(t) { console.log('\n' + t); }

// Contexte de base : 2 hôtels, service Réception, vendredi 2026-07-24 (weekday 5).
const DAY = '2026-07-24';
const WD = 5;
const hotels = [
  { id: 'FO', name: 'Folkestone', hotel_code: 'FO001', active: true },
  { id: 'VO', name: 'Vendôme', hotel_code: 'VO001', active: true },
  { id: 'XX', name: 'Inactif', hotel_code: 'XX001', active: false },
];
function cell(h, e, status) { return { hotel_id: h, employee_id: e, name: e, role: 'Réceptionniste', is_extra: false, origin_hotel_id: h, day: DAY, status: status }; }

// FO sureffectif (4 présents, requis 2) ; VO sous-effectif (2 présents, requis 4).
const baseCells = [
  cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('FO', 'e3', 'P'), cell('FO', 'e4', 'P'),
  cell('VO', 'v1', 'P'), cell('VO', 'v2', 'P'),
];
const requirements = [
  { hotel_id: 'FO', weekday: WD, shift: null, required: 2 },
  { hotel_id: 'VO', weekday: WD, shift: null, required: 4 },
];
const baseCtx = { hotels, cells: baseCells, requirements, employee: { id: 'e1', skills: ['reception'] } };

section('1. Déplacement pertinent FO(sureffectif)->VO(sous-effectif)');
{
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: baseCtx });
  ok(r.ok === true, 'déplacement autorisé (aucun blocage)');
  ok(r.from.before.level === 'sureffectif' && r.from.after.level === 'sureffectif', 'FO reste sureffectif (4->3, requis 2 : ratio 1.5 > 1.3) — sureffectif allégé');
  ok(r.to.before.level === 'sous_effectif' && r.to.after.level === 'sous_effectif', 'VO reste sous-effectif (2->3, requis 4)');
  ok(r.sousEffectif.before === 1 && r.sousEffectif.after === 1, 'sous-effectifs comptés (1 avant / 1 après)');
  ok(r.from.after.prevu === 3 && r.to.after.prevu === 3, 'effectifs après corrects');
}

section('2. Blocage : même hôtel');
{
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'FO' }, context: baseCtx });
  ok(r.ok === false && r.blockers.some(b => b.code === 'BLK_SAME_HOTEL'), 'BLK_SAME_HOTEL');
}

section('3. Blocage : collaborateur absent de l\'hôtel de départ');
{
  const r = simulateMove({ move: { employeeId: 'ghost', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: baseCtx });
  ok(r.ok === false && r.blockers.some(b => b.code === 'BLK_NOT_PRESENT_AT_SOURCE'), 'BLK_NOT_PRESENT_AT_SOURCE');
}

section('4. Conflit + blocage : déjà présent à destination (double affectation)');
{
  const cells = baseCells.concat([cell('VO', 'e1', 'P')]); // e1 présent à FO ET VO
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: { ...baseCtx, cells } });
  ok(r.ok === false && r.blockers.some(b => b.code === 'BLK_ALREADY_AT_DEST'), 'BLK_ALREADY_AT_DEST');
  ok(r.conflicts.some(c => c.code === 'CFL_ALREADY_AT_DEST'), 'conflit signalé');
}

section('5. Blocage : hôtel d\'arrivée inactif');
{
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'XX' }, context: baseCtx });
  ok(r.ok === false && r.blockers.some(b => b.code === 'BLK_DEST_INACTIVE'), 'BLK_DEST_INACTIVE');
}

section('6. Avertissement : le départ crée un sous-effectif à la source');
{
  // FO à l'effectif juste (requis 3, présents 3) : partir -> sous-effectif.
  const cells = [cell('FO', 'e1', 'P'), cell('FO', 'e2', 'P'), cell('FO', 'e3', 'P'), cell('VO', 'v1', 'P')];
  const reqs = [{ hotel_id: 'FO', weekday: WD, shift: null, required: 3 }, { hotel_id: 'VO', weekday: WD, shift: null, required: 1 }];
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: { hotels, cells, requirements: reqs, employee: { id: 'e1' } } });
  ok(r.ok === true, 'déplacement possible');
  ok(r.warnings.some(w => w.code === 'WARN_CREATES_UNDERSTAFF_SOURCE'), 'WARN_CREATES_UNDERSTAFF_SOURCE');
  ok(r.sousEffectif.delta === 1, 'sous-effectifs : +1');
}

section('7. Compétences requises manquantes (avertissement, puis blocage si configuré)');
{
  const ctx = { ...baseCtx, employee: { id: 'e1', skills: ['reception'] }, serviceSkills: { 'Réception': ['reception', 'night_audit'] } };
  const r1 = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: ctx });
  ok(r1.skills.missing.includes('night_audit') && r1.warnings.some(w => w.code === 'WARN_MISSING_SKILLS'), 'compétence manquante = avertissement');
  const r2 = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: ctx, config: { blockOnMissingSkill: true } });
  ok(r2.ok === false && r2.blockers.some(b => b.code === 'BLK_MISSING_SKILLS'), 'compétence manquante = blocage si configuré');
}

section('8. Indisponibilité déclarée (blocage par défaut, avertissement si désactivé)');
{
  const ctx = { ...baseCtx, employee: { id: 'e1', availability: { unavailableDays: [DAY], reason: 'Congé' } } };
  const r1 = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: ctx });
  ok(r1.ok === false && r1.blockers.some(b => b.code === 'BLK_UNAVAILABLE'), 'indispo = blocage par défaut');
  const r2 = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: ctx, config: { blockOnUnavailable: false } });
  ok(r2.availability.available === false && r2.warnings.some(w => w.code === 'WARN_UNAVAILABLE'), 'indispo = avertissement si désactivé');
}

section('9. Dépassements réglementaires (heures hebdo, jours consécutifs, repos)');
{
  const ctx = { ...baseCtx, employee: { id: 'e1', plannedThisWeek: { hours: 44, consecutiveDays: 6 }, lastRestHours: 9 } };
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: ctx, config: { regulatory: { maxWeeklyHours: 48, maxConsecutiveDays: 6, minRestHours: 11, shiftHours: 7 } } });
  ok(r.regulatory.some(x => x.code === 'REG_WEEKLY_HOURS'), '44+7=51 > 48 -> REG_WEEKLY_HOURS');
  ok(r.regulatory.some(x => x.code === 'REG_CONSECUTIVE_DAYS'), '6+1=7 > 6 -> REG_CONSECUTIVE_DAYS');
  ok(r.regulatory.some(x => x.code === 'REG_REST'), '9h < 11h -> REG_REST');
}

section('10. Seuils de couverture paramétrables');
{
  // Avec conformeUpTo abaissé à 1.1, FO(4->3, requis 2 : ratio 1.5) reste sureffectif.
  const r = simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: baseCtx, config: { coverage: { redBelow: 1.0, limiteUpTo: 1.0, conformeUpTo: 1.1 } } });
  ok(r.from.after.level === 'sureffectif', 'seuil resserré -> FO après reste sureffectif');
}

section('11. Pureté : aucune mutation des entrées');
{
  const snapshot = JSON.stringify(baseCtx);
  simulateMove({ move: { employeeId: 'e1', service: 'Réception', day: DAY, fromHotelId: 'FO', toHotelId: 'VO' }, context: baseCtx });
  ok(JSON.stringify(baseCtx) === snapshot, 'le contexte d\'entrée est inchangé');
}

console.log('\n=================================');
console.log('Résultat : ' + pass + ' réussis, ' + fail + ' échoués');
console.log('=================================');
if (fail) process.exit(1);
