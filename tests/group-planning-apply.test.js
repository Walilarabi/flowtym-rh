'use strict';
const { monthsCoveredBySlots, buildVisibilityPlan } = require('./lib/groupPlanningApply');

// Ces tests documentent le CONTRAT que group_move_apply (RPC SQL) doit
// respecter dans la même transaction que l'écriture staff_planning :
//   1. un upsert employee_hotel_assignments par (employee, target_hotel)
//   2. un upsert employee_extra_activations par (employee, target_hotel,
//      year, month) — un par mois couvert par les slots
// Voir sql/57_group_move_apply_visibility.sql pour l'implémentation atomique.
//
// La logique pure buildVisibilityPlan / monthsCoveredBySlots sert ici de
// spec exécutable : elle formalise l'ordre et les paramètres attendus,
// utile pour les tests d'intégration SQL futurs et pour comparer une
// implémentation candidate au comportement attendu.

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

// ── buildVisibilityPlan — spec du contrat RPC ────────────────────────────────

describe('Planning Groupe · buildVisibilityPlan — spec de _gmp_ensure_visibility', () => {
  const eid = '5848d73d-ddba-4146-870f-219e06d3e4cc';

  test('affectation d\'un jour → 1 upsert assignment + 1 upsert activation', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    });
    expect(plan).toEqual([
      { op: 'addHotelAssignment', args: [eid, 'FO', 'VO', 'Renfort inter-hôtels — Planning Groupe', null] },
      { op: 'setExtraActivation', args: ['VO', eid, 2026, 7, null, null, true, 'Renfort inter-hôtels appliqué depuis le Planning Groupe'] },
    ]);
  });

  test('mission sur 2 mois → 1 upsert assignment + 2 upserts activation', () => {
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

  test('cible bien l\'hôtel de destination et le bon employee', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'WO',
      slots: [{ date: '2026-07-25' }],
    });
    expect(plan[1].args[0]).toBe('WO');
    expect(plan[1].args[1]).toBe(eid);
    expect(plan[1].args[6]).toBe(true);
  });

  test('libellé traçable pour l\'audit', () => {
    const plan = buildVisibilityPlan({
      employeeId: eid, fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    });
    expect(plan[0].args[3]).toMatch(/Planning Groupe/);
    expect(plan[1].args[7]).toMatch(/Planning Groupe/);
  });
});

// ── Idempotence attendue de la RPC ───────────────────────────────────────────

describe('Planning Groupe · idempotence — double clic ne doit pas dupliquer', () => {
  test('deux plans identiques produisent le même effet (upserts SQL)', () => {
    const p = {
      employeeId: 'e1', fromHotelId: 'FO', destHotelId: 'VO',
      slots: [{ date: '2026-07-25' }],
    };
    expect(buildVisibilityPlan(p)).toEqual(buildVisibilityPlan(p));
    // Idempotence garantie côté RPC par :
    //  · ON CONFLICT (employee_id, target_hotel_id) sur employee_hotel_assignments
    //  · ON CONFLICT (employee_id, hotel_id, year, month) sur employee_extra_activations
    //  · La clé idempotency_key de group_move_applications (retour du résultat mémorisé)
    // Cf. sql/57_group_move_apply_visibility.sql.
  });
});

// ── Contrat SQL documenté ────────────────────────────────────────────────────
// Ces assertions valident la présence de la migration SQL et son intégration
// dans le fichier canonique de reconstruction — barrière contre une régression
// qui supprimerait le correctif atomique.
const fs = require('fs');
const path = require('path');

describe('Planning Groupe · contrat SQL atomique', () => {
  const migration = fs.readFileSync(
    path.join(__dirname, '..', 'sql', '57_group_move_apply_visibility.sql'),
    'utf8'
  );
  const reconstruct = fs.readFileSync(
    path.join(__dirname, '..', 'db', 'reconstruct', '30_functions.sql'),
    'utf8'
  );

  test('migration crée _gmp_ensure_visibility', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\._gmp_ensure_visibility/);
  });

  test('migration réécrit group_move_apply et l\'appelle', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\.group_move_apply/);
    expect(migration).toMatch(/PERFORM public\._gmp_ensure_visibility/);
  });

  test('migration utilise ON CONFLICT (idempotence)', () => {
    expect(migration).toMatch(/ON CONFLICT \(employee_id, target_hotel_id\)/);
    expect(migration).toMatch(/ON CONFLICT \(employee_id, hotel_id, year, month\)/);
  });

  test('migration ajoute la fonction d\'audit LECTURE SEULE', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\.group_move_visibility_audit/);
    expect(migration).toMatch(/STABLE SECURITY DEFINER/);
  });

  test('reconstruct/30_functions.sql intègre l\'appel visibilité', () => {
    expect(reconstruct).toMatch(/PERFORM public\._gmp_ensure_visibility/);
    expect(reconstruct).toMatch(/visibilite_extra/);
  });
});

// ── Contrat frontend : plus aucune réparation client ─────────────────────────

describe('Planning Groupe · frontend n\'appelle plus addHotelAssignment / setExtraActivation dans gpConfirmAffectation', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  test('gpConfirmAffectation ne contient plus BE.addHotelAssignment', () => {
    const start = html.indexOf('async function gpConfirmAffectation');
    expect(start).toBeGreaterThan(-1);
    // Le corps de la fonction se termine à l'accolade fermante alignée.
    const chunk = html.slice(start, start + 3000);
    expect(chunk).not.toMatch(/BE\.addHotelAssignment/);
    expect(chunk).not.toMatch(/BE\.setExtraActivation/);
  });
});
