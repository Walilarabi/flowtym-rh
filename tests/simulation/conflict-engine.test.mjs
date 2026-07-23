/**
 * Tests du moteur de conflits & concurrence. node tests/simulation/conflict-engine.test.mjs
 */
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const CE = require('../../js/conflict-engine.js');

let pass = 0, fail = 0;
const ok = (c, l) => { if (c) { pass++; console.log('  ✅ ' + l); } else { fail++; console.log('  ❌ ' + l); } };
const S = t => console.log('\n' + t);

S('1. Chevauchement de créneaux');
ok(CE.slotsOverlap([{ date: '2026-07-24', start: '09:00', end: '13:00' }], [{ date: '2026-07-24', start: '12:00', end: '16:00' }]) === true, 'chevauchement horaire même jour');
ok(CE.slotsOverlap([{ date: '2026-07-24', start: '09:00', end: '11:00' }], [{ date: '2026-07-24', start: '12:00', end: '16:00' }]) === false, 'pas de chevauchement (jointifs disjoints)');
ok(CE.slotsOverlap([{ date: '2026-07-24' }], [{ date: '2026-07-24', start: '12:00', end: '16:00' }]) === true, 'journée complète chevauche tout');
ok(CE.slotsOverlap([{ date: '2026-07-24' }], [{ date: '2026-07-25' }]) === false, 'jours différents');

S('2. Détection de propositions concurrentes');
{
  const target = { id: 'T', employee_id: 'e1', status: 'draft', slots: [{ date: '2026-07-24' }] };
  const others = [
    { id: 'O1', employee_id: 'e1', status: 'approved', slots: [{ date: '2026-07-24', start: '09:00', end: '12:00' }] },
    { id: 'O2', employee_id: 'e1', status: 'cancelled', slots: [{ date: '2026-07-24' }] }, // fermée -> ignorée
    { id: 'O3', employee_id: 'e2', status: 'draft', slots: [{ date: '2026-07-24' }] },     // autre collab
    { id: 'O4', employee_id: 'e1', status: 'draft', slots: [{ date: '2026-07-25' }] },     // autre jour
  ];
  const c = CE.detectConflicts(target, others);
  ok(c.length === 1 && c[0].id === 'O1', 'seul O1 est un conflit ouvert et chevauchant');
}

S('3. Résolution de priorité');
{
  const props = [
    { id: 'A', status: 'draft', created_at: '2026-07-01', score: 90 },
    { id: 'B', status: 'scheduled', created_at: '2026-07-02', score: 70 },
    { id: 'C', status: 'approved', created_at: '2026-07-03', score: 80 },
  ];
  const r = CE.resolvePriority(props);
  ok(r.priority === 'B', 'la plus avancée (scheduled) est prioritaire');
  ok(r.decisions.find(d => d.id === 'C').action === 'revalidate', 'approuvée concurrente -> à revalider');
  ok(r.decisions.find(d => d.id === 'A').action === 'cancel', 'brouillon concurrent -> à annuler');
}
{
  // Égalité de rang -> plus ancienne gagne
  const r = CE.resolvePriority([{ id: 'X', status: 'draft', created_at: '2026-07-05' }, { id: 'Y', status: 'draft', created_at: '2026-07-02' }]);
  ok(r.priority === 'Y', 'à rang égal, la plus ancienne gagne');
}

S('4. Empreintes par catégorie + diff');
{
  const raw1 = { cells: [1, 2], requirements: [{ h: 1 }], employee: { skills: ['a'], plannedThisWeek: { hours: 40 } }, travelTimes: [{ d: 25 }], rhRules: null, workflow: ['s1'] };
  const raw2 = JSON.parse(JSON.stringify(raw1)); raw2.employee.skills = ['a', 'b']; raw2.travelTimes = [{ d: 30 }];
  const changed = CE.diffCategories(CE.categoryHashes(raw1), CE.categoryHashes(raw2));
  ok(changed.includes('skills') && changed.includes('travel'), 'skills + travel détectés comme changés');
  ok(!changed.includes('requirements'), 'requirements inchangés non listés');
}

S('5. Assess : valid / to_refresh / conflict / expired');
{
  const base = CE.categoryHashes({ cells: [1] });
  ok(CE.assess({ storedHashes: base, currentHashes: base, decision: 'allowed' }).status === 'valid', 'valid quand rien ne change');
  ok(CE.assess({ storedHashes: base, currentHashes: CE.categoryHashes({ cells: [1, 2] }), decision: 'allowed' }).status === 'to_refresh', 'to_refresh si planning changé');
  ok(CE.assess({ storedHashes: base, currentHashes: base, conflicts: [{ id: 'x' }], decision: 'allowed' }).status === 'conflict', 'conflict si concurrente');
  ok(CE.assess({ storedHashes: base, currentHashes: base, expiresAt: '2026-07-01T00:00:00Z', now: '2026-07-10T00:00:00Z', decision: 'allowed' }).status === 'expired', 'expired si délai dépassé');
  ok(CE.assess({ storedHashes: base, currentHashes: base, decision: 'blocked' }).applicable === false, 'non applicable si décision bloquée');
}

S('6. Priorité de l\'expiration sur les autres états');
{
  const base = CE.categoryHashes({ cells: [1] });
  const r = CE.assess({ storedHashes: base, currentHashes: CE.categoryHashes({ cells: [9] }), conflicts: [{ id: 'x' }], expiresAt: '2026-01-01T00:00:00Z', now: '2026-07-10T00:00:00Z', decision: 'allowed' });
  ok(r.status === 'expired', 'expiration prioritaire sur conflit/obsolescence');
}

S('7. Déterminisme');
{
  const props = [{ id: 'A', status: 'approved', created_at: '2026-07-01', score: 1 }, { id: 'B', status: 'approved', created_at: '2026-07-01', score: 1 }];
  ok(JSON.stringify(CE.resolvePriority(props)) === JSON.stringify(CE.resolvePriority(props)), 'résolution déterministe');
}

console.log('\n=================================');
console.log('Résultat : ' + pass + ' réussis, ' + fail + ' échoués');
console.log('=================================');
if (fail) process.exit(1);
