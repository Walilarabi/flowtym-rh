'use strict';
const {
  hotelStatusBadge, subscriptionStatusBadge, trialDaysRemaining,
  fmtMoney, fmtNum, groupNameOr, sortRows, errorLabel,
  attributionTypeBadge, addonStatusBadge, causeLabel, eventTypeLabel, actionsForStatus,
  hotelActionsForStatus,
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

describe('Super Admin — attributionTypeBadge()', () => {
  test('régularisation interne est mise en avant (ambre)', () => {
    expect(attributionTypeBadge('internal_regularization')).toEqual({ label: 'Régularisation interne', cls: 'amber' });
  });
  test('commercial est neutre (gris)', () => {
    expect(attributionTypeBadge('commercial')).toEqual({ label: 'Commercial', cls: 'gray' });
  });
  test('valeur inconnue retombe sur la valeur brute', () => {
    expect(attributionTypeBadge('mystere').label).toBe('mystere');
  });
});

describe('Super Admin — addonStatusBadge()', () => {
  test('actif est vert, retiré est gris', () => {
    expect(addonStatusBadge('active')).toEqual({ label: 'Actif', cls: 'green' });
    expect(addonStatusBadge('cancelled')).toEqual({ label: 'Retiré', cls: 'gray' });
  });
});

describe('Super Admin — causeLabel()', () => {
  test('traduit les 13 codes de divergence connus en français', () => {
    expect(causeLabel('missing_main_subscription')).toBe('Aucun abonnement principal');
    expect(causeLabel('expired_trial')).toBe("Période d'essai expirée");
    expect(causeLabel('addon_missing_app_mapping')).toBe('Option active sans application associée');
  });
  test('code inconnu est renvoyé tel quel (jamais masqué)', () => {
    expect(causeLabel('futur_code_inconnu')).toBe('futur_code_inconnu');
  });
});

describe('Super Admin — eventTypeLabel()', () => {
  test('traduit les événements de cycle de vie', () => {
    expect(eventTypeLabel('plan_changed')).toBe('Changement de plan');
    expect(eventTypeLabel('trial_extended')).toBe('Essai prolongé');
    expect(eventTypeLabel('expired_automatic')).toBe('Expiration automatique');
  });
  test('code inconnu est renvoyé tel quel', () => {
    expect(eventTypeLabel('code_futur')).toBe('code_futur');
  });
});

describe('Super Admin — actionsForStatus()', () => {
  test('trial : prolongation, conversion, changement de plan et résiliation possibles, pas de suspension', () => {
    const a = actionsForStatus('trial');
    expect(a.extendTrial).toBe(true);
    expect(a.convertTrial).toBe(true);
    expect(a.changePlan).toBe(true);
    expect(a.scheduleCancel).toBe(true);
    expect(a.cancelNow).toBe(true);
    expect(a.suspend).toBe(false);
    expect(a.reactivate).toBe(false);
  });
  test('active : suspension, renouvellement, changement de plan possibles, pas de conversion d\'essai', () => {
    const a = actionsForStatus('active');
    expect(a.suspend).toBe(true);
    expect(a.renew).toBe(true);
    expect(a.changePlan).toBe(true);
    expect(a.extendTrial).toBe(false);
    expect(a.convertTrial).toBe(false);
  });
  test('suspended : réactivation et changement de plan possibles, pas de suspension ni de renouvellement', () => {
    const a = actionsForStatus('suspended');
    expect(a.reactivate).toBe(true);
    expect(a.changePlan).toBe(true);
    expect(a.suspend).toBe(false);
    expect(a.renew).toBe(false);
  });
  test('expired : seule la résiliation immédiate reste pertinente', () => {
    const a = actionsForStatus('expired');
    expect(a.cancelNow).toBe(true);
    expect(a.suspend).toBe(false);
    expect(a.changePlan).toBe(false);
    expect(a.reactivate).toBe(false);
  });
  test('cancelled : statut final, aucune action de cycle de vie', () => {
    const a = actionsForStatus('cancelled');
    expect(Object.values(a).every(v => v === false)).toBe(true);
  });
});

describe('Super Admin — hotelActionsForStatus() (distinct de actionsForStatus, jamais confondu)', () => {
  test('draft : activable, non suspendable, archivable, non restaurable', () => {
    expect(hotelActionsForStatus('draft')).toEqual({ canActivate: true, canSuspend: false, canArchive: true, canRestore: false });
  });
  test('active : non activable, suspendable, archivable, non restaurable', () => {
    expect(hotelActionsForStatus('active')).toEqual({ canActivate: false, canSuspend: true, canArchive: true, canRestore: false });
  });
  test('suspended : activable, non suspendable (déjà suspendu), archivable', () => {
    const a = hotelActionsForStatus('suspended');
    expect(a.canActivate).toBe(true);
    expect(a.canSuspend).toBe(false);
    expect(a.canArchive).toBe(true);
  });
  test('archived : seule la restauration est proposée', () => {
    expect(hotelActionsForStatus('archived')).toEqual({ canActivate: true, canSuspend: false, canArchive: false, canRestore: true });
  });
});

describe('Super Admin — filtres Hôtels (logique pure reproduite)', () => {
  const hotels = [
    { id: 'h1', name: 'Alpha', group_id: 'g1', _sub: { plan_id: 'p1', status: 'active' } },
    { id: 'h2', name: 'Beta', group_id: null, _sub: { plan_id: 'p2', status: 'trial', trial_ends_at: '2026-08-01T00:00:00Z' } },
    { id: 'h3', name: 'Gamma', group_id: 'g1', _sub: null },
  ];
  test('filtre par groupe ne retourne que les hôtels rattachés', () => {
    expect(hotels.filter(h => h.group_id === 'g1').map(h => h.name)).toEqual(['Alpha', 'Gamma']);
  });
  test('filtre "sans abonnement" isole les hôtels autonomes sans _sub', () => {
    expect(hotels.filter(h => !h._sub).map(h => h.name)).toEqual(['Gamma']);
  });
  test('filtre par statut d\'abonnement', () => {
    expect(hotels.filter(h => h._sub?.status === 'trial').map(h => h.name)).toEqual(['Beta']);
  });
  test('hôtel autonome (group_id null) affiché distinctement d\'un hôtel de groupe', () => {
    const autonomous = hotels.filter(h => !h.group_id);
    expect(autonomous.map(h => h.name)).toEqual(['Beta']);
  });
});
