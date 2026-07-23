/**
 * Flowtym — Couche d'adaptation entre les données Flowtym et le moteur de simulation.
 * =========================================================================
 * PARTIE PURE (ce fichier) : normalisation + évaluation de complétude des
 * données. AUCUN accès Supabase ici. La récupération des données brutes est
 * faite par `buildMoveSimulationContext(...)` côté application (index.html),
 * qui appelle ensuite ces fonctions pures.
 *
 * Le moteur (move-simulator) ne doit jamais accéder à la base : seule la couche
 * applicative interroge les données, puis délègue à ces helpers purs.
 *
 * Exposé en CommonJS + global window.FlowtymSimAdapter.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FlowtymSimAdapter = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function weekdayOf(iso) { return new Date(iso + 'T00:00:00Z').getUTCDay(); }

  // Construit la table de trajets minutesBetween pour le moteur.
  // La marge de sécurité par couple est repliée dans la durée (le moteur applique
  // une marge globale mise à 0), afin de respecter une marge PAR COUPLE.
  function buildTravel(travelRows) {
    const minutesBetween = {};
    (travelRows || []).forEach(function (t) {
      minutesBetween[t.from_hotel_id + '|' + t.to_hotel_id] = (t.duration_min || 0) + (t.safety_margin_min || 0);
    });
    return { minutesBetween: minutesBetween };
  }

  /**
   * Évalue la complétude des données. Ne remplace JAMAIS silencieusement une
   * donnée manquante : signale disponible / manquant / hypothèse, + confiance.
   * @returns {{fields:Array, confidence:number, authorized:boolean, assumptions:Array}}
   */
  function assessInputs(raw) {
    raw = raw || {};
    const fields = [];
    const F = function (key, label, status, detail) { fields.push({ key: key, label: label, status: status, detail: detail || null }); };
    const assumptions = [];

    // Autorisation hôtel de destination
    const authorized = !raw.accessibleHotelIds || raw.accessibleHotelIds.indexOf(raw.destination && raw.destination.hotelId) !== -1;
    F('dest_authorized', "Accès à l'hôtel de destination", authorized ? 'available' : 'missing', authorized ? null : 'Hôtel de destination non autorisé pour cet utilisateur.');

    // Temps de trajet configuré pour le couple
    const pair = (raw.origin && raw.origin.hotelId) + '|' + (raw.destination && raw.destination.hotelId);
    const hasTravel = (raw.travelTimes || []).some(function (t) { return (t.from_hotel_id + '|' + t.to_hotel_id) === pair; });
    F('travel_time', 'Temps de trajet configuré', hasTravel ? 'available' : 'missing', hasTravel ? null : 'Aucun temps de trajet configuré entre ces deux établissements.');

    // Compétences du collaborateur
    const skillsKnown = Array.isArray(raw.employee && raw.employee.skills);
    if (skillsKnown) F('skills', 'Compétences du collaborateur', 'available');
    else { F('skills', 'Compétences du collaborateur', 'assumption', 'Compétences non renseignées : contrôle de compétence non concluant.'); assumptions.push('Compétences non vérifiées'); }

    // Besoin de couverture à destination (jour concerné)
    const dates = (raw.slots || []).map(function (s) { return s.date; });
    let destReqOk = false;
    if (raw.destination && dates.length) {
      destReqOk = dates.every(function (d) {
        const wd = weekdayOf(d);
        return (raw.requirements || []).some(function (r) { return r.hotel_id === raw.destination.hotelId && r.weekday === wd && (r.shift == null); });
      });
    }
    F('dest_requirement', "Besoin d'effectif configuré (destination)", destReqOk ? 'available' : 'missing', destReqOk ? null : "Besoin non configuré : impact de couverture partiellement évaluable.");

    // Horaires de shift complets
    const partial = (raw.slots || []).some(function (s) { return (s.start && !s.end) || (!s.start && s.end); });
    F('shift_times', 'Horaires de créneau complets', partial ? 'missing' : 'available', partial ? 'Un créneau a un horaire incomplet.' : null);

    // Vacations existantes du collaborateur (pour trajet/repos/amplitude)
    const hasShifts = Array.isArray(raw.employeeShifts) && raw.employeeShifts.length > 0;
    if (hasShifts) F('employee_shifts', 'Vacations existantes du collaborateur', 'available');
    else { F('employee_shifts', 'Vacations existantes du collaborateur', 'assumption', 'Aucune vacation connue : trajet/repos/amplitude non vérifiés finement.'); assumptions.push('Emploi du temps existant inconnu'); }

    // Règles RH
    const rhOk = !!raw.rhRules;
    if (rhOk) F('rh_rules', 'Règles RH applicables', 'available');
    else { F('rh_rules', 'Règles RH applicables', 'assumption', 'Règles RH par défaut utilisées.'); assumptions.push('Règles RH par défaut'); }

    // Seuils de couverture
    F('coverage_cfg', 'Seuils de couverture', raw.coverageCfg ? 'available' : 'assumption', raw.coverageCfg ? null : 'Seuils par défaut utilisés.');
    if (!raw.coverageCfg) assumptions.push('Seuils de couverture par défaut');

    // Confiance : 100 - pénalités (manquant = 15, hypothèse = 8), bornée.
    let conf = 100;
    fields.forEach(function (f) { if (f.status === 'missing') conf -= 15; else if (f.status === 'assumption') conf -= 8; });
    conf = Math.max(0, Math.min(100, conf));

    return { fields: fields, confidence: conf, authorized: authorized, assumptions: assumptions };
  }

  /**
   * Construit { move, context, config } pour le moteur, à partir des données
   * brutes normalisées. N'invente aucune valeur métier : applique uniquement des
   * défauts explicites (repérés par assessInputs comme hypothèses).
   */
  function buildContext(raw, baseConfig) {
    raw = raw || {};
    const svcSkills = raw.serviceSkills || null;

    const move = {
      employeeId: raw.employee && raw.employee.id,
      employeeName: raw.employee && raw.employee.name,
      fromHotelId: raw.origin && raw.origin.hotelId,
      toHotelId: raw.destination && raw.destination.hotelId,
      service: raw.destination && raw.destination.service,
      slots: (raw.slots || []).slice(),
    };

    const context = {
      hotels: raw.hotels || [],
      cells: raw.cells || [],
      requirements: raw.requirements || [],
      employee: {
        id: raw.employee && raw.employee.id,
        skills: (raw.employee && raw.employee.skills) || undefined,
        availability: (raw.employee && raw.employee.availability) || undefined,
        shifts: raw.employeeShifts || [],
        plannedThisWeek: (raw.employee && raw.employee.plannedThisWeek) || undefined,
      },
      serviceSkills: svcSkills || undefined,
      travel: buildTravel(raw.travelTimes),
    };

    // Config : la marge par couple étant repliée dans le trajet, marge globale = 0.
    const config = Object.assign({}, baseConfig, {
      coverage: raw.coverageCfg || (baseConfig && baseConfig.coverage),
      regulatory: (raw.rhRules && raw.rhRules.regulatory) || (baseConfig && baseConfig.regulatory),
      time: Object.assign({ travelSafetyMarginMin: 0 }, (raw.rhRules && raw.rhRules.time), baseConfig && baseConfig.time, { travelSafetyMarginMin: 0 }),
    });

    return { move: move, context: context, config: config };
  }

  return { assessInputs: assessInputs, buildContext: buildContext, buildTravel: buildTravel };
});
