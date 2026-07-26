/**
 * Logique pure de résolution "cette cellule provient-elle d'un déplacement ?".
 *
 * Réplique côté test de findMoveRowInPlanning (index.html). Sert de spec
 * exécutable pour le comportement client attendu, et permet de valider les
 * cas limites (row inexistante, source_proposal_id null, etc.).
 */

function findMoveRow(planningRows, employeeId, day, currentHotelId) {
  const row = (planningRows || []).find(r => r.employee_id === employeeId && r.day === day);
  if (row && row.source_proposal_id) {
    return {
      proposal_id: row.source_proposal_id,
      employee_id: employeeId,
      day,
      hotel_id: currentHotelId,
      origin_hotel_id: row.origin_hotel_id || null,
    };
  }
  return null;
}

/**
 * Spec de l'appel BE.gmpCancelApplied : décide si on annule un segment ou
 * tout le déplacement selon les paramètres UI.
 */
function planCancelCall({ proposalId, day, scope }) {
  if (!proposalId) return { call: null, reason: 'proposition manquante' };
  if (scope === 'segment' && !day) {
    return { call: null, reason: 'jour requis pour un scope segment' };
  }
  return {
    call: {
      name: 'gmpCancelApplied',
      args: [proposalId, scope === 'segment' ? day : null],
    },
  };
}

module.exports = { findMoveRow, planCancelCall };
