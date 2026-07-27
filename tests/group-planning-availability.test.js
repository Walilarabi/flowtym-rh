'use strict';
const {
  computeUnavailReason,
  resolveEmployeeName,
  slotsOverlap,
  planConfirmationOutcome,
} = require('./lib/groupPlanningAvailability');

const CMAP = {
  P:    { label: 'Présent',          cat: 'worked' },
  PE:   { label: 'Présence Extra',   cat: 'worked' },
  MAD:  { label: 'Mise à dispo',     cat: 'ext'    },
  CP:   { label: 'Congé payé',       cat: 'paid'   },
  MAL:  { label: 'Maladie',          cat: 'abs'    },
  ABS:  { label: 'Abs. injust.',     cat: 'abs'    },
  MAT:  { label: 'Mat./Pat.',        cat: 'abs'    },
  PAT:  { label: 'Paternité',        cat: 'abs'    },
  RTT:  { label: 'RTT',              cat: 'paid'   },
  FORM: { label: 'Formation',        cat: 'abs'    },
  REC:  { label: 'Récupération',     cat: 'abs'    },
  AE:   { label: 'Except.',          cat: 'abs'    },
  CSS:  { label: 'Sans solde',       cat: 'abs'    },
  F:    { label: 'Férié',            cat: 'holiday' },
};

// ── computeUnavailReason ───────────────────────────────────────────────────

describe('Planning Groupe · gpUnavailReason — règles métier (Maladie/Absence/Mat/Pat bloquent, autres affectables)', () => {
  const eid = '5848d73d-ddba-4146-870f-219e06d3e4cc';
  const nu = (status, reserved) => computeUnavailReason({
    employeeId: eid, collabCell: { status }, cmap: CMAP, reserved: reserved || {},
  });

  // ── Bloqués : congés médicaux / absences ──────────────────────────────────
  test('maladie → « maladie »',                 () => expect(nu('MAL')).toBe('maladie'));
  test('absence injustifiée → « absence »',     () => expect(nu('ABS')).toBe('absence'));
  test('maternité → « maternité »',             () => expect(nu('MAT')).toBe('maternité'));
  test('paternité → « paternité »',             () => expect(nu('PAT')).toBe('paternité'));

  // ── Bloqué indépendamment : mission déjà programmée ───────────────────────
  test('mission déjà programmée (P + réservé)', () => expect(
    nu('P', { [eid]: { id: 'prop-42' } })
  ).toBe('mission déjà programmée'));

  // ── Affectables : présents, repos, CP, mobilisables ───────────────────────
  test('présent (P) → affectable',              () => expect(nu('P')).toBe(''));
  test('présent extra (PE) → affectable',       () => expect(nu('PE')).toBe(''));
  test('mise à disposition (MAD) → affectable', () => expect(nu('MAD')).toBe(''));
  test('repos (status vide) → affectable',      () => expect(nu('')).toBe(''));
  test('CP → affectable (peut faire un extra)', () => expect(nu('CP')).toBe(''));
  test('RTT → affectable (mobilisable)',        () => expect(nu('RTT')).toBe(''));
  test('récupération (REC) → affectable',       () => expect(nu('REC')).toBe(''));
  test('formation (FORM) → affectable',         () => expect(nu('FORM')).toBe(''));
  test('congé exceptionnel (AE) → affectable',  () => expect(nu('AE')).toBe(''));
  test('congé sans solde (CSS) → affectable',   () => expect(nu('CSS')).toBe(''));
  test('férié (F) → affectable',                () => expect(nu('F')).toBe(''));

  test('collaborateur sans cellule → affectable (silencieusement)', () => {
    expect(computeUnavailReason({
      employeeId: eid, collabCell: null, cmap: CMAP, reserved: {},
    })).toBe('');
  });

  test('statut inconnu → affectable (permissif, pas de blocage arbitraire)', () => {
    expect(computeUnavailReason({
      employeeId: eid, collabCell: { status: 'INCONNU' }, cmap: CMAP, reserved: {},
    })).toBe('');
  });
});

// ── resolveEmployeeName — aucun UUID exposé ─────────────────────────────────

