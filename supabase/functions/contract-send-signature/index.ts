import { createClient } from 'jsr:@supabase/supabase-js@2';

// Crée une session de signature et envoie le lien par email au signataire.
// Remplace yousign-create pour les contrats.
// POST { contract_id, signer_email, signer_name, signer_first_name }

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const RESEND_KEY    = Deno.env.get('RESEND_API_KEY') ?? '';
// URL de la fonction de signature (publique)
const SIGN_URL      = `${SUPABASE_URL.replace('supabase.co','supabase.co')}/functions/v1/contract-sign`;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Content-Type': 'application/json',
};

async function sendEmail(to: string, signerName: string, contractLabel: string, link: string): Promise<boolean> {
  // Priorité : Resend (API simple, gratuit jusqu'à 3 000 emails/mois)
  if (RESEND_KEY) {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Flowtym RH <noreply@flowtym.com>',
        to: [to],
        subject: `Signature requise — ${contractLabel}`,
        html: emailHtml(signerName, contractLabel, link),
      }),
    });
    if (r.ok) return true;
    console.warn('Resend error:', await r.text());
  }
  // Fallback : SMTP via Supabase (si configuré dans le dashboard)
  const sbAnon = createClient(SUPABASE_URL, SUPABASE_ANON);
  const { error } = await sbAnon.auth.resetPasswordForEmail(to, { redirectTo: link });
  if (!error) return true;
  console.warn('SMTP fallback error:', error.message);
  return false;
}

function emailHtml(name: string, label: string, link: string): string {
  return `<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;background:#f5f5f5;padding:30px">
  <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:12px;padding:32px;box-shadow:0 2px 8px rgba(0,0,0,.08)">
    <div style="text-align:center;margin-bottom:24px">
      <span style="font-size:22px;font-weight:800;color:#5B21B6">Flowtym</span><span style="font-size:14px;color:#9ca3af"> RH</span>
    </div>
    <h2 style="color:#111;font-size:18px;margin-bottom:8px">Bonjour ${name || ''},</h2>
    <p style="color:#374151;font-size:14px;line-height:1.6">
      Votre employeur vous invite à signer électroniquement le document suivant :<br>
      <strong>${label}</strong>
    </p>
    <div style="text-align:center;margin:28px 0">
      <a href="${link}" style="background:#5B21B6;color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:15px;font-weight:700;display:inline-block">
        Lire et signer mon contrat →
      </a>
    </div>
    <p style="color:#6b7280;font-size:12px;line-height:1.6">
      Ce lien est valable <strong>7 jours</strong>.<br>
      Votre identité sera vérifiée par code à usage unique envoyé à votre adresse email.
    </p>
    <hr style="border:none;border-top:1px solid #e5e7eb;margin:20px 0">
    <p style="color:#9ca3af;font-size:11px;text-align:center">
      Flowtym RH — Solution RH Hôtelière<br>
      Cette signature est conforme au règlement eIDAS (signature électronique simple).
    </p>
  </div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  // Auth
  const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
  const sbAnon = createClient(SUPABASE_URL, SUPABASE_ANON);
  const { data: { user }, error: authErr } = await sbAnon.auth.getUser(token);
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: 'Non autorisé' }), { status: 401, headers: CORS });
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_SVC);
  const body = await req.json();
  const { contract_id, signer_email, signer_name, signer_first_name, hotel_id, employee_id } = body;

  if (!contract_id || !signer_email) {
    return new Response(JSON.stringify({ error: 'contract_id et signer_email requis' }), { status: 400, headers: CORS });
  }

  // Récupérer le contrat
  const { data: contract, error: cErr } = await sb.from('generated_contracts')
    .select('id, hotel_id, employee_id, contract_number, contract_type, generated_html')
    .eq('id', contract_id).single();
  if (cErr || !contract) {
    return new Response(JSON.stringify({ error: 'Contrat introuvable' }), { status: 404, headers: CORS });
  }

  const fullName = [signer_first_name, signer_name].filter(Boolean).join(' ') || signer_email;
  const contractLabel = `Contrat ${contract.contract_type ?? ''} — ${fullName} — ${contract.contract_number ?? ''}`.trim();

  // Créer la session de signature
  const { data: session, error: sErr } = await sb.from('signature_sessions').insert({
    hotel_id: contract.hotel_id ?? hotel_id,
    contract_id: contract.id,
    employee_id: contract.employee_id ?? employee_id ?? null,
    signer_email: signer_email.trim().toLowerCase(),
    signer_name: fullName,
  }).select('id, token').single();

  if (sErr || !session) {
    return new Response(JSON.stringify({ error: 'Création session échouée : ' + sErr?.message }), { status: 500, headers: CORS });
  }

  const signingLink = `${SIGN_URL}?token=${session.token}`;

  // Mettre à jour le contrat
  await sb.from('generated_contracts').update({
    status: 'pending_signature',
    sent_at: new Date().toISOString(),
    signer_email: signer_email.trim().toLowerCase(),
    signer_name: fullName,
    signature_provider: 'native',
    yousign_sr_id: null,
    yousign_status: null,
    signature_token: session.token,
    signature_link: signingLink,
  }).eq('id', contract_id);

  // Audit
  await sb.from('contract_audit_logs').insert({
    hotel_id: contract.hotel_id,
    contract_id: contract.id,
    employee_id: contract.employee_id ?? null,
    action: 'sent',
    actor_email: user.email ?? null,
    details: { signer_email, signer_name: fullName, session_id: session.id },
  }).then(null, () => {});

  // Envoyer l'email
  const emailSent = await sendEmail(signer_email, fullName, contractLabel, signingLink);
  console.log('[contract-send-signature] email sent:', emailSent, 'to:', signer_email);

  return new Response(JSON.stringify({
    success: true,
    session_id: session.id,
    signing_link: signingLink,
    email_sent: emailSent,
  }), { headers: CORS });
});
