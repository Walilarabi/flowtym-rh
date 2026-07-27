/**
 * Logique pure de disponibilité d'un collaborateur pour affectation
 * inter-hôtels (Planning Groupe). Extraite de index.html pour être testable.
 *
 * @param {Object} params
 *   employeeId    UUID du collaborateur (jamais exposé à l'UI)
 *   collabCell    ligne agrégée du RPC group_planning : { status, is_extra, name, ... }
 *   cmap          référentiel des statuts { CODE: {label, cat:'worked'|'abs'|'paid'|...} }
 *   reserved      map { employee_id: { ... } } des propositions déjà réservées
 * @returns {string} raison d'indisponibilité (vide si affectable)
 */
// Règles métier Planning Groupe :
//   Présent / PE / MAD  → affectable
//   Repos (status vide) → affectable
//   CP                  → affectable (extra possible)
//   RTT/REC/FORM/AE/CSS → affectable (mobilisables)
//   MAL / ABS           → BLOQUÉ (maladie, absence)
//   MAT / PAT           → BLOQUÉ (congés protégés)
//   mission déjà programmée → BLOQUÉ (indépendant du statut)
const GP_UNAVAIL_STATUSES = {
  MAL: 'maladie',
  ABS: 'absence',
  MAT: 'maternité',
  PAT: 'paternité',
};
function computeUnavailReason({ employeeId, collabCell, cmap, reserved }) {
  if (reserved && reserved[employeeId]) return 'mission déjà programmée';
  if (!collabCell) return '';
  const st = collabCell.status;
  if (!st) return '';                        // Repos → affectable
  const meta = cmap[st];
  if (!meta) return '';
  if (meta.cat === 'worked') return '';      // P / PE / MAD → affectable
  return GP_UNAVAIL_STATUSES[st] || '';      // seuls MAL/ABS/MAT/PAT bloquent
}

/**
 * Résolution du nom affichable d'un collaborateur — jamais l'UUID.
 * @param {Object} params
 *   employeeId       UUID
 *   staffCache       liste d'employés [{ id, first_name, last_name }]
 *   extraCache       Map<id, {first_name, last_name}>
 *   renderedCollab   éventuel { name } trouvé dans le dernier rendu Planning Groupe
 * @returns {string}  nom affichable, chaîne vide si aucune source.
 */
function resolveEmployeeName({ employeeId, staffCache, extraCache, renderedCollab }) {
  const emp = (staffCache || []).find(x => x.id === employeeId) ||
              (extraCache && extraCache.get && extraCache.get(employeeId)) || null;
  if (emp && (emp.first_name || emp.last_name)) {
    return ((emp.first_name || '') + ' ' + (emp.last_name || '')).trim();
  }
  if (renderedCollab && renderedCollab.name) return renderedCollab.name;
  return '';
}

/**
 * Détecte un chevauchement horaire entre deux tableaux de créneaux [{date, start?, end?}].
 * Journée complète : start/end absents → 00:00-24:00.
 */
function toMin(t) { if (t == null) return null; const p = String(t).split(':'); return (+p[0]) * 60 + (+(p[1] || 0)); }
function slotsOverlap(slotsA, slotsB) {
  for (const a of slotsA || []) {
    const as = toMin(a.start), ae = toMin(a.end);
    const aS = as == null ? 0 : as, aE = ae == null ? 1440 : ae;
    for (const b of slotsB || []) {
      const bs = toMin(b.start), be = toMin(b.end);
      const bS = bs == null ? 0 : bs, bE = be == null ? 1440 : be;
      if (a.date === b.date && aS < bE && bS < aE) return true;
    }
  }
  return false;
}

/**
 * Le pipeline "Confirmer l'affectation" côté client :
 *  - decision === 'blocked'          → refus (re-vérification serveur préventive)
 *  - canApply === true               → chaîne complète draft+submit+approve+apply
 *  - canApply === false              → repli sur circuit d'approbation
 * @returns {{status:'blocked'|'applied'|'submitted', reason?:string}}
 */
function planConfirmationOutcome({ decision, canApply }) {
  if (decision === 'blocked') return { status: 'blocked', reason: 'contraintes bloquantes' };
  if (canApply) return { status: 'applied' };
  return { status: 'submitted' };
}

module.exports = {
  computeUnavailReason,
  resolveEmployeeName,
  slotsOverlap,
  planConfirmationOutcome,
};
