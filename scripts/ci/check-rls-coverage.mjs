// CI — garde-fou RLS : échoue si un fichier sql/*.sql crée une table `public.*`
// sans qu'aucun fichier sql/*.sql n'active RLS dessus (`ENABLE ROW LEVEL SECURITY`).
//
// Origine : audit Security Advisor 2026-08-05 (rls_disabled_in_public /
// policy_exists_rls_disabled). Racine confirmée sur les 262 migrations trackées
// côté Supabase (hors périmètre de ce dépôt) : pour ~29 tables (guests,
// staff_members, rate_plans, pricing_rules, sas_disputes, ...), RLS a été activée
// directement en production (SQL éditeur / dashboard) sans jamais être capturée
// dans un fichier de migration versionné. Toute base reconstruite uniquement
// depuis l'historique tracké (branche Supabase, nouvel environnement, DR)
// recrée alors ces tables avec RLS désactivée — silencieusement.
//
// Ce script protège le sous-ensemble sous contrôle de CE dépôt (sql/*.sql).
// BASELINE ci-dessous : tables déjà dans cet état avant l'introduction de ce
// garde-fou (RLS active en prod, jamais capturée dans sql/) — dette connue,
// pré-existante, non bloquante. Toute NOUVELLE table doit avoir son propre
// `ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY` dans sql/*.sql.
// Ne pas ajouter une table à cette liste pour contourner le garde-fou : si RLS
// est réellement activée en production pour une table sql/, ajoutez plutôt le
// `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` manquant dans un fichier sql/.
const BASELINE_PRE_EXISTING_GAP = new Set([
  'employee_contracts',
  'employee_documents',
  'employees',
  'hotel_group_flag_audit',
  'staff_absences',
  'staff_departments',
  'staff_payroll_periods',
  'staff_planning',
  'staff_roles',
]);

import { readFileSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';

function stripLineComments(text) {
  return text
    .split('\n')
    .map((line) => {
      const idx = line.indexOf('--');
      return idx === -1 ? line : line.slice(0, idx);
    })
    .join('\n');
}

const files = globSync('sql/*.sql').sort();
const created = new Map(); // table -> first file
const enabled = new Set();

const CREATE_RE = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"?(?:public\.)?"?([a-zA-Z_][a-zA-Z0-9_]*)"?/gi;
const ENABLE_RE = /ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?"?(?:public\.)?"?([a-zA-Z_][a-zA-Z0-9_]*)"?\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/gi;

for (const file of files) {
  const text = stripLineComments(readFileSync(file, 'utf8'));
  for (const m of text.matchAll(CREATE_RE)) {
    const table = m[1].toLowerCase();
    if (!created.has(table)) created.set(table, file);
  }
  for (const m of text.matchAll(ENABLE_RE)) {
    enabled.add(m[1].toLowerCase());
  }
}

const missing = [...created.keys()]
  .filter((t) => !enabled.has(t))
  .sort();

const newGaps = missing.filter((t) => !BASELINE_PRE_EXISTING_GAP.has(t));
const staleBaseline = [...BASELINE_PRE_EXISTING_GAP].filter((t) => !missing.includes(t));

console.log(`sql/*.sql : ${created.size} table(s) créée(s), ${enabled.size} avec RLS activée dans sql/.`);

let failed = false;

if (newGaps.length > 0) {
  failed = true;
  console.error('ECHEC — table(s) public créée(s) dans sql/ sans ENABLE ROW LEVEL SECURITY dans sql/ :');
  for (const t of newGaps) {
    console.error(`  - public.${t}  (créée dans ${path.relative('.', created.get(t))})`);
  }
  console.error('Ajoutez `ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY;` (+ policies) dans le même fichier sql/ ou un fichier sql/ suivant.');
}

if (staleBaseline.length > 0) {
  console.log('Note : ces tables de la baseline ont désormais RLS activée dans sql/ — retirez-les de BASELINE_PRE_EXISTING_GAP dans ce script :');
  for (const t of staleBaseline) console.log(`  - public.${t}`);
}

process.exit(failed ? 1 : 0);
