/**
 * Logique pure d'affichage d'un collaborateur dans le Planning Groupe :
 * badge de statut, couleur du voyant, classe du nom (grisé ou non).
 * Miroir de gpStatusBadge / gpDotClass / la construction de nameCls dans
 * gpBuildCollab (index.html).
 */

/**
 * Badge affiché à droite du nom. Repos (code vide, non extra) affiche
 * désormais un badge explicite « Repos » — auparavant aucun badge.
 * @returns {{cls:string,label:string}|null}
 */
function statusBadge(code, isExtra) {
  if (isExtra) return { cls: 'extra', label: 'Extra' };
  if (!code) return { cls: 'rest', label: 'Repos' };
  const map = {
    CP: { cls: 'cp', label: 'CP' }, MAL: { cls: 'mal', label: 'Maladie' },
    ABS: { cls: 'abs', label: 'Abs.' }, MAT: { cls: 'mat', label: 'Mat.' },
    PAT: { cls: 'mat', label: 'Pat.' }, CSS: { cls: 'abs', label: 'Sans solde' },
    AE: { cls: 'abs', label: 'Except.' }, RTT: { cls: 'rest', label: 'RTT' },
    REC: { cls: 'rest', label: 'Récup.' }, F: { cls: 'rest', label: 'Férié' },
    FORM: { cls: 'rest', label: 'Formation' },
  };
  return map[code] || null;
}

/**
 * Classe CSS du nom du collaborateur — grisé pour tout statut non travaillé
 * (y compris Repos), noir uniquement si le collaborateur travaille (P/PE/MAD).
 * @param {boolean} isWorking
 */
function nameClass(isWorking) {
  return isWorking ? 'nm' : 'nm mut';
}

/**
 * Couleur du voyant : vert=travaille, gris=repos, rouge=absence/congé payé.
 * @param {string} code
 * @param {(code:string)=>boolean} isWorkingFn
 * @param {Object} cmap  {CODE: {cat}}
 */
function dotClass(code, isWorkingFn, cmap) {
  if (isWorkingFn(code)) return 'g';
  if (!code) return 'q';
  const cat = cmap[code] ? cmap[code].cat : null;
  if (cat === 'abs' || cat === 'paid') return 'r';
  return 'q';
}

/**
 * Le bouton Affecter est totalement absent (pas seulement désactivé) pour
 * les collaborateurs en Maladie ou Absence — ils ne doivent plus pouvoir
 * être sélectionnés pour une mission depuis le Planning Groupe.
 * @param {string} status  code CMAP du jour ('' = Repos)
 */
function shouldHideAffectButton(status) {
  return status === 'MAL' || status === 'ABS';
}

/**
 * Filtre "statut du jour" de la toolbar Planning Groupe.
 * @param {string} collabStatus  status du collaborateur ('' = Repos)
 * @param {string} filterValue   '' (aucun filtre) | 'REPOS' | code CMAP
 */
function matchesDayStatusFilter(collabStatus, filterValue) {
  if (!filterValue) return true;
  if (filterValue === 'REPOS') return !collabStatus;
  return collabStatus === filterValue;
}

module.exports = { statusBadge, nameClass, dotClass, shouldHideAffectButton, matchesDayStatusFilter };
