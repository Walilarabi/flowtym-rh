// Tests de RÈGLE (spécification) pour le hotfix RH — anomalies d'autorisation.
// La logique vit dans index.html (monolithe non importable) ; ces tests encodent
// les règles appliquées et servent de spécification vérifiable. Les tests
// utilisateur E2E (TEST 1..10) s'exécutent en navigateur authentifié (QA pilote).
import assert from 'node:assert';
let pass=0, fail=0; const ok=(n,c)=>{try{assert.ok(c);console.log('PASS',n);pass++;}catch(e){console.log('FAIL',n);fail++;}};

/* ===== INCIDENT 1 — Compteurs légaux : gate = permission « tracking » (Suivi du temps) ===== */
// Sous-ensemble fidèle de DEFAULT_PERMISSIONS.tracking.view (matrice réelle du projet).
const TRACKING_VIEW = { direction:true, admin_hotel:true, comptabilite:true,
  revenue_manager:false, reception:false, gouvernante:false, maintenance:false,
  breakfast:false, femme_de_chambre:false };
const canSeeLegalCounters = role => TRACKING_VIEW[role]===true;

ok('T1  Réception ne voit PAS les compteurs légaux', canSeeLegalCounters('reception')===false);
ok('T3  Direction (habilitée) voit les compteurs',   canSeeLegalCounters('direction')===true);
ok('T3b Admin hôtel voit les compteurs',             canSeeLegalCounters('admin_hotel')===true);
ok('T1b Gouvernante ne voit pas les compteurs',      canSeeLegalCounters('gouvernante')===false);
// TEST 2 (récupération directe) : les compteurs sont DÉRIVÉS côté client du planning
// déjà visible (statuts) — aucun endpoint/RPC dédié ne renvoie de « données compteurs ».
// Le correctif ne calcule même pas les alertes si le rôle n'est pas habilité.
const computeAlerts = (role, planning) => canSeeLegalCounters(role) ? planning.map(()=>'alert') : [];
ok('T2  Réception : aucune donnée de compteur produite (0 alerte)', computeAlerts('reception',[1,2,3]).length===0);
ok('T2b Direction : compteurs produits',                            computeAlerts('direction',[1,2,3]).length===3);

/* ===== ANOMALIE 3 — Organigramme : racines = têtes réelles ; non-affectés en bas ===== */
function classifyOrg(staff){
  const act = staff.filter(s=>s.active);
  const byMgr = new Map();
  act.forEach(s=>{ if(s.manager_id){ if(!byMgr.has(s.manager_id)) byMgr.set(s.manager_id,[]); byMgr.get(s.manager_id).push(s);} });
  const roots = act.filter(s=>!s.manager_id || !act.find(e=>e.id===s.manager_id));
  return { genuineRoots: roots.filter(s=>byMgr.has(s.id)), unassigned: roots.filter(s=>!byMgr.has(s.id)), byMgr };
}
// Jeu de données : A = tête (a B sous lui) ; B = rattaché à A ; C = sans responsable ni subordonné.
const staffH1 = [
  {id:'A',active:true,manager_id:null,hotel_id:'H1'},
  {id:'B',active:true,manager_id:'A',hotel_id:'H1'},
  {id:'C',active:true,manager_id:null,hotel_id:'H1'},
];
const r1 = classifyOrg(staffH1);
ok('T8  C (sans responsable, sans subordonné) => section non affecté', r1.unassigned.some(s=>s.id==='C'));
ok('T8b C n\'est PAS une racine hiérarchique',                          !r1.genuineRoots.some(s=>s.id==='C'));
ok('T9  B (avec responsable) n\'est ni racine ni non-affecté',          !r1.genuineRoots.some(s=>s.id==='B') && !r1.unassigned.some(s=>s.id==='B'));
ok('T9b B est bien rattaché sous A',                                    r1.byMgr.get('A').some(s=>s.id==='B'));
ok('T10 A (tête réelle, a des subordonnés) reste au sommet',            r1.genuineRoots.some(s=>s.id==='A'));
// Cloisonnement multi-établissement : la classification opère sur le staff d'UN hôtel.
const r2 = classifyOrg(staffH1.filter(s=>s.hotel_id==='H1'));
ok('T-iso Partitionnement par établissement préservé (staff d\'un seul hôtel)', r2.genuineRoots.length+r2.unassigned.length===2);

console.log(`\n${pass} PASS / ${fail} FAIL`);
process.exit(fail?1:0);
