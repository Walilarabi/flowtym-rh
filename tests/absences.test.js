'use strict';
const { makeTestBE } = require('./lib/testBE');

const H = 'hotel-test-001';
const E1 = 'emp-001';
const E2 = 'emp-002';

describe('BE.listAbsences — bug P1', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('retourne un tableau vide si aucune demande', async () => {
    const result = await be.listAbsences(H);
    expect(result).toEqual([]);
  });

  test('retourne les demandes avec status "submitted"', async () => {
    await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05' });
    const result = await be.listAbsences(H);
    expect(result).toHaveLength(1);
    expect(result[0].status).toBe('submitted');
  });

  test('retourne aussi les demandes "pending"', async () => {
    await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05' });
    const reqs = await be.listAbsenceRequests(H);
    // Forcer le statut en pending (edge case compatibilité)
    reqs[0].status = 'pending';
    const result = await be.listAbsences(H);
    expect(result).toHaveLength(1);
  });

  test('ne retourne PAS les demandes approuvées ni rejetées', async () => {
    const r = await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05' });
    await be.updateAbsenceRequestStatus(r.id, 'approved', null, null, null);
    const result = await be.listAbsences(H);
    expect(result).toHaveLength(0);
  });

  test('isole par hotel_id', async () => {
    await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05' });
    const result = await be.listAbsences('autre-hotel');
    expect(result).toHaveLength(0);
  });

  test('enrichit avec absence_types', async () => {
    await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05' });
    const result = await be.listAbsences(H);
    expect(result[0].absence_types).not.toBeNull();
    expect(result[0].absence_types.code).toBe('CP');
  });
});

describe('Workflow complet demande d\'absence', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('créer → approuver → balance débitée', async () => {
    await be.upsertAbsenceBalance(H, E1, 2025, 'CP', 25, 0);
    const r = await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-05', days_count: 5 });
    expect(r.status).toBe('submitted');

    await be.updateAbsenceRequestStatus(r.id, 'approved', 'u-admin', 'admin@hotel.fr', null);
    await be.upsertAbsenceBalance(H, E1, 2025, 'CP', 25, 5);
    await be.addBalanceMovement(H, E1, null, r.id, 'CP', -5, 'Approbation CP', 'admin@hotel.fr');

    const bal = await be.listAbsenceBalances(H, 2025);
    const cp = bal.find(b => b.balance_type === 'CP');
    expect(cp.taken).toBe(5);
    expect(cp.remaining).toBe(20);
  });

  test('rejeter une demande la rend non visible dans listAbsences', async () => {
    const r = await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'RTT', start_date: '2025-07-01', end_date: '2025-07-02' });
    await be.updateAbsenceRequestStatus(r.id, 'rejected', null, null, 'Non justifié');
    const pending = await be.listAbsences(H);
    expect(pending).toHaveLength(0);
  });

  test('listAbsenceRequests filtre par status', async () => {
    await be.createAbsenceRequest(H, { employee_id: E1, type_code: 'CP', start_date: '2025-06-01', end_date: '2025-06-03' });
    const r2 = await be.createAbsenceRequest(H, { employee_id: E2, type_code: 'MAL', start_date: '2025-06-05', end_date: '2025-06-10' });
    await be.updateAbsenceRequestStatus(r2.id, 'approved', null, null, null);

    const submitted = await be.listAbsenceRequests(H, { status: 'submitted' });
    expect(submitted).toHaveLength(1);
    const approved = await be.listAbsenceRequests(H, { status: 'approved' });
    expect(approved).toHaveLength(1);
  });
});
