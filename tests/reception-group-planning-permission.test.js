'use strict';
/**
 * Régression P0 — onglet « Groupe » invisible pour la Réception d'un hôtel membre d'un groupe.
 *
 * DEFAULT_PERMISSIONS.reception (index.html) n'a jamais eu d'entrée group_planning : canDo()
 * renvoyait false, masquant le bouton « Groupe » du Planning quelle que soit la correction
 * backend (sql/98-100). Demande produit explicite : la Réception d'un hôtel membre d'un groupe
 * doit pouvoir CONSULTER (jamais créer/approuver) le Planning Groupe de son propre groupe.
 *
 * Ces tests lisent le fichier réel (pas une copie mirroir) pour garantir qu'aucune régression
 * future ne retire cette permission sans passer par une décision explicite.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

function extractBlock(source, startMarker, endMarkerFromStart) {
  const start = source.indexOf(startMarker);
  if (start === -1) throw new Error(`Marqueur introuvable dans index.html : ${startMarker}`);
  const end = source.indexOf(endMarkerFromStart, start);
  if (end === -1) throw new Error(`Fin de bloc introuvable après : ${startMarker}`);
  return source.slice(start, end + endMarkerFromStart.length);
}

// MODULE_LABELS + ALL_MODULES + PERM_ACTIONS + helpers (_p/_0/_v/_vc/_all/_fullAccess) +
// DEFAULT_PERMISSIONS + effectivePerms/canDo/canSee : bloc contigu dans index.html.
const src = extractBlock(indexHtml, 'const MODULE_LABELS = {', '\nfunction canDo(tab,action){if(!myRole)return false;return effectivePerms(myRole,tab)[action]===true;}');

// `hotelPerms` est déclaré via `let` dans le bloc extrait (index.html:1992) : une affectation
// sur sandbox.hotelPerms AVANT l'exécution du script serait masquée par cette re-déclaration
// lexicale. On expose donc un setter fermé sur le binding réel plutôt que de préaffecter.
const sandbox = { myRole: null, module: { exports: {} } };
vm.createContext(sandbox);
vm.runInContext(
  src + '\nfunction __setHotelPerms(v){hotelPerms=v;}\nmodule.exports = { DEFAULT_PERMISSIONS, effectivePerms, canDo, canSee, __setHotelPerms };',
  sandbox
);
const { DEFAULT_PERMISSIONS, effectivePerms, canDo, canSee, __setHotelPerms } = sandbox.module.exports;

describe('Réception — permission group_planning (régression sql/100 + index.html)', () => {
  test('DEFAULT_PERMISSIONS.reception.group_planning.view est true', () => {
    expect(DEFAULT_PERMISSIONS.reception.group_planning).toBeDefined();
    expect(DEFAULT_PERMISSIONS.reception.group_planning.view).toBe(true);
  });

  test('DEFAULT_PERMISSIONS.reception.group_planning reste en lecture seule (create/edit/delete false)', () => {
    const p = DEFAULT_PERMISSIONS.reception.group_planning;
    expect(p.create).toBe(false);
    expect(p.edit).toBe(false);
    expect(p.delete).toBe(false);
  });

  test('canDo("group_planning","view") est true pour un myRole=reception sans surcharge hôtel', () => {
    sandbox.myRole = 'reception';
    __setHotelPerms(null);
    expect(canDo('group_planning', 'view')).toBe(true);
  });

  test('canDo("group_planning","view") reste false si aucun rôle résolu (myRole null)', () => {
    sandbox.myRole = null;
    __setHotelPerms(null);
    expect(canDo('group_planning', 'view')).toBe(false);
  });

  test('une surcharge hotel_role_permissions explicite reste prioritaire sur le défaut', () => {
    sandbox.myRole = 'reception';
    __setHotelPerms({ reception: { group_planning: { view: false, create: false, edit: false, delete: false, export: false, validate: false, sensitive: false } } });
    expect(canDo('group_planning', 'view')).toBe(false);
  });

  test("rôles sans droit d'écriture métier (femme_de_chambre, breakfast) n'ont toujours pas group_planning", () => {
    expect(DEFAULT_PERMISSIONS.femme_de_chambre.group_planning).toBeUndefined();
    expect(DEFAULT_PERMISSIONS.breakfast.group_planning).toBeUndefined();
  });
});
