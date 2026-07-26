/**
 * Logique pure du Drag & Drop du Planning Groupe.
 *
 * Aucune dépendance DOM. Toutes les décisions "cette ligne est-elle
 * déplaçable ?" et "cette cellule accepte-t-elle le dépôt ?" sont ici,
 * afin d'être testables sans navigateur. Le fichier index.html se contente
 * d'appeler ces fonctions et d'attacher les classes CSS correspondantes.
 *
 * Aucun second moteur métier : la validation finale reste faite par
 * FlowtymMoveSim au moment de la confirmation, exactement comme pour le
 * bouton Affecter et les suggestions IA.
 */

/**
 * Peut-on démarrer un drag sur ce collaborateur ?
 * @param {Object} params
 *   unavailReason   raison d'indisponibilité (chaîne vide si affectable),
 *                   obtenue via computeUnavailReason (module frère).
 *   allowedHotelIds ensemble facultatif ; si fourni, l'origine doit y appartenir
 *                   (autrement on considère le collaborateur non déplaçable).
 *   originHotelId
 * @returns {{draggable:boolean, reason?:string}}
 */
function canDrag({ unavailReason, allowedHotelIds, originHotelId }) {
  if (unavailReason) return { draggable: false, reason: unavailReason };
  if (allowedHotelIds && originHotelId && !allowedHotelIds.has(originHotelId)) {
    return { draggable: false, reason: 'hôtel d\'origine hors périmètre' };
  }
  return { draggable: true };
}

/**
 * Classe une cellule (hôtel × service) comme cible de dépôt pour un
 * collaborateur donné.
 *
 * Retour : {level: 'origin' | 'invalid' | 'warning' | 'valid', reason?: string}
 *  - origin  : cellule d'origine (surbrillance neutre, aucun dépôt utile)
 *  - invalid : dépôt interdit (hôtel non autorisé, service incompatible,
 *              conflit horaire manifeste)
 *  - warning : dépôt autorisé mais nécessitant une validation (couverture
 *              non configurée, chevauchement partiel)
 *  - valid   : dépôt franchement bénéfique (destination en sous-effectif)
 *
 * @param {Object} p
 *   origin              { hotelId, service }
 *   target              { hotelId, service }
 *   employeeCompetences liste facultative de compétences ; si présente et non
 *                       vide, doit contenir targetService pour être compatible.
 *   allowedHotelIds     ensemble facultatif d'hôtels autorisés
 *   coverageLevel       'sous_effectif' | 'limite' | 'conforme' | 'sureffectif'
 *                       | 'non_configure' | undefined
 *   plannedSlots        créneaux déjà planifiés {date,start?,end?} pour ce collab
 *   proposedSlot        créneau proposé pour la nouvelle mission (même forme)
 *   sameDayOtherHotel   booléen : le collab a-t-il déjà un shift sur un autre
 *                       hôtel ce même jour (chevauchement manifeste).
 */
function classifyDrop(p) {
  const { origin, target } = p;
  if (origin && target && origin.hotelId === target.hotelId && origin.service === target.service) {
    return { level: 'origin', reason: 'même hôtel et même service' };
  }
  if (p.allowedHotelIds && target && !p.allowedHotelIds.has(target.hotelId)) {
    return { level: 'invalid', reason: 'hôtel non autorisé' };
  }
  const skills = p.employeeCompetences;
  if (Array.isArray(skills) && skills.length > 0 && target && target.service && skills.indexOf(target.service) === -1) {
    return { level: 'invalid', reason: 'service incompatible' };
  }
  if (p.sameDayOtherHotel) {
    return { level: 'invalid', reason: 'chevauchement horaire' };
  }
  if (p.plannedSlots && p.proposedSlot && slotsOverlap(p.plannedSlots, [p.proposedSlot])) {
    return { level: 'invalid', reason: 'chevauchement horaire' };
  }
  const cov = p.coverageLevel;
  if (cov === 'sous_effectif' || cov === 'limite') return { level: 'valid' };
  if (cov === 'non_configure') return { level: 'warning', reason: 'besoin non configuré' };
  if (cov === 'sureffectif') return { level: 'warning', reason: 'destination déjà en sureffectif' };
  return { level: 'valid' };
}

/**
 * Charge utile transportée pendant le drag. Ne contient AUCUNE information
 * qui serait affichée directement à l'écran — l'UI utilise le nom résolu
 * séparément via resolveEmployeeName.
 */
function buildDragPayload({ employeeId, originHotelId, originService, dayISO }) {
  return {
    v: 1,
    employeeId: String(employeeId || ''),
    originHotelId: String(originHotelId || ''),
    originService: String(originService || ''),
    day: String(dayISO || ''),
  };
}

/**
 * Analyse la position du curseur relative au conteneur scrollable et
 * indique de combien scroller (px/frame). Utilisé pour auto-scroller
 * horizontalement pendant un drag près des bords.
 * @returns {number}  -N (scroller vers la gauche), +N (droite), 0 (aucun).
 */
function autoScrollAmount({ clientX, boundsLeft, boundsRight, edge = 60, maxSpeed = 24 }) {
  if (clientX < boundsLeft + edge) {
    const t = 1 - (clientX - boundsLeft) / edge;
    return -Math.max(2, Math.round(maxSpeed * Math.max(0, Math.min(1, t))));
  }
  if (clientX > boundsRight - edge) {
    const t = 1 - (boundsRight - clientX) / edge;
    return Math.max(2, Math.round(maxSpeed * Math.max(0, Math.min(1, t))));
  }
  return 0;
}

// Réplique locale du chevauchement horaire pour éviter la dépendance
// circulaire avec groupPlanningAvailability.js.
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

module.exports = { canDrag, classifyDrop, buildDragPayload, autoScrollAmount };
