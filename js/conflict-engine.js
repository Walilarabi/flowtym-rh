/**
 * Flowtym — Moteur de conflits & concurrence des propositions de renfort.
 * =========================================================================
 * PUR, INDÉPENDANT DE L'INTERFACE. Déterministe. Aucune écriture.
 * Détermine si une proposition est toujours applicable :
 *   - obsolescence (données changées depuis la simulation) par catégorie ;
 *   - expiration (délai dépassé) ;
 *   - conflits entre propositions (même collaborateur, créneaux qui se chevauchent) ;
 *   - priorité / revalidation / annulation entre propositions concurrentes ;
 *   - réservation d'un collaborateur par une proposition programmée/approuvée.
 *
 * La récupération des propositions concurrentes et des données courantes est
 * faite par l'appelant (RPC) ; ce moteur ne fait que raisonner.
 *
 * Exposé en CommonJS + global window.FlowtymConflictEngine.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FlowtymConflictEngine = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // Statuts "ouverts" (une proposition ouverte peut encore aboutir).
  const OPEN = ['draft', 'pending_review', 'approved', 'scheduled'];
  // Rang de priorité : plus avancé = plus prioritaire.
  const RANK = { applied: 6, scheduled: 5, approved: 4, pending_review: 3, draft: 2, rejected: 0, cancelled: 0, expired: 0 };
  // Catégories de données dont un changement rend la simulation obsolète.
  const CATEGORIES = ['planning', 'requirements', 'absences', 'skills', 'hours', 'rhRules', 'travel', 'workflow'];

  function hash(x) { const s = JSON.stringify(x === undefined ? null : x); let h = 5381; for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0; return h.toString(16); }

  // Empreintes par catégorie à partir d'un contexte "raw" normalisé.
  function categoryHashes(raw) {
    raw = raw || {};
    return {
      planning:     hash(raw.cells),
      requirements: hash(raw.requirements),
      absences:     hash(raw.absences || (raw.employee && raw.employee.availability) || null),
      skills:       hash(raw.employee && raw.employee.skills),
      hours:        hash(raw.employee && raw.employee.plannedThisWeek),
      rhRules:      hash(raw.rhRules),
      travel:       hash(raw.travelTimes),
      workflow:     hash(raw.workflow),
    };
  }

  // Catégories ayant changé entre deux jeux d'empreintes.
  function diffCategories(oldH, newH) {
    oldH = oldH || {}; newH = newH || {};
    return CATEGORIES.filter(c => (oldH[c] !== undefined || newH[c] !== undefined) && oldH[c] !== newH[c]);
  }

  // ── Chevauchement de créneaux ────────────────────────────────────────────────
  function toMin(t) { if (t == null) return null; const p = String(t).split(':'); return (+p[0]) * 60 + (+(p[1] || 0)); }
  function slotWindow(s) { const st = toMin(s.start), en = toMin(s.end); return { date: s.date, s: st == null ? 0 : st, e: en == null ? 1440 : en }; }
  function slotsOverlap(slotsA, slotsB) {
    for (const a0 of (slotsA || [])) { const a = slotWindow(a0);
      for (const b0 of (slotsB || [])) { const b = slotWindow(b0);
        if (a.date === b.date && a.s < b.e && b.s < a.e) return true;
      } }
    return false;
  }

  // ── Conflits entre propositions (même collaborateur, créneaux chevauchants) ──
  // target: {id, employee_id, slots, status, created_at, score}
  // others: liste d'autres propositions du même collaborateur.
  function detectConflicts(target, others) {
    const open = (others || []).filter(o => o.id !== target.id && o.employee_id === target.employee_id && OPEN.indexOf(o.status) !== -1 && slotsOverlap(target.slots, o.slots));
    return open;
  }

  // Priorité / revalidation / annulation parmi un ensemble de propositions
  // concurrentes (toutes ouvertes, même collaborateur, créneaux chevauchants).
  function resolvePriority(proposals) {
    const list = (proposals || []).slice();
    const cmp = (a, b) => (RANK[b.status] || 0) - (RANK[a.status] || 0)
      || (String(a.created_at || '')).localeCompare(String(b.created_at || ''))
      || (b.score || 0) - (a.score || 0);
    list.sort(cmp);
    const winner = list[0];
    return {
      priority: winner ? winner.id : null,
      decisions: list.map((p, i) => ({
        id: p.id,
        action: i === 0 ? 'priority' : (['approved', 'scheduled'].indexOf(p.status) !== -1 ? 'revalidate' : 'cancel'),
        reason: i === 0 ? 'Proposition la plus avancée / la plus ancienne' : (['approved', 'scheduled'].indexOf(p.status) !== -1 ? 'Conflit avec une proposition prioritaire — à revalider' : 'Redondante avec la proposition prioritaire — à annuler'),
      })),
    };
  }

  // ── Applicabilité / fraîcheur d'une proposition ──────────────────────────────
  // opts: { storedHashes, currentHashes, expiresAt, scheduledAt, now, decision, conflicts }
  function assess(opts) {
    opts = opts || {};
    const now = opts.now || null;
    const reasons = [];
    let status = 'valid';
    const changed = diffCategories(opts.storedHashes, opts.currentHashes);
    if (opts.expiresAt && now && new Date(opts.expiresAt) < new Date(now)) { status = 'expired'; reasons.push('Délai dépassé (expiration).'); }
    else if (opts.conflicts && opts.conflicts.length) { status = 'conflict'; reasons.push(opts.conflicts.length + ' proposition(s) concurrente(s) sur le même créneau.'); }
    else if (changed.length) { status = 'to_refresh'; reasons.push('Données modifiées : ' + changed.join(', ') + '.'); }
    const applicable = status === 'valid' && opts.decision !== 'blocked';
    return { status: status, applicable: applicable, changedCategories: changed, reasons: reasons };
  }

  // Échéance proche (pour notification deadline_near).
  function deadlineNear(target, now, withinHours) {
    if (!target || !now) return false;
    const w = (withinHours == null ? 24 : withinHours) * 3600000;
    const ref = target === undefined ? null : target;
    return ref != null && (new Date(ref) - new Date(now)) > 0 && (new Date(ref) - new Date(now)) <= w;
  }

  return {
    OPEN, RANK, CATEGORIES,
    hash, categoryHashes, diffCategories,
    slotsOverlap, detectConflicts, resolvePriority, assess, deadlineNear,
  };
});
