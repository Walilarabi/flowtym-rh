// Vérifie que SEULES les erreurs « objet backend absent » sont converties en message
// fonctionnel ; les erreurs métier/validation conservent leur message d'origine.
import assert from 'node:assert';
function _isBackendUnavailable(e){
  const m=((e&&(e.message||e))||'').toString().toLowerCase();
  return m.includes('could not find the function')||m.includes('could not find the table')
    ||m.includes('schema cache')||m.includes('pgrst202')||m.includes('pgrst205')
    ||(m.includes('function')&&m.includes('does not exist'))
    ||(m.includes('relation')&&m.includes('does not exist'));
}
function friendlyErr(e,msg){ if(_isBackendUnavailable(e)){return msg||"indispo";} return (e&&e.message)||'Erreur'; }
let p=0,f=0; const ok=(n,c)=>{try{assert.ok(c);console.log('PASS',n);p++;}catch(_){console.log('FAIL',n);f++;}};
const FRIENDLY="Le module de validation des modifications n'est pas encore activé.";
// Disponibilité -> message fonctionnel
ok('func not found', friendlyErr(new Error("Demande : Could not find the function public.planning_change_request_create in the schema cache"),FRIENDLY)===FRIENDLY);
ok('table not found', friendlyErr(new Error("Could not find the table public.x in the schema cache"),FRIENDLY)===FRIENDLY);
ok('function does not exist', friendlyErr(new Error('function public.x() does not exist'),FRIENDLY)===FRIENDLY);
ok('relation does not exist', friendlyErr(new Error('relation "public.x" does not exist'),FRIENDLY)===FRIENDLY);
// Erreurs MÉTIER -> message d'origine (NON masqué)
ok('métier: non autorisé', friendlyErr(new Error('Décision : Non autorisé à traiter cette demande'),FRIENDLY)==='Décision : Non autorisé à traiter cette demande');
ok('métier: motif obligatoire', friendlyErr(new Error('Le motif est obligatoire'),FRIENDLY)==='Le motif est obligatoire');
ok('métier: doublon FL011', friendlyErr(new Error('Une demande est déjà en attente pour ce collaborateur à cette date'),FRIENDLY).includes('déjà en attente'));
ok('métier: autre établissement', friendlyErr(new Error('Accès refusé (autre établissement)'),FRIENDLY)==='Accès refusé (autre établissement)');
console.log(`\n${p} PASS / ${f} FAIL`); process.exit(f?1:0);
