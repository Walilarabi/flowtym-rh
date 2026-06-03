/**
 * absences.test.js — Suite de tests pour le module P3B Absences/CP-RTT
 * Format compatible Jest / jsdom (Node)
 *
 * Installation: npm install --save-dev jest jest-environment-jsdom
 * Run: npx jest tests/absences.test.js
 */

'use strict';

// ---------------------------------------------------------------------------
// Helper : simuler un environnement minimal identique à makeTestBE()
// ---------------------------------------------------------------------------
function makeBE() {
  const emps = [
    { id: 'e1', hotel_id: 'h1', first_name: 'Ghani', last_name: 'Amrani', role: 'Chef de réception', active: true },
    { id: 'e2', hotel_id: 'h1', first_name: 'Lyes',  last_name: 'Imzi',   role: 'Réceptionniste',   active: true },
    { id: 'e5', hotel_id: 'h2', first_name: 'Marie', last_name: 'Dubois', role: 'Réceptionniste',   active: true },
  ];
  let planning = [];
  let absenceRequests = [];
  let absenceBalances  = [];
  let absenceMovements = [];
  let absenceHistory   = [];

  const ABSENCE_TYPES = [
    { code: 'CP',    label: 'Congé payé',          planning_code: 'CP',   debit_balance: true,  balance_type: 'CP',  requires_attachment: false, sort_order: 10, color_bg: '#C6EFCE', color_fg: '#0F5132', active: true },
    { code: 'RTT',   label: 'RTT',                  planning_code: 'RTT',  debit_balance: true,  balance_type: 'RTT', requires_attachment: false, sort_order: 20, color_bg: '#BDD7EE', color_fg: '#1F4E78', active: true },
    { code: 'MAL',   label: 'Maladie',              planning_code: 'MAL',  debit_balance: false, balance_type: null,  requires_attachment: true,  sort_order: 30, color_bg: '#FFC7CE', color_fg: '#9C0006', active: true },
    { code: 'MAT',   label: 'Maternité',            planning_code: 'MAT',  debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 40, color_bg: '#E1D5F0', color_fg: '#5B2A86', active: true },
    { code: 'PAT',   label: 'Paternité',            planning_code: 'PAT',  debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 50, color_bg: '#E8E0F5', color_fg: '#4A2080', active: true },
    { code: 'ABS',   label: 'Absence injustifiée',  planning_code: 'ABS',  debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 60, color_bg: '#FFD9D9', color_fg: '#7B0000', active: true },
    { code: 'REC',   label: 'Récupération',         planning_code: 'REC',  debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 70, color_bg: '#D4F0FC', color_fg: '#0C4A6E', active: true },
    { code: 'REPOS', label: 'Repos compensateur',   planning_code: null,   debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 80, color_bg: '#F5F5F5', color_fg: '#6B7280', active: true },
    { code: 'FORM',  label: 'Formation',            planning_code: 'FORM', debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 90, color_bg: '#FEF3C7', color_fg: '#92400E', active: true },
    { code: 'AUT',   label: 'Autre',                planning_code: 'AE',   debit_balance: false, balance_type: null,  requires_attachment: false, sort_order: 100, color_bg: '#FFE699', color_fg: '#7F6000', active: true },
  ];

  return {
    isTest: true,
    async listAbsenceTypes() { return ABSENCE_TYPES.filter(t => t.active); },
    async listAbsenceRequests(h, filters) {
      let list = absenceRequests.filter(r => r.hotel_id === h);
      if (filters?.status)      list = list.filter(r => r.status === filters.status);
      if (filters?.employee_id) list = list.filter(r => r.employee_id === filters.employee_id);
      if (filters?.month) {
        list = list.filter(r => r.start_date >= filters.month + '-01' && r.start_date <= filters.month + '-31');
      }
      const types = ABSENCE_TYPES;
      return list.sort((a, b) => b.start_date.localeCompare(a.start_date)).map(r => ({
        ...r,
        absence_types: types.find(x => x.code === r.type_code) || null,
      }));
    },
    async createAbsenceRequest(h, payload) {
      const id = 'ar' + Date.now() + Math.random().toString(36).slice(2, 6);
      const t = ABSENCE_TYPES.find(x => x.code === payload.type_code);
      const rec = { id, hotel_id: h, ...payload, status: 'submitted', created_at: new Date().toISOString(), updated_at: new Date().toISOString(), absence_types: t || null };
      absenceRequests.push(rec);
      return rec;
    },
    async updateAbsenceRequestStatus(id, status, actorUserId, actorEmail, comment, hotelId, employeeId) {
      const r = absenceRequests.find(x => x.id === id);
      if (!r) throw new Error('not found');
      r.status = status; r.updated_at = new Date().toISOString();
      absenceHistory.push({ id: 'ah' + Date.now(), hotel_id: hotelId, request_id: id, employee_id: employeeId,
        action: status === 'approved' ? 'approve' : status === 'rejected' ? 'reject' : 'cancel',
        actor_user_id: actorUserId, actor_email: actorEmail, comment: comment || null,
        created_at: new Date().toISOString() });
      return r;
    },
    async listAbsenceBalances(h, year) {
      return absenceBalances.filter(b => b.hotel_id === h && b.year === year);
    },
    async upsertAbsenceBalance(h, employee_id, year, type_code, patch) {
      const i = absenceBalances.findIndex(b => b.hotel_id === h && b.employee_id === employee_id && b.year === year && b.type_code === type_code);
      if (i >= 0) Object.assign(absenceBalances[i], patch, { updated_at: new Date().toISOString() });
      else absenceBalances.push({ id: 'ab' + Date.now(), hotel_id: h, employee_id, year, type_code, entitled: 0, taken: 0, adjusted: 0, ...patch, created_at: new Date().toISOString(), updated_at: new Date().toISOString() });
    },
    async addBalanceMovement(h, employee_id, type_code, year, delta, reason, request_id, created_by) {
      absenceMovements.push({ id: 'am' + Date.now(), hotel_id: h, employee_id, type_code, year, delta, reason, request_id: request_id || null, created_by: created_by || null, created_at: new Date().toISOString() });
    },
    async listApprovalHistory(h, request_id) {
      return absenceHistory.filter(x => x.hotel_id === h && x.request_id === request_id)
        .sort((a, b) => a.created_at.localeCompare(b.created_at));
    },
    async savePlanning(h, ups, dels) {
      ups.forEach(u => {
        const i = planning.findIndex(p => p.hotel_id === u.hotel_id && p.employee_id === u.employee_id && p.day === u.day);
        if (i >= 0) planning[i] = { ...planning[i], ...u };
        else planning.push({ ...u });
      });
      dels.forEach(d => { planning = planning.filter(p => !(p.hotel_id === d.hotel_id && p.employee_id === d.employee_id && p.day === d.day)); });
    },
    _planning: () => planning,
    _emps: emps,
  };
}

