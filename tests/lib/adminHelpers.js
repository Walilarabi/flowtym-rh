'use strict';
/**
 * Reproduction exacte de la logique pure de admin.html (badges de statut,
 * calculs de dates, formatage) — sans DOM, testable en Node. À garder
 * synchronisé manuellement avec admin.html (pas de build/import partagé,
 * même contrainte que les autres fichiers de tests/lib/).
 */

const HOTEL_STATUS_LABEL = { draft: 'Brouillon', active: 'Actif', suspended: 'Suspendu', archived: 'Archivé' };
const HOTEL_STATUS_CLASS = { draft: 'gray', active: 'green', suspended: 'red', archived: 'gray' };
function hotelStatusBadge(status) {
  return { label: HOTEL_STATUS_LABEL[status] || status || '—', cls: HOTEL_STATUS_CLASS[status] || 'gray' };
}

const SUB_STATUS_LABEL = { trial: 'Essai', active: 'Actif', suspended: 'Suspendu', expired: 'Expiré', cancelled: 'Résilié' };
const SUB_STATUS_CLASS = { trial: 'amber', active: 'green', suspended: 'red', expired: 'gray', cancelled: 'gray' };
function subscriptionStatusBadge(status) {
  return { label: SUB_STATUS_LABEL[status] || status || '—', cls: SUB_STATUS_CLASS[status] || 'gray' };
}

function trialDaysRemaining(dateStr, nowMs) {
  if (!dateStr) return null;
  const now = nowMs || Date.now();
  const end = new Date(dateStr).getTime();
  if (Number.isNaN(end)) return null;
  return Math.ceil((end - now) / 86400000);
}

function fmtMoney(n, cur) {
  const v = Number(n || 0);
  return v.toLocaleString('fr-FR', { minimumFractionDigits: 0, maximumFractionDigits: 2 }) + ' ' + (cur === 'EUR' || !cur ? '€' : cur);
}

function fmtNum(n) { return Number(n || 0).toLocaleString('fr-FR'); }

function groupNameOr(name) { return (name && name.trim()) ? name : '(sans nom)'; }

function sortRows(rows, key, dir) {
  return [...rows].sort((a, b) => {
    const av = a[key], bv = b[key];
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    if (av > bv) return dir === 'desc' ? -1 : 1;
    if (av < bv) return dir === 'desc' ? 1 : -1;
    return 0;
  });
}

function errorLabel(msg) {
  const map = {
    NOM_VIDE: 'Le nom est requis.',
    CODE_EXISTANT: 'Ce code hôtel existe déjà.',
    HOTEL_INTROUVABLE: 'Hôtel introuvable.',
    GROUPE_INTROUVABLE: 'Groupe introuvable.',
    STATUT_INVALIDE: 'Statut invalide.',
  };
  const key = String(msg || '').split(' ')[0].replace(/:$/, '');
  if (map[key]) return map[key];
  if (String(msg || '').startsWith('GROUPE_NON_VIDE')) return String(msg).replace('GROUPE_NON_VIDE :', '').trim();
  return msg || 'Une erreur est survenue.';
}

const ATTRIBUTION_TYPE_LABEL = { commercial: 'Commercial', internal_regularization: 'Régularisation interne' };
function attributionTypeBadge(t) {
  return { label: ATTRIBUTION_TYPE_LABEL[t] || t || '—', cls: t === 'internal_regularization' ? 'amber' : 'gray' };
}

const ADDON_STATUS_LABEL = { active: 'Actif', cancelled: 'Retiré' };
const ADDON_STATUS_CLASS = { active: 'green', cancelled: 'gray' };
function addonStatusBadge(status) {
  return { label: ADDON_STATUS_LABEL[status] || status || '—', cls: ADDON_STATUS_CLASS[status] || 'gray' };
}

const CAUSE_LABEL = {
  missing_main_subscription: 'Aucun abonnement principal',
  app_not_in_plan: 'Application non incluse dans le plan',
  missing_addon: 'Aucune option ne couvre cette application',
  addon_missing_app_mapping: 'Option active sans application associée',
  expired_addon: 'Option expirée',
  expired_trial: "Période d'essai expirée",
  trial_missing_end_date: "Date de fin d'essai manquante",
  inactive_user: 'Utilisateur désactivé',
  suspended_hotel: 'Hôtel non actif',
  incomplete_contract_snapshot: 'Contrat historique incomplet',
  archived_plan: 'Plan archivé',
  inactive_plan: 'Plan inactif',
  missing_individual_access: 'Aucun accès individuel accordé',
};
function causeLabel(code) { return CAUSE_LABEL[code] || code; }

const EVENT_TYPE_LABEL = {
  created: 'Création', trial_started: 'Début essai', trial_extended: 'Essai prolongé', trial_converted: 'Essai converti',
  activated: 'Activation', suspended: 'Suspension', reactivated: 'Réactivation', renewed: 'Renouvellement',
  cancelled_immediate: 'Résiliation immédiate', cancellation_scheduled: 'Résiliation planifiée', cancellation_reverted: 'Résiliation annulée',
  expired_automatic: 'Expiration automatique', plan_changed: 'Changement de plan', price_snapshot_updated: 'Tarif mis à jour',
  regularized_legacy: 'Régularisation', migrated_to_commercial_plan: 'Migration vers plan commercial',
};
function eventTypeLabel(code) { return EVENT_TYPE_LABEL[code] || code; }

function actionsForStatus(status) {
  const all = { extendTrial: false, convertTrial: false, activate: false, suspend: false, reactivate: false,
    renew: false, changePlan: false, scheduleCancel: false, revertCancel: false, cancelNow: false };
  if (status === 'trial') return { ...all, extendTrial: true, convertTrial: true, changePlan: true, scheduleCancel: true, cancelNow: true };
  if (status === 'active') return { ...all, suspend: true, renew: true, changePlan: true, scheduleCancel: true, cancelNow: true };
  if (status === 'suspended') return { ...all, reactivate: true, changePlan: true, cancelNow: true };
  if (status === 'expired') return { ...all, cancelNow: true };
  return all;
}

module.exports = {
  hotelStatusBadge, subscriptionStatusBadge, trialDaysRemaining,
  fmtMoney, fmtNum, groupNameOr, sortRows, errorLabel,
  attributionTypeBadge, addonStatusBadge, causeLabel, eventTypeLabel, actionsForStatus,
};
