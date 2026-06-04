import { createClient } from 'jsr:@supabase/supabase-js@2';

// ── YouSign API v3 — Création d'une demande de signature électronique ─────────
// Appelé depuis index.html (manager) quand il clique "Envoyer pour signature"
// Flow : upload PDF → create SR → add document → add signer → activate
//
// Secrets Supabase requis :
//   YOUSIGN_API_KEY          clé API YouSign (sandbox ou prod)
//   YOUSIGN_SANDBOX          "true" pour sandbox, absent/false pour prod
//   SUPABASE_SERVICE_ROLE_KEY

const YOUSIGN_API = Deno.env.get('YOUSIGN_SANDBOX') === 'true'
  ? 'https://api-sandbox.yousign.app/v3'
  : 'https://api.yousign.app/v3';
const YOUSIGN_KEY     = Deno.env.get('YOUSIGN_API_KEY') ?? '';
const SUPABASE_URL    = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON   = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

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
    // Authentifier l'utilisateur manager
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    const sbAnon = createClient(SUPABASE_URL, SUPABASE_ANON);
    const { data: { user }, error: authErr } = await sbAnon.auth.getUser(token);
    if (authErr || !user) return new Response(JSON.stringify({ error: 'Non autorisé' }), { status: 401, headers: CORS });

    const sb = createClient(SUPABASE_URL, SUPABASE_SVC);
    const { document_id, employee_id, hotel_id, signer_first_name, signer_name, signer_email, signer_phone } = await req.json();

    // Récupérer le fichier PDF depuis Supabase Storage
    const { data: docRow } = await sb.from('employee_documents')
      .select('storage_path, label, file_path').eq('id', document_id).single();
    if (!docRow) return new Response(JSON.stringify({ error: 'Document introuvable' }), { status: 404, headers: CORS });

    const storagePath = docRow.storage_path || docRow.file_path;
    if (!storagePath) return new Response(JSON.stringify({ error: 'Chemin de fichier absent' }), { status: 400, headers: CORS });

    const { data: fileData, error: dlErr } = await sb.storage.from('employee-documents').download(storagePath);
    if (dlErr || !fileData) return new Response(JSON.stringify({ error: 'Téléchargement impossible : ' + dlErr?.message }), { status: 500, headers: CORS });

    // 1. Créer la signature request (draft)
    const srRes = await ys('/signature_requests', 'POST', {
      name: docRow.label || 'Contrat',
      delivery_mode: 'none',      // on gère nous-mêmes la notif via le portail
      timezone: 'Europe/Paris',
      audit_trail_locale: 'fr',
      signers_allowed_to_decline: true,
    });
    if (!srRes.ok) return new Response(JSON.stringify({ error: 'YouSign SR : ' + await srRes.text() }), { status: 502, headers: CORS });
    const sr = await srRes.json();
    const srId = sr.id as string;

    // 2. Uploader le document PDF
    const pdfBytes = await fileData.arrayBuffer();
    const form = new FormData();
    form.append('file', new Blob([pdfBytes], { type: 'application/pdf' }), 'document.pdf');
    form.append('nature', 'signable_document');
    form.append('parse_anchors', 'false');
    const docRes = await fetch(`${YOUSIGN_API}/signature_requests/${srId}/documents`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}` },
      body: form,
    });
    if (!docRes.ok) return new Response(JSON.stringify({ error: 'YouSign doc : ' + await docRes.text() }), { status: 502, headers: CORS });
    const ysDoc = await docRes.json();

    // 3. Ajouter le signataire + champ de signature (dernière page, bas gauche)
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
        page: 1,      // page 1 par défaut ; à personnaliser si besoin
        x: 80, y: 680,
        width: 200, height: 70,
      }],
      signature_authentication_mode: signer_phone ? 'otp_sms' : 'otp_email',
    });
    if (!signerRes.ok) return new Response(JSON.stringify({ error: 'YouSign signer : ' + await signerRes.text() }), { status: 502, headers: CORS });
    const signer = await signerRes.json();

    // 4. Activer la demande → passe de draft à ongoing
    const actRes = await ys(`/signature_requests/${srId}/activate`, 'POST');
    if (!actRes.ok) return new Response(JSON.stringify({ error: 'YouSign activate : ' + await actRes.text() }), { status: 502, headers: CORS });
    const activated = await actRes.json();

    // Récupérer le signature_link du signer
    const signatureLink = (activated.signers as Array<{ id: string; signature_link?: string }>)
      ?.find(s => s.id === signer.id)?.signature_link ?? signer.signature_link ?? '';

    // 5. Enregistrer en base
    const { data: psrRow, error: insErr } = await sb.from('portal_signature_requests').insert({
      hotel_id, employee_id, document_id,
      yousign_sr_id: srId,
      yousign_signer_id: signer.id,
      yousign_document_id: ysDoc.id,
      status: 'ongoing',
      initiated_by: user.id,
    }).select('id').single();
    if (insErr) return new Response(JSON.stringify({ error: 'DB : ' + insErr.message }), { status: 500, headers: CORS });

    // 6. Mettre à jour employee_documents
    await sb.from('employee_documents').update({
      signature_status: 'pending',
      signature_request_id: psrRow.id,
    }).eq('id', document_id);

    // 7. Message portail pour le salarié
    await sb.from('portal_messages').insert({
      hotel_id, employee_id,
      direction: 'manager_to_employee',
      body: '📝 Un document est en attente de votre signature électronique dans votre coffre-fort.',
    });

    return new Response(JSON.stringify({ success: true, psr_id: psrRow.id, signature_link: signatureLink }), { headers: CORS });
  } catch (e) {
    console.error('yousign-create error:', e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
