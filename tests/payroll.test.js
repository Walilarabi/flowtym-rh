'use strict';
const { makeTestBE } = require('./lib/testBE');

const H = 'hotel-pay-001';

describe('Paie — calcul éléments variables', () => {
  let be;
  beforeEach(async () => {
    be = makeTestBE();
    // Ajouter deux employés
    await be.addEmployee(H, { first_name: 'Alice', last_name: 'Martin', active: true });
    await be.addEmployee(H, { first_name: 'Bob', last_name: 'Dupont', active: true });
  });

  test('listMonthPlanning retourne les statuts du mois', async () => {
    const emps = await be.listEmployees(H);
    const eid = emps[0].id;
    await be.savePlanning(H, [
      { hotel_id: H, employee_id: eid, day: '2025-06-02', status: 'P' },
      { hotel_id: H, employee_id: eid, day: '2025-06-03', status: 'CP' },
    ], []);
    const rows = await be.listMonthPlanning(H, 2025, 6);
    expect(rows).toHaveLength(2);
    const statuses = rows.map(r => r.status);
    expect(statuses).toContain('P');
    expect(statuses).toContain('CP');
  });

  test('listClockingsByRange agrège les pointages du mois', async () => {
    const emps = await be.listEmployees(H);
    const eid = emps[0].id;
    await be.addClocking(H, { employee_id: eid, day: '2025-06-02', clock_in_ts: '2025-06-02T08:00:00Z', clock_out_ts: '2025-06-02T16:00:00Z', break_minutes: 30 });
    await be.addClocking(H, { employee_id: eid, day: '2025-06-03', clock_in_ts: '2025-06-03T09:00:00Z', clock_out_ts: '2025-06-03T17:00:00Z', break_minutes: 0 });
    const rows = await be.listClockingsByRange(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(2);
  });

  test('pointage hors plage mensuelle ignoré', async () => {
    const emps = await be.listEmployees(H);
    await be.addClocking(H, { employee_id: emps[0].id, day: '2025-05-31', clock_in_ts: '2025-05-31T08:00:00Z', clock_out_ts: '2025-05-31T16:00:00Z', break_minutes: 0 });
    const rows = await be.listClockingsByRange(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(0);
  });

  test('isolation hotel_id dans les pointages', async () => {
    const emps = await be.listEmployees(H);
    await be.addClocking('autre-hotel', { employee_id: emps[0].id, day: '2025-06-01', clock_in_ts: '2025-06-01T08:00:00Z', clock_out_ts: '2025-06-01T16:00:00Z', break_minutes: 0 });
    const rows = await be.listClockingsByRange(H, '2025-06-01', '2025-06-30');
    expect(rows).toHaveLength(0);
  });
});