describe('Planning Groupe · resolveEmployeeName — le nom vient toujours des données réelles, jamais de l\'UUID', () => {
  const eid = '5848d73d-ddba-4146-870f-219e06d3e4cc';

  test('trouve prénom + nom dans le cache staff', () => {
    expect(resolveEmployeeName({
      employeeId: eid,
      staffCache: [{ id: eid, first_name: 'Fatma', last_name: 'TLIDJANE' }],
      extraCache: null, renderedCollab: null,
    })).toBe('Fatma TLIDJANE');
  });

  test('fallback : cache extras', () => {
    const extra = new Map([[eid, { first_name: 'Ghani', last_name: 'AMRANI' }]]);
    expect(resolveEmployeeName({
      employeeId: eid, staffCache: [], extraCache: extra, renderedCollab: null,
    })).toBe('Ghani AMRANI');
  });

  test('fallback : nom présent dans le rendu Planning Groupe', () => {
    expect(resolveEmployeeName({
      employeeId: eid, staffCache: [], extraCache: null,
      renderedCollab: { name: 'Émilie CROITE' },
    })).toBe('Émilie CROITE');
  });

  test('aucune source → chaîne vide (jamais l\'UUID)', () => {
    const name = resolveEmployeeName({
      employeeId: eid, staffCache: [], extraCache: null, renderedCollab: null,
    });
    expect(name).toBe('');
    expect(name).not.toContain(eid);
  });

  test('collaborateur avec prénom seul', () => {
    expect(resolveEmployeeName({
      employeeId: eid,
      staffCache: [{ id: eid, first_name: 'Wassila', last_name: '' }],
    })).toBe('Wassila');
  });
});

// ── slotsOverlap — chevauchement horaire ────────────────────────────────────

describe('Planning Groupe · slotsOverlap — mission existante bloque un chevauchement', () => {
  test('journée complète vs journée complète le même jour → conflit', () => {
    expect(slotsOverlap(
      [{ date: '2026-07-25' }],
      [{ date: '2026-07-25' }],
    )).toBe(true);
  });

  test('créneaux du même jour qui se chevauchent → conflit', () => {
    expect(slotsOverlap(
      [{ date: '2026-07-25', start: '09:00', end: '13:00' }],
      [{ date: '2026-07-25', start: '12:00', end: '17:00' }],
    )).toBe(true);
  });

  test('créneaux disjoints le même jour → pas de conflit', () => {
    expect(slotsOverlap(
      [{ date: '2026-07-25', start: '09:00', end: '12:00' }],
      [{ date: '2026-07-25', start: '13:00', end: '17:00' }],
    )).toBe(false);
  });

  test('jours différents → pas de conflit', () => {
    expect(slotsOverlap(
      [{ date: '2026-07-25' }],
      [{ date: '2026-07-26' }],
    )).toBe(false);
  });

  test('journée complète chevauche un créneau du même jour', () => {
    expect(slotsOverlap(
      [{ date: '2026-07-25' }],
      [{ date: '2026-07-25', start: '14:00', end: '18:00' }],
    )).toBe(true);
  });
});

// ── planConfirmationOutcome — décision de la confirmation ───────────────────

describe('Planning Groupe · planConfirmationOutcome — confirmation directe vs circuit d\'approbation', () => {
  test('décision bloquée → refus (re-vérification serveur)', () => {
    expect(planConfirmationOutcome({ decision: 'blocked', canApply: true }))
      .toEqual({ status: 'blocked', reason: 'contraintes bloquantes' });
  });

  test('décision autorisée + droit apply → écriture directe', () => {
    expect(planConfirmationOutcome({ decision: 'allowed', canApply: true }))
      .toEqual({ status: 'applied' });
  });

  test('décision autorisée sans droit apply → repli sur circuit d\'approbation', () => {
    expect(planConfirmationOutcome({ decision: 'allowed', canApply: false }))
      .toEqual({ status: 'submitted' });
  });

  test('décision avec avertissements + droit apply → écriture directe', () => {
    expect(planConfirmationOutcome({ decision: 'allowed_with_warnings', canApply: true }))
      .toEqual({ status: 'applied' });
  });
});
