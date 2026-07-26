'use strict';
const {
  canDrag,
  classifyDrop,
  buildDragPayload,
  autoScrollAmount,
} = require('./lib/groupPlanningDnd');

// ── canDrag ─────────────────────────────────────────────────────────────────

describe('Planning Groupe · canDrag — la source doit être mobilisable', () => {
  test('collab disponible → draggable', () => {
    expect(canDrag({ unavailReason: '' })).toEqual({ draggable: true });
  });

  test('collab en CP → non draggable, raison remontée', () => {
    expect(canDrag({ unavailReason: 'congé payé' })).toEqual({
      draggable: false, reason: 'congé payé',
    });
  });

  test('collab en maladie → non draggable', () => {
    expect(canDrag({ unavailReason: 'maladie' }).draggable).toBe(false);
  });

  test('collab avec mission déjà programmée → non draggable', () => {
    expect(canDrag({ unavailReason: 'mission déjà programmée' }).draggable).toBe(false);
  });

  test('hôtel d\'origine hors périmètre → non draggable', () => {
    expect(canDrag({
      unavailReason: '',
      allowedHotelIds: new Set(['H1', 'H2']),
      originHotelId: 'H99',
    })).toEqual({ draggable: false, reason: 'hôtel d\'origine hors périmètre' });
  });
});

// ── classifyDrop ────────────────────────────────────────────────────────────

describe('Planning Groupe · classifyDrop — validité des cellules de dépôt', () => {
  const ORIGIN = { hotelId: 'FO', service: 'Réception' };

  test('dépôt sur la cellule d\'origine → level=origin', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'FO', service: 'Réception' },
    })).toEqual({ level: 'origin', reason: 'même hôtel et même service' });
  });

  test('dépôt sur hôtel non autorisé → invalid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'WO', service: 'Réception' },
      allowedHotelIds: new Set(['FO', 'VO']),
    })).toEqual({ level: 'invalid', reason: 'hôtel non autorisé' });
  });

  test('service non maîtrisé (compétences déclarées) → invalid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Cuisine' },
      employeeCompetences: ['Réception', 'Petit-déjeuner'],
    })).toEqual({ level: 'invalid', reason: 'service incompatible' });
  });

  test('service maîtrisé → valid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      employeeCompetences: ['Réception', 'Petit-déjeuner'],
      coverageLevel: 'sous_effectif',
    })).toEqual({ level: 'valid' });
  });

  test('compétences non renseignées → pas de blocage arbitraire (permissif)', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Étage' },
      employeeCompetences: undefined,
      coverageLevel: 'sous_effectif',
    })).toEqual({ level: 'valid' });
  });

  test('conflit horaire manifeste (même jour, autre hôtel) → invalid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      sameDayOtherHotel: true,
    })).toEqual({ level: 'invalid', reason: 'chevauchement horaire' });
  });

  test('chevauchement de créneaux détecté → invalid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      plannedSlots: [{ date: '2026-07-25', start: '09:00', end: '13:00' }],
      proposedSlot:  { date: '2026-07-25', start: '12:00', end: '17:00' },
    }).level).toBe('invalid');
  });

  test('destination en sous-effectif → valid (dépôt franchement bénéfique)', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      coverageLevel: 'sous_effectif',
    })).toEqual({ level: 'valid' });
  });

  test('destination limite → valid', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      coverageLevel: 'limite',
    })).toEqual({ level: 'valid' });
  });

  test('destination sans besoin configuré → warning', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      coverageLevel: 'non_configure',
    })).toEqual({ level: 'warning', reason: 'besoin non configuré' });
  });

  test('destination en sureffectif → warning', () => {
    expect(classifyDrop({
      origin: ORIGIN, target: { hotelId: 'VO', service: 'Réception' },
      coverageLevel: 'sureffectif',
    })).toEqual({ level: 'warning', reason: 'destination déjà en sureffectif' });
  });
});

// ── buildDragPayload ────────────────────────────────────────────────────────

describe('Planning Groupe · buildDragPayload — pas de fuite d\'UUID à l\'écran', () => {
  test('payload contient uniquement des champs internes', () => {
    const p = buildDragPayload({
      employeeId: '5848d73d-ddba-4146-870f-219e06d3e4cc',
      originHotelId: 'FO', originService: 'Réception', dayISO: '2026-07-25',
    });
    expect(p).toEqual({
      v: 1,
      employeeId: '5848d73d-ddba-4146-870f-219e06d3e4cc',
      originHotelId: 'FO', originService: 'Réception', day: '2026-07-25',
    });
  });

  test('champs manquants → chaînes vides (jamais undefined)', () => {
    const p = buildDragPayload({});
    expect(p.employeeId).toBe('');
    expect(p.originHotelId).toBe('');
    expect(p.originService).toBe('');
    expect(p.day).toBe('');
  });
});

// ── autoScrollAmount ────────────────────────────────────────────────────────

describe('Planning Groupe · autoScrollAmount — scroll horizontal fluide en bord de zone', () => {
  const boundsLeft = 100, boundsRight = 900, edge = 60;

  test('curseur centré → aucun scroll', () => {
    expect(autoScrollAmount({ clientX: 500, boundsLeft, boundsRight, edge })).toBe(0);
  });

  test('curseur près du bord gauche → scroll négatif', () => {
    expect(autoScrollAmount({ clientX: 110, boundsLeft, boundsRight, edge })).toBeLessThan(0);
  });

  test('curseur près du bord droit → scroll positif', () => {
    expect(autoScrollAmount({ clientX: 890, boundsLeft, boundsRight, edge })).toBeGreaterThan(0);
  });

  test('curseur pile sur le bord gauche → scroll maximal négatif', () => {
    const v = autoScrollAmount({ clientX: 100, boundsLeft, boundsRight, edge, maxSpeed: 24 });
    expect(v).toBe(-24);
  });

  test('curseur pile sur le bord droit → scroll maximal positif', () => {
    const v = autoScrollAmount({ clientX: 900, boundsLeft, boundsRight, edge, maxSpeed: 24 });
    expect(v).toBe(24);
  });
});
