'use strict';

// ── Tests unitaires : refonte de la page Pointage RH (index.html) ───────────
// Le calcul du retard/rattrapage/solde est fait SERVEUR (sql/66, testé dans
// sql/tests/pointage_daily_summary.sql — 10 blocs OK, cas 1 à 5 du cahier des
// charges vérifiés contre PostgreSQL réel). Ce fichier couvre uniquement la
// logique de PRÉSENTATION dupliquée d'index.html : formatage, couleurs,
// filtres instantanés, agrégats KPI/mensuel — plus des tests de contrat sur
// le fichier source réel pour garantir qu'aucune fonctionnalité existante
// n'a été perdue lors de la refonte.

const fs = require('fs');
const path = require('path');

function plannedHHMM(t){ return t ? String(t).slice(0,5) : null; }

function signedMinLabel(min){
  if(min==null) return '—';
  if(min===0) return '0 min';
  return (min>0?'+':'') + min + ' min';
}

function soldeColorStyle(min){
  if(min==null) return 'color:var(--muted)';
  if(min<0)  return 'color:var(--green);font-weight:700';
  if(min>0)  return 'color:var(--red);font-weight:700';
  return 'color:var(--ink2);font-weight:600';
}
function retardColorStyle(min){
  if(min==null) return 'color:var(--muted)';
  if(min>0) return 'color:var(--red);font-weight:700';
  return 'color:var(--ink2)';
}
function rattrapageColorStyle(min){
  if(min==null) return 'color:var(--muted)';
  if(min>0) return 'color:var(--green);font-weight:700';
  return 'color:var(--ink2)';
}

// Réplique du filtrage instantané (Service / Statut / recherche) de redrawPointage.
function filterPointageRows(rows, {q='', service='', status=''}={}){
  return rows.filter(r => {
    if(q && !`${r.first_name} ${r.last_name} ${r.role||''}`.toLowerCase().includes(q)) return false;
    if(service && r.department !== service) return false;
    const pointed = !!r.real_in;
    if(status === 'pointe' && !pointed) return false;
    if(status === 'non_pointe' && pointed) return false;
    return true;
  });
}

// Réplique de l'agrégat "Total retard (mois)" : somme des soldes POSITIFS.
function aggregateMonthlyTotal(monthRows){
  const map = new Map();
  monthRows.forEach(r => {
    map.set(r.employee_id, (map.get(r.employee_id) || 0) + Math.max(0, r.solde_jour_min || 0));
  });
  return map;
}

// Réplique des 4 KPI du jour.
function computePointageKpis(todayRows){
  const nPrevus = todayRows.length;
  const nPointes = todayRows.filter(r => r.real_in).length;
  const nNonPointes = nPrevus - nPointes;
  const retardNet = todayRows.reduce((s,r) => s + (r.solde_jour_min || 0), 0);
  return { nPrevus, nPointes, nNonPointes, retardNet };
}

describe('plannedHHMM', () => {
  test('tronque un time SQL "HH:MM:SS" en "HH:MM"', () => {
    expect(plannedHHMM('08:00:00')).toBe('08:00');
  });
  test('accepte déjà un "HH:MM"', () => {
    expect(plannedHHMM('17:00')).toBe('17:00');
  });
  test('null/undefined → null (affiché "—" par l\'appelant)', () => {
    expect(plannedHHMM(null)).toBeNull();
    expect(plannedHHMM(undefined)).toBeNull();
  });
});

describe('signedMinLabel', () => {
  test('null → "—" (donnée non disponible, jamais 0 par erreur)', () => {
    expect(signedMinLabel(null)).toBe('—');
  });
  test('0 → "0 min" (à l\'heure, distinct de "—")', () => {
    expect(signedMinLabel(0)).toBe('0 min');
  });
  test('positif → préfixe "+"', () => {
    expect(signedMinLabel(15)).toBe('+15 min');
  });
  test('négatif → signe "-" natif, pas de double signe', () => {
    expect(signedMinLabel(-12)).toBe('-12 min');
  });
});

