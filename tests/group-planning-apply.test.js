'use strict';
const { monthsCoveredBySlots, buildVisibilityPlan } = require('./lib/groupPlanningApply');

// ── monthsCoveredBySlots ─────────────────────────────────────────────────────

describe('Planning Groupe · monthsCoveredBySlots — activations extras à créer', () => {
  test('slot unique → 1 mois', () => {
    expect(monthsCoveredBySlots([{ date: '2026-07-25' }])).toEqual([
      { year: 2026, month: 7 },
    ]);
  });

  test('plusieurs slots dans le même mois → 1 mois (dédupliqué)', () => {
    expect(monthsCoveredBySlots([
      { date: '2026-07-25' },
      { date: '2026-07-26' },
      { date: '2026-07-30' },
    ])).toEqual([{ year: 2026, month: 7 }]);
  });

  test('slots à cheval sur deux mois → deux entrées, dans l\'ordre', () => {
    expect(monthsCoveredBySlots([
      { date: '2026-07-30' },
      { date: '2026-08-02' },
    ])).toEqual([
      { year: 2026, month: 7 },
      { year: 2026, month: 8 },
    ]);
  });

  test('slots à cheval sur deux années', () => {
    expect(monthsCoveredBySlots([
      { date: '2026-12-31' },
      { date: '2027-01-01' },
    ])).toEqual([
      { year: 2026, month: 12 },
      { year: 2027, month: 1 },
    ]);
  });

  test('slot invalide ignoré, sans crasher', () => {
    expect(monthsCoveredBySlots([
      { date: '2026-07-25' },
      { date: 'plop' },
      null,
      { date: '' },
    ])).toEqual([{ year: 2026, month: 7 }]);
  });

  test('liste vide → []', () => {
    expect(monthsCoveredBySlots([])).toEqual([]);
    expect(monthsCoveredBySlots(undefined)).toEqual([]);
  });
});

// ── buildVisibilityPlan ──────────────────────────────────────────────────────

describe('Planning Groupe · buildVisibilityPlan — post-apply visibilité extra', () => {
  const eid = '5848d73d-ddba-4146-870f-219e06d3e4cc';

  test('affectation d\'un jour → 1 addHotelAssignment + 1 setExtraActivation', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    });
    expect(plan).toEqual([
      { op: 'addHotelAssignment', args: [eid, 'FO', 'VO', 'Renfort inter-hôtels — Planning Groupe', null] },
      { op: 'setExtraActivation', args: ['VO', eid, 2026, 7, null, null, true, 'Renfort inter-hôtels appliqué depuis le Planning Groupe'] },
    ]);
  });

  test('mission sur 2 mois → 1 addHotelAssignment + 2 setExtraActivation', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-30' }, { date: '2026-08-01' }],
    });
    expect(plan.length).toBe(3);
    expect(plan[0].op).toBe('addHotelAssignment');
    expect(plan[1].op).toBe('setExtraActivation');
    expect(plan[1].args[3]).toBe(7);
    expect(plan[2].op).toBe('setExtraActivation');
    expect(plan[2].args[3]).toBe(8);
  });

  test('l\'appel setExtraActivation cible bien l\'hôtel de destination', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'WO',
      slots: [{ date: '2026-07-25' }],
    });
    // args[0] du setExtraActivation = hotel_id
    expect(plan[1].args[0]).toBe('WO');
    // args[1] = employee_id, jamais un UUID d'un autre collaborateur
    expect(plan[1].args[1]).toBe(eid);
    // active=true (args[6])
    expect(plan[1].args[6]).toBe(true);
  });

  test('libellé traçable : mention explicite du Planning Groupe pour l\'audit', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    });
    expect(plan[0].args[3]).toMatch(/Planning Groupe/);
    expect(plan[1].args[7]).toMatch(/Planning Groupe/);
  });
});

// ── Comportement idempotent attendu (spec) ───────────────────────────────────

describe('Planning Groupe · idempotence spec — double clic ne doit pas dupliquer', () => {
  test('deux plans identiques produisent le même effet (upsert côté BE)', () => {
    const p = {
      employeeId: 'e1', fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    };
    const a = buildVisibilityPlan(p);
    const b = buildVisibilityPlan(p);
    expect(a).toEqual(b);
    // Note : l'idempotence réelle est garantie par les onConflict des upserts
    // (employee_hotel_assignments unique sur employee_id+target_hotel_id) et
    // extra_activation_set (RPC qui upsert par (employee, hotel, year, month)).
    // Cf. index.html:1203 et index.html:1213.
  });
});
