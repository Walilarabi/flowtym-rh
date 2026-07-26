/**
 * Logique pure de post-traitement d'une affectation appliquée.
 *
 * `group_move_apply` (SQL) écrit dans la source de vérité `staff_planning`.
 * MAIS le rendu du planning établissement ne montre un collaborateur d'un
 * autre hôtel QUE s'il apparaît dans `monthExtras` = intersection de :
 *   - employee_hotel_assignments(target_hotel_id, active=true)
 *   - employee_extra_activations(hotel_id, year, month, active=true)
 *
 * Ce module calcule, à partir des slots de la proposition, la liste
 * (year, month) des activations extras à créer côté destination pour rendre
 * la mission visible. C'est de la donnée dérivée, testable sans DOM ni RPC.
 */

/**
 * Retourne la liste dédupliquée [{year, month}] couverte par les slots.
 * Month est 1-based (comme l'API metier et la table employee_extra_activations).
 *
 * @param {Array<{date:string}>} slots
 * @returns {Array<{year:number, month:number}>}
 */
function monthsCoveredBySlots(slots) {
  const seen = new Set();
  const out = [];
  (slots || []).forEach(s => {
    if (!s || !s.date) return;
    const d = new Date(s.date);
    if (isNaN(d.getTime())) return;
    const y = d.getFullYear(), m = d.getMonth() + 1;
    const key = y + '-' + m;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ year: y, month: m });
  });
  return out;
}

/**
 * Construit l'ordre des appels de post-traitement de visibilité extra.
 * Rendu déterministe — utile pour comparer l'intention en test sans
 * intervenir sur les I/O.
 *
 * @param {Object} p
 *   employeeId, fromHotelId, destHotelId, slots
 * @returns {Array<{op:string, args:Array}>}
 */
function buildVisibilityPlan(p) {
  const calls = [];
  calls.push({
    op: 'addHotelAssignment',
    args: [p.employeeId, p.fromHotelId, p.destHotelId,
           'Renfort inter-hôtels — Planning Groupe', null],
  });
  monthsCoveredBySlots(p.slots).forEach(({ year, month }) => {
    calls.push({
      op: 'setExtraActivation',
      args: [p.destHotelId, p.employeeId, year, month, null, null, true,
             'Renfort inter-hôtels appliqué depuis le Planning Groupe'],
    });
  });
  return calls;
}

module.exports = { monthsCoveredBySlots, buildVisibilityPlan };
