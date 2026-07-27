/**
 * Rythme de travail (fixed_days_off / rotating_cycle) et Auto-remplissage du planning.
 *
 * Copie fidèle des fonctions pures de index.html (computeAutoFill / computeCodeForDate,
 * cf. « CALCUL DU CODE CYCLE » et « MODALE : AUTO-REMPLIR »). Ce fichier n'est PAS importé
 * par index.html (application monofichier sans bundler) : toute modification de la logique
 * de génération dans index.html doit être répercutée ici pour que les tests restent
 * représentatifs du comportement réel.
 */
'use strict';

// ─── DATES — mêmes fonctions que index.html : dates voyagent en 'YYYY-MM-DD',
// arithmétique 100% UTC pour être immune aux fuseaux horaires et au DST ────────

function addDays(dateStr, n) {
  const ms = new Date(dateStr).getTime() + n * 86400000;
  return new Date(ms).toISOString().slice(0, 10);
}

function dateDiffDays(startStr, endStr) {
  return Math.round((new Date(endStr).getTime() - new Date(startStr).getTime()) / 86400000);
}

function dateStrRange(fromStr, toStr) {
  const result = [];
  let cur = fromStr;
  while (cur <= toStr) { result.push(cur); cur = addDays(cur, 1); }
  return result;
}

function weekdayOf(dateStr) {
  return new Date(dateStr).getUTCDay(); // 0=dim … 6=sam, UTC-safe
}

// ─── CALCUL DU CODE CYCLE — identique à index.html ────────────────────────────

function computeCodeForDate(emp, dateStr, pattern) {
  if (!pattern || pattern.pattern_type === 'manual') return null;

  if (pattern.pattern_type === 'fixed_days_off') {
    const wd = weekdayOf(dateStr);
    const fdo = pattern.fixed_days_off || [];
    return fdo.includes(wd) ? { code: '', reason: 'Repos fixe' } : { code: 'P', reason: 'Jour travaillé' };
  }

  if (pattern.pattern_type === 'rotating_cycle') {
    if (!pattern.cycle_start_date || !pattern.cycle_length_days || !pattern.cycle_days?.length) return null;
    const diffDays = dateDiffDays(pattern.cycle_start_date, dateStr);
    if (diffDays < 0) return null;
    const idx = diffDays % pattern.cycle_length_days;
    const entry = (pattern.cycle_days || []).find(e => +e.day === (idx + 1));
    if (!entry) return null;
    return entry.status === 'work'
      ? { code: 'P', reason: `Cycle J${idx + 1} travail` }
      : { code: '', reason: `Cycle J${idx + 1} repos` };
  }

  return null;
}

// ─── BOUCLE DE GÉNÉRATION — reproduit computeAutoFill() pour UN salarié,
// sans dépendance BE/DOM, pour pouvoir la tester unitairement. ────────────────
//
// existingMap : Map<'YYYY-MM-DD', status> — planning déjà en base pour ce salarié
// protectedCodes : Set<string> — codes d'absence/congé protégés (PROTECTED_CODES)
//
function planEmployeeAutoFill({ emp, pattern, fromStr, toStr, existingMap, safeOnly = true, protectAbs = true, protectedCodes = new Set() }) {
  const toCreate = [], skipped = [], protected_ = [], conflicts = [];

  if (!pattern || pattern.pattern_type === 'manual') {
    return { toCreate, skipped, protected_, conflicts, noRule: 'Mode manuel / aucune règle' };
  }
  if (pattern.pattern_type === 'rotating_cycle' && (!pattern.cycle_start_date || !pattern.cycle_length_days || !pattern.cycle_days?.length)) {
    return { toCreate, skipped, protected_, conflicts, noRule: 'Cycle incomplet (manque date de départ ou jours)' };
  }

  for (const ds of dateStrRange(fromStr, toStr)) {
    const existing = existingMap.has(ds) ? existingMap.get(ds) : undefined;

    if (protectAbs && existing !== undefined && protectedCodes.has(existing)) {
      protected_.push({ date: ds, existing, reason: 'Absence/congé protégé' });
      continue;
    }

    const result = computeCodeForDate(emp, ds, pattern);
    if (result === null) continue; // avant le début du cycle

    if (safeOnly && existing !== undefined && existing !== '') {
      if (existing === 'P' && result.code === '') {
        conflicts.push({ date: ds, existing, expected: result.code, reason: result.reason });
      }
      skipped.push({ date: ds, existing, reason: 'Cellule déjà renseignée' });
      continue;
    }

    toCreate.push({ day: ds, status: result.code, reason: result.reason, old_value: existing || '' });
  }

  return { toCreate, skipped, protected_, conflicts, noRule: null };
}

module.exports = { addDays, dateDiffDays, dateStrRange, weekdayOf, computeCodeForDate, planEmployeeAutoFill };
