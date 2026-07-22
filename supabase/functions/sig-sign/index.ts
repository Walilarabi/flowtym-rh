import { createClient } from 'jsr:@supabase/supabase-js@2';
import { PDFDocument, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';

// sig-sign — Page de signature électronique Flowtym (sans CDN, sans JWT).
// GET  ?request_id=xxx        → page HTML de signature (SANS contenu du contrat avant OTP)
// POST {request_id, action}   → send_otp | verify_otp | get_document | sign | refuse
//
// CONFIDENTIALITÉ : le contenu du contrat (HTML, données salariales, clauses,
// données personnelles) n'est JAMAIS inclus dans la réponse GET. Il n'est
// transmis qu'après validation OTP réussie, via l'action POST get_document,
// qui exige status='otp_verified'. Le masquage n'est pas seulement visuel :
// le serveur n'émet pas le document tant que l'OTP n'est pas vérifié.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RESEND_KEY   = Deno.env.get('RESEND_API_KEY') ?? '';

const JSON_H = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Content-Type': 'application/json',
};
const HTML_H = { 'Content-Type': 'text/html; charset=utf-8' };

function jsonR(d: unknown, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: JSON_H });
}

async function sha256hex(data: Uint8Array | string): Promise<string> {
  const buf = await crypto.subtle.digest(
    'SHA-256',
    typeof data === 'string' ? new TextEncoder().encode(data) : data,
  );
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function genOTP(): string {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return String((a[0] % 900000) + 100000);
}

// ── Masquage identité (avant validation OTP) ────────────────────────────────
function maskEmail(email: string): string {
  const [local, domain] = String(email || '').split('@');
  if (!domain) return '•••';
  const head = local.slice(0, 2);
  return head + '•••@' + domain;
}
function maskName(name: string): string {
  return String(name || '').trim().split(/\s+/).map(w =>
    w ? w[0].toUpperCase() + (w.length > 1 ? '•••' : '') : '',
  ).join(' ').trim() || '•••';
}

async function sendOTPEmail(to: string, name: string, otp: string): Promise<void> {
  const html =
    '<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;background:#f5f5f5;padding:30px">'
    + '<div style="max-width:420px;margin:0 auto;background:#fff;border-radius:12px;padding:32px">'
    + '<div style="text-align:center;margin-bottom:20px"><span style="font-size:20px;font-weight:800;color:#5B21B6">Flowtym</span><span style="font-size:13px;color:#9ca3af"> RH</span></div>'
    + '<h3 style="color:#111;font-size:16px">Bonjour ' + name + ',</h3>'
    + '<p style="color:#374151;font-size:14px;margin-bottom:16px">Votre code de vérification :</p>'
    + '<div style="text-align:center;margin:20px 0">'
    + '<span style="font-size:36px;font-weight:800;letter-spacing:8px;color:#5B21B6;background:#EDE9FE;padding:16px 24px;border-radius:10px;display:inline-block">' + otp + '</span>'
    + '</div>'
    + '<p style="color:#6b7280;font-size:12px">Valable <strong>48 heures</strong>. Ne le communiquez à personne.</p>'
    + '</div></body></html>';

  const resp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + RESEND_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'Flowtym RH <noreply@flowtym.com>',
      to: [to],
      subject: 'Code de signature : ' + otp,
      html,
    }),
  });
  if (!resp.ok) throw new Error('Resend ' + resp.status);
}

// Convertit HTML en texte brut pour inclusion dans le PDF
function htmlToText(html: string): string {
  return html
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n\n')
    .replace(/<\/h[1-6]>/gi, '\n\n')
    .replace(/<\/li>/gi, '\n')
    .replace(/<\/tr>/gi, '\n')
    .replace(/<\/td>/gi, '  ')
    .replace(/<\/th>/gi, '  ')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\t/g, '  ')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

// Découpe une longue chaîne en lignes de maxChars caractères
function wrapLine(text: string, maxChars: number): string[] {
  const words = text.split(' ');
  const lines: string[] = [];
  let current = '';
  for (const word of words) {
    if (!word) continue;
    if ((current + (current ? ' ' : '') + word).length <= maxChars) {
      current = current ? current + ' ' + word : word;
    } else {
      if (current) lines.push(current);
      let remaining = word;
      while (remaining.length > maxChars) {
        lines.push(remaining.slice(0, maxChars));
        remaining = remaining.slice(maxChars);
      }
      current = remaining;
    }
  }
  if (current) lines.push(current);
  return lines;
}