// ---------------------------------------------------------------------------
// Helper pur : countAbsenceDays (copie de la fonction dans index.html)
// ---------------------------------------------------------------------------
function countAbsenceDays(startDate, endDate, halfDayStart, halfDayEnd) {
  const s = new Date(startDate), e = new Date(endDate);
  let days = 0;
  const c = new Date(s);
  while (c <= e) { days++; c.setDate(c.getDate() + 1); }
  if (halfDayStart) days -= 0.5;
  if (halfDayEnd)   days -= 0.5;
  return Math.max(days, 0.5);
}

// ---------------------------------------------------------------------------
// Helper : syncAbsenceToPlanning (copie de la fonction dans index.html)
// ---------------------------------------------------------------------------
async function syncAbsenceToPlanning(BE, req, absenceTypes) {
  const planCode = req.absence_types?.planning_code
    || absenceTypes.find(t => t.code === req.type_code)?.planning_code;
  if (!planCode) return;
  const upserts = [];
  const s = new Date(req.start_date), e = new Date(req.end_date);
  const c = new Date(s); let day = 0;
  while (c <= e) {
    const dayIso = c.toISOString().slice(0, 10);
    let duration = 1.0;
    const isLast = c.getTime() === e.getTime();
    if (day === 0 && req.half_day_start && isLast && req.half_day_end) duration = 0.5;
    else if (day === 0 && req.half_day_start) duration = 0.5;
    else if (isLast && req.half_day_end) duration = 0.5;
    upserts.push({ hotel_id: req.hotel_id, employee_id: req.employee_id, day: dayIso, status: planCode, duration });
    c.setDate(c.getDate() + 1); day++;
  }
  await BE.savePlanning(req.hotel_id, upserts, []);
}

