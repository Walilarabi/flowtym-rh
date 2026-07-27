'use strict';
const { weekdayOf, dateStrRange, computeCodeForDate, planEmployeeAutoFill } = require('./lib/autoFillPattern');

const PROTECTED_CODES = new Set(['CP', 'RTT', 'MAL', 'MAT', 'CSS', 'AE', 'F', 'PAT', 'ABS', 'REC', 'FORM']);
const DOW_NAMES = ['Dim', 'Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam'];

// Référence indépendante du jour de la semaine (Date.UTC), pour ne pas retester
// weekdayOf avec lui-même.
function refWeekday(y, m, d) { return new Date(Date.UTC(y, m - 1, d)).getUTCDay(); }

// ── Bug réel : « Autoremplir » sur Folkestone Opéra, sept.–déc. 2026 ──────────
// (issue rapportée : dimanche/lundi traités comme travaillés au lieu de repos)

describe('fixed_days_off — non-régression bug Folkestone Opéra sept.–déc. 2026', () => {
  test('Ali Larabi (repos fixes samedi+dimanche [6,0]) : tous les dimanches et samedis de sept. à déc. 2026 sont repos', () => {
    const pattern = { pattern_type: 'fixed_days_off', fixed_days_off: [0, 6] };
    for (const ds of dateStrRange('2026-09-01', '2026-12-31')) {
      const wd = weekdayOf(ds);
      const res = computeCodeForDate(null, ds, pattern);
      if (wd === 0 || wd === 6) expect(res).toEqual({ code: '', reason: 'Repos fixe' });
      else expect(res).toEqual({ code: 'P', reason: 'Jour travaillé' });
    }
  });

  test('Samy Kaldas (repos fixes dimanche+lundi [0,1]) : tous les lundis et dimanches de sept. à déc. 2026 sont repos', () => {
    const pattern = { pattern_type: 'fixed_days_off', fixed_days_off: [0, 1] };
    for (const ds of dateStrRange('2026-09-01', '2026-12-31')) {
      const wd = weekdayOf(ds);
      const res = computeCodeForDate(null, ds, pattern);
      if (wd === 0 || wd === 1) expect(res).toEqual({ code: '', reason: 'Repos fixe' });
      else expect(res).toEqual({ code: 'P', reason: 'Jour travaillé' });
    }
  });

  test('juin–août 2026 (période jugée « fonctionnelle ») donne le même résultat que sept.–déc. : pas de logique dépendante du mois', () => {
    const patAli = { pattern_type: 'fixed_days_off', fixed_days_off: [0, 6] };
    const patSamy = { pattern_type: 'fixed_days_off', fixed_days_off: [0, 1] };
    for (const ds of dateStrRange('2026-06-01', '2026-08-31')) {
      const wd = weekdayOf(ds);
      expect(computeCodeForDate(null, ds, patAli).code).toBe((wd === 0 || wd === 6) ? '' : 'P');
      expect(computeCodeForDate(null, ds, patSamy).code).toBe((wd === 0 || wd === 1) ? '' : 'P');
    }
  });
});

