'use strict';
const { computeLegalAlerts, computeCoverageAlerts } = require('./lib/planningLogic');

const dim = (y, m) => new Date(y, m + 1, 0).getDate();
const iso = (y, m, d) => `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
const CMAP = {
  P:    { cat: 'worked' },
  PE:   { cat: 'worked' },
  CP:   { cat: 'paid'   },
  RTT:  { cat: 'paid'   },
  MAL:  { cat: 'abs'    },
  MAT:  { cat: 'abs'    },
  ABS:  { cat: 'abs'    },
  F:    { cat: 'holiday' },
};
const deps = { cmap: CMAP, dimFn: dim, isoFn: iso };

// ── computeLegalAlerts ─────────────────────────────────────────────────────

describe('computeLegalAlerts — 7 jours consécutifs', () => {
  const E1 = 'emp-001';
  const Y = 2025, M = 5; // juin 2025

  test('0 alerte si < 7 jours consécutifs', () => {
    const rows = [];
    for (let d = 1; d <= 6; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    expect(computeLegalAlerts(rows, Y, M, deps)).toHaveLength(0);
  });

  test('1 alerte au 7ème jour consécutif', () => {
    const rows = [];
    for (let d = 1; d <= 7; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    const alerts = computeLegalAlerts(rows, Y, M, deps);
    expect(alerts.filter(a => a.type === '7_consecutive')).toHaveLength(1);
    expect(alerts[0].employee_id).toBe(E1);
    expect(alerts[0].day).toBe(iso(Y, M, 1));
  });

  test('repos interrompt le compteur', () => {
    const rows = [];
    for (let d = 1; d <= 6; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    // jour 7 = repos (absent du planning)
    for (let d = 8; d <= 14; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    const alerts = computeLegalAlerts(rows, Y, M, deps);
    // Jour 7 absent → streak reset → aucun 7 consécutifs
    expect(alerts.filter(a => a.type === '7_consecutive')).toHaveLength(1);
    expect(alerts[0].day).toBe(iso(Y, M, 8)); // streak repart à 8
  });

  test('CP/RTT interrompent le compteur', () => {
    const rows = [];
    for (let d = 1; d <= 5; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    rows.push({ employee_id: E1, day: iso(Y, M, 6), status: 'CP' });
    for (let d = 7; d <= 11; d++) rows.push({ employee_id: E1, day: iso(Y, M, d), status: 'P' });
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === '7_consecutive')).toHaveLength(0);
  });

  test('isole par employee_id', () => {
    const rows = [];
    for (let d = 1; d <= 7; d++) rows.push({ employee_id: 'emp-A', day: iso(Y, M, d), status: 'P' });
    for (let d = 1; d <= 4; d++) rows.push({ employee_id: 'emp-B', day: iso(Y, M, d), status: 'P' });
    const alerts = computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === '7_consecutive');
    expect(alerts).toHaveLength(1);
    expect(alerts[0].employee_id).toBe('emp-A');
  });
});

describe('computeLegalAlerts — shift sur absence', () => {
  const E1 = 'emp-001';
  const Y = 2025, M = 5;

  test('alerte si shift_label sur CP', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 5), status: 'CP', shift_label: 'M' }];
    const alerts = computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'shift_on_absence');
    expect(alerts).toHaveLength(1);
  });

  test('alerte si shift_label sur MAL', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 5), status: 'MAL', shift_label: 'S' }];
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'shift_on_absence')).toHaveLength(1);
  });

  test('pas d\'alerte si shift_label sur P (normal)', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 5), status: 'P', shift_label: 'M' }];
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'shift_on_absence')).toHaveLength(0);
  });

  test('pas d\'alerte si CP sans shift', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 5), status: 'CP', shift_label: null }];
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'shift_on_absence')).toHaveLength(0);
  });
});

describe('computeLegalAlerts — durée excessive', () => {
  const E1 = 'emp-001';
  const Y = 2025, M = 5;

  test('alerte si durée > 10h (sans pause)', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 1), status: 'P', shift_start: '06:00', shift_end: '17:00', break_minutes: 0 }];
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'excessive_duration')).toHaveLength(1);
  });

  test('pas d\'alerte si durée <= 10h avec pause', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 1), status: 'P', shift_start: '06:00', shift_end: '17:00', break_minutes: 60 }];
    // 11h - 1h pause = 10h exactement → pas d'alerte
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'excessive_duration')).toHaveLength(0);
  });

  test('poste de nuit cross-minuit géré', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 1), status: 'P', shift_start: '22:00', shift_end: '09:00', break_minutes: 0 }];
    // 11h → alerte
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'excessive_duration')).toHaveLength(1);
  });

  test('pas d\'alerte si shift_start/end absents', () => {
    const rows = [{ employee_id: E1, day: iso(Y, M, 1), status: 'P', shift_start: null, shift_end: null }];
    expect(computeLegalAlerts(rows, Y, M, deps).filter(a => a.type === 'excessive_duration')).toHaveLength(0);
  });
});

// ── computeCoverageAlerts ──────────────────────────────────────────────────

describe('computeCoverageAlerts', () => {
  const cdeps = { dimFn: dim, isoFn: iso };
  const Y = 2025, M = 5;
  const deptMap = new Map([['emp-A', 'Reception'], ['emp-B', 'Reception'], ['emp-C', 'Etages']]);

  const rules = [
    { department: 'Reception', shift_label: 'M', day_of_week: null, min_staff_base: 2, active: true },
    { department: 'Etages',    shift_label: 'J', day_of_week: null, min_staff_base: 1, active: true },
  ];

  test('alerte si effectif < min_staff_base', () => {
    const rows = [{ employee_id: 'emp-A', day: iso(Y, M, 2), status: 'P', shift_label: 'M' }];
    // 1 présent en Matin, min = 2 → alerte
    const alerts = computeCoverageAlerts(rows, rules, deptMap, Y, M, cdeps);
    const dayAlerts = alerts.filter(a => a.day === iso(Y, M, 2) && a.shift === 'M');
    expect(dayAlerts.length).toBeGreaterThan(0);
    expect(dayAlerts[0].actual).toBe(1);
    expect(dayAlerts[0].required).toBe(2);
  });

  test('pas d\'alerte si effectif >= min_staff_base', () => {
    const rows = [
      { employee_id: 'emp-A', day: iso(Y, M, 2), status: 'P', shift_label: 'M' },
      { employee_id: 'emp-B', day: iso(Y, M, 2), status: 'P', shift_label: 'M' },
    ];
    const alerts = computeCoverageAlerts(rows, rules, deptMap, Y, M, cdeps);
    expect(alerts.filter(a => a.day === iso(Y, M, 2) && a.shift === 'M')).toHaveLength(0);
  });

  test('filtre par département (emp-C = Etages, pas Reception)', () => {
    const rows = [{ employee_id: 'emp-C', day: iso(Y, M, 2), status: 'P', shift_label: 'M' }];
    // emp-C est en Etages, pas Reception → ne compte pas pour la règle Reception/M
    const alerts = computeCoverageAlerts(rows, rules, deptMap, Y, M, cdeps);
    const rAlerts = alerts.filter(a => a.day === iso(Y, M, 2) && a.department === 'Reception' && a.shift === 'M');
    expect(rAlerts[0]?.actual).toBe(0);
  });

  test('filtre day_of_week — règle ne s\'applique pas aux autres jours', () => {
    const mondayRules = [{ department: 'Reception', shift_label: 'M', day_of_week: 0, min_staff_base: 2, active: true }];
    // Trouver un lundi dans juin 2025 : 2 juin 2025 = lundi
    const rows = [{ employee_id: 'emp-A', day: iso(Y, M, 3), status: 'P', shift_label: 'M' }]; // mardi
    const alerts = computeCoverageAlerts(rows, mondayRules, deptMap, Y, M, cdeps);
    // La règle lundi (day_of_week=0) ne s'applique pas au mardi
    expect(alerts.filter(a => a.day === iso(Y, M, 3))).toHaveLength(0);
  });

  test('règle inactive ignorée', () => {
    const inactiveRules = [{ department: 'Reception', shift_label: 'M', day_of_week: null, min_staff_base: 5, active: false }];
    const rows = [];
    expect(computeCoverageAlerts(rows, inactiveRules, deptMap, Y, M, cdeps)).toHaveLength(0);
  });
});
