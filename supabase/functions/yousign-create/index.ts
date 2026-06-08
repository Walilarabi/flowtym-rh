import { createClient } from 'jsr:@supabase/supabase-js@2';

// ── YouSign API v3 — Création d'une demande de signature électronique ─────────
// Mode A (contracts)  : pdf_base64 + contract_id  → upload PDF directement
// Mode B (portal docs): document_id               → lookup depuis employee_documents
//
// Secrets Supabase requis :
//   YOUSIGN_API_KEY          clé API YouSign (sandbox)
//   SUPABASE_SERVICE_ROLE_KEY

// Sandbox hardcodé — on n'utilise PAS la prod depuis cette fonction
const YOUSIGN_API  = 'https://api-sandbox.yousign.app/v3';
const YOUSIGN_KEY  = Deno.env.get('YOUSIGN_API_KEY') ?? '';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

console.log('[yousign-create] boot — YOUSIGN_API:', YOUSIGN_API, '— key present:', !!YOUSIGN_KEY);

const ys = (path: string, method = 'GET', body?: unknown) =>
  fetch(`${YOUSIGN_API}${path}`, {
    method,
    headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Content-Type': 'application/json',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  try {
    // ── Auth ──────────────────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    const sbAnon = createClient(SUPABASE_URL, SUPABASE_ANON);
    const { data: { user }, error: authErr } = await sbAnon.auth.getUser(token);
    if (authErr || !user) {
      console.error('[yousign-create] auth error:', authErr?.message);
      return new Response(JSON.stringify({ error: 'Non autorisé' }), { status: 401, headers: CORS });
    }
    console.log('[yousign-create] auth ok — user:', user.id);

    if (!YOUSIGN_KEY) {
      console.error('[yousign-create] YOUSIGN_API_KEY manquant');
      return new Response(JSON.stringify({ error: 'YOUSIGN_NOT_CONFIGURED', detail: 'YOUSIGN_API_KEY absent' }), { status: 500, headers: CORS });
    }

    const payload = await req.json();
    console.log('[yousign-create] payload keys:', Object.keys(payload).join(', '));

    const {
      // Mode A
      pdf_base64, contract_id, contract_label,
      // Mode B
      document_id,
      // Common
      employee_id, hotel_id,
      signer_first_name, signer_name, signer_email, signer_phone,
    } = payload;

    const sb = createClient(SUPABASE_URL, SUPABASE_SVC);

    let pdfBytes: ArrayBuffer;
    let docLabel: string;

    // ── Mode A : pdf_base64 + contract_id ────────────────────────────────────
    if (pdf_base64) {
      console.log('[yousign-create] Mode A — pdf_base64 size:', pdf_base64.length, 'contract_id:', contract_id);
      // Decode base64 → binary
      const binary = atob(pdf_base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      pdfBytes = bytes.buffer;
      docLabel = contract_label || 'Contrat';

    // ── Mode B : document_id → employee_documents ─────────────────────────────
    } else if (document_id) {
      console.log('[yousign-create] Mode B — document_id:', document_id);
      const { data: docRow } = await sb.from('employee_documents')
        .select('storage_path, label, file_path').eq('id', document_id).single();
      if (!docRow) return new Response(JSON.stringify({ error: 'Document introuvable', detail: `id=${document_id}` }), { status: 404, headers: CORS });

      const storagePath = docRow.storage_path || docRow.file_path;
      if (!storagePath) return new Response(JSON.stringify({ error: 'Chemin de fichier absent' }), { status: 400, headers: CORS });

      const { data: fileData, error: dlErr } = await sb.storage.from('employee-documents').download(storagePath);
      if (dlErr || !fileData) return new Response(JSON.stringify({ error: 'Téléchargement impossible', detail: dlErr?.message }), { status: 500, headers: CORS });

      pdfBytes = await fileData.arrayBuffer();
      docLabel = docRow.label || 'Document';
    } else {
      return new Response(JSON.stringify({ error: 'pdf_base64 ou document_id requis' }), { status: 400, headers: CORS });
    }

    console.log('[yousign-create] pdf bytes:', pdfBytes.byteLength);

    // ── 1. Créer la signature request (draft) ─────────────────────────────────
    console.log('[yousign-create] step 1 — create SR');
    const srRes = await ys('/signature_requests', 'POST', {
      name: docLabel,
      delivery_mode: 'none',
      timezone: 'Europe/Paris',
      audit_trail_locale: 'fr',
      signers_allowed_to_decline: true,
    });
    if (!srRes.ok) {
      const errText = await srRes.text();
      console.error('[yousign-create] SR error', srRes.status, errText);
      return new Response(JSON.stringify({ error: 'YouSign SR échoué', detail: errText, status: srRes.status }), { status: 502, headers: CORS });
    }
    const sr = await srRes.json();
    const srId = sr.id as string;
    console.log('[yousign-create] SR created — id:', srId);

    // ── 2. Uploader le document PDF ───────────────────────────────────────────
    console.log('[yousign-create] step 2 — upload PDF');
    const form = new FormData();
    form.append('file', new Blob([pdfBytes], { type: 'application/pdf' }), 'document.pdf');
    form.append('nature', 'signable_document');
    form.append('parse_anchors', 'false');
    const docRes = await fetch(`${YOUSIGN_API}/signature_requests/${srId}/documents`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}` },
      body: form,
    });
    if (!docRes.ok) {
      const errText = await docRes.text();
      console.error('[yousign-create] doc upload error', docRes.status, errText);
      return new Response(JSON.stringify({ error: 'YouSign upload PDF échoué', detail: errText, status: docRes.status }), { status: 502, headers: CORS });
    }
    const ysDoc = await docRes.json();
    console.log('[yousign-create] doc uploaded — id:', ysDoc.id);

    // ── 3. Ajouter le signataire ──────────────────────────────────────────────
    console.log('[yousign-create] step 3 — add signer', signer_email);
    const signerRes = await ys(`/signature_requests/${srId}/signers`, 'POST', {
      info: {
        first_name: signer_first_name,
        last_name: signer_name,
        email: signer_email,
        phone_number: signer_phone || undefined,
        locale: 'fr',
      },
      fields: [{
        document_id: ysDoc.id,
        type: 'signature',
        page: 1,
        x: 80, y: 680,
        width: 200, height: 70,
      }],
      signature_authentication_mode: signer_phone ? 'otp_sms' : 'otp_email',
    });
    if (!signerRes.ok) {
      const errText = await signerRes.text();
      console.error('[yousign-create] signer error', signerRes.status, errText);
      return new Response(JSON.stringify({ error: 'YouSign signer échoué', detail: errText, status: signerRes.status }), { status: 502, headers: CORS });
    }
    const signer = await signerRes.json();
    console.log('[yousign-create] signer added — id:', signer.id);

    // ── 4. Activer ────────────────────────────────────────────────────────────
    console.log('[yousign-create] step 4 — activate');
    const actRes = await ys(`/signature_requests/${srId}/activate`, 'POST');
    if (!actRes.ok) {
      const errText = await actRes.text();
      console.error('[yousign-create] activate error', actRes.status, errText);
      return new Response(JSON.stringify({ error: 'YouSign activate échoué', detail: errText, status: actRes.status }), { status: 502, headers: CORS });
    }
    const activated = await actRes.json();
    console.log('[yousign-create] activated — status:', activated.status);

    const signatureLink = (activated.signers as Array<{ id: string; signature_link?: string }>)
      ?.find(s => s.id === signer.id)?.signature_link ?? signer.signature_link ?? '';

    // ── 5. Enregistrer en base ────────────────────────────────────────────────
    console.log('[yousign-create] step 5 — save to DB');

    if (pdf_base64 && contract_id) {
      // Mode A : mettre à jour generated_contracts
      const { error: updErr } = await sb.from('generated_contracts').update({
        yousign_sr_id: srId,
        yousign_signer_id: signer.id,
        signature_status: 'pending',
      }).eq('id', contract_id);
      if (updErr) console.warn('[yousign-create] generated_contracts update warn:', updErr.message);

      // Message portail
      if (employee_id && hotel_id) {
        await sb.from('portal_messages').insert({
          hotel_id, employee_id,
          direction: 'manager_to_employee',
          body: '📝 Un contrat est en attente de votre signature électronique.',
        });
      }

      console.log('[yousign-create] Mode A done — sr_id:', srId);
      return new Response(JSON.stringify({ success: true, sr_id: srId, signature_link: signatureLink }), { headers: CORS });

    } else {
      // Mode B : portal_signature_requests
      const { data: psrRow, error: insErr } = await sb.from('portal_signature_requests').insert({
        hotel_id, employee_id, document_id,
        yousign_sr_id: srId,
        yousign_signer_id: signer.id,
        yousign_document_id: ysDoc.id,
        status: 'ongoing',
        initiated_by: user.id,
      }).select('id').single();
      if (insErr) return new Response(JSON.stringify({ error: 'DB insert échoué', detail: insErr.message }), { status: 500, headers: CORS });

      await sb.from('employee_documents').update({
        signature_status: 'pending',
        signature_request_id: psrRow.id,
      }).eq('id', document_id);

      await sb.from('portal_messages').insert({
        hotel_id, employee_id,
        direction: 'manager_to_employee',
        body: '📝 Un document est en attente de votre signature électronique dans votre coffre-fort.',
      });

      console.log('[yousign-create] Mode B done — psr_id:', psrRow.id);
      return new Response(JSON.stringify({ success: true, psr_id: psrRow.id, signature_link: signatureLink }), { headers: CORS });
    }

  } catch (e) {
    console.error('[yousign-create] unexpected error:', e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
