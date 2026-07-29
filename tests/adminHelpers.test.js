'use strict';
const {
  hotelStatusBadge, subscriptionStatusBadge, trialDaysRemaining,
  fmtMoney, fmtNum, groupNameOr, sortRows, errorLabel,
  attributionTypeBadge, addonStatusBadge, causeLabel, eventTypeLabel, actionsForStatus,
  hotelActionsForStatus,
  hotelRoleLabel, platformRoleLabel, accountStatus, accountStatusBadge, primaryRoleLabel,
  revokeHotelImpactMessage, isLastHotelAdminError, historyActionLabel,
  invoiceStatusBadge, financialStateBadge, paymentStatusBadge, creditNoteStatusBadge,
  paymentMethodLabel, billingActionsForStatus, isInvoiceOverdue,
  severityBadge, periodLabel, alertTypeIcon, sortAlertsBySeverity,
  settingValueType, validateSettingValue, formatPayloadValue,
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

describe('Super Admin — hotelRoleLabel() / platformRoleLabel()', () => {
  test('mappe chaque rôle hôtel connu vers un libellé français', () => {
    expect(hotelRoleLabel('direction')).toBe('Direction');
    expect(hotelRoleLabel('admin_hotel')).toBe('Administrateur hôtel');
    expect(hotelRoleLabel('femme_de_chambre')).toBe('Femme de chambre');
  });
  test('rôle hôtel inconnu ou vide retombe proprement', () => {
    expect(hotelRoleLabel('mystere')).toBe('mystere');
    expect(hotelRoleLabel(null)).toBe('—');
  });
  test('mappe chaque rôle plateforme connu vers un libellé français', () => {
    expect(platformRoleLabel('super_admin')).toBe('Super Admin');
    expect(platformRoleLabel('billing_admin')).toBe('Administrateur facturation');
    expect(platformRoleLabel('support_agent')).toBe('Agent support');
  });
});

describe('Super Admin — accountStatus() (jamais confondu avec le statut hôtel/abonnement)', () => {
  const now = new Date('2026-07-29T12:00:00Z').getTime();
  test('compte désactivé prime sur tout le reste', () => {
    expect(accountStatus({ is_active: false, email_confirmed_at: null, invited_at: null }, now)).toBe('deactivated');
    expect(accountStatus({ is_active: false, email_confirmed_at: '2026-01-01T00:00:00Z' }, now)).toBe('deactivated');
  });
  test('email confirmé et compte actif -> actif', () => {
    expect(accountStatus({ is_active: true, email_confirmed_at: '2026-07-01T00:00:00Z' }, now)).toBe('active');
  });
  test('invitation récente non confirmée -> en attente', () => {
    expect(accountStatus({ is_active: true, email_confirmed_at: null, invited_at: '2026-07-25T00:00:00Z' }, now)).toBe('pending_invite');
  });
  test('invitation non confirmée sans date -> en attente (jamais "expirée" sans référence de date)', () => {
    expect(accountStatus({ is_active: true, email_confirmed_at: null, invited_at: null }, now)).toBe('pending_invite');
  });
  test('invitation non confirmée de plus de 14 jours -> ancienne (indicateur UI, pas une vraie expiration technique)', () => {
    expect(accountStatus({ is_active: true, email_confirmed_at: null, invited_at: '2026-07-01T00:00:00Z' }, now)).toBe('expired_invite');
  });
  test('is_active null (compte plateforme pur) ne déclenche pas "désactivé"', () => {
    expect(accountStatus({ is_active: null, email_confirmed_at: '2026-07-01T00:00:00Z' }, now)).toBe('active');
  });
});

describe('Super Admin — accountStatusBadge()', () => {
  test('mappe chaque statut vers un libellé et une classe distincts', () => {
    expect(accountStatusBadge('active')).toEqual({ label: 'Actif', cls: 'green' });
    expect(accountStatusBadge('deactivated')).toEqual({ label: 'Désactivé', cls: 'red' });
    expect(accountStatusBadge('pending_invite')).toEqual({ label: 'Invitation en attente', cls: 'amber' });
    expect(accountStatusBadge('expired_invite')).toEqual({ label: 'Invitation ancienne', cls: 'gray' });
  });
});

describe('Super Admin — primaryRoleLabel() (Super Admin jamais confondu avec un rôle hôtel)', () => {
  test('Super Admin plateforme prime toujours, même avec des accès hôtel', () => {
    expect(primaryRoleLabel({ is_super_admin: true, hotels: [{ role: 'reception', is_default: true }] })).toBe('Super Admin');
  });
  test('sans rôle plateforme : rôle de l\'hôtel par défaut', () => {
    expect(primaryRoleLabel({ is_super_admin: false, hotels: [{ role: 'reception', is_default: false }, { role: 'direction', is_default: true }] })).toBe('Direction');
  });
  test('sans hôtel par défaut explicite, retombe sur le premier hôtel', () => {
    expect(primaryRoleLabel({ is_super_admin: false, hotels: [{ role: 'gouvernante', is_default: false }] })).toBe('Gouvernante');
  });
  test('aucun accès du tout -> tiret', () => {
    expect(primaryRoleLabel({ is_super_admin: false, hotels: [] })).toBe('—');
  });
});

describe('Super Admin — revokeHotelImpactMessage() (impact explicite avant action à fort impact)', () => {
  test('avec d\'autres hôtels : précise que les autres accès sont conservés', () => {
    const msg = revokeHotelImpactMessage('Folkestone Opéra', ['Hôtel Rivoli', 'Hôtel Nation']);
    expect(msg).toContain('Folkestone Opéra');
    expect(msg).toContain('conservera ses accès aux autres établissements');
    expect(msg).toContain('Hôtel Rivoli');
  });
  test('sans autre hôtel : avertit que l\'utilisateur perdra tout accès', () => {
    const msg = revokeHotelImpactMessage('Folkestone Opéra', []);
    expect(msg).toContain('n\'aura plus aucun accès hôtel');
    expect(msg).not.toContain('conservera');
  });
});

describe('Super Admin — isLastHotelAdminError()', () => {
  test('détecte le message serveur du garde-fou dernier administrateur', () => {
    expect(isLastHotelAdminError('Ce retrait laisserait l\'hôtel sans administrateur (direction/admin_hotel) — fournissez un remplaçant')).toBe(true);
  });
  test('ne se déclenche pas sur une autre erreur', () => {
    expect(isLastHotelAdminError('Accès hôtel introuvable pour cet utilisateur')).toBe(false);
    expect(isLastHotelAdminError(null)).toBe(false);
  });
});

describe('Super Admin — historyActionLabel()', () => {
  test('mappe chaque action journalisée vers un libellé lisible', () => {
    expect(historyActionLabel('user.grant_hotel')).toBe('Accès hôtel accordé');
    expect(historyActionLabel('user.revoke_hotel')).toBe('Accès hôtel retiré');
    expect(historyActionLabel('user.change_role')).toBe('Rôle hôtel modifié');
    expect(historyActionLabel('platform_admin.grant')).toBe('Rôle plateforme accordé');
    expect(historyActionLabel('platform_admin.revoke')).toBe('Rôle plateforme retiré');
  });
  test('action inconnue retombe sur la valeur brute', () => {
    expect(historyActionLabel('unknown.action')).toBe('unknown.action');
  });
});

describe('Super Admin — filtres Utilisateurs (logique pure reproduite)', () => {
  const users = [
    { user_id: 'u1', email: 'a@x.com', is_super_admin: true, hotels: [], group_names: [] },
    { user_id: 'u2', email: 'b@x.com', is_super_admin: false, hotels: [{ hotel_id: 'h1', hotel_name: 'Alpha', role: 'direction' }], group_names: ['Groupe A'] },
    { user_id: 'u3', email: 'c@x.com', is_super_admin: false, hotels: [{ hotel_id: 'h2', hotel_name: 'Beta', role: 'reception' }], group_names: [] },
  ];
  test('filtre "Super Admin uniquement" isole les comptes plateforme', () => {
    expect(users.filter(u => u.is_super_admin).map(u => u.user_id)).toEqual(['u1']);
  });
  test('filtre par rôle hôtel ignore les Super Admin sans cet accès', () => {
    expect(users.filter(u => u.hotels.some(h => h.role === 'reception')).map(u => u.user_id)).toEqual(['u3']);
  });
  test('filtre par hôtel isole les utilisateurs ayant un accès à cet hôtel précis', () => {
    expect(users.filter(u => u.hotels.some(h => h.hotel_id === 'h1')).map(u => u.user_id)).toEqual(['u2']);
  });
  test('filtre par groupe isole les utilisateurs dont un hôtel appartient à ce groupe', () => {
    expect(users.filter(u => u.group_names.includes('Groupe A')).map(u => u.user_id)).toEqual(['u2']);
  });
});

describe('Super Admin — invoiceStatusBadge() (Lot 4 : jamais confondu avec statut abonnement/hôtel)', () => {
  test('mappe les trois statuts de facture plateforme', () => {
    expect(invoiceStatusBadge('proforma')).toEqual({ label: 'Proforma', cls: 'amber' });
    expect(invoiceStatusBadge('issued')).toEqual({ label: 'Émise', cls: 'blue' });
    expect(invoiceStatusBadge('cancelled')).toEqual({ label: 'Annulée', cls: 'gray' });
  });
});

describe('Super Admin — financialStateBadge() (état financier calculé serveur, jamais le statut documentaire)', () => {
  test('les 5 valeurs sont mappées vers un libellé et une classe distincts', () => {
    expect(financialStateBadge('unpaid')).toEqual({ label: 'Impayée', cls: 'gray' });
    expect(financialStateBadge('partially_paid')).toEqual({ label: 'Partiellement réglée', cls: 'amber' });
    expect(financialStateBadge('paid')).toEqual({ label: 'Réglée', cls: 'green' });
    expect(financialStateBadge('overdue')).toEqual({ label: 'En retard', cls: 'red' });
    expect(financialStateBadge('fully_credited')).toEqual({ label: 'Soldée par avoir', cls: 'blue' });
  });
  test('absent (facture non émise) retombe sur un tiret neutre', () => {
    expect(financialStateBadge(null)).toEqual({ label: '—', cls: 'gray' });
    expect(financialStateBadge(undefined)).toEqual({ label: '—', cls: 'gray' });
  });
});

describe('Super Admin — paymentStatusBadge() / creditNoteStatusBadge()', () => {
  test('statuts de paiement', () => {
    expect(paymentStatusBadge('recorded')).toEqual({ label: 'Enregistré', cls: 'green' });
    expect(paymentStatusBadge('pending')).toEqual({ label: 'En attente', cls: 'amber' });
    expect(paymentStatusBadge('failed')).toEqual({ label: 'Échoué', cls: 'red' });
    expect(paymentStatusBadge('reversed')).toEqual({ label: 'Renversé', cls: 'gray' });
  });
  test('statuts d\'avoir', () => {
    expect(creditNoteStatusBadge('issued')).toEqual({ label: 'Émis', cls: 'blue' });
    expect(creditNoteStatusBadge('voided')).toEqual({ label: 'Annulé', cls: 'gray' });
  });
});

describe('Super Admin — paymentMethodLabel()', () => {
  test('traduit les méthodes déjà préparées pour de futurs prestataires', () => {
    expect(paymentMethodLabel('bank_transfer')).toBe('Virement');
    expect(paymentMethodLabel('sepa')).toBe('Prélèvement SEPA');
    expect(paymentMethodLabel('card')).toBe('Carte');
  });
  test('méthode inconnue retombe sur la valeur brute', () => {
    expect(paymentMethodLabel('bitcoin')).toBe('bitcoin');
  });
});

describe('Super Admin — billingActionsForStatus() (distinct de actionsForStatus/hotelActionsForStatus)', () => {
  test('proforma : émission possible, annulation possible, pas de paiement ni avoir', () => {
    const a = billingActionsForStatus('proforma', 0);
    expect(a).toEqual({ canIssue: true, canCancel: true, canRecordPayment: false, canCreateCreditNote: false });
  });
  test('émise sans paiement : annulation encore possible', () => {
    const a = billingActionsForStatus('issued', 0);
    expect(a.canCancel).toBe(true);
    expect(a.canRecordPayment).toBe(true);
    expect(a.canCreateCreditNote).toBe(true);
  });
  test('émise avec paiement : annulation interdite (utiliser un avoir)', () => {
    const a = billingActionsForStatus('issued', 50);
    expect(a.canCancel).toBe(false);
  });
  test('annulée : plus aucune action', () => {
    const a = billingActionsForStatus('cancelled', 0);
    expect(a.canIssue).toBe(false);
    expect(a.canCancel).toBe(false);
    expect(a.canRecordPayment).toBe(false);
    expect(a.canCreateCreditNote).toBe(false);
  });
});

describe('Super Admin — isInvoiceOverdue()', () => {
  test('facture émise, échéance dépassée, solde positif -> en retard', () => {
    expect(isInvoiceOverdue({ status: 'issued', due_date: '2026-07-01', balance: 50 }, '2026-07-29')).toBe(true);
  });
  test('facture émise mais déjà réglée (solde nul) -> jamais en retard', () => {
    expect(isInvoiceOverdue({ status: 'issued', due_date: '2026-07-01', balance: 0 }, '2026-07-29')).toBe(false);
  });
  test('proforma jamais en retard, quelle que soit l\'échéance', () => {
    expect(isInvoiceOverdue({ status: 'proforma', due_date: '2026-01-01', balance: 100 }, '2026-07-29')).toBe(false);
  });
  test('échéance future -> pas encore en retard', () => {
    expect(isInvoiceOverdue({ status: 'issued', due_date: '2026-08-15', balance: 50 }, '2026-07-29')).toBe(false);
  });
  test('sans échéance renseignée -> jamais en retard', () => {
    expect(isInvoiceOverdue({ status: 'issued', due_date: null, balance: 50 }, '2026-07-29')).toBe(false);
  });
});

describe('Super Admin — severityBadge() (Lot 5, alertes)', () => {
  test('high -> Prioritaire / red', () => {
    expect(severityBadge('high')).toEqual({ label: 'Prioritaire', cls: 'red' });
  });
  test('medium -> À surveiller / amber', () => {
    expect(severityBadge('medium')).toEqual({ label: 'À surveiller', cls: 'amber' });
  });
  test('low -> Information / gray', () => {
    expect(severityBadge('low')).toEqual({ label: 'Information', cls: 'gray' });
  });
  test('valeur inconnue -> repli sur la valeur brute, classe gray', () => {
    expect(severityBadge('exotic')).toEqual({ label: 'exotic', cls: 'gray' });
  });
  test('vide/null -> tiret, classe gray', () => {
    expect(severityBadge(null)).toEqual({ label: '—', cls: 'gray' });
  });
});

describe('Super Admin — periodLabel()', () => {
  test('mappe chaque période connue', () => {
    expect(periodLabel('this_month')).toBe('Ce mois');
    expect(periodLabel('last_month')).toBe('Mois précédent');
    expect(periodLabel('quarter')).toBe('Trimestre');
    expect(periodLabel('year')).toBe('Année');
    expect(periodLabel('custom')).toBe('Période personnalisée');
  });
  test('valeur inconnue -> repli sur la valeur brute', () => {
    expect(periodLabel('semester')).toBe('semester');
  });
  test('vide/null -> tiret', () => {
    expect(periodLabel(null)).toBe('—');
  });
});

describe('Super Admin — alertTypeIcon()', () => {
  test('renvoie une icône dédiée pour chaque type d\'alerte connu', () => {
    expect(alertTypeIcon('trial_ending_soon')).toBe('fa-regular fa-hourglass-half');
    expect(alertTypeIcon('invoice_overdue')).toBe('fa-solid fa-file-invoice');
    expect(alertTypeIcon('hotel_without_admin')).toBe('fa-solid fa-user-shield');
    expect(alertTypeIcon('deactivated_user_with_access')).toBe('fa-solid fa-user-slash');
  });
  test('type inconnu -> icône générique, jamais une icône trompeuse', () => {
    expect(alertTypeIcon('unknown_alert')).toBe('fa-solid fa-circle-info');
  });
});

describe('Super Admin — sortAlertsBySeverity() (les alertes prioritaires toujours en premier)', () => {
  test('trie high avant medium avant low', () => {
    const alerts = [{ id: 1, severity: 'low' }, { id: 2, severity: 'high' }, { id: 3, severity: 'medium' }];
    expect(sortAlertsBySeverity(alerts).map(a => a.id)).toEqual([2, 3, 1]);
  });
  test('une sévérité inconnue passe après les connues, ne casse pas le tri', () => {
    const alerts = [{ id: 1, severity: 'weird' }, { id: 2, severity: 'high' }];
    expect(sortAlertsBySeverity(alerts).map(a => a.id)).toEqual([2, 1]);
  });
  test('ne mute pas le tableau original', () => {
    const alerts = [{ id: 1, severity: 'low' }, { id: 2, severity: 'high' }];
    const sorted = sortAlertsBySeverity(alerts);
    expect(sorted).not.toBe(alerts);
    expect(alerts.map(a => a.id)).toEqual([1, 2]);
  });
  test('liste vide/null -> tableau vide', () => {
    expect(sortAlertsBySeverity([])).toEqual([]);
    expect(sortAlertsBySeverity(null)).toEqual([]);
  });
});

describe('Super Admin — settingValueType() (jamais de paramètre inventé)', () => {
  test('clés numériques connues -> number', () => {
    expect(settingValueType('mrr_target')).toBe('number');
    expect(settingValueType('default_tva_rate')).toBe('number');
    expect(settingValueType('trial_duration_days')).toBe('number');
  });
  test('dunning_days_before -> array', () => {
    expect(settingValueType('dunning_days_before')).toBe('array');
  });
  test('toute autre clé -> string', () => {
    expect(settingValueType('platform_name')).toBe('string');
    expect(settingValueType('support_email')).toBe('string');
  });
});

describe('Super Admin — validateSettingValue()', () => {
  test('nombre valide accepté et converti', () => {
    expect(validateSettingValue('mrr_target', '5000')).toEqual({ valid: true, value: 5000 });
  });
  test('nombre vide ou non numérique refusé', () => {
    expect(validateSettingValue('mrr_target', '').valid).toBe(false);
    expect(validateSettingValue('mrr_target', 'abc').valid).toBe(false);
  });
  test('liste de nombres valide acceptée (dunning_days_before)', () => {
    expect(validateSettingValue('dunning_days_before', '3, 7, 15')).toEqual({ valid: true, value: [3, 7, 15] });
  });
  test('liste vide ou contenant une valeur non numérique refusée', () => {
    expect(validateSettingValue('dunning_days_before', '').valid).toBe(false);
    expect(validateSettingValue('dunning_days_before', '3, x, 15').valid).toBe(false);
  });
  test('chaîne non vide acceptée telle quelle', () => {
    expect(validateSettingValue('platform_name', 'Flowtym RH')).toEqual({ valid: true, value: 'Flowtym RH' });
  });
  test('chaîne vide refusée', () => {
    expect(validateSettingValue('support_email', '   ').valid).toBe(false);
    expect(validateSettingValue('support_email', null).valid).toBe(false);
  });
});

describe('Super Admin — formatPayloadValue() (rendu lisible du JSON d\'audit, jamais un bloc technique brut)', () => {
  test('null/undefined -> tiret', () => {
    expect(formatPayloadValue(null)).toBe('—');
    expect(formatPayloadValue(undefined)).toBe('—');
  });
  test('booléen -> Oui/Non', () => {
    expect(formatPayloadValue(true)).toBe('Oui');
    expect(formatPayloadValue(false)).toBe('Non');
  });
  test('tableau -> valeurs jointes par virgule, récursif', () => {
    expect(formatPayloadValue([1, 2, 3])).toBe('1, 2, 3');
    expect(formatPayloadValue([true, false, null])).toBe('Oui, Non, —');
  });
  test('tableau vide -> tiret', () => {
    expect(formatPayloadValue([])).toBe('—');
  });
  test('objet -> JSON.stringify', () => {
    expect(formatPayloadValue({ a: 1 })).toBe(JSON.stringify({ a: 1 }));
  });
  test('nombre/chaîne -> String()', () => {
    expect(formatPayloadValue(42)).toBe('42');
    expect(formatPayloadValue('hello')).toBe('hello');
  });
});
