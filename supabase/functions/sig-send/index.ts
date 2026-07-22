import { createClient } from 'jsr:@supabase/supabase-js@2';

// sig-send — Manager initie une demande de signature Flowtym (eIDAS simple).
// JWT manager requis. Crée signature_requests, hache l'OTP, envoie l'email.
// Moteur v2 (unifié). Journal append-only signature_events.

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const RESEND_KEY    = Deno.env.get('RESEND_API_KEY') ?? '';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Content-Type': 'application/json',
};

function json(d: unknown, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: CORS });
}

async function sha256hex(input: string | Uint8Array): Promise<string> {
  const data = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  const buf  = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function genOTP(): string {
  const arr = new Uint32Array(1);
  crypto.getRandomValues(arr);
  return String((arr[0] % 900000) + 100000);
}

async function sendEmail(to: string, name: string, otp: string, requestId: string): Promise<void> {
  const fnBase = SUPABASE_URL + '/functions/v1';
  const sigUrl = `${fnBase}/sig-sign?request_id=${encodeURIComponent(requestId)}`;
  const html = `<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;background:#f5f5f5;padding:30px">
  <div style="max-width:480px;margin:0 auto;background:#fff;border-radius:12px;padding:32px">
    <div style="text-align:center;margin-bottom:20px">
      <span style="font-size:20px;font-weight:800;color:#5B21B6">Flowtym</span>
      <span style="font-size:13px;color:#9ca3af"> RH</span>
    </div>
    <h3 style="color:#111;font-size:16px">Bonjour ${name},</h3>
    <p style="color:#374151;font-size:14px;margin-bottom:16px">
      Un document vous a été transmis pour <strong>signature électronique</strong>.
    </p>
    <p style="color:#374151;font-size:14px;margin-bottom:8px">Votre code de vérification :</p>
    <div style="text-align:center;margin:20px 0">
      <span style="font-size:38px;font-weight:800;letter-spacing:8px;color:#5B21B6;background:#EDE9FE;padding:16px 24px;border-radius:10px;display:inline-block">${otp}</span>
    </div>
    <p style="color:#6b7280;font-size:12px;margin-bottom:24px">Code valable <strong>48 heures</strong>. Ne le communiquez à personne.</p>
    <div style="text-align:center;margin-bottom:24px">
      <a href="${sigUrl}" style="display:inline-block;background:#5B21B6;color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-weight:700;font-size:15px">
        Signer le document &rarr;
      </a>
    </div>
    <p style="color:#9ca3af;font-size:11px;text-align:center">
      Signature conforme au règlement eIDAS (UE) n°910/2014 — Signature électronique simple.
    </p>
  </div></body></html>`;

  const resp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'Flowtym RH <noreply@flowtym.com>',
      to:   [to],
      subject: `Document à signer — Code : ${otp}`,
      html,
    }),
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => '');
    console.error('[sig-send] Resend error', resp.status, txt);
    throw new Error(`Email non envoyé (${resp.status})`);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth) return json({ error: 'Non authentifié' }, 401);

  const sbUser = createClient(SUPABASE_URL, SUPABASE_ANON, {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user }, error: authErr } = await sbUser.auth.getUser();
  if (authErr || !user) return json({ error: 'Token invalide' }, 401);

  const body = await req.json().catch(() => ({}));
  const { contract_id, document_id, employee_id, hotel_id, signer_name, signer_email } = body;

  if (!hotel_id || !employee_id || !signer_name || !signer_email) {
    return json({ error: 'Champs requis : hotel_id, employee_id, signer_name, signer_email' }, 400);
  }
  if (!contract_id && !document_id) {
    return json({ error: 'contract_id ou document_id requis' }, 400);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_SVC);

  // Étape 1 : récupérer public.users.id depuis auth_id (= user.id du JWT)
  const { data: appUser } = await sb
    .from('users')
    .select('id')
    .eq('auth_id', user.id)
    .maybeSingle();
  if (!appUser) return json({ error: 'Utilisateur introuvable' }, 403);

  // Étape 2 : vérifier accès à l'hôtel
  const { data: access } = await sb
    .from('user_hotels')
    .select('hotel_id')
    .eq('user_id', appUser.id)
    .eq('hotel_id', hotel_id)
    .maybeSingle();
  if (!access) return json({ error: 'Accès refusé à cet hôtel' }, 403);

  // Hash SHA-256 du document source (HTML contrat → empreinte eIDAS)
  let documentHash: string | null = null;
  let contractNumber: string | null = null;
  let contractType: string | null = null;

  if (contract_id) {
    const { data: c } = await sb.from('generated_contracts')
      .select('generated_html, contract_number, contract_type, status')
      .eq('id', contract_id).maybeSingle();
    if (!c) return json({ error: 'Contrat introuvable' }, 404);
    if (c.generated_html) documentHash = await sha256hex(c.generated_html);
    contractNumber = c.contract_number;
    contractType   = c.contract_type;
  }

  // OTP cryptographique
  const otp     = genOTP();
  const otpHash = await sha256hex(otp);
  const otpExp  = new Date(Date.now() + 48 * 3600_000).toISOString();

  // Créer la demande
  const { data: sigReq, error: insErr } = await sb.from('signature_requests').insert({
    hotel_id,
    employee_id,
    contract_id:          contract_id  ?? null,
    document_id:          document_id  ?? null,
    signer_name,
    signer_email,
    status:               'otp_sent',
    otp_hash:             otpHash,
    otp_expires_at:       otpExp,
    otp_attempts:         0,
    document_hash_sha256: documentHash,
    initiated_by:         user.id,
  }).select('id').single();

  if (insErr || !sigReq) {
    console.error('[sig-send] insert:', insErr?.message);
    return json({ error: 'Erreur création demande de signature' }, 500 );
  }

  const requestId = sigReq.id;

  // Journal append-only
  await sb.from('signature_events').insert([
    {
      request_id: requestId, hotel_id, type: 'created',
      metadata: { initiated_by: user.id, signer_email, contract_id: contract_id ?? null, document_id: document_id ?? null },
    },
    {
      request_id: requestId, hotel_id, type: 'otp_sent',
      metadata: { email: signer_email },
    },
  ]);

  // Mettre à jour le contrat
  if (contract_id) {
    await sb.from('generated_contracts').update({
      signature_provider:    'flowtym',
      signature_request_id:  requestId,
      sent_at:               new Date().toISOString(),
      status:                'sent',
      signer_name,
      signer_email,
      document_hash_sha256:  documentHash,
    }).eq('id', contract_id);
  }

  // Envoyer l'email
  try {
    await sendEmail(signer_email, signer_name, otp, requestId);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('[sig-send] email failed:', msg);
    return json({ success: true, request_id: requestId, email_warning: msg });
  }

  console.log('[sig-send] created', requestId, 'for', signer_email,
    'contract', contractNumber ?? document_id);
  return json({ success: true, request_id: requestId });
});
