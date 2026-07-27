'use strict';
const { shouldHideAffectButton, matchesDayStatusFilter } = require('./lib/groupPlanningBadges');
const fs = require('fs');
const path = require('path');

// ── shouldHideAffectButton ──────────────────────────────────────────────────

describe('Planning Groupe · shouldHideAffectButton — Maladie/Absence sans bouton', () => {
  test('Maladie → bouton absent',   () => expect(shouldHideAffectButton('MAL')).toBe(true));
  test('Absence → bouton absent',   () => expect(shouldHideAffectButton('ABS')).toBe(true));
  test('Présent → bouton présent',  () => expect(shouldHideAffectButton('P')).toBe(false));
  test('Repos → bouton présent (disabled par unavail, jamais ce cas)', () => expect(shouldHideAffectButton('')).toBe(false));
  test('CP → bouton présent',       () => expect(shouldHideAffectButton('CP')).toBe(false));
  test('Maternité → bouton présent (désactivé, pas masqué)', () => expect(shouldHideAffectButton('MAT')).toBe(false));
  test('Paternité → bouton présent (désactivé, pas masqué)', () => expect(shouldHideAffectButton('PAT')).toBe(false));
});

// ── matchesDayStatusFilter ───────────────────────────────────────────────────

describe('Planning Groupe · matchesDayStatusFilter — filtre statut du jour', () => {
  test('aucun filtre (chaîne vide) → tout matche', () => {
    expect(matchesDayStatusFilter('P', '')).toBe(true);
    expect(matchesDayStatusFilter('', '')).toBe(true);
    expect(matchesDayStatusFilter('MAL', '')).toBe(true);
  });

  test('filtre REPOS → matche uniquement statut vide', () => {
    expect(matchesDayStatusFilter('', 'REPOS')).toBe(true);
    expect(matchesDayStatusFilter('P', 'REPOS')).toBe(false);
    expect(matchesDayStatusFilter('CP', 'REPOS')).toBe(false);
  });

  test('filtre CP → matche uniquement CP', () => {
    expect(matchesDayStatusFilter('CP', 'CP')).toBe(true);
    expect(matchesDayStatusFilter('MAL', 'CP')).toBe(false);
    expect(matchesDayStatusFilter('', 'CP')).toBe(false);
  });

  test('filtre MAL → matche uniquement Maladie', () => {
    expect(matchesDayStatusFilter('MAL', 'MAL')).toBe(true);
    expect(matchesDayStatusFilter('ABS', 'MAL')).toBe(false);
  });

  test('filtre ABS → matche uniquement Absence', () => {
    expect(matchesDayStatusFilter('ABS', 'ABS')).toBe(true);
    expect(matchesDayStatusFilter('MAL', 'ABS')).toBe(false);
  });

  test('filtre P → matche uniquement Présent', () => {
    expect(matchesDayStatusFilter('P', 'P')).toBe(true);
    expect(matchesDayStatusFilter('PE', 'P')).toBe(false);
  });
});

// ── Contrat frontend ─────────────────────────────────────────────────────────

describe('Frontend · toolbar filtre statut journalier + suppression bouton Affecter', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  test('select gpDayStatusSel présent avec les options Repos/CP/Maladie/Absence', () => {
    expect(html).toMatch(/id="gpDayStatusSel"/);
    expect(html).toMatch(/value="REPOS"[^>]*>Repos</);
    expect(html).toMatch(/value="CP"[^>]*>CP</);
    expect(html).toMatch(/value="MAL"[^>]*>Maladie</);
    expect(html).toMatch(/value="ABS"[^>]*>Absence</);
  });

  test('gpDayStatusSel.onchange met à jour gpFilters.dayStatus et re-render', () => {
    expect(html).toMatch(/\$\('gpDayStatusSel'\)\.onchange=ev=>\{ gpFilters\.dayStatus=ev\.target\.value; gpRenderBody\(\); \}/);
  });

  test('filteredForDisplay applique le filtre dayStatus (REPOS = statut vide)', () => {
    const idx = html.indexOf('const filteredForDisplay');
    const next = html.indexOf('\n      const csDisp', idx);
    const body = html.slice(idx, next > 0 ? next : idx + 800);
    expect(body).toMatch(/gpFilters\.dayStatus/);
    expect(body).toMatch(/a\.filter\(c=>!c\.status\)/);
  });

  test('gpBuildCollab masque totalement le bouton Affecter pour MAL/ABS (pas juste disabled)', () => {
    const idx = html.indexOf('function gpBuildCollab');
    const next = html.indexOf('\nfunction ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 1800);
    expect(body).toMatch(/const hideAffectBtn = \(c\.status==='MAL' \|\| c\.status==='ABS'\);/);
    expect(body).toMatch(/const affBtn = hideAffectBtn \? '' : /);
  });
});
