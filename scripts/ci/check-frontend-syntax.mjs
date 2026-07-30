// CI — vérifie la syntaxe JS des scripts inline (index.html, portal.html, admin.html) et
// signale le code de debug résiduel (debugger). Tolère le top-level await des
// scripts type="module" (revalide en enveloppant dans une fonction async).
import { readFileSync } from 'node:fs';
let failed = false;
function checkSyntax(code) {
  try { new Function(code); return null; }
  catch (e) {
    // top-level await : valide en module -> revalider en contexte async
    try { new Function(`return (async () => { ${code} \n})`); return null; }
    catch (e2) { return e.message; }
  }
}
for (const file of ['index.html', 'portal.html', 'admin.html']) {
  const html = readFileSync(file, 'utf8');
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m, i = 0;
  while ((m = re.exec(html))) {
    i++;
    const err = checkSyntax(m[1]);
    if (err) { failed = true; console.error(`SYNTAX ERROR ${file} bloc #${i}: ${err}`); }
  }
  const dbg = (html.match(/\bdebugger\b/g) || []).length;
  if (dbg > 0) { failed = true; console.error(`${file}: ${dbg} 'debugger' résiduel(s)`); }
  console.log(`${file}: ${i} bloc(s) script vérifié(s)${failed ? '' : ', 0 erreur'}`);
}
process.exit(failed ? 1 : 0);
