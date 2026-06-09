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
const YOUSIGN_KEY    = Deno.env.get('YOUSIGN_API_KEY') ?? '';
const WEBHOOK_SECRET = Deno.env.get('YOUSIGN_WEBHOOK_SECRET') ?? '';
const SUPABASE_URL   = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

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

const ysGet = (path: string) => fetch(`${YOUSIGN_API}${path}`, {
  headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}` },
});

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

  // ── Chercher d'abord dans generated_contracts (contrats RH) ──────────────
  const { data: contract } = await sb.from('generated_contracts')
    .select('id, hotel_id, employee_id, contract_number, contract_type, signer_email, signer_name')
    .eq('yousign_sr_id', srId).maybeSingle();

  if (contract) {
    await _handleContractEvent(sb, contract, srId, evtName);
    return new Response('OK', { status: 200 });
  }

  // ── Fallback : portal_signature_requests (documents portail) ─────────────
  const { data: psr } = await sb.from('portal_signature_requests')
    .select('id, hotel_id, employee_id, document_id')
    .eq('yousign_sr_id', srId).single();
  if (!psr) return new Response('PSR not found', { status: 200 });

  await _handlePortalDocEvent(sb, psr, srId, evtName);
  return new Response('OK', { status: 200 });
});

// ── Gestion signature contrat RH ─────────────────────────────────────────────
async function _handleContractEvent(
  sb: ReturnType<typeof createClient>,
  contract: { id: string; hotel_id: string; employee_id: string; contract_number: string; contract_type: string; signer_email: string; signer_name: string },
  srId: string,
  evtName: string,
) {
  const now = new Date().toISOString();

  const logAudit = (action: string, details: Record<string, unknown> = {}) =>
    sb.from('contract_audit_logs').insert({
      hotel_id: contract.hotel_id,
      contract_id: contract.id,
      employee_id: contract.employee_id,
      action,
      actor_email: contract.signer_email ?? null,
      details,
    }).then(null, (e: Error) => console.warn('audit failed', e));

  if (evtName === 'signature_request.done') {
    // Télécharger le PDF signé depuis YouSign
    const signedStoragePath = `contracts/signed/${contract.hotel_id}/${contract.employee_id}/${contract.id}_${Date.now()}.pdf`;
    let signedPdfUrl: string | null = null;

    const dlRes = await ysGet(`/signature_requests/${srId}/documents/download?version=completed&archive=false`);
    if (dlRes.ok) {
      const bytes = await dlRes.arrayBuffer();
      const { error: upErr } = await sb.storage.from('contracts')
        .upload(signedStoragePath, bytes, { contentType: 'application/pdf', upsert: true });

      if (!upErr) {
        const { data: urlData } = sb.storage.from('contracts').getPublicUrl(signedStoragePath);
        signedPdfUrl = urlData?.publicUrl ?? null;
      } else {
        console.warn('Storage upload error:', upErr.message);
      }
    }

    // Récupérer infos du signataire depuis YouSign
    let signerName: string | null = contract.signer_name ?? null;
    let signerEmail: string | null = contract.signer_email ?? null;
    try {
      const sigRes = await ysGet(`/signature_requests/${srId}/signers`);
      if (sigRes.ok) {
        const sigData = await sigRes.json();
        const firstSigner = Array.isArray(sigData) ? sigData[0] : sigData?.signers?.[0];
        if (firstSigner) {
          signerName = [firstSigner.info?.first_name, firstSigner.info?.last_name].filter(Boolean).join(' ') || signerName;
          signerEmail = firstSigner.info?.email ?? signerEmail;
        }
      }
    } catch { /* ignore */ }

    // Mettre à jour generated_contracts
    await sb.from('generated_contracts').update({
      status: 'signed',
      yousign_status: 'signed',
      signed_at: now,
      signed_pdf_url: signedPdfUrl,
      signed_pdf_storage_path: signedStoragePath,
      signer_name: signerName,
      signer_email: signerEmail,
      signature_provider: 'yousign',
    }).eq('id', contract.id);

    // Archiver le PDF dans employee_documents (coffre-fort salarié)
    if (signedPdfUrl) {
      await sb.from('employee_documents').insert({
        hotel_id: contract.hotel_id,
        employee_id: contract.employee_id,
        doc_type: 'contrat_signe',
        label: `Contrat ${contract.contract_type ?? ''} ${contract.contract_number ?? ''} — signé`.trim(),
        storage_path: signedStoragePath,
        signature_status: 'signed',
        signed_at: now,
      }).then(null, () => { /* doc déjà présent ou table différente */ });
    }

    // Notification RH
    await sb.from('notifications').insert({
      hotel_id: contract.hotel_id,
      type: 'contract_signed',
      title: 'Contrat signé',
      body: `Le contrat de ${signerName ?? 'un collaborateur'} a été signé électroniquement.`,
      metadata: { contract_id: contract.id, employee_id: contract.employee_id },
    }).then(null, () => { /* table optionnelle */ });

    // Message portail salarié
    await sb.from('portal_messages').insert({
      hotel_id: contract.hotel_id,
      employee_id: contract.employee_id,
      direction: 'manager_to_employee',
      body: `✅ Votre contrat ${contract.contract_type ?? ''} a été signé avec succès. Il est maintenant disponible dans votre coffre-fort documentaire.`,
    }).then(null, () => { /* table optionnelle */ });

    await logAudit('signed', { yousign_sr_id: srId, signed_pdf_url: signedPdfUrl });

  } else {
    // refused / expired / canceled
    const statusMap: Record<string, string> = {
      'signature_request.refused':  'cancelled',
      'signature_request.expired':  'archived',
      'signature_request.canceled': 'archived',
    };
    const ysStatusMap: Record<string, string> = {
      'signature_request.refused':  'refused',
      'signature_request.expired':  'expired',
      'signature_request.canceled': 'canceled',
    };
    const newStatus = statusMap[evtName];
    if (!newStatus) return;

    await sb.from('generated_contracts').update({
      status: newStatus,
      yousign_status: ysStatusMap[evtName] ?? evtName,
      refused_at: evtName === 'signature_request.refused' ? now : undefined,
    }).eq('id', contract.id);

    await logAudit(ysStatusMap[evtName] ?? 'cancelled', { yousign_sr_id: srId, event: evtName });
  }
}

// ── Gestion signature documents portail (existant) ───────────────────────────
async function _handlePortalDocEvent(
  sb: ReturnType<typeof createClient>,
  psr: { id: string; hotel_id: string; employee_id: string; document_id: string },
  srId: string,
  evtName: string,
) {
  const now = new Date().toISOString();

  if (evtName === 'signature_request.done') {
    const signedPath = `${psr.hotel_id}/${psr.employee_id}/signed_${srId.slice(0, 8)}_${Date.now()}.pdf`;
    const auditPath  = `${psr.hotel_id}/${psr.employee_id}/audit_${srId.slice(0, 8)}_${Date.now()}.pdf`;

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

    await sb.from('portal_signature_requests').update({
      status: 'done',
      signed_document_path: finalSignedPath,
      audit_trail_path: finalAuditPath,
      done_at: now,
    }).eq('yousign_sr_id', srId);

    if (psr.document_id) {
      await sb.from('employee_documents')
        .update({ signature_status: 'signed' }).eq('id', psr.document_id);
    }

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

    await sb.from('portal_messages').insert({
      hotel_id: psr.hotel_id,
      employee_id: psr.employee_id,
      direction: 'manager_to_employee',
      body: '✅ Votre document a été signé avec succès. Le contrat signé est disponible dans votre coffre-fort.',
    });

    await sb.from('portal_audit_log').insert({
      hotel_id: psr.hotel_id,
      employee_id: psr.employee_id,
      actor_type: 'system',
      action: 'document_signed',
      metadata: { yousign_sr_id: srId, signed_path: finalSignedPath, audit_path: finalAuditPath },
    });

  } else {
    const statusMap: Record<string, string> = {
      'signature_request.refused':  'refused',
      'signature_request.expired':  'expired',
      'signature_request.canceled': 'canceled',
    };
    const newStatus = statusMap[evtName];
    if (!newStatus) return;

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
      hotel_id: psr.hotel_id,
      employee_id: psr.employee_id,
      direction: 'manager_to_employee',
      body: bodyMsg[newStatus] ?? 'Statut de signature mis à jour.',
    });
  }
}
