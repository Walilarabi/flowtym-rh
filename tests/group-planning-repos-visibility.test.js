'use strict';
const { statusBadge, nameClass, dotClass } = require('./lib/groupPlanningBadges');
const { computeUnavailReason } = require('./lib/groupPlanningAvailability');
const fs = require('fs');
const path = require('path');

const CMAP = {
  P:    { label: 'Présent',        cat: 'worked' },
  PE:   { label: 'Présence Extra', cat: 'worked' },
  MAD:  { label: 'Mise à dispo',   cat: 'ext'    },
  CP:   { label: 'Congé payé',     cat: 'paid'   },
  MAL:  { label: 'Maladie',        cat: 'abs'    },
  ABS:  { label: 'Abs. injust.',   cat: 'abs'    },
  MAT:  { label: 'Mat./Pat.',      cat: 'abs'    },
  PAT:  { label: 'Paternité',      cat: 'abs'    },
  RTT:  { label: 'RTT',            cat: 'paid'   },
};
const isWorking = code => !!(code && CMAP[code] && CMAP[code].cat === 'worked');

// ── Badge « Repos » explicite ────────────────────────────────────────────────

describe('Planning Groupe · statusBadge — Repos affiché explicitement', () => {
  test('statut vide (Repos), non extra → badge { rest, "Repos" }', () => {
    expect(statusBadge('', false)).toEqual({ cls: 'rest', label: 'Repos' });
  });

  test('extra prime sur le statut vide', () => {
    expect(statusBadge('', true)).toEqual({ cls: 'extra', label: 'Extra' });
  });

  test('CP → badge inchangé', () => {
    expect(statusBadge('CP', false)).toEqual({ cls: 'cp', label: 'CP' });
  });

  test('Maladie → badge inchangé', () => {
    expect(statusBadge('MAL', false)).toEqual({ cls: 'mal', label: 'Maladie' });
  });

  test('Présent (P) → aucun badge', () => {
    expect(statusBadge('P', false)).toBeNull();
  });
});

// ── Nom grisé pour tout statut non travaillé (y compris Repos) ─────────────

describe('Planning Groupe · nameClass — Repos grisé comme CP/Maladie', () => {
  test('Repos (non travaillé) → nm mut', () => {
    expect(nameClass(isWorking(''))).toBe('nm mut');
  });
  test('CP (non travaillé) → nm mut', () => {
    expect(nameClass(isWorking('CP'))).toBe('nm mut');
  });
  test('Maladie (non travaillé) → nm mut', () => {
    expect(nameClass(isWorking('MAL'))).toBe('nm mut');
  });
  test('Présent (travaillé) → nm (noir)', () => {
    expect(nameClass(isWorking('P'))).toBe('nm');
  });
  test('Présence Extra (travaillé) → nm (noir)', () => {
    expect(nameClass(isWorking('PE'))).toBe('nm');
  });
});

// ── Couleur du voyant ─────────────────────────────────────────────────────

describe('Planning Groupe · dotClass — voyant Repos gris, affectable', () => {
  test('Repos → gris (q)',    () => expect(dotClass('', isWorking, CMAP)).toBe('q'));
  test('Présent → vert (g)',  () => expect(dotClass('P', isWorking, CMAP)).toBe('g'));
  test('CP → rouge (r)',      () => expect(dotClass('CP', isWorking, CMAP)).toBe('r'));
  test('Maladie → rouge (r)', () => expect(dotClass('MAL', isWorking, CMAP)).toBe('r'));
});

// ── Règle métier complète : Repos et CP restent affectables ─────────────────

describe('Planning Groupe · récapitulatif règles métier (tableau utilisateur)', () => {
  const eid = 'e1';
  const nu = status => computeUnavailReason({ employeeId: eid, collabCell: { status }, cmap: CMAP, reserved: {} });

  test('Présent      → grisé=non, affectable=oui', () => {
    expect(isWorking('P')).toBe(true);
    expect(nu('P')).toBe('');
  });
  test('Repos        → grisé=oui, affectable=oui', () => {
    expect(isWorking('')).toBe(false);
    expect(nu('')).toBe('');
  });
  test('CP           → grisé=oui, affectable=oui', () => {
    expect(isWorking('CP')).toBe(false);
    expect(nu('CP')).toBe('');
  });
  test('Maladie      → grisé=oui, affectable=non', () => {
    expect(isWorking('MAL')).toBe(false);
    expect(nu('MAL')).not.toBe('');
  });
  test('Absence      → grisé=oui, affectable=non', () => {
    expect(isWorking('ABS')).toBe(false);
    expect(nu('ABS')).not.toBe('');
  });
});

// ── Contrat SQL — migration 62 ────────────────────────────────────────────

describe('Planning Groupe · contrat SQL — group_planning inclut les employés en Repos', () => {
  const migration = fs.readFileSync(
    path.join(__dirname, '..', 'sql', '62_group_planning_repos_visibility.sql'),
    'utf8'
  );

  test('migration réécrit group_planning (CREATE OR REPLACE)', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\.group_planning\(p_service text, p_from date, p_to date\)/);
  });

  test('la branche titulaires part de employees, pas de staff_planning', () => {
    // Le FROM doit être `employees e`, avec LEFT JOIN staff_planning (pas
    // INNER JOIN) — c'est la cause racine du bug corrigé.
    expect(migration).toMatch(/FROM employees e\s*\n\s*CROSS JOIN generate_series/);
    expect(migration).toMatch(/LEFT JOIN staff_planning sp ON sp\.employee_id=e\.id/);
  });

  test('absence de ligne staff_planning → status coalesce vers chaîne vide (Repos)', () => {
    expect(migration).toMatch(/coalesce\(sp\.status,''\)/);
  });

  test('filtre les employés sortis (parti), conserve les actifs et en pause', () => {
    expect(migration).toMatch(/<> 'parti'/);
  });

  test('couvre chaque jour de la période demandée (generate_series p_from..p_to)', () => {
    expect(migration).toMatch(/generate_series\(p_from, p_to, interval '1 day'\)/);
  });

  test('la branche extras reste inchangée (INNER JOIN staff_planning conservé)', () => {
    expect(migration).toMatch(/JOIN staff_planning sp ON sp\.employee_id=act\.employee_id/);
  });
});

// ── Contrat frontend — payload limité au jour affiché ───────────────────────

describe('Planning Groupe · frontend ne fetch que le jour affiché (pas le mois)', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  test('gpLoadAndRender interroge un seul jour (from=to=gpDay), pas le mois complet', () => {
    const idx = html.indexOf('async function gpLoadAndRender');
    expect(idx).toBeGreaterThan(-1);
    const next = html.indexOf('\nasync function ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 1200);
    expect(body).toMatch(/const from=new Date\(gpDay\.getFullYear\(\),gpDay\.getMonth\(\),gpDay\.getDate\(\)\), to=from;/);
    // Régression : ne doit plus utiliser le 1er jour / dernier jour du mois.
    expect(body).not.toMatch(/gpDay\.getMonth\(\),1\)/);
    expect(body).not.toMatch(/getMonth\(\)\+1,0\)/);
  });

  test('gpStatusBadge affiche « Repos » pour un statut vide non-extra', () => {
    expect(html).toMatch(/if\(!code\) return \{cls:'rest', label:'Repos'\}/);
  });

  test('gpBuildCollab grise le nom pour tout statut non travaillé (pas seulement abs/paid)', () => {
    const idx = html.indexOf('function gpBuildCollab');
    const next = html.indexOf('\nfunction ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 1500);
    expect(body).toMatch(/const nameCls = isWork \? 'nm' : 'nm mut';/);
  });
});