describe('couleurs — § 6 du cahier des charges (vert/rouge/gris)', () => {
  test('solde négatif (avance) → vert', () => {
    expect(soldeColorStyle(-12)).toContain('var(--green)');
  });
  test('solde positif (retard) → rouge', () => {
    expect(soldeColorStyle(20)).toContain('var(--red)');
  });
  test('solde nul → ni vert ni rouge', () => {
    const s = soldeColorStyle(0);
    expect(s).not.toContain('var(--green)');
    expect(s).not.toContain('var(--red)');
  });
  test('solde NULL (non disponible) → gris', () => {
    expect(soldeColorStyle(null)).toContain('var(--muted)');
  });
  test('retard matin > 0 → rouge ; retard = 0 → neutre ; NULL → gris', () => {
    expect(retardColorStyle(15)).toContain('var(--red)');
    expect(retardColorStyle(0)).not.toContain('var(--red)');
    expect(retardColorStyle(null)).toContain('var(--muted)');
  });
  test('rattrapage soir > 0 → vert ; rattrapage = 0 → neutre ; NULL → gris', () => {
    expect(rattrapageColorStyle(15)).toContain('var(--green)');
    expect(rattrapageColorStyle(0)).not.toContain('var(--green)');
    expect(rattrapageColorStyle(null)).toContain('var(--muted)');
  });
});

describe('filterPointageRows — filtres Service/Statut/recherche instantanés', () => {
  const rows = [
    {employee_id:'e1', first_name:'Bahia', last_name:'ABERKANE', role:'Femme de chambre', department:'Étages',    real_in:'2026-01-12T08:15:00Z'},
    {employee_id:'e2', first_name:'Farouk', last_name:'AZOUGUI',  role:'Réceptionniste',  department:'Réception', real_in:'2026-01-12T18:28:00Z'},
    {employee_id:'e3', first_name:'Ghali',  last_name:'AMRANI',   role:'Veilleur de nuit', department:'Réception', real_in:null},
  ];

  test('sans filtre → toutes les lignes', () => {
    expect(filterPointageRows(rows).length).toBe(3);
  });
  test('filtre Service="Réception" → 2 lignes', () => {
    expect(filterPointageRows(rows, {service:'Réception'}).length).toBe(2);
  });
  test('filtre Statut="pointe" → uniquement real_in non nul', () => {
    const r = filterPointageRows(rows, {status:'pointe'});
    expect(r.map(x=>x.employee_id)).toEqual(['e1','e2']);
  });
  test('filtre Statut="non_pointe" → uniquement real_in nul', () => {
    const r = filterPointageRows(rows, {status:'non_pointe'});
    expect(r.map(x=>x.employee_id)).toEqual(['e3']);
  });
  test('recherche texte sur nom/prénom/rôle, insensible à la casse', () => {
    expect(filterPointageRows(rows, {q:'aberkane'}).length).toBe(1);
    expect(filterPointageRows(rows, {q:'réceptionniste'}).length).toBe(1);
  });
  test('cumul de filtres (Service + Statut)', () => {
    const r = filterPointageRows(rows, {service:'Réception', status:'non_pointe'});
    expect(r.map(x=>x.employee_id)).toEqual(['e3']);
  });
});

describe('aggregateMonthlyTotal — cumul des soldes positifs uniquement', () => {
  test('ignore les soldes négatifs (avance) et NULL, cumule les positifs', () => {
    const rows = [
      {employee_id:'e1', solde_jour_min: 15},
      {employee_id:'e1', solde_jour_min: -20},   // avance : ne doit PAS réduire le cumul
      {employee_id:'e1', solde_jour_min: null},  // non calculable : ignoré
      {employee_id:'e1', solde_jour_min: 10},
      {employee_id:'e2', solde_jour_min: 5},
    ];
    const m = aggregateMonthlyTotal(rows);
    expect(m.get('e1')).toBe(25);
    expect(m.get('e2')).toBe(5);
  });
});