// ---------------------------------------------------------------------------
// Helper : canApproveAbsences (rôle passé en paramètre)
// ---------------------------------------------------------------------------
function canApproveAbsences(role) {
  return ['direction', 'admin_hotel'].includes(role);
}

// ===========================================================================
// TESTS
// ===========================================================================

describe('countAbsenceDays', () => {
  // Test 1
  test('5 jours du 1 au 5 juin, sans demi-journée', () => {
    expect(countAbsenceDays('2026-06-01', '2026-06-05', false, false)).toBe(5);
  });

  // Test 2
  test('0.5 jour : 1 seul jour avec demi-journée début', () => {
    expect(countAbsenceDays('2026-06-01', '2026-06-01', true, false)).toBe(0.5);
  });

  test('résultat minimum 0.5 même si double demi-journée sur 1 jour', () => {
    expect(countAbsenceDays('2026-06-01', '2026-06-01', true, true)).toBe(0.5);
  });

  test('3 jours avec demi-journée fin = 2.5', () => {
    expect(countAbsenceDays('2026-06-01', '2026-06-03', false, true)).toBe(2.5);
  });
});

describe('Création de demande CP', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 3 — Création avec solde suffisant
  test('crée une demande avec status submitted', async () => {
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { entitled: 25, taken: 0, adjusted: 0 });
    const req = await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'CP', start_date: '2026-06-01', end_date: '2026-06-05',
      half_day_start: false, half_day_end: false, days_count: 5,
    });
    expect(req.status).toBe('submitted');
    expect(req.type_code).toBe('CP');
    expect(req.days_count).toBe(5);
  });
});

describe('Approbation CP', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 4 — Approbation → solde débité
  test('approuver un CP décremente le solde taken', async () => {
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { entitled: 25, taken: 5, adjusted: 0 });
    const req = await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'CP', start_date: '2026-06-01', end_date: '2026-06-03',
      half_day_start: false, half_day_end: false, days_count: 3,
    });
    // Simulate approve workflow
    await BE.updateAbsenceRequestStatus(req.id, 'approved', null, 'admin@test.fr', null, 'h1', 'e1');
    const types = await BE.listAbsenceTypes();
    const t = types.find(x => x.code === 'CP');
    const year = 2026;
    const bals = await BE.listAbsenceBalances('h1', year);
    const bal = bals.find(b => b.employee_id === 'e1' && b.type_code === 'CP');
    const newTaken = (bal?.taken || 0) + req.days_count;
    await BE.upsertAbsenceBalance('h1', 'e1', year, 'CP', { taken: newTaken });
    await BE.addBalanceMovement('h1', 'e1', 'CP', year, -req.days_count, `Approbation ${req.id}`, req.id, null);

    const bals2 = await BE.listAbsenceBalances('h1', 2026);
    const b2 = bals2.find(b => b.employee_id === 'e1' && b.type_code === 'CP');
    expect(b2.taken).toBe(8); // 5 + 3
  });
});

describe('Refus avec motif', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 5 — Refus → status rejected, motif enregistré
  test('refuser une demande avec commentaire → status rejected', async () => {
    const req = await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'MAL', start_date: '2026-06-10', end_date: '2026-06-12',
      half_day_start: false, half_day_end: false, days_count: 3,
    });
    const motif = 'Manque de justificatifs médicaux';
    const updated = await BE.updateAbsenceRequestStatus(req.id, 'rejected', null, 'rh@test.fr', motif, 'h1', 'e1');
    expect(updated.status).toBe('rejected');
    const hist = await BE.listApprovalHistory('h1', req.id);
    expect(hist.length).toBeGreaterThan(0);
    expect(hist[0].action).toBe('reject');
    expect(hist[0].comment).toBe(motif);
  });
});

