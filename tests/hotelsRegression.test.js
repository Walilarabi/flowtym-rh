'use strict';
/**
 * Régression P0 — écran Super Admin « Hôtels » : « column hotels.updated_at does not exist ».
 *
 * hotels n'a jamais eu de colonne updated_at (ni en production, ni dans la reconstruction
 * versionnée du dépôt — db/reconstruct/10_foundation.sql, ni dans aucune migration sql/).
 * admin.html la référençait pourtant (select, tri, affichage liste + fiche détail) depuis le
 * merge RC1 (PR #17) : PostgREST rejette la requête entière dès qu'une colonne inexistante est
 * demandée, ce qui vidait la liste des hôtels et cassait la recherche (filtrée côté client sur
 * des données jamais reçues), tout en exposant le message SQL brut à l'écran.
 *
 * Ces tests lisent le fichier réel (pas une copie mirroir) pour garantir qu'aucune régression
 * future ne réintroduit une référence à cette colonne sans passer par une migration dédiée.
 */
const fs = require('fs');
const path = require('path');

const adminHtml = fs.readFileSync(path.join(__dirname, '..', 'admin.html'), 'utf8');

function extractFunctionBody(source, functionName) {
  const start = source.indexOf(`async function ${functionName}(`);
  if (start === -1) throw new Error(`Fonction ${functionName} introuvable dans admin.html`);
  // Prochaine fonction top-level après celle-ci comme borne de fin (suffisant pour ce fichier,
  // pas de fonctions imbriquées de même nom).
  const next = source.indexOf('\nasync function ', start + 10);
  const nextSync = source.indexOf('\nfunction ', start + 10);
  const candidates = [next, nextSync].filter(i => i !== -1);
  const end = candidates.length ? Math.min(...candidates) : source.length;
  return source.slice(start, end);
}

describe('Super Admin — régression hotels.updated_at (admin.html réel)', () => {
  const renderHotels = extractFunctionBody(adminHtml, 'renderHotels');

  test('renderHotels() ne sélectionne plus updated_at sur hotels', () => {
    const selectCall = renderHotels.match(/sb\.from\('hotels'\)\.select\('([^']*)'\)/);
    expect(selectCall).not.toBeNull();
    const columns = selectCall[1].split(',');
    expect(columns).not.toContain('updated_at');
    // Garde-fou positif : la colonne réellement disponible reste sélectionnée.
    expect(columns).toContain('created_at');
  });

  test('renderHotels() ne référence h.updated_at nulle part (tri, affichage)', () => {
    expect(renderHotels).not.toMatch(/\bh\.updated_at\b/);
    expect(renderHotels).not.toMatch(/data-k="updated_at"/);
  });

  test('la requête de base sur hotels est ordonnée explicitement (tri stable, indépendant du réseau)', () => {
    expect(renderHotels).toMatch(/sb\.from\('hotels'\)\.select\([^)]*\)\.order\(/);
  });

  test('aucune fonction de rendu de admin.html ne référence encore hotel.updated_at (fiche détail)', () => {
    expect(adminHtml).not.toMatch(/\bhotel\.updated_at\b/);
  });

  test('le catch générique de chargement de page n\'interpole plus e.message (fuite de détail SQL)', () => {
    const renderView = extractFunctionBody(adminHtml, 'renderView');
    expect(renderView).not.toMatch(/esc\(e\.message/);
    expect(renderView).toMatch(/VIEW_LOAD_ERROR_LABEL/);
    // Le détail technique doit rester en console, jamais disparaître silencieusement.
    expect(renderView).toMatch(/console\.error/);
  });
});
