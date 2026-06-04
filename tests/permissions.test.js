'use strict';
const { canSee, canFicheFull, canManageUsers } = require('./lib/permissions');

describe('Matrice des permissions — canSee()', () => {
  test('direction voit tous les onglets', () => {
    expect(canSee('direction', 'planning')).toBe(true);
    expect(canSee('direction', 'payroll')).toBe(true);
    expect(canSee('direction', 'config')).toBe(true);
    expect(canSee('direction', 'recruitment')).toBe(true);
  });

  test('femme_de_chambre voit uniquement dashboard et planning', () => {
    expect(canSee('femme_de_chambre', 'dashboard')).toBe(true);
    expect(canSee('femme_de_chambre', 'planning')).toBe(true);
    expect(canSee('femme_de_chambre', 'absences')).toBe(false);
    expect(canSee('femme_de_chambre', 'payroll')).toBe(false);
    expect(canSee('femme_de_chambre', 'config')).toBe(false);
  });

  test('reception voit absences mais pas payroll', () => {
    expect(canSee('reception', 'absences')).toBe(true);
    expect(canSee('reception', 'payroll')).toBe(false);
    expect(canSee('reception', 'contracts')).toBe(false);
  });

  test('comptabilite voit tracking et payroll', () => {
    expect(canSee('comptabilite', 'tracking')).toBe(true);
    expect(canSee('comptabilite', 'payroll')).toBe(true);
    expect(canSee('comptabilite', 'planning')).toBe(false);
  });

  test('rôle inconnu retourne false', () => {
    expect(canSee('hacker', 'dashboard')).toBe(false);
    expect(canSee(null, 'dashboard')).toBe(false);
    expect(canSee(undefined, 'planning')).toBe(false);
  });
});

describe('Matrice des permissions — canFicheFull()', () => {
  test('direction et admin_hotel voient la fiche complète', () => {
    expect(canFicheFull('direction')).toBe(true);
    expect(canFicheFull('admin_hotel')).toBe(true);
    expect(canFicheFull('comptabilite')).toBe(true);
  });

  test('reception et gouvernante ne voient pas la fiche complète', () => {
    expect(canFicheFull('reception')).toBe(false);
    expect(canFicheFull('gouvernante')).toBe(false);
    expect(canFicheFull('femme_de_chambre')).toBe(false);
  });
});

describe('Matrice des permissions — canManageUsers()', () => {
  test('seuls direction et admin_hotel peuvent gérer les accès', () => {
    expect(canManageUsers('direction')).toBe(true);
    expect(canManageUsers('admin_hotel')).toBe(true);
    expect(canManageUsers('comptabilite')).toBe(false);
    expect(canManageUsers('reception')).toBe(false);
  });
});
