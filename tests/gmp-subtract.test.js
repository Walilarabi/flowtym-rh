'use strict';
const { subtract, totalMinutes } = require('./lib/gmpSubtract');

// Notation : H*60 pour rendre lisible (08:00 = 480, 12:00 = 720, etc.)
const H = h => h * 60;

// Aide : convertit un shift d'origine 08:00-18:00 en {os, oe}.
const shift = (h1, h2) => ({ os: H(h1), oe: H(h2) });
// Aide : convertit une plage en cut {s, e}.
const cut = (h1, h2) => ({ s: H(h1), e: H(h2) });

describe('_gmp_subtract — spec SQL (source de vérité : db/reconstruct/30_functions.sql:25)', () => {

  // Cas 1 — mission 08-12 sur shift 08-18 : garde 12-18.
  test('mission début de journée (08-12) → reliquat 12-18', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(8, 12)]);
    expect(out).toEqual([{ s: H(12), e: H(18) }]);
    expect(totalMinutes(out)).toBe(H(6));
  });

  // Cas 2 — mission 14-18 sur shift 08-18 : garde 08-14.
  test('mission fin de journée (14-18) → reliquat 08-14', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(14, 18)]);
    expect(out).toEqual([{ s: H(8), e: H(14) }]);
    expect(totalMinutes(out)).toBe(H(6));
  });

  // Cas 3 — mission 10-16 au milieu du shift 08-18 : garde 08-10 et 16-18.
  test('mission au milieu (10-16) → deux segments 08-10 et 16-18', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(10, 16)]);
    expect(out).toEqual([
      { s: H(8),  e: H(10) },
      { s: H(16), e: H(18) },
    ]);
    expect(totalMinutes(out)).toBe(H(4));
  });

  // Cas 4 — mission journée complète : rien ne subsiste.
  test('mission journée complète (00-24) → aucun reliquat', () => {
    const out = subtract(0, 1440, [cut(0, 24)]);
    expect(out).toEqual([]);
    expect(totalMinutes(out)).toBe(0);
  });

  // Cas 5 — plusieurs coupures disjointes sur la même journée.
  test('deux missions disjointes (09-11 et 14-16) sur shift 08-18', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(9, 11), cut(14, 16)]);
    expect(out).toEqual([
      { s: H(8),  e: H(9)  },
      { s: H(11), e: H(14) },
      { s: H(16), e: H(18) },
    ]);
    expect(totalMinutes(out)).toBe(H(6));
  });

  // Cas 6 — coupures adjacentes (sans chevauchement) : bordure exacte.
  test('deux missions adjacentes (10-12 et 12-14) — bordure exacte', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(10, 12), cut(12, 14)]);
    // 08-10 + 14-18 (l'intervalle 12-12 n'existe pas, int4range half-open)
    expect(out).toEqual([
      { s: H(8),  e: H(10) },
      { s: H(14), e: H(18) },
    ]);
    expect(totalMinutes(out)).toBe(H(6));
  });

  // Cas 7 — coupures qui se chevauchent partiellement.
  test('deux missions chevauchantes (10-14 et 12-16) — recalcul en 2 passes', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(10, 14), cut(12, 16)]);
    // Après 10-14 : [08-10, 14-18]
    // Après 12-16 sur ces deux segments :
    //   - [08-10] ne chevauche pas 12-16 → conservé
    //   - [14-18] chevauche 12-16 → garde [16-18]
    expect(out).toEqual([
      { s: H(8),  e: H(10) },
      { s: H(16), e: H(18) },
    ]);
    expect(totalMinutes(out)).toBe(H(4));
  });

  // Cas 8 — coupure entièrement en dehors du shift.
  test('coupure hors du shift (20-22) → shift intact', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(20, 22)]);
    expect(out).toEqual([{ s: H(8), e: H(18) }]);
    expect(totalMinutes(out)).toBe(H(10));
  });

  // Cas 9 — coupure débordante à gauche.
  test('coupure débordant à gauche (06-10) → reliquat 10-18', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(6, 10)]);
    expect(out).toEqual([{ s: H(10), e: H(18) }]);
    expect(totalMinutes(out)).toBe(H(8));
  });

  // Cas 10 — coupure débordante à droite.
  test('coupure débordant à droite (16-20) → reliquat 08-16', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(16, 20)]);
    expect(out).toEqual([{ s: H(8), e: H(16) }]);
    expect(totalMinutes(out)).toBe(H(8));
  });

  // Cas 11 — coupure identique au shift : aucun reliquat.
  test('coupure identique au shift (08-18) → aucun reliquat', () => {
    const s = shift(8, 18);
    const out = subtract(s.os, s.oe, [cut(8, 18)]);
    expect(out).toEqual([]);
    expect(totalMinutes(out)).toBe(0);
  });

  // Invariant global — aucune heure travaillée n'est perdue ni créée.
  test('somme des reliquats + somme des coupures actives = durée du shift, pour tout cas', () => {
    const s = shift(8, 18);
    const cases = [
      [cut(8, 12)],
      [cut(14, 18)],
      [cut(10, 16)],
      [cut(9, 11), cut(14, 16)],
      [cut(10, 12), cut(12, 14)],
      [cut(6, 10)],
      [cut(16, 20)],
    ];
    for (const cuts of cases) {
      const kept = subtract(s.os, s.oe, cuts);
      // Calcul de la portion des coupures qui est INTERNE au shift.
      const cutsInside = cuts.map(c => ({
        s: Math.max(c.s, s.os), e: Math.min(c.e, s.oe),
      })).filter(c => c.e > c.s);
      // Union des cutsInside (éventuellement chevauchants) — normalisation.
      const norm = mergeIntervals(cutsInside);
      const cutMinutes = norm.reduce((a, c) => a + (c.e - c.s), 0);
      const keptMinutes = totalMinutes(kept);
      expect(keptMinutes + cutMinutes).toBe(s.oe - s.os);
    }
  });
});

// Helpers d'assertion (union d'intervalles).
function mergeIntervals(arr) {
  if (!arr.length) return [];
  const sorted = arr.slice().sort((a, b) => a.s - b.s);
  const out = [sorted[0]];
  for (let i = 1; i < sorted.length; i++) {
    const last = out[out.length - 1];
    const cur = sorted[i];
    if (cur.s <= last.e) last.e = Math.max(last.e, cur.e);
    else out.push(cur);
  }
  return out;
}
