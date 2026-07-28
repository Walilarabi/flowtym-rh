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

module.exports = {
  hotelStatusBadge, subscriptionStatusBadge, trialDaysRemaining,
  fmtMoney, fmtNum, groupNameOr, sortRows, errorLabel,
};