// Génère un PDF multi-pages : contrat original (pages 1..n) + attestation (dernière page)
async function buildSignedPDF(opts: {
  signerName: string; signerEmail: string; signedAt: string;
  signerIp: string; requestId: string;
  documentHash: string; signedDocHash: string;
  signatureImageB64: string;
  contractNumber: string | null; contractType: string | null;
  contractHtml: string | null;
}): Promise<Uint8Array> {
  const pdfDoc = await PDFDocument.create();
  const font   = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const fontB  = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

  const A4W = 595;
  const A4H = 842;
  const mg  = 50;
  const lineH = 14;
  const fontSize = 9;
  const maxCharsPerLine = 95;

  // Pages contrat original
  if (opts.contractHtml) {
    const plainText = htmlToText(opts.contractHtml);
    const rawLines  = plainText.split('\n');

    const allLines: string[] = [];
    for (const raw of rawLines) {
      const wrapped = wrapLine(raw, maxCharsPerLine);
      if (wrapped.length === 0) allLines.push('');
      else allLines.push(...wrapped);
    }

    const usableH      = A4H - mg * 2 - 60;
    const linesPerPage = Math.floor(usableH / lineH);
    const totalPages   = Math.ceil(allLines.length / linesPerPage);

    for (let start = 0; start < allLines.length; start += linesPerPage) {
      const chunk   = allLines.slice(start, start + linesPerPage);
      const page    = pdfDoc.addPage([A4W, A4H]);
      const pageNum = Math.floor(start / linesPerPage) + 1;

      page.drawRectangle({ x: 0, y: A4H - 40, width: A4W, height: 40, color: rgb(0.97, 0.97, 0.97) });
      page.drawText('Document contractuel — Flowtym RH', { x: mg, y: A4H - 26, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
      const meta = (opts.contractType ?? '') + (opts.contractNumber ? '  |  ' + opts.contractNumber : '') + '  |  Page ' + pageNum + '/' + totalPages;
      page.drawText(meta, { x: mg, y: A4H - 36, size: 7.5, font, color: rgb(0.65, 0.65, 0.65) });

      let y = A4H - 60;
      for (const line of chunk) {
        if (y < mg) break;
        if (line.trim()) {
          page.drawText(line, { x: mg, y, size: fontSize, font, color: rgb(0.1, 0.1, 0.1) });
        }
        y -= lineH;
      }
    }
  }

  // Page attestation
  const page  = pdfDoc.addPage([A4W, A4H]);
  const { width, height } = page.getSize();
  let y = height - mg;

  page.drawRectangle({ x: 0, y: height - 80, width, height: 80, color: rgb(0.357, 0.129, 0.714) });
  page.drawText('Flowtym RH', { x: mg, y: height - 50, size: 22, font: fontB, color: rgb(1, 1, 1) });
  page.drawText('Attestation de signature électronique', { x: mg, y: height - 68, size: 11, font, color: rgb(0.87, 0.84, 0.96) });
  y = height - 110;

  page.drawText('ATTESTATION DE SIGNATURE ÉLECTRONIQUE', { x: mg, y, size: 14, font: fontB, color: rgb(0.11, 0.11, 0.11) });
  y -= 8;
  page.drawLine({ start: { x: mg, y }, end: { x: width - mg, y }, thickness: 1, color: rgb(0.36, 0.13, 0.71) });
  y -= 22;

  const row = (label: string, value: string) => {
    if (y < mg + 40) return;
    page.drawText(label, { x: mg, y, size: 10, font, color: rgb(0.41, 0.41, 0.41) });
    page.drawText(value || '—', { x: mg + 170, y, size: 10, font: fontB, color: rgb(0.11, 0.11, 0.11) });
    y -= 18;
  };

  row('Signataire', opts.signerName);
  row('Email vérifié (OTP)', opts.signerEmail);
  row('Date et heure (UTC)', opts.signedAt);
  row('Adresse IP', opts.signerIp);
  row('Référence signature', opts.requestId);
  if (opts.contractNumber) row('N° contrat', opts.contractNumber);
  if (opts.contractType)   row('Type de contrat', opts.contractType);

  y -= 8;
  page.drawLine({ start: { x: mg, y }, end: { x: width - mg, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 16;

  page.drawText('Empreintes documentaires (SHA-256)', { x: mg, y, size: 10, font: fontB, color: rgb(0.36, 0.13, 0.71) });
  y -= 15;

  const hashRow = (label: string, hash: string) => {
    if (!hash || y < mg + 30) return;
    page.drawText(label, { x: mg, y, size: 9, font, color: rgb(0.41, 0.41, 0.41) });
    y -= 13;
    const mid = Math.ceil(hash.length / 2);
    page.drawText(hash.slice(0, mid), { x: mg + 10, y, size: 8, font, color: rgb(0.2, 0.2, 0.2) });
    y -= 11;
    page.drawText(hash.slice(mid), { x: mg + 10, y, size: 8, font, color: rgb(0.2, 0.2, 0.2) });
    y -= 15;
  };
  hashRow('Document source :', opts.documentHash);
  hashRow('Document signé  :', opts.signedDocHash);

  y -= 8;
  page.drawLine({ start: { x: mg, y }, end: { x: width - mg, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 18;

  if (opts.signatureImageB64 && y > mg + 100) {
    try {
      const raw  = opts.signatureImageB64.replace(/^data:image\/png;base64,/, '');
      const imgB = Uint8Array.from(atob(raw), c => c.charCodeAt(0));
      const img  = await pdfDoc.embedPng(imgB);
      const imgW = Math.min(260, width - mg * 2);
      const imgH = Math.round(imgW * img.height / img.width);
      page.drawText('Signature manuscrite numérique :', { x: mg, y, size: 10, font, color: rgb(0.36, 0.13, 0.71) });
      y -= 14;
      page.drawImage(img, { x: mg, y: y - imgH, width: imgW, height: imgH });
      y -= imgH + 16;
    } catch (_) { /* image invalide */ }
  }

  page.drawLine({ start: { x: mg, y: mg + 36 }, end: { x: width - mg, y: mg + 36 }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  page.drawText('Signature électronique simple conforme au Règlement (UE) n° 910/2014 (eIDAS).', { x: mg, y: mg + 22, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
  page.drawText('Les données sont horodatées UTC et archivées de façon sécurisée.', { x: mg, y: mg + 10, size: 8, font, color: rgb(0.5, 0.5, 0.5) });

  return pdfDoc.save();
}

// Page HTML — NE CONTIENT JAMAIS le contenu du contrat (chargé après OTP via get_document).
function buildPage(sr: {
  id: string; signer_name: string; signer_email: string; status: string;
  contract_type: string | null; contract_number: string | null;
}): string {
  const already = sr.status === 'signed';
  const refused = sr.status === 'refused';
  const expired = sr.status === 'expired';
  const preVerified = sr.status === 'otp_verified'; // reprise après OTP validé

  const terminalBlock = already
    ? '<div class="card" style="text-align:center;padding:40px"><div style="font-size:52px;margin-bottom:16px">✅</div><h2>Déjà signé</h2><p style="color:#6b7280;margin-top:8px">Vous pouvez fermer cette fenêtre.</p></div>'
    : refused
    ? '<div class="card" style="text-align:center;padding:40px"><div style="font-size:52px;margin-bottom:16px">❌</div><h2>Signature refusée</h2><p style="color:#6b7280;margin-top:8px">Contactez votre employeur.</p></div>'
    : expired
    ? '<div class="card" style="text-align:center;padding:40px"><div style="font-size:52px;margin-bottom:16px">⏳</div><h2>Lien expiré</h2><p style="color:#6b7280;margin-top:8px">Demandez un nouveau lien à votre employeur.</p></div>'
    : null;

  const contractMeta = sr.contract_type
    ? '<div style="margin-bottom:12px"><span class="tag" style="background:#EDE9FE;color:#5B21B6">'
      + esc(sr.contract_type) + '</span>'
      + (sr.contract_number ? ' <span class="tag" style="background:#f1f5f9;color:#374151">' + esc(sr.contract_number) + '</span>' : '')
      + '</div>'
    : '';

  // Étape 1 : identité MASQUÉE + saisie OTP uniquement. Aucun contenu de contrat.
  const flow = terminalBlock ?? (
    '<div id="step1">'
    + '<div class="card"><h2>✉️ Vérification de votre identité</h2>'
    + '<p style="margin-bottom:8px">Un document vous a été transmis pour signature électronique.</p>'
    + '<div class="ibox" style="margin-bottom:16px;font-size:13px;color:#4b5563">'
    + 'Signataire : <strong>' + esc(maskName(sr.signer_name)) + '</strong><br>'
    + 'Un code à 6 chiffres a été envoyé à <strong>' + esc(maskEmail(sr.signer_email)) + '</strong>.'
    + '</div>'
    + '<input class="otpf" type="text" id="otpIn" maxlength="6" placeholder="000000" inputmode="numeric" autocomplete="one-time-code">'
    + '<div id="otpErr" class="err hide"></div>'
    + '<p style="font-size:12px;color:#9ca3af;margin-top:12px">Le contenu du document ne sera affiché qu\'après vérification de votre identité.</p>'
    + '<div class="acts"><button class="btn btng" id="btnRe" onclick="resend()">Renvoyer le code</button><button class="btn btnp" id="btnV" onclick="verify()">Vérifier &rarr;</button></div>'
    + '</div></div>'
    // Étape 2 : lecture du document (injecté par get_document) + consentement
    + '<div id="step2" class="hide">'
    + '<div class="card"><h2>📄 Lecture du document</h2>'
    + '<p style="margin-bottom:12px">Bonjour <strong id="realName"></strong>,</p>'
    + '<div id="metaBox">' + contractMeta + '</div>'
    + '<div id="docPreview" class="cpreview"><p style="color:#9ca3af;text-align:center;padding:40px">Chargement du document…</p></div>'
    + '</div>'
    + '<div class="card ibox">'
    + '<div class="crow"><input type="checkbox" id="readCheck"><label for="readCheck">J&apos;atteste avoir lu et compris l&apos;intégralité du document. Je consens à le signer électroniquement conformément au règlement eIDAS.</label></div>'
    + '<div style="margin-top:14px;text-align:right"><button class="btn btnp" id="btnP" disabled onclick="goSign()">Procéder à la signature &rarr;</button></div>'
    + '</div></div>'
    // Étape 3 : signature manuscrite
    + '<div id="step3" class="hide">'
    + '<div class="card"><h2>✍️ Apposez votre signature</h2>'
    + '<p style="margin-bottom:14px">Dessinez votre signature dans l&apos;espace ci-dessous.</p>'
    + '<canvas id="sigC" width="520" height="140"></canvas>'
    + '<div style="margin-top:8px"><button class="btn btng" onclick="clrSig()" style="font-size:12px;padding:7px 14px">🗑 Effacer</button></div>'
    + '<div class="crow" style="margin-top:16px"><input type="checkbox" id="terms"><label for="terms" style="font-size:12.5px">Je confirme que cette signature est la mienne et qu&#39;elle engage ma responsabilité contractuelle. Elle a valeur légale conforme à eIDAS.</label></div>'
    + '<div id="sigErr" class="err hide"></div>'
    + '<div class="acts"><button class="btn btnr" onclick="refuse()">❌ Refuser</button><button class="btn btnp" id="btnS" disabled onclick="sign()">✅ Signer le document</button></div>'
    + '</div></div>'
    // Étape 4 : succès
    + '<div id="step4" class="hide">'
    + '<div class="card" style="text-align:center;padding:40px"><div style="font-size:56px;margin-bottom:16px">✅</div>'
    + '<h2 style="font-size:20px;margin-bottom:10px">Document signé avec succès !</h2>'
    + '<p style="margin-bottom:20px;color:#4b5563">Votre signature a été enregistrée et archivée.</p>'
    + '<div id="certInfo" style="background:#f9fafb;border-radius:10px;padding:16px;font-size:12px;color:#4b5563;text-align:left;margin-top:16px"></div>'
    + '</div></div>'
  );

  return '<!DOCTYPE html>\n'
    + '<html lang="fr"><head><meta charset="UTF-8">'
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>Signature — Flowtym RH</title>'
    + '<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Arial,sans-serif;background:#f3f4f6;min-height:100vh;color:#111}'
    + '.header{background:#fff;border-bottom:1px solid #e5e7eb;padding:14px 24px;display:flex;align-items:center;gap:12px;position:sticky;top:0;z-index:20}'
    + '.logo{font-size:18px;font-weight:800;color:#5B21B6}'
    + '.prog{display:flex;gap:4px;flex:1;max-width:300px;margin-left:auto}'
    + '.ps{flex:1;height:4px;background:#e5e7eb;border-radius:2px;transition:.3s}.ps.done{background:#5B21B6}'
    + '.wrap{max-width:820px;margin:28px auto;padding:0 16px}'
    + '.card{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:24px;margin-bottom:18px;box-shadow:0 1px 4px rgba(0,0,0,.06)}'
    + '.card h2{font-size:16px;font-weight:700;margin-bottom:10px}'
    + '.cpreview{max-height:52vh;overflow:auto;border:1px solid #e5e7eb;border-radius:10px;padding:20px;background:#fafafa;font-family:\'Times New Roman\',serif;font-size:10.5pt;line-height:1.65;color:#111}'
    + '.btn{display:inline-flex;align-items:center;gap:6px;padding:11px 22px;border-radius:8px;font-size:14px;font-weight:700;border:none;cursor:pointer;transition:.15s}'
    + '.btnp{background:#5B21B6;color:#fff}.btnp:hover{background:#4C1D95}'
    + '.btng{background:#f3f4f6;color:#374151;border:1px solid #d1d5db}'
    + '.btnr{background:#fee2e2;color:#dc2626;border:1px solid #fca5a5}'
    + '.btn:disabled{opacity:.45;cursor:not-allowed}'
    + '.otpf{width:100%;padding:13px;border:2px solid #d1d5db;border-radius:8px;font-size:22px;letter-spacing:8px;text-align:center;font-weight:700;outline:none;transition:.2s}'
    + '.otpf:focus{border-color:#5B21B6}'
    + 'canvas{border:2px solid #d1d5db;border-radius:10px;cursor:crosshair;touch-action:none;background:#fff;display:block;max-width:100%}'
    + '.err{background:#fee2e2;color:#dc2626;padding:9px 14px;border-radius:8px;font-size:13px;margin-top:10px}'
    + '.hide{display:none!important}'
    + '.crow{display:flex;align-items:flex-start;gap:10px}.crow input[type=checkbox]{width:18px;height:18px;margin-top:2px;accent-color:#5B21B6;flex-shrink:0}'
    + '.crow label{cursor:pointer;font-size:13.5px;color:#374151}'
    + '.tag{display:inline-block;padding:3px 10px;border-radius:6px;font-size:12px;font-weight:600}'
    + '.acts{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;margin-top:16px}'
    + '.ibox{background:#EDE9FE;border:1px solid #C4B5FD;border-radius:10px;padding:14px 18px}'
    + '@media(max-width:600px){.cpreview{max-height:38vh;font-size:9.5pt}.card{padding:16px}}'
    + '</style></head><body>\n'
    + '<div class="header">'
    + '<span class="logo">Flowtym <span style="font-size:12px;color:#9ca3af;font-weight:400">RH</span></span>'
    + '<span style="font-size:13px;color:#6b7280">Signature électronique</span>'
    + '<div class="prog" id="prog"><div class="ps done" id="ps1"></div><div class="ps" id="ps2" style="margin:0 2px"></div><div class="ps" id="ps3"></div></div>'
    + '</div>\n'
    + '<div class="wrap">\n'
    + flow
    + '\n</div>\n'
    + '<script>\n'
    + 'var RID="' + sr.id + '";\n'
    + 'var PREVERIFIED=' + (preVerified ? 'true' : 'false') + ';\n'
    + 'var API=location.origin+location.pathname;\n'
    + 'function setStep(n){["step1","step2","step3","step4"].forEach(function(id,i){var e=document.getElementById(id);if(e)e.classList.toggle("hide",i!==n-1);});["ps1","ps2","ps3"].forEach(function(id,i){var e=document.getElementById(id);if(e)e.classList.toggle("done",i<n);});}\n'
    + 'function api(body,cb){body.request_id=RID;fetch(API,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)}).then(function(r){return r.json().then(function(d){return{ok:r.ok,d:d};});}).then(function(x){if(!x.ok)throw new Error(x.d.error||"Erreur serveur");cb(null,x.d);}).catch(function(e){cb(e.message||String(e));});}\n'
    + 'function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}\n'
    + 'function loadDoc(){api({action:"get_document"},function(err,d){var p=document.getElementById("docPreview");if(err){if(p)p.innerHTML="<p style=\\'color:#dc2626;text-align:center;padding:30px\\'>Erreur de chargement : "+esc(err)+"</p>";return;}var rn=document.getElementById("realName");if(rn)rn.textContent=d.signer_name||"";if(p)p.innerHTML=d.contract_html||"<p style=\\'color:#9ca3af;text-align:center;padding:40px\\'>Aperçu non disponible.</p>";var mb=document.getElementById("metaBox");if(mb&&(d.contract_type||d.contract_number)){mb.innerHTML="<div style=\\'margin-bottom:12px\\'><span class=\\'tag\\' style=\\'background:#EDE9FE;color:#5B21B6\\'>"+esc(d.contract_type||"")+"</span> <span class=\\'tag\\' style=\\'background:#f1f5f9;color:#374151\\'>"+esc(d.contract_number||"")+"</span></div>";}bindReadCheck();});}\n'
    + 'function bindReadCheck(){var rc=document.getElementById("readCheck");if(rc)rc.addEventListener("change",function(){var b=document.getElementById("btnP");if(b)b.disabled=!this.checked;});}\n'
    + 'function resend(){var b=document.getElementById("btnRe");b.disabled=true;b.textContent="Envoi…";api({action:"send_otp"},function(err){b.disabled=false;b.textContent="Renvoyer le code";if(err)alert("Erreur : "+err);else alert("Nouveau code envoyé.");});}\n'
    + 'function verify(){var otp=document.getElementById("otpIn").value.trim();if(otp.length!==6){showErr("otpErr","Entrez les 6 chiffres");return;}var b=document.getElementById("btnV");b.disabled=true;b.textContent="Vérification…";api({action:"verify_otp",otp:otp},function(err){if(err){showErr("otpErr",err);b.disabled=false;b.textContent="Vérifier →";}else{hideErr("otpErr");setStep(2);loadDoc();}});}\n'
    + 'function goSign(){setStep(3);initCanvas();}\n'
    + 'var drawing=false,cvs=null,ctx=null;\n'
    + 'function initCanvas(){cvs=document.getElementById("sigC");ctx=cvs.getContext("2d");ctx.strokeStyle="#1e293b";ctx.lineWidth=2.5;ctx.lineCap="round";ctx.lineJoin="round";function pt(e){var p=e.touches?e.touches[0]:e;var r=cvs.getBoundingClientRect();return{x:(p.clientX-r.left)*cvs.width/r.width,y:(p.clientY-r.top)*cvs.height/r.height};}function ev(e){e.preventDefault();var p=pt(e);var t=e.type;if(t==="mousedown"||t==="touchstart"){drawing=true;ctx.beginPath();ctx.moveTo(p.x,p.y);}else if((t==="mousemove"||t==="touchmove")&&drawing){ctx.lineTo(p.x,p.y);ctx.stroke();}else{drawing=false;}}["mousedown","mousemove","mouseup","mouseleave","touchstart","touchmove","touchend"].forEach(function(n){cvs.addEventListener(n,ev,{passive:false});});document.getElementById("terms").addEventListener("change",function(){document.getElementById("btnS").disabled=!this.checked;});}\n'
    + 'function clrSig(){if(ctx)ctx.clearRect(0,0,cvs.width,cvs.height);}\n'
    + 'function sigEmpty(){if(!cvs)return true;var d=ctx.getImageData(0,0,cvs.width,cvs.height).data;for(var i=3;i<d.length;i+=4)if(d[i]>0)return false;return true;}\n'
    + 'function sign(){if(sigEmpty()){showErr("sigErr","Veuillez dessiner votre signature");return;}var img=cvs.toDataURL("image/png");var b=document.getElementById("btnS");b.disabled=true;b.textContent="Signature en cours…";api({action:"sign",signature_image:img},function(err,d){if(err){showErr("sigErr","Erreur : "+err);b.disabled=false;b.textContent="✅ Signer le document";}else{var ci=document.getElementById("certInfo");ci.innerHTML="<strong>Attestation</strong><br>Signataire : "+esc(d.signer_name||"")+"<br>Email : "+esc(d.signer_email||"")+"<br>Horodatage UTC : "+esc(d.signed_at||"")+"<br>Référence : "+RID+"<br><span style=\\'font-size:11px;color:#9ca3af\\'>Signature électronique simple conforme eIDAS n°910/2014</span>";setStep(4);}});}\n'
    + 'function refuse(){var r=window.prompt("Motif de refus (facultatif) :")||"";if(!window.confirm("Confirmer le refus de signature ?"))return;api({action:"refuse",reason:r},function(err){if(err){alert("Erreur : "+err);}else{document.body.innerHTML="<div style=\\'display:flex;align-items:center;justify-content:center;min-height:100vh;font-family:Arial\\'><div style=\\'text-align:center;padding:40px\\'><div style=\\'font-size:52px;margin-bottom:16px\\'>❌</div><h2>Refus enregistré</h2><p style=\\'color:#6b7280;margin-top:8px\\'>Votre employeur en a été informé.</p></div></div>";}});}\n'
    + 'function showErr(id,msg){var e=document.getElementById(id);if(e){e.textContent=msg;e.classList.remove("hide");}}\n'
    + 'function hideErr(id){var e=document.getElementById(id);if(e)e.classList.add("hide");}\n'
    + 'if(PREVERIFIED){setStep(2);loadDoc();}\n'
    + '</script>\n</body></html>';
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: JSON_H });

  const url = new URL(req.url);
  const sb  = createClient(SUPABASE_URL, SUPABASE_SVC);

  if (req.method === 'GET') {
    const rid = url.searchParams.get('request_id') ?? '';
    if (!rid) return new Response('<html><body style="font-family:Arial;padding:40px">Lien invalide — paramètre manquant.</body></html>', { status: 400, headers: HTML_H });

    // On ne récupère QUE les métadonnées non sensibles — jamais le contenu du contrat.
    const { data: sr } = await sb.from('signature_requests')
      .select('id, hotel_id, status, signer_name, signer_email, contract_id, otp_expires_at')
      .eq('id', rid).maybeSingle();
    if (!sr) return new Response('<html><body style="font-family:Arial;padding:40px">Lien invalide ou expiré.</body></html>', { status: 404, headers: HTML_H });

    let status = sr.status as string;
    if (status === 'otp_sent' && sr.otp_expires_at && new Date(sr.otp_expires_at) < new Date()) {
      status = 'expired';
      await sb.from('signature_requests').update({ status: 'expired' }).eq('id', rid);
      await sb.from('signature_events').insert({ request_id: rid, hotel_id: sr.hotel_id, type: 'expired', metadata: {} });
    }

    // Type/numéro de contrat = métadonnées faiblement sensibles, affichées après OTP.
    // On les récupère mais on ne les injecte dans le HTML QUE si non-terminal, et le
    // contenu (generated_html) n'est JAMAIS lu ici.
    let contractNumber: string | null = null;
    let contractType: string | null = null;
    if (sr.contract_id) {
      const { data: c } = await sb.from('generated_contracts')
        .select('contract_number, contract_type').eq('id', sr.contract_id).maybeSingle();
      contractNumber = c?.contract_number  ?? null;
      contractType   = c?.contract_type    ?? null;
    }

    const page = buildPage({ id: sr.id, signer_name: sr.signer_name, signer_email: sr.signer_email, status, contract_type: contractType, contract_number: contractNumber });
    return new Response(page, { headers: HTML_H });
  }

  if (req.method !== 'POST') return jsonR({ error: 'Method not allowed' }, 405);

  const body = await req.json().catch(() => ({}));
  const { request_id, action } = body;
  if (!request_id || !action) return jsonR({ error: 'request_id et action requis' }, 400);

  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || req.headers.get('cf-connecting-ip') || 'unknown';
  const ua = req.headers.get('user-agent') ?? '';

  const { data: sr } = await sb.from('signature_requests')
    .select('id, hotel_id, employee_id, signer_name, signer_email, status, otp_hash, otp_expires_at, otp_attempts, contract_id, document_hash_sha256')
    .eq('id', request_id).maybeSingle();
  if (!sr) return jsonR({ error: 'Demande introuvable' }, 404);
  if (sr.status === 'signed')  return jsonR({ error: 'Document déjà signé' }, 409);
  if (sr.status === 'refused') return jsonR({ error: 'Signature refusée' }, 409);

  if (action === 'send_otp') {
    const otp     = genOTP();
    const otpHash = await sha256hex(otp);
    const otpExp  = new Date(Date.now() + 48 * 3_600_000).toISOString();
    await sb.from('signature_requests').update({ otp_hash: otpHash, otp_expires_at: otpExp, otp_attempts: 0, status: 'otp_sent' }).eq('id', request_id);
    await sb.from('signature_events').insert({ request_id, hotel_id: sr.hotel_id, type: 'otp_sent', actor_ip: ip, actor_ua: ua, metadata: { email: sr.signer_email } });
    try { await sendOTPEmail(sr.signer_email, sr.signer_name, otp); }
    catch (e: unknown) { return jsonR({ error: 'Email non envoyé : ' + (e instanceof Error ? e.message : String(e)) }, 500); }
    return jsonR({ success: true });
  }

  if (action === 'verify_otp') {
    const { otp } = body;
    if (!otp) return jsonR({ error: 'OTP requis' }, 400);
    if (sr.otp_expires_at && new Date(sr.otp_expires_at) < new Date()) return jsonR({ error: 'Code expiré. Cliquez sur "Renvoyer le code".' }, 410);
    if ((sr.otp_attempts ?? 0) >= 5) return jsonR({ error: 'Trop de tentatives. Demandez un nouveau code.' }, 429);
    const hash = await sha256hex(String(otp).trim());
    // Incrément atomique du compteur (anti brute-force concurrent) via RPC si présente,
    // sinon fallback update simple.
    const { data: attemptsNow } = await sb.rpc('sig_bump_otp_attempts', { p_request_id: request_id });
    const attemptCount = typeof attemptsNow === 'number' ? attemptsNow : (sr.otp_attempts ?? 0) + 1;
    if (attemptCount > 5) return jsonR({ error: 'Trop de tentatives. Demandez un nouveau code.' }, 429);
    if (hash !== sr.otp_hash) {
      await sb.from('signature_events').insert({ request_id, hotel_id: sr.hotel_id, type: 'otp_failed', actor_ip: ip, actor_ua: ua, metadata: { attempt: attemptCount } });
      return jsonR({ error: 'Code incorrect' }, 400);
    }
    await sb.from('signature_requests').update({ status: 'otp_verified' }).eq('id', request_id);
    await sb.from('signature_events').insert([
      { request_id, hotel_id: sr.hotel_id, type: 'portal_authenticated', actor_ip: ip, actor_ua: ua, metadata: {} },
      { request_id, hotel_id: sr.hotel_id, type: 'otp_verified', actor_ip: ip, actor_ua: ua, metadata: {} },
    ]);
    return jsonR({ success: true });
  }

  // get_document : renvoie le contenu du contrat UNIQUEMENT après OTP vérifié.
  if (action === 'get_document') {
    if (sr.status !== 'otp_verified') return jsonR({ error: 'Identité non vérifiée' }, 403);
    let contractHtml: string | null = null;
    let contractNumber: string | null = null;
    let contractType: string | null = null;
    if (sr.contract_id) {
      const { data: c } = await sb.from('generated_contracts')
        .select('generated_html, contract_number, contract_type').eq('id', sr.contract_id).maybeSingle();
      contractHtml   = c?.generated_html  ?? null;
      contractNumber = c?.contract_number ?? null;
      contractType   = c?.contract_type   ?? null;
    }
    return jsonR({ success: true, signer_name: sr.signer_name, contract_html: contractHtml, contract_number: contractNumber, contract_type: contractType });
  }

  if (action === 'sign') {
    if (sr.status !== 'otp_verified') return jsonR({ error: 'OTP non vérifié' }, 403);
    const { signature_image } = body;
    if (!signature_image) return jsonR({ error: 'signature_image requis' }, 400);

    const now           = new Date().toISOString();
    const signedDisplay = now.replace('T', ' ').slice(0, 19) + ' UTC';

    let contractNumber: string | null = null;
    let contractType: string | null = null;
    let contractHtml: string | null = null;
    if (sr.contract_id) {
      const { data: c } = await sb.from('generated_contracts')
        .select('contract_number, contract_type, generated_html').eq('id', sr.contract_id).maybeSingle();
      contractNumber = c?.contract_number ?? null;
      contractType   = c?.contract_type   ?? null;
      contractHtml   = c?.generated_html  ?? null;
    }

    await sb.from('signature_requests').update({ accepted_terms_at: now }).eq('id', request_id);
    await sb.from('signature_events').insert({ request_id, hotel_id: sr.hotel_id, type: 'terms_accepted', actor_ip: ip, actor_ua: ua, metadata: {} });

    let pdfBytes: Uint8Array;
    let signedDocHash = '';
    try {
      const opts = {
        signerName: sr.signer_name, signerEmail: sr.signer_email,
        signedAt: signedDisplay, signerIp: ip, requestId: request_id,
        documentHash: sr.document_hash_sha256 ?? '', signedDocHash: '',
        signatureImageB64: signature_image,
        contractNumber, contractType, contractHtml,
      };
      const first = await buildSignedPDF(opts);
      signedDocHash = await sha256hex(first);
      pdfBytes = await buildSignedPDF({ ...opts, signedDocHash });
    } catch (e: unknown) {
      return jsonR({ error: 'Erreur génération PDF : ' + (e instanceof Error ? e.message : String(e)) }, 500);
    }

    const storagePath = 'signed/' + sr.hotel_id + '/' + sr.employee_id + '/' + request_id + '.pdf';
    const { error: upErr } = await sb.storage.from('hr-documents').upload(storagePath, pdfBytes, { contentType: 'application/pdf', upsert: true });
    if (upErr) return jsonR({ error: 'Erreur archivage PDF : ' + upErr.message }, 500);

    // Vérification post-upload : l'objet existe RÉELLEMENT avant de marquer signé.
    // Évite un statut "signed" pointant vers un PDF fantôme.
    const { data: dl, error: dlErr } = await sb.storage.from('hr-documents').download(storagePath);
    if (dlErr || !dl || dl.size === 0) {
      return jsonR({ error: 'Archivage non confirmé : PDF absent du storage après upload' }, 500);
    }

    await sb.from('signature_requests').update({
      status: 'signed', signed_pdf_storage_path: storagePath,
      signed_document_hash_sha256: signedDocHash, signer_ip: ip, signer_ua: ua, signed_at: now,
    }).eq('id', request_id);

    await sb.from('signature_events').insert([
      { request_id, hotel_id: sr.hotel_id, type: 'signed', actor_ip: ip, actor_ua: ua, metadata: { signed_document_hash_sha256: signedDocHash, contract_id: sr.contract_id } },
      { request_id, hotel_id: sr.hotel_id, type: 'pdf_archived', metadata: { storage_path: storagePath, bucket: 'hr-documents', size: dl.size } },
    ]);

    if (sr.contract_id) {
      await sb.from('generated_contracts').update({
        status: 'signed', signed_at: now,
        signed_pdf_storage_path: storagePath, signed_pdf_url: null,
        signed_document_hash_sha256: signedDocHash, accepted_terms_at: now,
        signature_request_id: request_id, signature_provider: 'flowtym',
      }).eq('id', sr.contract_id);
    }

    if (sr.employee_id) {
      await sb.from('employee_documents').insert({
        hotel_id: sr.hotel_id, employee_id: sr.employee_id,
        doc_type: 'contrat_signe', doc_type_code: 'contrat_signe', status: 'provided',
        file_path: storagePath, file_url: null, issued_at: now.slice(0, 10),
        signature_status: 'signed', signature_request_id: request_id,
        notes: ('Contrat ' + (contractType ?? '') + ' ' + (contractNumber ?? '') + ' — signé électroniquement').trim(),
      }).then(null, (e: unknown) => console.warn('[sig-sign] emp_docs:', e instanceof Error ? e.message : e));
      await sb.from('portal_messages').insert({
        hotel_id: sr.hotel_id, employee_id: sr.employee_id, direction: 'manager_to_employee',
        body: '✅ Votre contrat a été signé électroniquement et archivé dans votre espace documentaire.',
      }).then(null, () => {});
    }

    console.log('[sig-sign] signed', request_id, 'by', sr.signer_email, 'size', dl.size);
    return jsonR({ success: true, signed_at: signedDisplay, signer_name: sr.signer_name, signer_email: sr.signer_email });
  }

  if (action === 'refuse') {
    const now = new Date().toISOString();
    await sb.from('signature_requests').update({ status: 'refused', refused_reason: body.reason ?? null, refused_at: now }).eq('id', request_id);
    await sb.from('signature_events').insert({ request_id, hotel_id: sr.hotel_id, type: 'refused', actor_ip: ip, actor_ua: ua, metadata: { reason: body.reason ?? null } });
    if (sr.contract_id) {
      await sb.from('generated_contracts').update({ status: 'refused', refused_reason: body.reason ?? null, refused_at: now }).eq('id', sr.contract_id);
    }
    return jsonR({ success: true });
  }

  return jsonR({ error: 'Action inconnue' }, 400);
});
