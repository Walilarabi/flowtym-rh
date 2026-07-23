/**
 * Flowtym — Moteur de simulation de déplacement inter-hôtels
 * =========================================================================
 * PUR, INDÉPENDANT DE L'INTERFACE. Aucune dépendance DOM, réseau, ni écriture.
 * Réutilisable par : Drag & Drop, suggestions IA, simulations RH, propositions
 * automatiques de renfort.
 *
 * Le moteur NE DÉPLACE JAMAIS un collaborateur. Il calcule, pour un déplacement
 * proposé, ses conséquences, et renvoie un verdict structuré que l'appelant
 * (ex. le Drag & Drop) affichera avant de demander confirmation.
 *
 * Contrat d'entrée : simulateMove({ move, context, config })
 *   move    : le déplacement proposé.
 *   context : les données nécessaires (planning du jour, besoins, collaborateur…).
 *   config  : seuils de couverture + limites réglementaires + options.
 *
 * Contrat de sortie : voir @typedef SimulationResult ci-dessous.
 *
 * Exposé en CommonJS (module.exports) ET en global navigateur (window.FlowtymMoveSim).
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FlowtymMoveSim = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // Défauts — AUCUNE valeur métier codée en dur dans la logique : tout est ici,
  // surchargé par config. Les seuils de couverture sont des RATIOS prévu/requis,
  // identiques à la logique centralisée du Planning Groupe (COVERAGE_LEVEL).
  const DEFAULTS = {
    coverage: { redBelow: 1.0, limiteUpTo: 1.0, conformeUpTo: 1.3 },
    regulatory: { maxWeeklyHours: 48, maxConsecutiveDays: 6, minRestHours: 11, shiftHours: 7 },
    workingStatuses: ['P', 'PE'],   // statuts comptant comme "présent/travaillé"
    blockOnMissingSkill: false,     // compétence manquante = avertissement par défaut
    blockOnUnavailable: true,       // indisponibilité déclarée = blocage par défaut
  };

  function mergeConfig(cfg) {
    cfg = cfg || {};
    return {
      coverage: Object.assign({}, DEFAULTS.coverage, cfg.coverage),
      regulatory: Object.assign({}, DEFAULTS.regulatory, cfg.regulatory),
      workingStatuses: cfg.workingStatuses || DEFAULTS.workingStatuses,
      blockOnMissingSkill: cfg.blockOnMissingSkill != null ? !!cfg.blockOnMissingSkill : DEFAULTS.blockOnMissingSkill,
      blockOnUnavailable: cfg.blockOnUnavailable != null ? !!cfg.blockOnUnavailable : DEFAULTS.blockOnUnavailable,
    };
  }

  // Niveau de couverture — MÊME formule (ratio) que le Planning Groupe.
  function coverageLevel(prevu, requis, covCfg) {
    if (requis === null || requis === undefined) return { level: 'non_configure', label: 'Besoin non configuré' };
    if (requis === 0) return prevu > 0 ? { level: 'sureffectif', label: 'Sureffectif' } : { level: 'limite', label: 'Limite' };
    const r = prevu / requis;
    if (r < covCfg.redBelow) return { level: 'sous_effectif', label: 'Sous-effectif' };
    if (r <= covCfg.limiteUpTo) return { level: 'limite', label: 'Limite' };
    if (r <= covCfg.conformeUpTo) return { level: 'conforme', label: 'Conforme' };
    return { level: 'sureffectif', label: 'Sureffectif' };
  }

  function weekdayOf(iso) {
    // iso 'YYYY-MM-DD' -> 0=dimanche..6=samedi, en UTC pour être déterministe.
    const d = new Date(iso + 'T00:00:00Z');
    return d.getUTCDay();
  }

  function requirementFor(requirements, hotelId, weekday) {
    // Besoin au niveau JOUR (shift null) — V1. Retourne null si non configuré.
    const rows = (requirements || []).filter(function (r) {
      return r.hotel_id === hotelId && r.weekday === weekday && (r.shift === null || r.shift === undefined);
    });
    return rows.length ? rows[0].required : null;
  }

  function isWorking(status, workingStatuses) {
    return workingStatuses.indexOf(status) !== -1;
  }

  // Effectif présent (distinct) pour un hôtel/jour, à partir des cellules fournies.
  function presentCount(cells, hotelId, day, workingStatuses, excludeEmployeeId) {
    const ids = new Set();
    (cells || []).forEach(function (c) {
      if (c.hotel_id !== hotelId || c.day !== day) return;
      if (excludeEmployeeId && c.employee_id === excludeEmployeeId) return;
      if (isWorking(c.status, workingStatuses)) ids.add(c.employee_id);
    });
    return ids.size;
  }

  function hasWorkingCell(cells, hotelId, day, employeeId, workingStatuses) {
    return (cells || []).some(function (c) {
      return c.hotel_id === hotelId && c.day === day && c.employee_id === employeeId && isWorking(c.status, workingStatuses);
    });
  }

  function coverageBlock(prevu, requis, covCfg) {
    const lvl = coverageLevel(prevu, requis, covCfg);
    return {
      prevu: prevu,
      requis: requis,
      ecart: (requis === null || requis === undefined) ? null : (prevu - requis),
      level: lvl.level,
      label: lvl.label,
      tauxCouverture: (requis && requis > 0) ? Math.round((prevu / requis) * 100) : null,
    };
  }

  /**
   * @typedef {Object} SimulationResult
   * @property {boolean} ok               - false s'il existe au moins un blocage dur.
   * @property {Array}   blockers         - blocages empêchant le déplacement [{code,message}].
   * @property {Array}   warnings         - avertissements non bloquants [{code,message}].
   * @property {Array}   conflicts        - conflits détectés [{code,message}].
   * @property {Object}  from             - impact hôtel de départ {hotelId, before, after}.
   * @property {Object}  to               - impact hôtel d'arrivée {hotelId, before, after}.
   * @property {Object}  coverageChange   - évolution des niveaux de couverture.
   * @property {Object}  sousEffectif     - {before, after, delta} sur les 2 hôtels.
   * @property {Object}  skills           - {required, have, missing}.
   * @property {Array}   regulatory       - dépassements réglementaires [{code,message,severity}].
   * @property {Object}  availability     - {available, reason}.
   * @property {string}  summary          - résumé lisible.
   */

  /**
   * Simule un déplacement. Ne modifie rien.
   * @returns {SimulationResult}
   */
  function simulateMove(input) {
    input = input || {};
    const move = input.move || {};
    const ctx = input.context || {};
    const cfg = mergeConfig(input.config);
    const covCfg = cfg.coverage;

    const blockers = [], warnings = [], conflicts = [], regulatory = [];
    const B = function (code, message) { blockers.push({ code: code, message: message }); };
    const W = function (code, message) { warnings.push({ code: code, message: message }); };

    const day = move.day;
    const service = move.service;
    const empId = move.employeeId;
    const fromId = move.fromHotelId;
    const toId = move.toHotelId;
    const cells = ctx.cells || [];
    const hotels = ctx.hotels || [];
    const wd = day ? weekdayOf(day) : null;
    const hotelById = {}; hotels.forEach(function (h) { hotelById[h.id] = h; });

    // --- Validations structurelles / blocages durs ---
    if (!empId || !fromId || !toId || !service || !day) {
      B('BLK_INVALID_INPUT', 'Paramètres de déplacement incomplets.');
    }
    if (fromId && toId && fromId === toId) {
      B('BLK_SAME_HOTEL', 'Hôtel de départ et d\'arrivée identiques.');
    }
    const destHotel = hotelById[toId];
    if (toId && destHotel && destHotel.active === false) {
      B('BLK_DEST_INACTIVE', 'L\'établissement d\'arrivée est inactif.');
    }

    // Le collaborateur est-il réellement présent (travaillé) à l'hôtel de départ ce jour ?
    const presentAtSource = hasWorkingCell(cells, fromId, day, empId, cfg.workingStatuses);
    if (!presentAtSource && fromId && day && empId) {
      B('BLK_NOT_PRESENT_AT_SOURCE', 'Le collaborateur n\'est pas planifié en présence à l\'hôtel de départ ce jour — rien à déplacer.');
    }
    // Déjà présent à destination le même jour -> conflit / blocage.
    const alreadyAtDest = hasWorkingCell(cells, toId, day, empId, cfg.workingStatuses);
    if (alreadyAtDest) {
      conflicts.push({ code: 'CFL_ALREADY_AT_DEST', message: 'Le collaborateur est déjà planifié en présence à l\'hôtel d\'arrivée ce jour.' });
      B('BLK_ALREADY_AT_DEST', 'Double affectation le même jour à l\'hôtel d\'arrivée.');
    }

    // --- Couverture avant / après ---
    const reqFrom = requirementFor(ctx.requirements, fromId, wd);
    const reqTo = requirementFor(ctx.requirements, toId, wd);
    const prevuFromBefore = presentCount(cells, fromId, day, cfg.workingStatuses);
    const prevuToBefore = presentCount(cells, toId, day, cfg.workingStatuses);
    // Après : -1 au départ (si présent y comptait), +1 à l'arrivée (si pas déjà compté).
    const prevuFromAfter = presentAtSource ? Math.max(0, prevuFromBefore - 1) : prevuFromBefore;
    const prevuToAfter = alreadyAtDest ? prevuToBefore : prevuToBefore + 1;

    const fromBefore = coverageBlock(prevuFromBefore, reqFrom, covCfg);
    const fromAfter = coverageBlock(prevuFromAfter, reqFrom, covCfg);
    const toBefore = coverageBlock(prevuToBefore, reqTo, covCfg);
    const toAfter = coverageBlock(prevuToAfter, reqTo, covCfg);

    // Sous-effectifs (sur les deux hôtels concernés)
    const sousBefore = (fromBefore.level === 'sous_effectif' ? 1 : 0) + (toBefore.level === 'sous_effectif' ? 1 : 0);
    const sousAfter = (fromAfter.level === 'sous_effectif' ? 1 : 0) + (toAfter.level === 'sous_effectif' ? 1 : 0);

    // Avertissements de couverture
    if (fromBefore.level !== 'sous_effectif' && fromAfter.level === 'sous_effectif') {
      W('WARN_CREATES_UNDERSTAFF_SOURCE', 'Le départ fait passer l\'hôtel d\'origine en sous-effectif.');
    }
    if (toAfter.level === 'sureffectif') {
      W('WARN_OVERSTAFF_DEST', 'L\'arrivée met l\'hôtel de destination en sureffectif.');
    }
    if (reqTo === null) {
      W('WARN_DEST_REQ_NOT_CONFIGURED', 'Besoin non configuré à l\'hôtel d\'arrivée : impact de couverture non évaluable.');
    }

    // --- Compétences requises ---
    const required = (move.requiredSkills || (ctx.serviceSkills && ctx.serviceSkills[service]) || []).slice();
    const have = ((ctx.employee && ctx.employee.skills) || []).slice();
    const missing = required.filter(function (s) { return have.indexOf(s) === -1; });
    if (missing.length) {
      if (cfg.blockOnMissingSkill) B('BLK_MISSING_SKILLS', 'Compétences requises manquantes : ' + missing.join(', ') + '.');
      else W('WARN_MISSING_SKILLS', 'Compétences requises manquantes : ' + missing.join(', ') + '.');
    }

    // --- Disponibilité ---
    const availability = { available: true, reason: null };
    const emp = ctx.employee || {};
    if (emp.availability) {
      const av = emp.availability;
      const unavailableToday = (av.unavailableDays && av.unavailableDays.indexOf(day) !== -1) || av.available === false;
      if (unavailableToday) {
        availability.available = false;
        availability.reason = av.reason || 'Indisponibilité déclarée ce jour.';
        if (cfg.blockOnUnavailable) B('BLK_UNAVAILABLE', availability.reason);
        else W('WARN_UNAVAILABLE', availability.reason);
      }
    }

    // --- Dépassements réglementaires (uniquement si les données sont fournies) ---
    const wk = emp.plannedThisWeek || {};
    const reg = cfg.regulatory;
    if (typeof wk.hours === 'number') {
      const projected = wk.hours + reg.shiftHours;
      if (projected > reg.maxWeeklyHours) {
        regulatory.push({ code: 'REG_WEEKLY_HOURS', severity: 'high', message: 'Dépassement heures hebdo : ' + projected + 'h > ' + reg.maxWeeklyHours + 'h.' });
        W('WARN_REG_WEEKLY_HOURS', 'Le déplacement dépasserait la durée hebdomadaire maximale.');
      }
    }
    if (typeof wk.consecutiveDays === 'number') {
      const cons = wk.consecutiveDays + 1;
      if (cons > reg.maxConsecutiveDays) {
        regulatory.push({ code: 'REG_CONSECUTIVE_DAYS', severity: 'high', message: 'Jours consécutifs : ' + cons + ' > ' + reg.maxConsecutiveDays + '.' });
        W('WARN_REG_CONSECUTIVE_DAYS', 'Le déplacement dépasserait le nombre de jours consécutifs autorisés.');
      }
    }
    if (typeof emp.lastRestHours === 'number' && emp.lastRestHours < reg.minRestHours) {
      regulatory.push({ code: 'REG_REST', severity: 'medium', message: 'Repos insuffisant : ' + emp.lastRestHours + 'h < ' + reg.minRestHours + 'h.' });
      W('WARN_REG_REST', 'Le repos minimal entre deux services ne serait pas respecté.');
    }

    const ok = blockers.length === 0;
    const fromH = hotelById[fromId] || {}, toH = hotelById[toId] || {};
    const summary = ok
      ? 'Déplacement possible' + (warnings.length ? ' avec ' + warnings.length + ' avertissement(s)' : '') + ' : '
        + (fromH.hotel_code || fromH.code || 'départ') + ' ' + fromBefore.label + '→' + fromAfter.label
        + ' | ' + (toH.hotel_code || toH.code || 'arrivée') + ' ' + toBefore.label + '→' + toAfter.label + '.'
      : 'Déplacement bloqué : ' + blockers.map(function (b) { return b.message; }).join(' ');

    return {
      ok: ok,
      blockers: blockers,
      warnings: warnings,
      conflicts: conflicts,
      from: { hotelId: fromId, service: service, day: day, before: fromBefore, after: fromAfter },
      to: { hotelId: toId, service: service, day: day, before: toBefore, after: toAfter },
      coverageChange: {
        from: { before: fromBefore.level, after: fromAfter.level },
        to: { before: toBefore.level, after: toAfter.level },
      },
      sousEffectif: { before: sousBefore, after: sousAfter, delta: sousAfter - sousBefore },
      skills: { required: required, have: have, missing: missing },
      regulatory: regulatory,
      availability: availability,
      summary: summary,
    };
  }

  return {
    simulateMove: simulateMove,
    coverageLevel: coverageLevel,   // exposé pour réutilisation / cohérence
    DEFAULTS: DEFAULTS,
    _internals: { weekdayOf: weekdayOf, presentCount: presentCount, requirementFor: requirementFor },
  };
});
