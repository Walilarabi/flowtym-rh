import { createClient } from 'jsr:@supabase/supabase-js@2';

// Page publique de signature électronique (sans JWT).
// GET  ?token=xxx          → page HTML de signature
// POST {token, action, …}  → API (send_otp / sign)

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RESEND_KEY    = Deno.env.get('RESEND_API_KEY') ?? '';
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const JSON_CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Content-Type': 'application/json',
};

function jsonResp(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_CORS });
}

// ── Génération OTP ────────────────────────────────────────────────────────────
function genOTP(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

// ── Envoi email OTP ───────────────────────────────────────────────────────────
async function sendOTPEmail(to: string, name: string, otp: string): Promise<void> {
  const html = `<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;background:#f5f5f5;padding:30px">
  <div style="max-width:420px;margin:0 auto;background:#fff;border-radius:12px;padding:32px">
    <div style="text-align:center;margin-bottom:20px">
      <span style="font-size:20px;font-weight:800;color:#5B21B6">Flowtym</span><span style="font-size:13px;color:#9ca3af"> RH</span>
    </div>
    <h3 style="color:#111;font-size:16px">Bonjour ${name || ''},</h3>
    <p style="color:#374151;font-size:14px">Votre code de vérification pour signer votre contrat :</p>
    <div style="text-align:center;margin:24px 0">
      <span style="font-size:36px;font-weight:800;letter-spacing:8px;color:#5B21B6;background:#EDE9FE;padding:16px 24px;border-radius:10px;display:inline-block">${otp}</span>
    </div>
    <p style="color:#6b7280;font-size:12px">Ce code est valable <strong>10 minutes</strong>. Ne le communiquez à personne.</p>
  </div></body></html>`;

  if (RESEND_KEY) {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: 'Flowtym RH <noreply@flowtym.com>', to: [to], subject: `Code de signature : ${otp}`, html }),
    });
    return;
  }
  // Fallback Supabase SMTP — on envoie un magic link avec le code dans le message
  const sbAnon = createClient(SUPABASE_URL, SUPABASE_ANON);
  await sbAnon.auth.resetPasswordForEmail(to, { redirectTo: `${SUPABASE_URL}/functions/v1/contract-sign?otp=${otp}` });
}

