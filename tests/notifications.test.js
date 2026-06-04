'use strict';
const { makeTestBE } = require('./lib/testBE');

const H = 'hotel-notif-001';

describe('Cloche notifications — listAbsences', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('renvoie tableau vide quand rien en attente', async () => {
    const result = await be.listAbsences(H);
    expect(Array.isArray(result)).toBe(true);
    expect(result.length).toBe(0);
  });

  test('detecte demandes soumises pour la cloche', async () => {
    await be.createAbsenceRequest(H, { employee_id: 'e1', type_code: 'CP', start_date: '2025-08-01', end_date: '2025-08-05' });
    await be.createAbsenceRequest(H, { employee_id: 'e2', type_code: 'RTT', start_date: '2025-08-06', end_date: '2025-08-07' });
    const pending = await be.listAbsences(H);
    expect(pending.length).toBe(2);
    // Tous status submitted
    pending.forEach(a => expect(['submitted','pending']).toContain(a.status));
  });

  test('badge = 0 quand toutes demandes traitées', async () => {
    const r1 = await be.createAbsenceRequest(H, { employee_id: 'e1', type_code: 'CP', start_date: '2025-08-01', end_date: '2025-08-05' });
    const r2 = await be.createAbsenceRequest(H, { employee_id: 'e2', type_code: 'MAL', start_date: '2025-08-06', end_date: '2025-08-10' });
    await be.updateAbsenceRequestStatus(r1.id, 'approved', null, null, null);
    await be.updateAbsenceRequestStatus(r2.id, 'rejected', null, null, 'Non justifié');
    const pending = await be.listAbsences(H);
    expect(pending.length).toBe(0);
  });

  test('multi-hotel : isolé par hotel_id', async () => {
    await be.createAbsenceRequest(H, { employee_id: 'e1', type_code: 'CP', start_date: '2025-08-01', end_date: '2025-08-05' });
    const other = await be.listAbsences('hotel-autre');
    expect(other.length).toBe(0);
    const mine = await be.listAbsences(H);
    expect(mine.length).toBe(1);
  });
});
