/**
 * Flowtym — Moteur de simulation de déplacement inter-hôtels (v2)
 * =========================================================================
 * PUR, INDÉPENDANT DE L'INTERFACE. Aucune dépendance DOM, réseau, ni écriture.
 * Aucune API cartographique : le temps de trajet est FOURNI dans le contexte
 * (moteur déterministe). Réutilisable par : Drag & Drop, suggestions IA,
 * simulations RH, propositions automatiques de renfort.
 *
 * Le moteur NE DÉPLACE JAMAIS un collaborateur. Il calcule les conséquences
 * d'un déplacement proposé et renvoie une DÉCISION EXPLICABLE.
 *
 * simulateMove({ move, context, config }) -> SimulationResult (voir docs/simulation-engine.md)
 *
 * Exposé en CommonJS (module.exports) ET en global navigateur (window.FlowtymMoveSim).
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FlowtymMoveSim = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // ── Défauts (aucune valeur métier codée en dur dans la logique) ──────────────
  const DEFAULTS = {
    coverage: { redBelow: 1.0, limiteUpTo: 1.0, conformeUpTo: 1.3 },
    regulatory: { maxWeeklyHours: 48, maxConsecutiveDays: 6, shiftHours: 7 },
    time: {
      travelSafetyMarginMin: 10,     // marge de sécurité sur le trajet
      minBreakMin: 20,               // pause minimale entre 2 vacations le même jour
      maxDailyAmplitudeHours: 13,    // amplitude journalière maximale
      minRestBetweenDaysHours: 11,   // repos minimal entre deux journées
    },
    workingStatuses: ['P', 'PE'],
    blockOnMissingRequiredSkill: true,   // compétence OBLIGATOIRE manquante = blocage
    blockOnUnavailable: true,
    score: {
      enabled: true,
      // Pondérations documentées et configurables. Le score n'écrase JAMAIS un blocage.
      weights: { base: 50, destImproved: 20, destFullyCovered: 15, originSafe: 20, groupReduced: 15, warningPenalty: 8 },
    },
  };

  function mergeConfig(cfg) {
    cfg = cfg || {};
    return {
      coverage: Object.assign({}, DEFAULTS.coverage, cfg.coverage),
      regulatory: Object.assign({}, DEFAULTS.regulatory, cfg.regulatory),
      time: Object.assign({}, DEFAULTS.time, cfg.time),
      workingStatuses: cfg.workingStatuses || DEFAULTS.workingStatuses,
      blockOnMissingRequiredSkill: cfg.blockOnMissingRequiredSkill != null ? !!cfg.blockOnMissingRequiredSkill : DEFAULTS.blockOnMissingRequiredSkill,
      blockOnUnavailable: cfg.blockOnUnavailable != null ? !!cfg.blockOnUnavailable : DEFAULTS.blockOnUnavailable,
      score: {
        enabled: cfg.score && cfg.score.enabled != null ? !!cfg.score.enabled : DEFAULTS.score.enabled,
        weights: Object.assign({}, DEFAULTS.score.weights, cfg.score && cfg.score.weights),
      },
    };
  }

  // ── Couverture (même logique en ratio que le Planning Groupe) ────────────────
  function coverageLevel(prevu, requis, covCfg) {
    if (requis === null || requis === undefined) return { level: 'non_configure', label: 'Besoin non configuré' };
    if (requis === 0) return prevu > 0 ? { level: 'sureffectif', label: 'Sureffectif' } : { level: 'limite', label: 'Limite' };
    const r = prevu / requis;
    if (r < covCfg.redBelow) return { level: 'sous_effectif', label: 'Sous-effectif' };
    if (r <= covCfg.limiteUpTo) return { level: 'limite', label: 'Limite' };
    if (r <= covCfg.conformeUpTo) return { level: 'conforme', label: 'Conforme' };
    return { level: 'sureffectif', label: 'Sureffectif' };
  }
  const ratio = (prevu, requis) => (requis && requis > 0) ? Math.round((prevu / requis) * 100) / 100 : null;

  function weekdayOf(iso) { return new Date(iso + 'T00:00:00Z').getUTCDay(); }
  function requirementFor(requirements, hotelId, weekday) {
    const rows = (requirements || []).filter(r => r.hotel_id === hotelId && r.weekday === weekday && (r.shift === null || r.shift === undefined));
    return rows.length ? rows[0].required : null;
  }
  const isWorking = (status, ws) => ws.indexOf(status) !== -1;
  function presentCount(cells, hotelId, day, ws) {
    const ids = new Set();
    (cells || []).forEach(c => { if (c.hotel_id === hotelId && c.day === day && isWorking(c.status, ws)) ids.add(c.employee_id); });
    return ids.size;
  }
  const empPresent = (cells, hotelId, day, empId, ws) => (cells || []).some(c => c.hotel_id === hotelId && c.day === day && c.employee_id === empId && isWorking(c.status, ws));

  // ── Utilitaires temps / intervalles ──────────────────────────────────────────
  function toMin(t) { if (t == null) return null; const p = String(t).split(':'); return (+p[0]) * 60 + (+(p[1] || 0)); }
  const overlaps = (a, b) => a.s < b.e && b.s < a.e;
  function subtract(base, cuts) {
    let segs = [{ s: base.s, e: base.e }];
    cuts.forEach(c => {
      const out = [];
      segs.forEach(seg => {
        if (!overlaps(seg, c)) { out.push(seg); return; }
        if (seg.s < c.s) out.push({ s: seg.s, e: Math.min(seg.e, c.s) });
        if (seg.e > c.e) out.push({ s: Math.max(seg.s, c.e), e: seg.e });
      });
      segs = out;
    });
    return segs.filter(s => s.e > s.s);
  }
  function travelMinutes(travel, a, b) {
    if (!travel) return null;
    const m = travel.minutesBetween || {};
    if (m[a + '|' + b] != null) return m[a + '|' + b];
    if (m[b + '|' + a] != null) return m[b + '|' + a];
    return travel.defaultMinutes != null ? travel.defaultMinutes : null;
  }

  /**
   * @returns {SimulationResult}
   */
  function simulateMove(input) {
    input = input || {};
    const move = input.move || {};
    const ctx = input.context || {};
    const cfg = mergeConfig(input.config);
    const ws = cfg.workingStatuses, covCfg = cfg.coverage;

    const checks = [];
    const add = (code, level, message, opts) => checks.push(Object.assign({ code, level, message, details: null, field: null, waivable: false }, opts || {}));

    const service = move.service || move.serviceId;
    const empId = move.employeeId;
    const fromId = move.fromHotelId, toId = move.toHotelId;
    const cells = ctx.cells || [], hotels = ctx.hotels || [];
    const hotelById = {}; hotels.forEach(h => hotelById[h.id] = h);
    const emp = ctx.employee || {};

    // Normalise les créneaux : slots[] ou fallback move.day (journée complète).
    let slots = Array.isArray(move.slots) ? move.slots.slice() : [];
    if (!slots.length && move.day) slots = [{ date: move.day }];
    const dates = Array.from(new Set(slots.map(s => s.date))).sort();

    // ── Contrôles structurels (blocages durs) ──
    if (!empId || !fromId || !toId || !service || !slots.length) add('INVALID_INPUT', 'blocking', 'Paramètres de déplacement incomplets.', { field: 'move' });
    if (fromId && toId && fromId === toId) add('SAME_HOTEL', 'blocking', "Hôtel de départ et d'arrivée identiques.", { field: 'toHotelId' });
    if (toId && hotelById[toId] && hotelById[toId].active === false) add('DESTINATION_INACTIVE', 'blocking', "L'établissement d'arrivée est inactif.", { field: 'toHotelId' });

    // ── Disponibilité ──
    if (emp.availability) {
      const av = emp.availability;
      const unavailable = av.available === false || (av.unavailableDays && dates.some(d => av.unavailableDays.indexOf(d) !== -1));
      if (unavailable) add('EMPLOYEE_UNAVAILABLE', cfg.blockOnUnavailable ? 'blocking' : 'warning', av.reason || 'Indisponibilité déclarée sur la période.', { field: 'availability', waivable: !cfg.blockOnUnavailable, details: av });
    }

    // ── Compétences ──
    const svcSkills = (ctx.serviceSkills && ctx.serviceSkills[service]) || {};
    const required = (move.requiredSkills || svcSkills.required || (Array.isArray(svcSkills) ? svcSkills : [])).slice();
    const recommended = (move.recommendedSkills || svcSkills.recommended || []).slice();
    const have = (emp.skills || []).slice();
    const missingRequired = required.filter(s => have.indexOf(s) === -1);
    const missingRecommended = recommended.filter(s => have.indexOf(s) === -1);
    if (missingRequired.length) add('REQUIRED_SKILL_MISSING', cfg.blockOnMissingRequiredSkill ? 'blocking' : 'warning', 'Compétence obligatoire manquante : ' + missingRequired.join(', ') + '.', { field: 'skills', waivable: true, details: { missing: missingRequired } });
    if (missingRecommended.length) add('RECOMMENDED_SKILL_MISSING', 'info', 'Compétence recommandée absente : ' + missingRecommended.join(', ') + '.', { field: 'skills', details: { missing: missingRecommended } });

    // ── Construit l'emploi du temps EFFECTIF après déplacement (par date) ──
    // Départ de l'existant, on retire au départ le temps repris par les créneaux
    // (uniquement les vacations de l'hôtel d'origine chevauchées), on ajoute les
    // créneaux à destination. Les vacations d'autres hôtels sont conservées.
    const byDate = {};
    (emp.shifts || []).forEach(sh => {
      const s = toMin(sh.start), e = toMin(sh.end);
      if (s == null || e == null) return;
      (byDate[sh.date] = byDate[sh.date] || []).push({ s, e, hotel: sh.hotel_id, kind: 'existing' });
    });
    const originVacated = {}; // date -> bool
    dates.forEach(date => {
      const daySlots = slots.filter(sl => sl.date === date).map(sl => ({ s: toMin(sl.start), e: toMin(sl.end) }));
      const full = daySlots.some(sl => sl.s == null || sl.e == null);
      const cuts = daySlots.filter(sl => sl.s != null && sl.e != null);
      const arr = byDate[date] || (byDate[date] = []);
      // Retire / rogne les vacations d'origine reprises par le déplacement.
      const originShifts = arr.filter(x => x.hotel === fromId);
      let originRemainMin = 0;
      if (originShifts.length) {
        const others = arr.filter(x => x.hotel !== fromId);
        let kept = [];
        originShifts.forEach(os => {
          const rem = full ? [] : subtract(os, cuts);
          rem.forEach(r => kept.push({ s: r.s, e: r.e, hotel: fromId, kind: 'origin_kept' }));
        });
        originRemainMin = kept.reduce((a, k) => a + (k.e - k.s), 0);
        byDate[date] = others.concat(kept);
      }
      // Ajoute les créneaux à destination (créneaux datés uniquement ; journée
      // complète sans horaire => présence pour la couverture, sans borne temps).
      cuts.forEach(c => byDate[date].push({ s: c.s, e: c.e, hotel: toId, kind: 'moved' }));
      // Vacated si l'origine avait une présence et qu'il n'en reste plus.
      originVacated[date] = originShifts.length ? originRemainMin === 0 : full;
    });

    // ── Contrôles temps / trajet (par date) ──
    let travelUnknownFlagged = false, travelOkFlagged = false;
    dates.forEach(date => {
      const timed = (byDate[date] || []).filter(x => x.s != null && x.e != null).sort((a, b) => a.s - b.s);
      // chevauchements
      for (let i = 0; i < timed.length; i++) for (let j = i + 1; j < timed.length; j++) {
        if (overlaps(timed[i], timed[j])) add('SHIFT_OVERLAP', 'blocking', 'Chevauchement de vacations le ' + date + ' (présence simultanée impossible).', { field: 'slots', details: { a: timed[i], b: timed[j] } });
      }
      // transitions consécutives
      for (let i = 0; i < timed.length - 1; i++) {
        const cur = timed[i], nxt = timed[i + 1];
        const gap = nxt.s - cur.e;
        if (cur.hotel !== nxt.hotel) {
          const tv = travelMinutes(ctx.travel, cur.hotel, nxt.hotel);
          if (tv == null) { if (!travelUnknownFlagged) { add('TRAVEL_TIME_UNKNOWN', 'info', 'Temps de trajet inter-hôtels non fourni : faisabilité non vérifiée.', { field: 'travel' }); travelUnknownFlagged = true; } }
          else {
            const need = tv + cfg.time.travelSafetyMarginMin;
            if (gap < need) add('TRAVEL_TIME_INSUFFICIENT', 'blocking', 'Temps de trajet insuffisant le ' + date + ' : ' + gap + ' min disponibles, ' + need + ' min requis (trajet ' + tv + ' + marge ' + cfg.time.travelSafetyMarginMin + ').', { field: 'travel', details: { gap, need, travel: tv } });
            else if (!travelOkFlagged) { add('TRAVEL_TIME_OK', 'positive', 'Temps de trajet compatible.', { field: 'travel', details: { gap, need } }); travelOkFlagged = true; }
          }
        } else if (gap > 0 && gap < cfg.time.minBreakMin) {
          add('BREAK_TOO_SHORT', 'warning', 'Pause trop courte le ' + date + ' : ' + gap + ' min < ' + cfg.time.minBreakMin + ' min.', { field: 'slots', waivable: true, details: { gap } });
        }
      }
      // amplitude journalière
      if (timed.length) {
        const amp = (timed[timed.length - 1].e - timed[0].s) / 60;
        if (amp > cfg.time.maxDailyAmplitudeHours) add('DAILY_AMPLITUDE_EXCEEDED', 'warning', 'Amplitude journalière ' + amp.toFixed(1) + 'h > ' + cfg.time.maxDailyAmplitudeHours + 'h le ' + date + '.', { field: 'slots', waivable: true, details: { amplitudeHours: amp } });
      }
    });
    // Repos entre journées consécutives (sur l'emploi du temps effectif)
    const allDates = Object.keys(byDate).sort();
    for (let i = 0; i < allDates.length - 1; i++) {
      const d1 = allDates[i], d2 = allDates[i + 1];
      if ((new Date(d2 + 'T00:00:00Z') - new Date(d1 + 'T00:00:00Z')) !== 86400000) continue;
      const t1 = (byDate[d1] || []).filter(x => x.e != null); const t2 = (byDate[d2] || []).filter(x => x.s != null);
      if (!t1.length || !t2.length) continue;
      const lastEnd = Math.max.apply(null, t1.map(x => x.e));
      const firstStart = Math.min.apply(null, t2.map(x => x.s));
      const restMin = (1440 - lastEnd) + firstStart;
      if (restMin < cfg.time.minRestBetweenDaysHours * 60) add('MINIMUM_REST_NOT_RESPECTED', 'blocking', 'Repos entre ' + d1 + ' et ' + d2 + ' : ' + (restMin / 60).toFixed(1) + 'h < ' + cfg.time.minRestBetweenDaysHours + 'h.', { field: 'rest', waivable: true, details: { restHours: restMin / 60 } });
    }

    // ── Heures hebdomadaires ──
    const movedHours = slots.reduce((a, sl) => { const s = toMin(sl.start), e = toMin(sl.end); return a + (s != null && e != null ? (e - s) / 60 : cfg.regulatory.shiftHours); }, 0);
    if (emp.plannedThisWeek && typeof emp.plannedThisWeek.hours === 'number') {
      const projected = emp.plannedThisWeek.hours + movedHours;
      if (projected > cfg.regulatory.maxWeeklyHours) add('WEEKLY_HOURS_EXCEEDED', 'warning', 'Heures hebdo projetées ' + projected + 'h > ' + cfg.regulatory.maxWeeklyHours + 'h.', { field: 'regulatory', waivable: true, details: { projected } });
    }

    // ── Couverture par (hôtel, date) affecté ──
    const slotBreakdown = [];
    let groupBefore = 0, groupAfter = 0;
    let firstOriginCov = { before: null, after: null }, firstDestCov = { before: null, after: null }, firstSet = false;
    dates.forEach(date => {
      const wd = weekdayOf(date);
      const reqFrom = requirementFor(ctx.requirements, fromId, wd), reqTo = requirementFor(ctx.requirements, toId, wd);
      const oCountedBefore = empPresent(cells, fromId, date, empId, ws);
      const dCountedBefore = empPresent(cells, toId, date, empId, ws);
      const oPrevBefore = presentCount(cells, fromId, date, ws), dPrevBefore = presentCount(cells, toId, date, ws);
      const oPrevAfter = (originVacated[date] && oCountedBefore) ? Math.max(0, oPrevBefore - 1) : oPrevBefore;
      const dPrevAfter = dCountedBefore ? dPrevBefore : dPrevBefore + 1;
      const oB = coverageLevel(oPrevBefore, reqFrom, covCfg), oA = coverageLevel(oPrevAfter, reqFrom, covCfg);
      const dB = coverageLevel(dPrevBefore, reqTo, covCfg), dA = coverageLevel(dPrevAfter, reqTo, covCfg);
      groupBefore += (oB.level === 'sous_effectif' ? 1 : 0) + (dB.level === 'sous_effectif' ? 1 : 0);
      groupAfter += (oA.level === 'sous_effectif' ? 1 : 0) + (dA.level === 'sous_effectif' ? 1 : 0);
      if (!firstSet) { firstOriginCov = { before: ratio(oPrevBefore, reqFrom), after: ratio(oPrevAfter, reqFrom) }; firstDestCov = { before: ratio(dPrevBefore, reqTo), after: ratio(dPrevAfter, reqTo) }; firstSet = true; }
      // Signaux de couverture
      if (oB.level !== 'sous_effectif' && oA.level === 'sous_effectif') add('ORIGIN_UNDERSTAFFED_AFTER_MOVE', 'warning', 'Le départ met ' + (hotelById[fromId] || {}).name + ' en sous-effectif le ' + date + '.', { field: 'coverage', waivable: true, details: { date } });
      if (reqTo != null && reqTo > 0 && dPrevAfter > dPrevBefore) add('DESTINATION_COVERAGE_IMPROVED', 'positive', 'Couverture destination améliorée le ' + date + ' (' + Math.round((dPrevBefore / reqTo) * 100) + '% → ' + Math.round((dPrevAfter / reqTo) * 100) + '%).', { field: 'coverage', details: { date } });
      if (dA.level === 'sous_effectif') add('DESTINATION_STILL_UNDERSTAFFED', 'warning', 'Destination toujours en sous-effectif le ' + date + ' après renfort.', { field: 'coverage', waivable: true, details: { date } });
      slotBreakdown.push({ date, origin: { before: oB.level, after: oA.level, prevuBefore: oPrevBefore, prevuAfter: oPrevAfter, requis: reqFrom }, destination: { before: dB.level, after: dA.level, prevuBefore: dPrevBefore, prevuAfter: dPrevAfter, requis: reqTo } });
    });
    if (groupAfter < groupBefore) add('GROUP_UNDERSTAFFING_REDUCED', 'positive', 'Sous-effectifs du groupe réduits (' + groupBefore + ' → ' + groupAfter + ').', { field: 'coverage', details: { before: groupBefore, after: groupAfter } });

    // ── Décision globale ──
    const blockers = checks.filter(c => c.level === 'blocking');
    const warnings = checks.filter(c => c.level === 'warning');
    const infos = checks.filter(c => c.level === 'info');
    const positives = checks.filter(c => c.level === 'positive');
    const decision = blockers.length ? 'blocked' : (warnings.length ? 'allowed_with_warnings' : 'allowed');

    // ── Score (documenté, paramétrable ; n'écrase jamais un blocage) ──
    let score = null, scoreBreakdown = [];
    if (cfg.score.enabled && decision !== 'blocked') {
      const w = cfg.score.weights;
      const destImproved = checks.some(c => c.code === 'DESTINATION_COVERAGE_IMPROVED');
      const destCovered = slotBreakdown.some(s => s.destination.after === 'conforme' || s.destination.after === 'limite' || s.destination.after === 'sureffectif');
      const originSafe = !slotBreakdown.some(s => s.origin.after === 'sous_effectif');
      const groupReduced = groupAfter < groupBefore;
      const comp = (label, on, pts) => { if (on) { score = (score || 0); scoreBreakdown.push({ label, points: pts }); } };
      score = w.base; scoreBreakdown.push({ label: 'Base', points: w.base });
      comp('Couverture destination améliorée', destImproved, w.destImproved); if (destImproved) score += w.destImproved;
      comp('Destination couverte après', destCovered, w.destFullyCovered); if (destCovered) score += w.destFullyCovered;
      comp('Origine non fragilisée', originSafe, w.originSafe); if (originSafe) score += w.originSafe;
      comp('Sous-effectifs groupe réduits', groupReduced, w.groupReduced); if (groupReduced) score += w.groupReduced;
      const pen = warnings.length * w.warningPenalty;
      if (pen) { score -= pen; scoreBreakdown.push({ label: warnings.length + ' avertissement(s)', points: -pen }); }
      score = Math.max(0, Math.min(100, Math.round(score)));
    }

    // ── Synthèse & raisons lisibles ──
    const reasons = [];
    const fromH = hotelById[fromId] || {}, toH = hotelById[toId] || {};
    if (firstDestCov.before != null && firstDestCov.after != null) reasons.push('Couverture ' + (toH.name || 'destination') + ' : ' + Math.round(firstDestCov.before * 100) + '% → ' + Math.round(firstDestCov.after * 100) + '%');
    if (firstOriginCov.before != null && firstOriginCov.after != null) reasons.push('Couverture ' + (fromH.name || 'origine') + ' : ' + Math.round(firstOriginCov.before * 100) + '% → ' + Math.round(firstOriginCov.after * 100) + '%');
    if (checks.some(c => c.code === 'TRAVEL_TIME_OK')) reasons.push('Temps de trajet compatible');
    if (checks.some(c => c.code === 'TRAVEL_TIME_INSUFFICIENT')) reasons.push('Temps de trajet insuffisant');
    if (checks.some(c => c.code === 'WEEKLY_HOURS_EXCEEDED')) reasons.push('Heures supplémentaires générées');
    blockers.forEach(b => reasons.push('Blocage : ' + b.message));

    const summary = decision === 'blocked'
      ? 'Déplacement bloqué : ' + blockers.map(b => b.message).join(' ')
      : (decision === 'allowed_with_warnings' ? 'Déplacement possible sous réserve' : 'Déplacement recommandé')
        + (groupAfter < groupBefore ? ' — réduit les sous-effectifs du groupe' : '') + '.';

    return {
      decision, score, scoreBreakdown, summary, reasons,
      impact: {
        groupUnderstaffingBefore: groupBefore, groupUnderstaffingAfter: groupAfter,
        originCoverageBefore: firstOriginCov.before, originCoverageAfter: firstOriginCov.after,
        destinationCoverageBefore: firstDestCov.before, destinationCoverageAfter: firstDestCov.after,
      },
      checks, blockers, warnings, infos, positives,
      slots: slotBreakdown,
      skills: { required, recommended, have, missingRequired, missingRecommended },
      // Compat : `ok` conservé (miroir de la décision).
      ok: decision !== 'blocked',
    };
  }

  return {
    simulateMove,
    coverageLevel,
    DEFAULTS,
    _internals: { weekdayOf, presentCount, requirementFor, subtract, toMin, travelMinutes },
  };
});