describe('computePointageKpis', () => {
  test('cas nominal (mockup) : 8 prévus, 5 pointés, 3 non pointés', () => {
    const rows = [
      ...Array.from({length:5}, (_,i)=>({employee_id:'p'+i, real_in:'2026-01-12T08:00:00Z', solde_jour_min: i===0?18:0})),
      ...Array.from({length:3}, (_,i)=>({employee_id:'n'+i, real_in:null, solde_jour_min:null})),
    ];
    const k = computePointageKpis(rows);
    expect(k.nPrevus).toBe(8);
    expect(k.nPointes).toBe(5);
    expect(k.nNonPointes).toBe(3);
    expect(k.retardNet).toBe(18);
  });
  test('journée vide → tous les compteurs à 0', () => {
    const k = computePointageKpis([]);
    expect(k).toEqual({ nPrevus:0, nPointes:0, nNonPointes:0, retardNet:0 });
  });
});

// ── Contrats sur le fichier source réel (index.html) ─────────────────────────
describe('index.html · contrat refonte Pointage', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const start = html.indexOf('/* ===================== VUE POINTAGE ===================== */');
  const end = html.indexOf('/* ===================== VUE ABSENCES ===================== */');
  const section = html.slice(start, end > start ? end : undefined);

  test('le calcul du retard/solde vient du serveur (RPC), pas du frontend', () => {
    expect(html).toMatch(/pointageRangeSummary[\s\S]{0,120}sb\.rpc\('pointage_range_summary'/);
  });

  test('le tableau pleine largeur ne contient plus de second panneau (aperçu PDF)', () => {
    expect(section).not.toMatch(/apercu|aperçu.{0,20}pdf/i);
  });

  test('filtres Service et Statut présents avec les libellés attendus', () => {
    expect(section).toContain('Tous les services');
    expect(section).toContain('>Pointés<');
    expect(section).toContain('>Non pointés<');
  });

  test('bouton d\'export PDF dédié à la feuille de pointage', () => {
    expect(section).toContain('Exporter la feuille de pointage (PDF)');
    expect(section).toMatch(/async function exportPointagePdf/);
  });

  test('colonne "Pointage manuel" en dernière position du tableau', () => {
    const theadMatch = section.match(/<thead>[\s\S]*?<\/thead>/);
    expect(theadMatch).not.toBeNull();
    const thead = theadMatch[0];
    const idxManuel = thead.indexOf('Pointage manuel');
    const idxSolde = thead.indexOf('Solde du jour');
    expect(idxManuel).toBeGreaterThan(-1);
    expect(idxManuel).toBeGreaterThan(idxSolde);
  });

  test('bouton "+" par ligne : data-add-for + openClockingForm(null, …) inchangés', () => {
    expect(section).toMatch(/data-add-for="\$\{r\.employee_id\}"/);
    expect(section).toMatch(/openClockingForm\(null, b\.dataset\.addFor\)/);
  });

  test('bouton d\'ajout global du header (#ptAdd) toujours présent et inchangé', () => {
    expect(section).toMatch(/id="ptAdd"[\s\S]{0,10}>/);
    expect(section).toMatch(/\$\('ptAdd'\)\.onclick = \(\) => openClockingForm\(null\)/);
  });

  test('édition d\'un pointage existant toujours possible (clic sur l\'heure réelle)', () => {
    expect(section).toMatch(/data-edit-cid/);
    expect(section).toMatch(/if\(c\) openClockingForm\(c\)/);
  });

  test('openClockingForm lui-même n\'a pas été modifié (signature + champs)', () => {
    const fnStart = html.indexOf('function openClockingForm(c, presetEmpId)');
    expect(fnStart).toBeGreaterThan(-1);
    const fnEnd = html.indexOf('/* ===================== VUE ABSENCES ===================== */', fnStart);
    const fnBody = html.slice(fnStart, fnEnd > fnStart ? fnEnd : fnStart + 6000);
    expect(fnBody).toContain('BE.updateClocking(c.id');
    expect(fnBody).toContain("BE.addClocking(hotelId");
    expect(fnBody).toContain("$('ck_del')");
  });

  test('légende "Comprendre le solde du jour" présente sous le tableau', () => {
    expect(section).toContain('Comprendre le solde du jour');
    expect(section).toContain('Solde négatif = avance');
    expect(section).toContain('Solde positif = retard');
  });

  test('badge "Extra" pour un salarié inter-hôtel (régression LOT1 corrigée)', () => {
    expect(section).toMatch(/r\.is_extra[\s\S]{0,300}>Extra</);
  });
});
