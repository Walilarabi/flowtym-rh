'use strict';
const { makeTestBE } = require('./lib/testBE');

const H  = 'hotel-test-001';
const H2 = 'hotel-test-002';
const E1 = 'emp-001';
const E2 = 'emp-002';

// ── savePlanning / listMonthPlanning ───────────────────────────────────────

describe('savePlanning — shifts (migration 24)', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('sauvegarde un shift M avec shift_label', async () => {
    await be.savePlanning(H, [{ hotel_id: H, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'M' }], []);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows).toHaveLength(1);
    expect(rows[0].shift_label).toBe('M');
  });

  test('sauvegarde les horaires custom (shift_start / shift_end)', async () => {
    const row = { hotel_id: H, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'custom', shift_start: '07:30', shift_end: '15:30', break_minutes: 30 };
    await be.savePlanning(H, [row], []);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows[0].shift_start).toBe('07:30');
    expect(rows[0].shift_end).toBe('15:30');
    expect(rows[0].break_minutes).toBe(30);
  });

  test('upsert sur (hotel_id, employee_id, day) — met à jour shift_label', async () => {
    await be.savePlanning(H, [{ hotel_id: H, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'M' }], []);
    await be.savePlanning(H, [{ hotel_id: H, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'S' }], []);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows).toHaveLength(1);
    expect(rows[0].shift_label).toBe('S');
  });

  test('delete supprime la ligne', async () => {
    const row = { hotel_id: H, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'M' };
    await be.savePlanning(H, [row], []);
    await be.savePlanning(H, [], [{ hotel_id: H, employee_id: E1, day: '2025-06-02' }]);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows).toHaveLength(0);
  });

  test('isole par hotel_id', async () => {
    await be.savePlanning(H,  [{ hotel_id: H,  employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'M' }], []);
    await be.savePlanning(H2, [{ hotel_id: H2, employee_id: E1, day: '2025-06-02', status: 'P', shift_label: 'S' }], []);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows).toHaveLength(1);
    expect(rows[0].hotel_id).toBe(H);
  });
});

// ── Coverage rules ─────────────────────────────────────────────────────────

describe('BE.listCoverageRules / saveCoverageRule / deleteCoverageRule', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('liste vide initialement', async () => {
    expect(await be.listCoverageRules(H)).toEqual([]);
  });

  test('crée une règle et la retrouve', async () => {
    await be.saveCoverageRule(H, { department: 'reception', shift_label: 'M', min_staff_base: 2 });
    const rules = await be.listCoverageRules(H);
    expect(rules).toHaveLength(1);
    expect(rules[0].min_staff_base).toBe(2);
  });

  test('upsert sur (department, shift_label, day_of_week)', async () => {
    await be.saveCoverageRule(H, { department: 'reception', shift_label: 'M', day_of_week: null, min_staff_base: 1 });
    await be.saveCoverageRule(H, { department: 'reception', shift_label: 'M', day_of_week: null, min_staff_base: 3 });
    const rules = await be.listCoverageRules(H);
    expect(rules).toHaveLength(1);
    expect(rules[0].min_staff_base).toBe(3);
  });

  test('règle avec day_of_week spécifique (samedi=5)', async () => {
    await be.saveCoverageRule(H, { department: 'etages', shift_label: 'J', day_of_week: 5, min_staff_base: 4 });
    await be.saveCoverageRule(H, { department: 'etages', shift_label: 'J', day_of_week: null, min_staff_base: 2 });
    const rules = await be.listCoverageRules(H);
    expect(rules).toHaveLength(2);
  });

  test('delete supprime la règle', async () => {
    const rule = await be.saveCoverageRule(H, { department: 'reception', shift_label: 'M', min_staff_base: 2 });
    await be.deleteCoverageRule(rule.id);
    expect(await be.listCoverageRules(H)).toHaveLength(0);
  });

  test('isole par hotel_id', async () => {
    await be.saveCoverageRule(H,  { department: 'reception', shift_label: 'M', min_staff_base: 2 });
    await be.saveCoverageRule(H2, { department: 'reception', shift_label: 'M', min_staff_base: 1 });
    expect(await be.listCoverageRules(H)).toHaveLength(1);
    expect(await be.listCoverageRules(H2)).toHaveLength(1);
  });

  test('formula_type par défaut est static', async () => {
    const rule = await be.saveCoverageRule(H, { department: 'reception', shift_label: 'M', min_staff_base: 1 });
    expect(rule.formula_type).toBe('static');
  });

  test('sauvegarde occupancy_based avec formula_params', async () => {
    const rule = await be.saveCoverageRule(H, { department: 'etages', shift_label: 'J', min_staff_base: 2, formula_type: 'occupancy_based', formula_params: { per_room_ratio: 0.05 } });
    expect(rule.formula_type).toBe('occupancy_based');
    expect(rule.formula_params.per_room_ratio).toBe(0.05);
  });
});

// ── Occupancy forecast ─────────────────────────────────────────────────────

describe('BE.listOccupancyForecast / upsertOccupancyForecast', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('liste vide initialement', async () => {
    expect(await be.listOccupancyForecast(H, '2025-06-01', '2025-06-30')).toEqual([]);
  });

  test('crée une prévision et la retrouve dans la plage', async () => {
    await be.upsertOccupancyForecast(H, '2025-06-15', { total_rooms: 80, occupied_rooms: 60, arrivals: 10, departures: 8 });
    const rows = await be.listOccupancyForecast(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(1);
    expect(rows[0].occupied_rooms).toBe(60);
  });

  test('upsert met à jour les données existantes', async () => {
    await be.upsertOccupancyForecast(H, '2025-06-15', { occupied_rooms: 50 });
    await be.upsertOccupancyForecast(H, '2025-06-15', { occupied_rooms: 70 });
    const rows = await be.listOccupancyForecast(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(1);
    expect(rows[0].occupied_rooms).toBe(70);
  });

  test('filtre par plage de dates', async () => {
    await be.upsertOccupancyForecast(H, '2025-06-10', { occupied_rooms: 40 });
    await be.upsertOccupancyForecast(H, '2025-07-01', { occupied_rooms: 55 });
    const rows = await be.listOccupancyForecast(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(1);
    expect(rows[0].date).toBe('2025-06-10');
  });

  test('isole par hotel_id', async () => {
    await be.upsertOccupancyForecast(H,  '2025-06-15', { occupied_rooms: 60 });
    await be.upsertOccupancyForecast(H2, '2025-06-15', { occupied_rooms: 30 });
    expect(await be.listOccupancyForecast(H,  '2025-06-01', '2025-06-30')).toHaveLength(1);
    expect(await be.listOccupancyForecast(H2, '2025-06-01', '2025-06-30')).toHaveLength(1);
  });
});
