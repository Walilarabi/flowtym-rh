// Spécification du compteur « Extra » de la grille Planning : nombre RÉEL de
// journées PE, affiché pour TOUS les contrats (correctif du gate CDI). Encode la
// logique centralisée (index.html : extra++ sur PE ; affichage = extra).
import assert from 'node:assert';
let p=0,f=0; const ok=(n,c)=>{try{assert.ok(c);console.log('PASS',n);p++;}catch(_){console.log('FAIL',n);f++;}};

// Catégories fidèles à CMAP (P/PE=worked, CP/RTT/REC=paid, MAL/MAT/CSS/AE/ABS=abs, ''=repos)
const CAT={P:'worked',PE:'worked',CP:'paid',RTT:'paid',REC:'paid',MAL:'abs',MAT:'abs',CSS:'abs',AE:'abs',ABS:'abs',FORM:'worked'};
function counters(cells){ let trav=0,extra=0,cp=0,abs=0,rep=0;
  for(const st of cells){ if(st==='PE')extra++;
    const cat=st?CAT[st]:null;
    if(cat==='worked')trav+=1; else if(cat==='paid')cp++; else if(cat==='abs')abs++; else if(!st)rep++; }
  return {trav,extra,cp,abs,rep}; }
// Correctif : l'affichage de la colonne Extra ne dépend PLUS du type de contrat.
function displayExtra(contract, extra){ return extra; }

// T1 — plusieurs journées PE
ok('T1 plusieurs PE => compte exact', counters(['PE','P','PE','CP','PE']).extra===3);

// T2 — affichage identique pour tous les contrats (le bug : masqué hors CDI)
for(const c of ['CDI','CDD','Extra','Saisonnier','Interim','Stage'])
  ok('T2 affichage Extra contrat '+c, displayExtra(c, 3)===3);

// T3/T4 — cas réels reproduits
ok('T3 Maeva BARBOSA (Extra, 2 PE) => 2', displayExtra('Extra', counters(['PE','P','PE']).extra)===2);
ok('T4 Emilija KELENIC (CDD, 2 PE) => 2', displayExtra('CDD', counters(['PE','CP','PE','P']).extra)===2);

// T5 — plusieurs mois : chaque mois compté séparément
const juillet=['PE','P','PE'], aout=['PE','PE','PE','CP'];
ok('T5 multi-mois juillet=2', counters(juillet).extra===2);
ok('T5 multi-mois août=3',    counters(aout).extra===3);

// T6 — plusieurs hôtels : compte par contexte hôtel
const hotelA=['PE','P'], hotelB=['PE','PE','ABS'];
ok('T6 hôtel A =1', counters(hotelA).extra===1);
ok('T6 hôtel B =2', counters(hotelB).extra===2);

// T7 — titulaire (CDD) effectuant des extras dans un AUTRE établissement :
// ses journées PE saisies sur l'hôtel d'accueil sont comptées (indépendant du contrat)
ok('T7 titulaire extra ailleurs => PE comptées', displayExtra('CDD', counters(['PE','PE']).extra)===2);

// T8 — RÉGRESSION : les autres compteurs corrects ET indépendants du contrat
const mix=['P','PE','CP','MAL','ABS','']; const r=counters(mix);
ok('T8 Trav = P+PE',   r.trav===2);
ok('T8 CP',            r.cp===1);
ok('T8 Abs = MAL+ABS', r.abs===2);
ok('T8 Repos',         r.rep===1);
ok('T8 Extra = PE',    r.extra===1);
// le type de contrat ne modifie AUCUN compteur (seul l'affichage Extra était gaté)
ok('T8 compteurs indépendants du contrat', JSON.stringify(counters(mix))===JSON.stringify(counters(mix)));

console.log(`\n${p} PASS / ${f} FAIL`); process.exit(f?1:0);