// ── Page HTML de signature ────────────────────────────────────────────────────
function signingPage(session: {
  signer_name: string; signer_email: string; contract_number: string;
  contract_type: string; contract_label: string; contract_html: string;
  token: string; expired: boolean; already_signed: boolean;
}): string {
  if (session.expired) return errorPage('Lien expiré', 'Ce lien de signature a expiré. Veuillez contacter votre employeur pour en obtenir un nouveau.');
  if (session.already_signed) return errorPage('Déjà signé', 'Ce contrat a déjà été signé. Vous pouvez fermer cette fenêtre.');

  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Signature de contrat — Flowtym RH</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;background:#f3f4f6;min-height:100vh}
.header{background:#fff;border-bottom:1px solid #e5e7eb;padding:14px 24px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10}
.logo{font-size:18px;font-weight:800;color:#5B21B6}
.logo small{font-size:12px;color:#9ca3af;font-weight:400}
.step-bar{display:flex;gap:0;margin:0 auto;max-width:480px;padding:0 24px}
.step{flex:1;height:4px;background:#e5e7eb;transition:.3s}
.step.done{background:#5B21B6}
.container{max-width:860px;margin:24px auto;padding:0 16px}
.card{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:24px;box-shadow:0 1px 4px rgba(0,0,0,.06);margin-bottom:20px}
h2{font-size:17px;font-weight:700;color:#111;margin-bottom:6px}
p{font-size:13.5px;color:#4b5563;line-height:1.6}
.contract-wrap{max-height:55vh;overflow:auto;border:1px solid #e5e7eb;border-radius:10px;padding:20px;background:#fafafa;font-family:'Times New Roman',serif;font-size:11pt;line-height:1.6;color:#111}
.btn{display:inline-flex;align-items:center;gap:8px;padding:12px 24px;border-radius:8px;font-size:14px;font-weight:700;border:none;cursor:pointer;transition:.15s}
.btn-primary{background:#5B21B6;color:#fff}
.btn-primary:hover{background:#4C1D95}
.btn-secondary{background:#f3f4f6;color:#374151;border:1px solid #d1d5db}
.btn:disabled{opacity:.5;cursor:not-allowed}
input[type=text]{width:100%;padding:12px 16px;border:2px solid #d1d5db;border-radius:8px;font-size:16px;outline:none;transition:.2s;letter-spacing:4px;text-align:center;font-weight:700}
input[type=text]:focus{border-color:#5B21B6}
canvas{border:2px solid #d1d5db;border-radius:10px;touch-action:none;cursor:crosshair;background:#fff;max-width:100%}
.sig-wrap{display:flex;flex-direction:column;align-items:center;gap:10px}
.tag{display:inline-block;padding:3px 10px;border-radius:6px;font-size:12px;font-weight:600}
.error-msg{background:#fee2e2;color:#dc2626;padding:10px 14px;border-radius:8px;font-size:13px;margin-top:10px}
.success-icon{font-size:60px;text-align:center;margin-bottom:16px}
.hide{display:none!important}
@media(max-width:600px){.contract-wrap{max-height:40vh;font-size:10pt}.container{padding:0 8px}.card{padding:16px}}
</style>
</head>
<body>
<div class="header">
  <span class="logo">Flowtym <small>RH</small></span>
  <span style="font-size:13px;color:#6b7280;margin-left:8px">Signature électronique</span>
  <div style="flex:1"></div>
  <div class="step-bar" id="stepBar">
    <div class="step done" id="s1"></div>
    <div class="step" id="s2" style="margin:0 3px"></div>
    <div class="step" id="s3"></div>
  </div>
</div>

<div class="container">

<!-- ÉTAPE 1 : Lecture du contrat -->
<div id="step1">
  <div class="card">
    <h2>📄 Lecture du contrat</h2>
    <p style="margin-bottom:14px">Bonjour <strong>${session.signer_name || ''}</strong>, veuillez lire attentivement votre contrat avant de le signer.</p>
    <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px">
      <span class="tag" style="background:#EDE9FE;color:#5B21B6">${session.contract_type || ''}</span>
      <span class="tag" style="background:#f1f5f9;color:#374151">${session.contract_number || ''}</span>
    </div>
    <div class="contract-wrap" id="contractPreview">${session.contract_html || '<p style="color:#9ca3af;text-align:center;padding:40px">Contrat en cours de chargement…</p>'}</div>
  </div>
  <div class="card" style="background:#EDE9FE;border-color:#C4B5FD">
    <div style="display:flex;align-items:flex-start;gap:12px">
      <input type="checkbox" id="readCheck" style="width:18px;height:18px;margin-top:2px;accent-color:#5B21B6">
      <label for="readCheck" style="font-size:13.5px;color:#374151;cursor:pointer">
        J'atteste avoir lu et compris l'intégralité du contrat. Je consens à le signer électroniquement conformément au règlement eIDAS.
      </label>
    </div>
    <div style="margin-top:14px;text-align:right">
      <button class="btn btn-primary" id="btnProceed" onclick="proceedToOTP()" disabled>
        Procéder à la signature →
      </button>
    </div>
  </div>
</div>

<!-- ÉTAPE 2 : Vérification OTP -->
<div id="step2" class="hide">
  <div class="card">
    <h2>✉️ Vérification de votre identité</h2>
    <p style="margin-bottom:16px">Un code à 6 chiffres a été envoyé à <strong>${session.signer_email}</strong>. Saisissez-le ci-dessous pour confirmer votre identité.</p>
    <input type="text" id="otpInput" maxlength="6" placeholder="000000" inputmode="numeric" autocomplete="one-time-code">
    <div id="otpError" class="error-msg hide"></div>
    <div style="display:flex;justify-content:space-between;align-items:center;margin-top:14px;flex-wrap:wrap;gap:8px">
      <button class="btn btn-secondary" onclick="resendOTP()" id="btnResend">Renvoyer le code</button>
      <button class="btn btn-primary" id="btnVerify" onclick="verifyOTP()">Vérifier →</button>
    </div>
  </div>
</div>

<!-- ÉTAPE 3 : Signature manuscrite -->
<div id="step3" class="hide">
  <div class="card">
    <h2>✍️ Apposez votre signature</h2>
    <p style="margin-bottom:16px">Dessinez votre signature dans l'espace ci-dessous. Votre signature, votre nom, la date et votre adresse IP seront associés au document.</p>
    <div class="sig-wrap">
      <canvas id="sigCanvas" width="520" height="140"></canvas>
      <button class="btn btn-secondary" onclick="clearSig()" style="font-size:12px;padding:7px 16px">🗑 Effacer</button>
    </div>
    <div id="sigError" class="error-msg hide" style="margin-top:10px"></div>
    <div style="margin-top:16px;text-align:right">
      <button class="btn btn-primary" id="btnSign" onclick="submitSignature()">
        ✅ Signer et valider le contrat
      </button>
    </div>
  </div>
</div>

<!-- ÉTAPE 4 : Succès -->
<div id="step4" class="hide">
  <div class="card" style="text-align:center;padding:40px 24px">
    <div class="success-icon">✅</div>
    <h2 style="font-size:20px;margin-bottom:10px">Contrat signé avec succès !</h2>
    <p style="margin-bottom:20px">Votre contrat a été signé électroniquement et archivé.<br>Vous pouvez fermer cette fenêtre.</p>
    <div id="pdfLink"></div>
    <div style="margin-top:24px;padding:16px;background:#f9fafb;border-radius:10px;font-size:12px;color:#6b7280;text-align:left">
      <strong>Attestation de signature :</strong><br>
      Signataire : <span id="certName"></span><br>
      Email : ${session.signer_email}<br>
      Horodatage : <span id="certDate"></span><br>
      Réf. document : ${session.contract_number || '—'}<br>
      Conformité : Règlement eIDAS (UE) n°910/2014 — Signature électronique simple
    </div>
  </div>
</div>

</div><!-- /container -->

<script>
const TOKEN = '${session.token}';
const API   = location.origin + location.pathname;
let step = 1;

function setStep(n) {
  step = n;
  ['step1','step2','step3','step4'].forEach((id,i) => {
    document.getElementById(id).classList.toggle('hide', i !== n-1);
  });
  ['s1','s2','s3'].forEach((id,i) => {
    document.getElementById(id).classList.toggle('done', i < n);
  });
}

// Step 1
document.getElementById('readCheck').addEventListener('change', function() {
  document.getElementById('btnProceed').disabled = !this.checked;
});

async function proceedToOTP() {
  document.getElementById('btnProceed').disabled = true;
  document.getElementById('btnProceed').textContent = 'Envoi du code…';
  try {
    const r = await fetch(API, {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ token: TOKEN, action: 'send_otp' }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || 'Erreur envoi OTP');
    setStep(2);
  } catch(e) {
    document.getElementById('btnProceed').disabled = false;
    document.getElementById('btnProceed').textContent = 'Procéder à la signature →';
    alert('Erreur : ' + e.message);
  }
}

async function resendOTP() {
  document.getElementById('btnResend').disabled = true;
  await proceedToOTP().catch(() => {});
  document.getElementById('btnResend').disabled = false;
}

async function verifyOTP() {
  const otp = document.getElementById('otpInput').value.trim();
  if (otp.length !== 6) { showError('otpError','Entrez les 6 chiffres du code'); return; }
  document.getElementById('btnVerify').disabled = true;
  document.getElementById('btnVerify').textContent = 'Vérification…';
  try {
    const r = await fetch(API, {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ token: TOKEN, action: 'verify_otp', otp }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || 'Code incorrect');
    hideError('otpError');
    setStep(3);
    initCanvas();
  } catch(e) {
    showError('otpError', e.message);
    document.getElementById('btnVerify').disabled = false;
    document.getElementById('btnVerify').textContent = 'Vérifier →';
  }
}

// Canvas
let drawing = false, canvas, ctx;
function initCanvas() {
  canvas = document.getElementById('sigCanvas');
  ctx = canvas.getContext('2d');
  ctx.strokeStyle = '#1e293b';
  ctx.lineWidth = 2.5;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  const on = (e) => {
    e.preventDefault();
    const pt = e.touches ? e.touches[0] : e;
    const r = canvas.getBoundingClientRect();
    const x = (pt.clientX - r.left) * (canvas.width / r.width);
    const y = (pt.clientY - r.top)  * (canvas.height / r.height);
    if (e.type==='mousedown'||e.type==='touchstart') { drawing=true; ctx.beginPath(); ctx.moveTo(x,y); }
    else if ((e.type==='mousemove'||e.type==='touchmove') && drawing) { ctx.lineTo(x,y); ctx.stroke(); }
    else { drawing = false; }
  };
  ['mousedown','mousemove','mouseup','mouseleave','touchstart','touchmove','touchend'].forEach(ev => canvas.addEventListener(ev, on, {passive:false}));
}
function clearSig() { if(ctx) ctx.clearRect(0,0,canvas.width,canvas.height); }
function isSigEmpty() {
  if(!canvas) return true;
  const d = ctx.getImageData(0,0,canvas.width,canvas.height).data;
  for(let i=3;i<d.length;i+=4) if(d[i]>0) return false;
  return true;
}

async function submitSignature() {
  if (isSigEmpty()) { showError('sigError','Veuillez dessiner votre signature'); return; }
  const sigImage = canvas.toDataURL('image/png');
  document.getElementById('btnSign').disabled = true;
  document.getElementById('btnSign').textContent = 'Génération du PDF…';

  try {
    // Générer le PDF signé côté client
    const contractHtml = document.getElementById('contractPreview').innerHTML;
    const now = new Date();
    const dateStr = now.toLocaleDateString('fr-FR', {day:'numeric',month:'long',year:'numeric',hour:'2-digit',minute:'2-digit'});
    const sigBlock = \`<div style="page-break-before:always;padding:20mm;font-family:Arial,sans-serif">
      <h3 style="color:#5B21B6;margin-bottom:16px">Attestation de signature électronique</h3>
      <table style="width:100%;border-collapse:collapse;font-size:11pt">
        <tr><td style="padding:6px 0;color:#666;width:180px">Document</td><td style="font-weight:600">${session.contract_label}</td></tr>
        <tr><td style="padding:6px 0;color:#666">Signataire</td><td style="font-weight:600">${session.signer_name}</td></tr>
        <tr><td style="padding:6px 0;color:#666">Email vérifié</td><td>${session.signer_email}</td></tr>
        <tr><td style="padding:6px 0;color:#666">Date et heure</td><td>\${dateStr}</td></tr>
        <tr><td style="padding:6px 0;color:#666">Référence</td><td>${session.contract_number}</td></tr>
        <tr><td style="padding:6px 0;color:#666">Conformité</td><td>Règlement eIDAS (UE) n°910/2014 — Signature électronique simple</td></tr>
      </table>
      <div style="margin-top:24px"><p style="color:#666;font-size:10pt">Signature manuscrite numérique :</p>
        <img src="\${sigImage}" style="height:80px;border:1px solid #ddd;border-radius:6px;padding:4px;margin-top:8px">
      </div>
    </div>\`;

    const fullHtml = \`<div style="width:210mm;padding:20mm;font-family:'Times New Roman',serif;font-size:11pt;line-height:1.6;color:#111">\${contractHtml}</div>\${sigBlock}\`;
    const el = document.createElement('div');
    el.innerHTML = fullHtml;
    document.body.appendChild(el);
    el.style.cssText = 'position:absolute;left:-9999px;top:0;width:210mm';

    const pdf = await html2pdf().set({
      margin:0, filename:'contrat_signe.pdf',
      html2canvas:{scale:2,useCORS:true},
      jsPDF:{unit:'mm',format:'a4',orientation:'portrait'},
    }).from(el).outputPdf('arraybuffer');
    document.body.removeChild(el);

    // Encoder en base64
    const pdfBase64 = btoa(String.fromCharCode(...new Uint8Array(pdf)));

    // Envoyer au serveur
    document.getElementById('btnSign').textContent = 'Enregistrement…';
    const r = await fetch(API, {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ token: TOKEN, action: 'sign', signature_image: sigImage, pdf_base64: pdfBase64 }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || 'Erreur signature');

    // Succès
    document.getElementById('certName').textContent = '${session.signer_name}';
    document.getElementById('certDate').textContent = dateStr;
    if (d.signed_pdf_url) {
      document.getElementById('pdfLink').innerHTML = \`<a href="\${d.signed_pdf_url}" target="_blank" style="display:inline-flex;align-items:center;gap:8px;background:#5B21B6;color:#fff;text-decoration:none;padding:12px 24px;border-radius:8px;font-weight:700">📄 Télécharger mon contrat signé</a>\`;
    }
    setStep(4);
  } catch(e) {
    showError('sigError', 'Erreur : ' + e.message);
    document.getElementById('btnSign').disabled = false;
    document.getElementById('btnSign').textContent = '✅ Signer et valider le contrat';
  }
}

function showError(id, msg) { const e=document.getElementById(id); e.textContent=msg; e.classList.remove('hide'); }
function hideError(id) { document.getElementById(id).classList.add('hide'); }
</script>
</body></html>`;
}

function errorPage(title: string, msg: string): string {
  return `<!DOCTYPE html><html><head><meta charset="UTF-8"><title>${title}</title></head>
  <body style="font-family:Arial,sans-serif;background:#f3f4f6;display:flex;align-items:center;justify-content:center;min-height:100vh">
  <div style="background:#fff;border-radius:14px;padding:40px;max-width:420px;text-align:center">
    <div style="font-size:48px;margin-bottom:16px">${title.includes('Expi') ? '⌛' : '✅'}</div>
    <h2 style="color:#111;margin-bottom:10px">${title}</h2>
    <p style="color:#6b7280;font-size:14px">${msg}</p>
  </div></body></html>`;
}

// ── Handler principal ─────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const sb  = createClient(SUPABASE_URL, SUPABASE_SVC);

  // ── GET → page HTML ───────────────────────────────────────────────────────
  if (req.method === 'GET') {
    const token = url.searchParams.get('token') ?? '';
    const htmlHeaders = new Headers({ 'Content-Type': 'text/html; charset=utf-8' });
    if (!token) return new Response(errorPage('Lien invalide', 'Token manquant.'), { headers: htmlHeaders });

    const { data: sess } = await sb.from('signature_sessions')
      .select('*, contract:contract_id(contract_number,contract_type,generated_html)')
      .eq('token', token).maybeSingle();

    if (!sess) return new Response(errorPage('Lien invalide', 'Ce lien de signature est invalide.'), { headers: htmlHeaders });

    const contract = sess.contract as { contract_number: string; contract_type: string; generated_html: string } | null;
    const page = signingPage({
      signer_name:    sess.signer_name ?? '',
      signer_email:   sess.signer_email ?? '',
      contract_number: contract?.contract_number ?? '',
      contract_type:  contract?.contract_type ?? '',
      contract_label: `Contrat ${contract?.contract_type ?? ''} — ${sess.signer_name ?? ''} — ${contract?.contract_number ?? ''}`.trim(),
      contract_html:  contract?.generated_html ?? '',
      token,
      expired:        sess.expires_at ? new Date(sess.expires_at) < new Date() : false,
      already_signed: !!sess.signed_at,
    });
    return new Response(page, { headers: htmlHeaders });
  }

  // ── POST → API ────────────────────────────────────────────────────────────
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const body  = await req.json().catch(() => ({}));
  const token = body.token ?? '';
  const action = body.action ?? '';

  const { data: sess } = await sb.from('signature_sessions')
    .select('*').eq('token', token).maybeSingle();
  if (!sess) return jsonResp({ error: 'Session invalide' }, 404);
  if (sess.signed_at) return jsonResp({ error: 'Déjà signé' }, 409);
  if (new Date(sess.expires_at) < new Date()) return jsonResp({ error: 'Lien expiré' }, 410);

  // ── Action : send_otp ─────────────────────────────────────────────────────
  if (action === 'send_otp') {
    const otp = genOTP();
    await sb.from('signature_sessions').update({
      otp_code: otp,
      otp_sent_at: new Date().toISOString(),
      otp_attempts: 0,
    }).eq('token', token);

    await sendOTPEmail(sess.signer_email, sess.signer_name ?? '', otp);
    console.log('[contract-sign] OTP sent to:', sess.signer_email);
    return jsonResp({ success: true });
  }

  // ── Action : verify_otp ───────────────────────────────────────────────────
  if (action === 'verify_otp') {
    const { otp } = body;
    if (!sess.otp_code) return jsonResp({ error: 'Aucun code envoyé' }, 400);
    if (sess.otp_attempts >= 3) return jsonResp({ error: 'Trop de tentatives. Demandez un nouveau code.' }, 429);

    const otpAge = sess.otp_sent_at ? (Date.now() - new Date(sess.otp_sent_at).getTime()) / 1000 : 9999;
    if (otpAge > 600) return jsonResp({ error: 'Code expiré. Cliquez sur "Renvoyer le code".' }, 400);

    await sb.from('signature_sessions').update({ otp_attempts: (sess.otp_attempts ?? 0) + 1 }).eq('token', token);

    if (otp !== sess.otp_code) return jsonResp({ error: 'Code incorrect' }, 400);

    await sb.from('signature_sessions').update({ otp_verified_at: new Date().toISOString() }).eq('token', token);
    return jsonResp({ success: true });
  }

  // ── Action : sign ─────────────────────────────────────────────────────────
  if (action === 'sign') {
    if (!sess.otp_verified_at) return jsonResp({ error: 'OTP non vérifié' }, 403);

    const { signature_image, pdf_base64 } = body;
    if (!pdf_base64) return jsonResp({ error: 'PDF manquant' }, 400);

    const ip = req.headers.get('x-forwarded-for') ?? req.headers.get('cf-connecting-ip') ?? 'unknown';
    const ua = req.headers.get('user-agent') ?? '';
    const now = new Date().toISOString();

    // Décoder le PDF
    const pdfBytes = Uint8Array.from(atob(pdf_base64), c => c.charCodeAt(0));

    // Hash SHA-256 du PDF
    const hashBuf = await crypto.subtle.digest('SHA-256', pdfBytes);
    const pdfHash = Array.from(new Uint8Array(hashBuf)).map(b => b.toString(16).padStart(2,'0')).join('');

    // Stocker le PDF dans Supabase Storage
    const storagePath = `contracts/signed/${sess.hotel_id}/${sess.employee_id ?? sess.id}/${sess.contract_id}_${Date.now()}.pdf`;
    let signedPdfUrl: string | null = null;

    const { error: upErr } = await sb.storage.from('contracts')
      .upload(storagePath, pdfBytes, { contentType: 'application/pdf', upsert: true });

    if (!upErr) {
      const { data: urlData } = sb.storage.from('contracts').getPublicUrl(storagePath);
      signedPdfUrl = urlData?.publicUrl ?? null;
    } else {
      // Fallback portal-documents
      const { error: upErr2 } = await sb.storage.from('portal-documents')
        .upload(storagePath, pdfBytes, { contentType: 'application/pdf', upsert: true });
      if (!upErr2) {
        const { data: urlData2 } = sb.storage.from('portal-documents').getPublicUrl(storagePath);
        signedPdfUrl = urlData2?.publicUrl ?? null;
      }
    }

    // Mettre à jour la session
    await sb.from('signature_sessions').update({
      signed_at: now, ip_address: ip, user_agent: ua,
      pdf_hash: pdfHash, signed_pdf_url: signedPdfUrl, signed_pdf_path: storagePath,
    }).eq('token', token);

    // Mettre à jour le contrat
    await sb.from('generated_contracts').update({
      status: 'signed',
      yousign_status: null,
      signed_at: now,
      signed_pdf_url: signedPdfUrl,
      signed_pdf_storage_path: storagePath,
      signer_name: sess.signer_name,
      signer_email: sess.signer_email,
      signature_provider: 'native',
    }).eq('id', sess.contract_id);

    // Archiver dans coffre-fort salarié
    if (signedPdfUrl && sess.employee_id) {
      const { data: contract } = await sb.from('generated_contracts')
        .select('contract_number,contract_type').eq('id', sess.contract_id).single().catch(() => ({ data: null }));
      await sb.from('employee_documents').insert({
        hotel_id: sess.hotel_id, employee_id: sess.employee_id,
        doc_type: 'contrat_signe',
        label: `Contrat ${contract?.contract_type ?? ''} ${contract?.contract_number ?? ''} — signé`.trim(),
        storage_path: storagePath, signature_status: 'signed', signed_at: now,
      }).then(null, () => {});
    }

    // Message portail salarié
    if (sess.employee_id) {
      await sb.from('portal_messages').insert({
        hotel_id: sess.hotel_id, employee_id: sess.employee_id,
        direction: 'manager_to_employee',
        body: '✅ Votre contrat a été signé. Il est disponible dans votre coffre-fort documentaire.',
      }).then(null, () => {});
    }

    // Audit
    await sb.from('contract_audit_logs').insert({
      hotel_id: sess.hotel_id, contract_id: sess.contract_id, employee_id: sess.employee_id ?? null,
      action: 'signed', actor_email: sess.signer_email,
      details: { ip, ua, pdf_hash: pdfHash, signed_pdf_url: signedPdfUrl, method: 'native_canvas_otp' },
    }).then(null, () => {});

    console.log('[contract-sign] signed:', sess.contract_id, 'by:', sess.signer_email, 'ip:', ip);
    return jsonResp({ success: true, signed_at: now, signed_pdf_url: signedPdfUrl });
  }

  return jsonResp({ error: 'Action inconnue' }, 400);
});
