/**
 * Réplique JS de la fonction PostgreSQL public._gmp_subtract(p_os, p_oe, p_cuts).
 * Source SQL : db/reconstruct/30_functions.sql:25-42.
 *
 * L'objectif est de conserver, hors moteur SQL, une implémentation de
 * référence directement testable :
 *   - garantit qu'aucune heure travaillée n'est perdue ni créée ;
 *   - documente précisément les invariants attendus ;
 *   - sert de contrat exécutable pour toute évolution future de la RPC.
 *
 * Un intervalle [a,b) est représenté par {s:a, e:b}. Les entiers sont les
 * minutes depuis 00:00 (0..1440). L'algorithme SQL utilise int4range qui est
 * half-open : [lower, upper). On respecte cette convention.
 */

function subtract(os, oe, cuts) {
  // Invariant d'entrée : os < oe, chaque cut c a c.s < c.e (garanti par
  // check(seg_end_min > seg_start_min) en base).
  let segs = [{ s: os, e: oe }];
  for (const c of cuts || []) {
    const out = [];
    for (const s of segs) {
      // "s && c" en SQL = intervalles se chevauchent.
      const overlap = s.s < c.e && c.s < s.e;
      if (!overlap) {
        out.push(s);
      } else {
        if (s.s < c.s) out.push({ s: s.s, e: c.s });
        if (s.e > c.e) out.push({ s: c.e, e: s.e });
      }
    }
    segs = out;
  }
  return segs;
}

function totalMinutes(segs) {
  return (segs || []).reduce((a, s) => a + (s.e - s.s), 0);
}

module.exports = { subtract, totalMinutes };