describe('weekdayOf — exhaustif, immune aux fuseaux/DST/années bissextiles', () => {
  test('chaque jour de 2024 à 2032 correspond au calcul de référence Date.UTC', () => {
    let checked = 0;
    for (let y = 2024; y <= 2032; y++) {
      for (let m = 1; m <= 12; m++) {
        const nd = new Date(Date.UTC(y, m, 0)).getUTCDate();
        for (let d = 1; d <= nd; d++) {
          const ds = `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
          expect(weekdayOf(ds)).toBe(refWeekday(y, m, d));
          checked++;
        }
      }
    }
    expect(checked).toBeGreaterThan(3000); // sanity : la boucle a bien tourné
  });

  test('transition DST France (dernier dimanche d\'octobre 2026) ne décale pas le jour suivant', () => {
    expect(weekdayOf('2026-10-24')).toBe(6); // sam.
    expect(weekdayOf('2026-10-25')).toBe(0); // dim. — bascule heure d'hiver en France
    expect(weekdayOf('2026-10-26')).toBe(1); // lun.
  });

  test('changement d\'année (31 déc. → 1er janv.)', () => {
    expect(weekdayOf('2026-12-31')).toBe((refWeekday(2026, 12, 31)));
    expect(weekdayOf('2027-01-01')).toBe((refWeekday(2027, 1, 1)));
  });

  test('29 février (année bissextile 2028)', () => {
    expect(weekdayOf('2028-02-29')).toBe(refWeekday(2028, 2, 29));
    expect(weekdayOf('2028-03-01')).toBe(refWeekday(2028, 3, 1));
  });
});

describe('computeCodeForDate — fixed_days_off, brute force sur toutes les combinaisons de repos', () => {
  test('pour chaque jour de repos fixe (0-6) et chaque date de 2024 à 2032, le code suit exactement le jour de la semaine', () => {
    for (const ds of dateStrRange('2024-01-01', '2032-12-31')) {
      const wd = weekdayOf(ds);
      for (let restDay = 0; restDay < 7; restDay++) {
        const res = computeCodeForDate(null, ds, { pattern_type: 'fixed_days_off', fixed_days_off: [restDay] });
        expect(res.code).toBe(wd === restDay ? '' : 'P');
      }
    }
  });

  test('mode manuel ou rythme absent → null (aucune règle applicable)', () => {
    expect(computeCodeForDate(null, '2026-09-06', null)).toBeNull();
    expect(computeCodeForDate(null, '2026-09-06', { pattern_type: 'manual' })).toBeNull();
  });
});

describe('computeCodeForDate — rotating_cycle (traversée de mois et d\'année)', () => {
  const PAT = {
    pattern_type: 'rotating_cycle', cycle_start_date: '2026-09-01', cycle_length_days: 28,
    cycle_days: [
      { day: 1, status: 'off' }, { day: 2, status: 'off' }, { day: 3, status: 'work' }, { day: 4, status: 'work' },
      { day: 5, status: 'off' }, { day: 6, status: 'off' }, { day: 7, status: 'off' }, { day: 8, status: 'work' },
      { day: 9, status: 'work' }, { day: 10, status: 'off' }, { day: 11, status: 'off' }, { day: 12, status: 'work' },
      { day: 13, status: 'work' }, { day: 14, status: 'work' }, { day: 15, status: 'off' }, { day: 16, status: 'off' },
      { day: 17, status: 'work' }, { day: 18, status: 'work' }, { day: 19, status: 'off' }, { day: 20, status: 'off' },
      { day: 21, status: 'off' }, { day: 22, status: 'work' }, { day: 23, status: 'work' }, { day: 24, status: 'off' },
      { day: 25, status: 'off' }, { day: 26, status: 'work' }, { day: 27, status: 'work' }, { day: 28, status: 'work' },
    ],
  };

  test('le cycle se poursuit correctement au changement de mois (septembre → octobre)', () => {
    // Cycle de 28 jours démarré le 2026-09-01 (J1) : le 2026-10-01 est le 31e jour
    // du cycle, soit diff=30, idx=30%28=2 → J3 (travail).
    expect(computeCodeForDate(null, '2026-09-29', PAT).code).toBe(''); // diff=28 → J1 repos (le cycle boucle)
    expect(computeCodeForDate(null, '2026-09-30', PAT).code).toBe(''); // diff=29 → J2 repos
    expect(computeCodeForDate(null, '2026-10-01', PAT).code).toBe('P'); // diff=30 → J3 travail
    expect(computeCodeForDate(null, '2026-10-02', PAT).code).toBe('P'); // diff=31 → J4 travail
    expect(computeCodeForDate(null, '2026-10-03', PAT).code).toBe(''); // diff=32 → J5 repos
  });

  test('traversée du changement d\'année', () => {
    const pat2 = {
      pattern_type: 'rotating_cycle', cycle_start_date: '2026-11-15', cycle_length_days: 7,
      cycle_days: [
        { day: 1, status: 'work' }, { day: 2, status: 'work' }, { day: 3, status: 'off' },
        { day: 4, status: 'off' }, { day: 5, status: 'work' }, { day: 6, status: 'work' }, { day: 7, status: 'work' },
      ],
    };
    // diff('2026-11-15','2026-12-31')=46, 46%7=4 → J5 (travail)
    expect(computeCodeForDate(null, '2026-12-31', pat2).code).toBe('P');
    // diff('2026-11-15','2027-01-01')=47, 47%7=5 → J6 (travail)
    expect(computeCodeForDate(null, '2027-01-01', pat2).code).toBe('P');
  });

  test('avant le début du cycle → null', () => {
    expect(computeCodeForDate(null, '2026-08-31', PAT)).toBeNull();
  });
});

// ── Détection des conflits (mode sécurisé) ────────────────────────────────────
// Reproduit précisément le scénario découvert en base pour Folkestone Opéra :
// des lignes 'P' générées avant la mise en place du rythme fixed_days_off
// restent en base sur des jours désormais configurés comme repos fixe. Le
// mode sécurisé ne doit jamais les écraser silencieusement, mais doit les
// signaler comme conflits pour qu'un correctif ciblé soit possible.

describe('planEmployeeAutoFill — détection des conflits en mode sécurisé', () => {
  const aliPattern = { pattern_type: 'fixed_days_off', fixed_days_off: [0, 6] };

  test('un dimanche déjà marqué \'P\' en base (résidu) est signalé en conflit, jamais réécrit silencieusement', () => {
    const existingMap = new Map([['2026-09-06', 'P']]); // dimanche, résidu du bug historique
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-06', toStr: '2026-09-06',
      existingMap, safeOnly: true, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.toCreate).toHaveLength(0); // mode sécurisé : jamais écrasé automatiquement
    expect(r.skipped).toHaveLength(1);
    expect(r.conflicts).toEqual([{ date: '2026-09-06', existing: 'P', expected: '', reason: 'Repos fixe' }]);
  });

  test('une cellule déjà vide (repos confirmé) n\'est pas un conflit et est recalculée normalement', () => {
    const existingMap = new Map(); // aucune ligne = repos = pas de conflit
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-06', toStr: '2026-09-06',
      existingMap, safeOnly: true, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.conflicts).toHaveLength(0);
    expect(r.toCreate).toEqual([{ day: '2026-09-06', status: '', reason: 'Repos fixe', old_value: '' }]);
  });

  test('un jour travaillé correctement marqué \'P\' (hors repos fixe) n\'est jamais un faux conflit', () => {
    const existingMap = new Map([['2026-09-07', 'P']]); // lundi, jour travaillé légitime pour Ali
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-07', toStr: '2026-09-07',
      existingMap, safeOnly: true, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.conflicts).toHaveLength(0);
    expect(r.skipped).toHaveLength(1);
  });

  test('une absence protégée (CP) sur un jour de repos fixe reste protégée, jamais comptée en conflit', () => {
    const existingMap = new Map([['2026-09-06', 'CP']]);
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-06', toStr: '2026-09-06',
      existingMap, safeOnly: true, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.conflicts).toHaveLength(0);
    expect(r.protected_).toHaveLength(1);
    expect(r.skipped).toHaveLength(0);
  });

  test('en mode force (safeOnly=false), les cellules en conflit sont directement corrigées, pas seulement signalées', () => {
    const existingMap = new Map([['2026-09-06', 'P']]);
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-06', toStr: '2026-09-06',
      existingMap, safeOnly: false, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.conflicts).toHaveLength(0); // pas de détection nécessaire : déjà réécrit
    expect(r.toCreate).toEqual([{ day: '2026-09-06', status: '', reason: 'Repos fixe', old_value: 'P' }]);
  });

  test('reproduction fidèle du cas Folkestone Opéra : tous les dimanches sept.–déc. 2026 marqués \'P\' remontent en conflit', () => {
    const sundays = dateStrRange('2026-09-01', '2026-12-31').filter(ds => weekdayOf(ds) === 0);
    const existingMap = new Map(sundays.map(ds => [ds, 'P']));
    const r = planEmployeeAutoFill({
      emp: { id: 'ali' }, pattern: aliPattern,
      fromStr: '2026-09-01', toStr: '2026-12-31',
      existingMap, safeOnly: true, protectAbs: true, protectedCodes: PROTECTED_CODES,
    });
    expect(r.conflicts.map(c => c.date).sort()).toEqual(sundays.sort());
    expect(r.toCreate.some(c => sundays.includes(c.day))).toBe(false);
  });
});

// Sanity check that DOW_NAMES stays aligned with fixed_days_off indices (0=Dim..6=Sam)
// used by the employee fiche checkboxes, so a future edit doesn't silently desync them.
test('convention des indices de jour (0=Dim…6=Sam) alignée entre weekdayOf() et l\'UI', () => {
  expect(DOW_NAMES[weekdayOf('2026-09-06')]).toBe('Dim');
  expect(DOW_NAMES[weekdayOf('2026-09-07')]).toBe('Lun');
  expect(DOW_NAMES[weekdayOf('2026-09-12')]).toBe('Sam');
});
