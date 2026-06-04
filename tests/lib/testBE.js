'use strict';
/**
 * Reproduction fidèle de makeTestBE() en module CommonJS.
 * Utilisé par les tests Jest — aucune dépendance Supabase.
 */

const ABSENCE_TYPES_SEED = [
  {code:'CP',  label:'Congé payé',   color_bg:'#C6EFCE',color_fg:'#0F5132',planning_code:'CP',  debit_balance:true, balance_type:'CP'},
  {code:'RTT', label:'RTT',          color_bg:'#BDD7EE',color_fg:'#1F4E78',planning_code:'RTT', debit_balance:true, balance_type:'RTT'},
  {code:'MAL', label:'Maladie',      color_bg:'#FFC7CE',color_fg:'#9C0006',planning_code:'MAL', debit_balance:false,balance_type:null},
  {code:'MAT', label:'Maternité',    color_bg:'#E1D5F0',color_fg:'#5B2A86',planning_code:'MAT', debit_balance:false,balance_type:null},
  {code:'ABS', label:'Abs. injust.', color_bg:'#FFD9D9',color_fg:'#7B0000',planning_code:'ABS', debit_balance:false,balance_type:null},
];

function makeTestBE() {
  let staff = [];
  let absenceRequests = [];
  let absenceBalances = [];
  let balanceMovements = [];
  let clockings = [];
  let planning = [];

  const be = {
    isTest: true,

    // ── Employees ──────────────────────────────────────────────────────────
    async listEmployees(h) {
      return staff.filter(s => s.hotel_id === h);
    },
    async addEmployee(h, p) {
      const s = { id: 'emp-' + Date.now() + Math.random().toString(36).slice(2, 5), hotel_id: h, active: true, ...p };
      staff.push(s);
      return s;
    },
    async updateEmployee(id, p) {
      const s = staff.find(x => x.id === id);
      if (!s) throw new Error('Employee not found');
      Object.assign(s, p);
      return s;
    },

    // ── Absence types ──────────────────────────────────────────────────────
    async listAbsenceTypes() {
      return [...ABSENCE_TYPES_SEED];
    },

    // ── Absence requests ───────────────────────────────────────────────────
    async listAbsenceRequests(h, filters = {}) {
      let list = absenceRequests.filter(r => r.hotel_id === h);
      if (filters.status) list = list.filter(r => r.status === filters.status);
      if (filters.employee_id) list = list.filter(r => r.employee_id === filters.employee_id);
      if (filters.month) {
        list = list.filter(r => r.start_date >= filters.month + '-01' && r.start_date <= filters.month + '-31');
      }
      const types = await be.listAbsenceTypes();
      return list.sort((a, b) => b.start_date.localeCompare(a.start_date)).map(r => ({
        ...r, absence_types: types.find(t => t.code === r.type_code) || null,
      }));
    },
    async listAbsences(h) {
      const types = await be.listAbsenceTypes();
      return absenceRequests
        .filter(r => r.hotel_id === h && (r.status === 'submitted' || r.status === 'pending'))
        .sort((a, b) => b.start_date.localeCompare(a.start_date))
        .map(r => ({ ...r, absence_types: types.find(t => t.code === r.type_code) || null }));
    },
    async createAbsenceRequest(h, payload) {
      const id = 'ar-' + Date.now() + Math.random().toString(36).slice(2, 5);
      const types = await be.listAbsenceTypes();
      const rec = {
        id, hotel_id: h, ...payload, status: 'submitted',
        created_at: new Date().toISOString(), updated_at: new Date().toISOString(),
        absence_types: types.find(t => t.code === payload.type_code) || null,
      };
      absenceRequests.push(rec);
      return rec;
    },
    async updateAbsenceRequestStatus(id, status, actorUserId, actorEmail, comment) {
      const r = absenceRequests.find(x => x.id === id);
      if (!r) throw new Error('Request not found');
      r.status = status; r.updated_at = new Date().toISOString();
      return r;
    },

    // ── Absence balances ───────────────────────────────────────────────────
    async listAbsenceBalances(h, year) {
      return absenceBalances.filter(b => b.hotel_id === h && b.year === year);
    },
    // Signature réelle : upsertAbsenceBalance(h, employee_id, year, type_code, patch)
    // patch = { acquired, taken } ou sous-ensemble
    async upsertAbsenceBalance(h, employee_id, year, type_code, patch) {
      let b = absenceBalances.find(x => x.hotel_id === h && x.employee_id === employee_id && x.year === year && x.type_code === type_code);
      if (b) { Object.assign(b, patch); }
      else {
        b = { id: 'bal-' + Date.now(), hotel_id: h, employee_id, year, type_code, acquired: 0, taken: 0, ...patch };
        absenceBalances.push(b);
      }
      b.remaining = (b.acquired || 0) - (b.taken || 0);
      return b;
    },
    // Signature réelle : addBalanceMovement(h, employee_id, type_code, year, delta, reason, request_id, created_by)
    async addBalanceMovement(h, employee_id, type_code, year, delta, reason, request_id, created_by) {
      const mv = { id: 'mv-' + Date.now(), hotel_id: h, employee_id, type_code, year, delta, reason, request_id: request_id || null, created_by: created_by || null, created_at: new Date().toISOString() };
      balanceMovements.push(mv);
      return mv;
    },

    // ── Planning ───────────────────────────────────────────────────────────
    async listMonthPlanning(h, y, m) {
      const from = `${y}-${String(m).padStart(2,'0')}-01`;
      const to   = `${y}-${String(m).padStart(2,'0')}-31`;
      return planning.filter(p => p.hotel_id === h && p.day >= from && p.day <= to);
    },
    async savePlanning(h, upserts, deletes) {
      deletes.forEach(d => {
        const i = planning.findIndex(p => p.hotel_id === d.hotel_id && p.employee_id === d.employee_id && p.day === d.day);
        if (i >= 0) planning.splice(i, 1);
      });
      upserts.forEach(u => {
        const i = planning.findIndex(p => p.hotel_id === u.hotel_id && p.employee_id === u.employee_id && p.day === u.day);
        if (i >= 0) Object.assign(planning[i], u); else planning.push(u);
      });
    },

    // ── Clockings ──────────────────────────────────────────────────────────
    async listClockings(h, day) {
      return clockings.filter(c => c.hotel_id === h && c.day === day);
    },
    async listClockingsByRange(h, from, to) {
      return clockings.filter(c => c.hotel_id === h && c.day >= from && c.day <= to);
    },
    async addClocking(h, p) {
      const c = { id: 'ck-' + Date.now(), hotel_id: h, ...p, created_at: new Date().toISOString() };
      clockings.push(c);
      return c;
    },
    async updateClocking(id, patch) {
      const c = clockings.find(x => x.id === id);
      if (!c) throw new Error('Clocking not found');
      Object.assign(c, patch);
      return c;
    },

    // ── Access management ──────────────────────────────────────────────────
    async listAccess(h) {
      return [
        { user_id: 'u1', email: 'demo@flowtym.local', full_name: 'Demo User', role: 'direction', is_default: true, granted_at: '2025-01-01T00:00:00Z' },
      ];
    },
    async updateAccess() { return; },
    async revokeAccess() { return; },
    async inviteUser(h, email, full_name, role) {
      return { success: true, user_id: 'inv-' + Date.now() };
    },

    // ── Helpers for test inspection ────────────────────────────────────────
    _state() { return { staff, absenceRequests, absenceBalances, balanceMovements, clockings, planning }; },
    _reset() { staff=[]; absenceRequests=[]; absenceBalances=[]; balanceMovements=[]; clockings=[]; planning=[]; },
  };

  return be;
}

module.exports = { makeTestBE };