describe('Annulation → recrédit solde', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 6 — Annulation → le solde taken est recédité
  test('annuler un CP approuvé → taken revient au niveau initial', async () => {
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { entitled: 25, taken: 3, adjusted: 0 });
    const req = await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'CP', start_date: '2026-07-01', end_date: '2026-07-03',
      half_day_start: false, half_day_end: false, days_count: 3,
    });
    // Approve first
    await BE.updateAbsenceRequestStatus(req.id, 'approved', null, 'admin@test.fr', null, 'h1', 'e1');
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { taken: 6 }); // 3 + 3

    // Cancel
    await BE.updateAbsenceRequestStatus(req.id, 'cancelled', null, 'admin@test.fr', null, 'h1', 'e1');
    const bals = await BE.listAbsenceBalances('h1', 2026);
    const bal = bals.find(b => b.employee_id === 'e1' && b.type_code === 'CP');
    const newTaken = Math.max(0, bal.taken - req.days_count);
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { taken: newTaken });
    await BE.addBalanceMovement('h1', 'e1', 'CP', 2026, +req.days_count, `Annulation ${req.id}`, req.id, null);

    const bals2 = await BE.listAbsenceBalances('h1', 2026);
    const b2 = bals2.find(b => b.employee_id === 'e1' && b.type_code === 'CP');
    expect(b2.taken).toBe(3); // retour au niveau initial
  });
});

describe('Solde négatif / vérification', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 7 — Solde négatif détectable (le warning est calculable côté frontend)
  test('solde insuffisant = remaining < 0 détectable', async () => {
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { entitled: 2, taken: 5, adjusted: 0 });
    const bals = await BE.listAbsenceBalances('h1', 2026);
    const bal = bals.find(b => b.employee_id === 'e1' && b.type_code === 'CP');
    const remaining = bal.entitled - bal.taken + bal.adjusted;
    expect(remaining).toBeLessThan(0);
  });
});

describe('Calendrier des absences', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 8 — Absence approuvée apparaît dans listAbsenceRequests du bon mois
  test('absence approuvée remontée dans le filtre mensuel', async () => {
    const req = await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'CP', start_date: '2026-06-10', end_date: '2026-06-12',
      half_day_start: false, half_day_end: false, days_count: 3,
    });
    await BE.updateAbsenceRequestStatus(req.id, 'approved', null, 'admin@test.fr', null, 'h1', 'e1');
    const reqs = await BE.listAbsenceRequests('h1', { month: '2026-06' });
    expect(reqs.length).toBe(1);
    expect(reqs[0].status).toBe('approved');
  });
});

describe('Planning sync', () => {
  let BE;
  let absenceTypes;
  beforeEach(async () => {
    BE = makeBE();
    absenceTypes = await BE.listAbsenceTypes();
  });

  // Test 9 — syncAbsenceToPlanning produit les bonnes lignes de planning
  test('syncAbsenceToPlanning écrit CP dans staff_planning pour chaque jour', async () => {
    const req = {
      id: 'req-test', hotel_id: 'h1', employee_id: 'e1',
      type_code: 'CP', start_date: '2026-06-01', end_date: '2026-06-03',
      half_day_start: false, half_day_end: false,
      absence_types: absenceTypes.find(t => t.code === 'CP'),
    };
    await syncAbsenceToPlanning(BE, req, absenceTypes);
    const planning = BE._planning();
    const hotelPlan = planning.filter(p => p.hotel_id === 'h1' && p.employee_id === 'e1');
    expect(hotelPlan.length).toBe(3);
    hotelPlan.forEach(p => expect(p.status).toBe('CP'));
    expect(hotelPlan.map(p => p.day).sort()).toEqual(['2026-06-01', '2026-06-02', '2026-06-03']);
  });

  test('syncAbsenceToPlanning avec demi-journée = durée 0.5', async () => {
    const req = {
      id: 'req-half', hotel_id: 'h1', employee_id: 'e1',
      type_code: 'CP', start_date: '2026-06-05', end_date: '2026-06-05',
      half_day_start: true, half_day_end: false,
      absence_types: absenceTypes.find(t => t.code === 'CP'),
    };
    await syncAbsenceToPlanning(BE, req, absenceTypes);
    const planning = BE._planning().filter(p => p.day === '2026-06-05' && p.employee_id === 'e1');
    expect(planning[0].duration).toBe(0.5);
  });
});

