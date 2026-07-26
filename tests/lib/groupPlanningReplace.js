/**
 * Logique pure du parcours « Modifier l'affectation ».
 *
 * Décide si la confirmation d'une affectation doit être un create ou un
 * replace atomique, et normalise les erreurs technique → messages fonctionnels.
 * Réplique côté test de _gpReplaceOldId + _fnErrorMsg (index.html).
 */

/**
 * Retourne le plan d'appel BE à exécuter selon l'état du flow.
 *
 * @param {Object} params
 *   replaceOldId    string|null — proposition à remplacer (Modifier) ou null (Créer)
 *   payload         charge utile calculée depuis le formulaire
 *   idempotencyKey  clé pour l'appel (idempotence côté serveur)
 * @returns {{op:'create'|'replace', calls:Array<{name:string, args:Array}>}}
 */
function planConfirmCall({ replaceOldId, payload, idempotencyKey }) {
  if (!payload) return { op: 'noop', calls: [] };
  const key = String(idempotencyKey || '');
  if (replaceOldId) {
    return {
      op: 'replace',
      calls: [{ name: 'gmpReplaceApplied', args: [replaceOldId, payload, 'replace_' + key] }],
    };
  }
  return {
    op: 'create',
    calls: [
      { name: 'gmpCreate',          args: [payload] },
      { name: 'gmpSubmit',          args: ['<id-from-create>'] },
      { name: 'gmpApprovalDecide',  args: ['<id-from-create>', true, 'Confirmation directeur groupe'] },
      { name: 'gmpApply',           args: ['<id-from-create>', key] },
    ],
  };
}

/**
 * Cartographie technique → message fonctionnel. Cf. _fnErrorMsg (index.html).
 * @param {string|Error} err
 * @param {string} fallback
 * @returns {string}
 */
function functionalErrorMessage(err, fallback) {
  const raw = (err && err.message ? err.message : String(err || '')) || '';
  const map = [
    [/Proposition introuvable/i,                    'Cette affectation n\'existe plus.'],
    [/Seule une (affectation|proposition) appliquée peut/i, 'Cette affectation a déjà été modifiée ou annulée.'],
    [/Accès refusé/i,                               'Vous n\'avez pas les droits nécessaires sur cet établissement.'],
    [/Blocage non déroge|Blocage non dérogé/i,      'La nouvelle affectation est bloquée par des contraintes.'],
    [/Proposition bloquée/i,                        'La nouvelle affectation est bloquée par des contraintes.'],
    [/Données modifiées depuis la simulation/i,     'Les données ont changé, la vérification est nécessaire à nouveau.'],
    [/Proposition concurrente prioritaire/i,        'Une autre affectation concurrente doit être traitée en premier.'],
    [/schema cache|not find the function/i,         'Fonctionnalité indisponible actuellement — rechargez la page.'],
    [/déjà en cours pour cette clé/i,               'Opération déjà en cours, veuillez patienter.'],
    [/ensure_visibility: service.* introuvable/i,   'Le service de destination est inconnu de cet établissement.'],
    [/service.* introuvable sur l/i,                'Le service de destination est inconnu de cet établissement.'],
    [/JWT|permission denied|RLS/i,                  'Vous n\'avez pas les droits nécessaires.'],
  ];
  for (const [rx, msg] of map) { if (rx.test(raw)) return msg; }
  return fallback || 'Une erreur est survenue.';
}

module.exports = { planConfirmCall, functionalErrorMessage };
