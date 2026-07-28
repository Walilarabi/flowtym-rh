'use strict';
const {
  hotelStatusBadge, subscriptionStatusBadge, trialDaysRemaining,
  fmtMoney, fmtNum, groupNameOr, sortRows, errorLabel,
} = require('./lib/adminHelpers');

describe('Super Admin — hotelStatusBadge()', () => {
  test('mappe chaque statut connu vers un libellé et une classe', () => {
    expect(hotelStatusBadge('active')).toEqual({ label: 'Actif', cls: 'green' });
    expect(hotelStatusBadge('suspended')).toEqual({ label: 'Suspendu', cls: 'red' });
    expect(hotelStatusBadge('draft')).toEqual({ label: 'Brouillon', cls: 'gray' });
    expect(hotelStatusBadge('archived')).toEqual({ label: 'Archivé', cls: 'gray' });
  });
  test('statut inconnu retombe sur la valeur brute avec classe grise', () => {
    expect(hotelStatusBadge('mystere')).toEqual({ label: 'mystere', cls: 'gray' });
  });
  test('statut vide/null retombe sur un tiret', () => {
    expect(hotelStatusBadge(null).label).toBe('—');
    expect(hotelStatusBadge(undefined).label).toBe('—');
  });
});

describe('Super Admin — subscriptionStatusBadge()', () => {
  test('essai est mis en avant (ambre)', () => {
    expect(subscriptionStatusBadge('trial')).toEqual({ label: 'Essai', cls: 'amber' });
  });
  test('résilié et expiré sont distincts mais tous deux neutres', () => {
    expect(subscriptionStatusBadge('cancelled').label).toBe('Résilié');
    expect(subscriptionStatusBadge('expired').label).toBe('Expiré');
    expect(subscriptionStatusBadge('cancelled').cls).toBe('gray');
  });
});

describe('Super Admin — trialDaysRemaining()', () => {
  const now = new Date('2026-07-28T12:00:00Z').getTime();
  test('date future retourne un nombre de jours positif', () => {
    expect(trialDaysRemaining('2026-08-07T12:00:00Z', now)).toBe(10);
  });
  test('date passée retourne un nombre négatif (essai expiré)', () => {
    expect(trialDaysRemaining('2026-07-20T12:00:00Z', now)).toBe(-8);
  });
  test('absence de date retourne null', () => {
    expect(trialDaysRemaining(null, now)).toBeNull();
    expect(trialDaysRemaining(undefined, now)).toBeNull();
  });
  test('date invalide retourne null plutôt que NaN', () => {
    expect(trialDaysRemaining('pas-une-date', now)).toBeNull();
  });
});

describe('Super Admin — fmtMoney() / fmtNum()', () => {
  test('formate en euros par défaut', () => {
    expect(fmtMoney(1234)).toContain('€');
    expect(fmtMoney(1234)).toContain('1');
  });
  test('montant vide/null devient 0 €', () => {
    expect(fmtMoney(null)).toBe(fmtMoney(0));
  });
  test('devise différente est respectée', () => {
    expect(fmtMoney(10, 'USD')).toContain('USD');
  });
  test('fmtNum gère les valeurs manquantes sans planter', () => {
    expect(fmtNum(undefined)).toBe('0');
  });
});

describe('Super Admin — groupNameOr()', () => {
  test('nom vide/null/blanc retombe sur le placeholder', () => {
    expect(groupNameOr(null)).toBe('(sans nom)');
    expect(groupNameOr('')).toBe('(sans nom)');
    expect(groupNameOr('   ')).toBe('(sans nom)');
  });
  test('nom renseigné est conservé tel quel', () => {
    expect(groupNameOr('Boudaa Hotels')).toBe('Boudaa Hotels');
  });
});

describe('Super Admin — sortRows()', () => {
  const rows = [{ name: 'Vendome' }, { name: 'Aix' }, { name: null }, { name: 'Havre' }];
  test('tri ascendant, valeurs nulles en dernier', () => {
    expect(sortRows(rows, 'name', 'asc').map(r => r.name)).toEqual(['Aix', 'Havre', 'Vendome', null]);
  });
  test('tri descendant, valeurs nulles toujours en dernier', () => {
    expect(sortRows(rows, 'name', 'desc').map(r => r.name)).toEqual(['Vendome', 'Havre', 'Aix', null]);
  });
  test('ne mute pas le tableau original', () => {
    const original = [...rows];
    sortRows(rows, 'name', 'asc');
    expect(rows).toEqual(original);
  });
});

describe('Super Admin — errorLabel()', () => {
  test('traduit les codes RPC connus en messages FR', () => {
    expect(errorLabel('NOM_VIDE')).toBe('Le nom est requis.');
    expect(errorLabel('CODE_EXISTANT')).toBe('Ce code hôtel existe déjà.');
    expect(errorLabel('HOTEL_INTROUVABLE')).toBe('Hôtel introuvable.');
  });
  test('GROUPE_NON_VIDE conserve le détail (nombre d\'hôtels)', () => {
    expect(errorLabel("GROUPE_NON_VIDE : détachez d'abord les 2 hôtel(s) rattaché(s)"))
      .toBe("détachez d'abord les 2 hôtel(s) rattaché(s)");
  });
  test('message inconnu est renvoyé tel quel', () => {
    expect(errorLabel('boom')).toBe('boom');
  });
  test('message absent retombe sur un message générique', () => {
    expect(errorLabel(undefined)).toBe('Une erreur est survenue.');
  });
});