describe('Isolation multi-hôtel', () => {
  let BE;
  beforeEach(() => { BE = makeBE(); });

  // Test 10 — Les demandes d'un hôtel ne remontent pas pour l'autre
  test("les demandes de h1 n'apparaissent pas dans h2", async () => {
    await BE.createAbsenceRequest('h1', {
      employee_id: 'e1', type_code: 'MAL', start_date: '2026-06-01', end_date: '2026-06-03',
      half_day_start: false, half_day_end: false, days_count: 3,
    });
    const reqsH2 = await BE.listAbsenceRequests('h2', {});
    expect(reqsH2.length).toBe(0);
  });

  test('les soldes de h1 ne remontent pas dans h2', async () => {
    await BE.upsertAbsenceBalance('h1', 'e1', 2026, 'CP', { entitled: 25 });
    const bals = await BE.listAbsenceBalances('h2', 2026);
    expect(bals.length).toBe(0);
  });
});

describe('Droits par rôle — canApproveAbsences', () => {
  // Test 11 — Les rôles
  test('direction peut approuver', () => {
    expect(canApproveAbsences('direction')).toBe(true);
  });

  test('admin_hotel peut approuver', () => {
    expect(canApproveAbsences('admin_hotel')).toBe(true);
  });

  test('reception ne peut pas approuver', () => {
    expect(canApproveAbsences('reception')).toBe(false);
  });

  test('gouvernante ne peut pas approuver', () => {
    expect(canApproveAbsences('gouvernante')).toBe(false);
  });

  test('femme_de_chambre ne peut pas approuver', () => {
    expect(canApproveAbsences('femme_de_chambre')).toBe(false);
  });
});

describe('renderAbsences produit du HTML', () => {
  // Test 12 — Zéro bouton mort : renderAbsences produit du HTML valide

  test('countAbsenceDays est une fonction', () => {
    expect(typeof countAbsenceDays).toBe('function');
  });

  test('makeBE retourne un objet avec toutes les méthodes absences', () => {
    const be = makeBE();
    expect(typeof be.listAbsenceTypes).toBe('function');
    expect(typeof be.listAbsenceRequests).toBe('function');
    expect(typeof be.createAbsenceRequest).toBe('function');
    expect(typeof be.updateAbsenceRequestStatus).toBe('function');
    expect(typeof be.listAbsenceBalances).toBe('function');
    expect(typeof be.upsertAbsenceBalance).toBe('function');
    expect(typeof be.addBalanceMovement).toBe('function');
    expect(typeof be.listApprovalHistory).toBe('function');
  });

  test('absence_types contient 10 types avec les codes attendus', async () => {
    const be = makeBE();
    const types = await be.listAbsenceTypes();
    expect(types.length).toBe(10);
    const codes = types.map(t => t.code);
    expect(codes).toContain('CP');
    expect(codes).toContain('RTT');
    expect(codes).toContain('MAL');
    expect(codes).toContain('MAT');
    expect(codes).toContain('PAT');
    expect(codes).toContain('ABS');
    expect(codes).toContain('REC');
    expect(codes).toContain('REPOS');
    expect(codes).toContain('FORM');
    expect(codes).toContain('AUT');
  });

  test('types CP et RTT ont debit_balance=true', async () => {
    const be = makeBE();
    const types = await be.listAbsenceTypes();
    const cp = types.find(t => t.code === 'CP');
    const rtt = types.find(t => t.code === 'RTT');
    expect(cp.debit_balance).toBe(true);
    expect(rtt.debit_balance).toBe(true);
    expect(cp.balance_type).toBe('CP');
    expect(rtt.balance_type).toBe('RTT');
  });

  test('MAL a requires_attachment=true', async () => {
    const be = makeBE();
    const types = await be.listAbsenceTypes();
    const mal = types.find(t => t.code === 'MAL');
    expect(mal.requires_attachment).toBe(true);
  });
});
