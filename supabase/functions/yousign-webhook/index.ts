import { createClient } from 'jsr:@supabase/supabase-js@2';

// ── YouSign Webhook v3 ────────────────────────────────────────────────────────
// Reçoit les événements YouSign et met à jour la base de données.
// URL à configurer dans YouSign Dashboard (Webhooks) :
//   https://hzrzkvdebaadditvbqis.supabase.co/functions/v1/yousign-webhook
//
// Événements à souscrire :
//   signature_request.done, signature_request.refused,
//   signature_request.expired, signature_request.canceled
//
// Secrets Supabase requis :
//   YOUSIGN_API_KEY           clé API YouSign
//   YOUSIGN_WEBHOOK_SECRET    secret HMAC (copié depuis YouSign Dashboard)
//   YOUSIGN_SANDBOX           "true" pour sandbox
//   SUPABASE_SERVICE_ROLE_KEY

const YOUSIGN_API = Deno.env.get('YOUSIGN_SANDBOX') === 'true'
  ? 'https://api-sandbox.yousign.app/v3'
  : 'https://api.yousign.app/v3';
const YOUSIGN_KEY       = Deno.env.get('YOUSIGN_API_KEY') ?? '';
const WEBHOOK_SECRET    = Deno.env.get('YOUSIGN_WEBHOOK_SECRET') ?? '';
const SUPABASE_URL      = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC      = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

async function verifyHMAC(body: string, header: string): Promise<boolean> {
  if (!WEBHOOK_SECRET) return true; // pas encore configuré — accepter en dev
  try {
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(WEBHOOK_SECRET),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body));
    const hex = Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
    return `sha256=${hex}` === header;
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const rawBody = await req.text();
  const sigHeader = req.headers.get('X-Yousign-Signature-256') ?? '';

  if (WEBHOOK_SECRET && !(await verifyHMAC(rawBody, sigHeader))) {
    console.warn('yousign-webhook: HMAC invalide');
    return new Response('Invalid signature', { status: 401 });
  }

  let event: { name: string; data: { signature_request: { id: string } } };
  try { event = JSON.parse(rawBody); }
  catch { return new Response('Bad JSON', { status: 400 }); }

  const srId    = event?.data?.signature_request?.id;
  const evtName = event?.name ?? '';
  if (!srId) return new Response('OK', { status: 200 });

  const sb = createClient(SUPABASE_URL, SUPABASE_SVC);

  // Récupérer l'enregistrement interne
  const { data: psr } = await sb.from('portal_signature_requests')
    .select('id, hotel_id, employee_id, document_id')
    .eq('yousign_sr_id', srId).single();
  if (!psr) return new Response('PSR not found', { status: 200 }); // 200 pour éviter les retries YouSign

  const ysGet = (path: string) => fetch(`${YOUSIGN_API}${path}`, {
    headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}` },
  });

  if (evtName === 'signature_request.done') {
    const now = new Date().toISOString();
    const signedPath = `${psr.hotel_id}/${psr.employee_id}/signed_${srId.slice(0, 8)}_${Date.now()}.pdf`;
    const auditPath  = `${psr.hotel_id}/${psr.employee_id}/audit_${srId.slice(0, 8)}_${Date.now()}.pdf`;

    // Télécharger PDF signé + audit trail en parallèle
    const [dlRes, atRes] = await Promise.all([
      ysGet(`/signature_requests/${srId}/documents/download?version=completed&archive=false`),
      ysGet(`/signature_requests/${srId}/audit_trails/download`),
    ]);

    let finalSignedPath: string | null = null;
    let finalAuditPath:  string | null = null;

    if (dlRes.ok) {
      const bytes = await dlRes.arrayBuffer();
      const { error } = await sb.storage.from('portal-documents')
        .upload(signedPath, bytes, { contentType: 'application/pdf', upsert: true });
      if (!error) finalSignedPath = signedPath;
    }
    if (atRes.ok) {
      const bytes = await atRes.arrayBuffer();
      const { error } = await sb.storage.from('portal-documents')
        .upload(auditPath, bytes, { contentType: 'application/pdf', upsert: true });
      if (!error) finalAuditPath = auditPath;
    }

    // Mettre à jour portal_signature_requests
    await sb.from('portal_signature_requests').update({
      status: 'done',
      signed_document_path: finalSignedPath,
      audit_trail_path: finalAuditPath,
      done_at: now,
    }).eq('yousign_sr_id', srId);

    // Mettre à jour le statut du document source
    if (psr.document_id) {
      await sb.from('employee_documents')
        .update({ signature_status: 'signed' }).eq('id', psr.document_id);
    }

    // Créer une entrée "Contrat signé" dans le coffre-fort
    if (finalSignedPath) {
      await sb.from('employee_documents').insert({
        hotel_id: psr.hotel_id,
        employee_id: psr.employee_id,
        doc_type: 'contrat_signe',
        label: 'Contrat signé électroniquement',
        storage_path: finalSignedPath,
        signature_status: 'signed',
      });
    }

    // Message de confirmation dans le portail salarié
    await sb.from('portal_messages').insert({
      hotel_id:    psr.hotel_id,
      employee_id: psr.employee_id,
      direction:   'manager_to_employee',
      body: '✅ Votre document a été signé avec succès. Le contrat signé est disponible dans votre coffre-fort.',
    });

    // Audit log
    await sb.from('portal_audit_log').insert({
      hotel_id:      psr.hotel_id,
      employee_id:   psr.employee_id,
      actor_type:    'system',
      action:        'document_signed',
      metadata:      { yousign_sr_id: srId, signed_path: finalSignedPath, audit_path: finalAuditPath },
    });

  } else {
    // refused / expired / canceled
    const statusMap: Record<string, string> = {
      'signature_request.refused':  'refused',
      'signature_request.expired':  'expired',
      'signature_request.canceled': 'canceled',
    };
    const newStatus = statusMap[evtName];
    if (!newStatus) return new Response('OK', { status: 200 });

    await sb.from('portal_signature_requests').update({ status: newStatus }).eq('yousign_sr_id', srId);

    const docStatusMap: Record<string, string> = { refused: 'refused', expired: 'expired', canceled: 'none' };
    if (psr.document_id) {
      await sb.from('employee_documents')
        .update({ signature_status: docStatusMap[newStatus] ?? 'none' }).eq('id', psr.document_id);
    }

    const bodyMsg: Record<string, string> = {
      refused:  '❌ La signature du document a été refusée.',
      expired:  '⌛ La demande de signature a expiré.',
      canceled: 'La demande de signature a été annulée.',
    };
    await sb.from('portal_messages').insert({
      hotel_id: psr.hotel_id, employee_id: psr.employee_id,
      direction: 'manager_to_employee', body: bodyMsg[newStatus] ?? 'Statut de signature mis à jour.',
    });
  }

  return new Response('OK', { status: 200 });
});
