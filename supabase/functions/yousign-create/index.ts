import { createClient } from 'jsr:@supabase/supabase-js@2';

// ── YouSign API v3 — Signature électronique ───────────────────────────────────
// Mode A (contracts)  : pdf_base64 + contract_id  → upload PDF directement
// Mode B (portal docs): document_id               → lookup depuis employee_documents

const YOUSIGN_API   = 'https://api-sandbox.yousign.app/v3';
const YOUSIGN_KEY   = Deno.env.get('YOUSIGN_API_KEY') ?? '';
const SUPABASE_URL  = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const STEP_TIMEOUT_MS = 20_000; // 20s par étape YouSign

console.log('[yousign-create] boot — YOUSIGN_API:', YOUSIGN_API, '— key present:', !!YOUSIGN_KEY);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Content-Type': 'application/json',
};

// ── fetch avec timeout + logs ─────────────────────────────────────────────────
async function ysFetch(step: string, url: string, init: RequestInit): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), STEP_TIMEOUT_MS);
  const t0 = Date.now();
  console.log(`[yousign-create] ${step} START — ${init.method ?? 'GET'} ${url}`);
  try {
    const res = await fetch(url, { ...init, signal: ctrl.signal });
    const ms = Date.now() - t0;
    console.log(`[yousign-create] ${step} END — status:${res.status} duration:${ms}ms`);
    return res;
  } catch (e: unknown) {
    const ms = Date.now() - t0;
    const isAbort = e instanceof Error && e.name === 'AbortError';
    console.error(`[yousign-create] ${step} FAIL — ${isAbort ? 'TIMEOUT' : String(e)} duration:${ms}ms`);
    throw Object.assign(new Error(isAbort ? `YOUSIGN_TIMEOUT:${step}` : String(e)), { step });
  } finally {
    clearTimeout(timer);
  }
}

// ── helper: lire erreur YouSign + logger ─────────────────────────────────────
async function ysError(step: string, res: Response): Promise<Response> {
  if (!res.ok) {
    const body = await res.text();
    console.error(`[yousign-create] ${step} ERROR — HTTP ${res.status} — ${body}`);
    throw Object.assign(new Error(`YOUSIGN_HTTP:${step}:${res.status}`), { step, detail: body, httpStatus: res.status });
  }
  return res;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });

  try {
    // ── Auth ──────────────────────────────────────────────────────────────────
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
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

    // ── Mode diagnostic ───────────────────────────────────────────────────────
    if (payload.diagnostic === true) {
      const trimmedKey = YOUSIGN_KEY.trim();
      const keyInfo = {
        keyPresent:    !!trimmedKey,
        keyLength:     YOUSIGN_KEY.length,
        keyPrefix:     YOUSIGN_KEY.slice(0, 8),
        keySuffix:     YOUSIGN_KEY.slice(-4),
        hasWhitespace: YOUSIGN_KEY !== trimmedKey || /\s/.test(YOUSIGN_KEY),
        apiBase:       YOUSIGN_API,
      };
      console.log('[yousign-create] DIAGNOSTIC KEY —', JSON.stringify(keyInfo));

      let usersMe: unknown;
      try {
        const r = await fetch(`${YOUSIGN_API}/users/me`, {
          method: 'GET',
          headers: { 'Authorization': `Bearer ${trimmedKey}`, 'Content-Type': 'application/json' },
          signal: AbortSignal.timeout(10_000),
        });
        const body = await r.text();
        console.log(`[yousign-create] diag GET /users/me → ${r.status} — ${body.slice(0, 500)}`);
        usersMe = { status: r.status, body: body.slice(0, 500) };
      } catch (err) {
        console.error(`[yousign-create] diag GET /users/me → EXCEPTION: ${String(err)}`);
        usersMe = { error: String(err) };
      }

      return new Response(JSON.stringify({ ...keyInfo, usersMe }), { headers: CORS });
    }

    console.log('[yousign-create] payload keys:', Object.keys(payload).join(', '));

    const {
      pdf_base64, contract_id, contract_label,
      document_id,
      employee_id, hotel_id,
      signer_first_name, signer_name, signer_email, signer_phone,
      sig_field,
      dual_signature, sig_field_employer, employer_email, employer_name,
    } = payload;

    const sb = createClient(SUPABASE_URL, SUPABASE_SVC);

    // ── Résoudre le PDF ───────────────────────────────────────────────────────
    let pdfBytes: ArrayBuffer;
    let docLabel: string;

    if (pdf_base64) {
      console.log('[yousign-create] Mode A — base64 length:', pdf_base64.length, 'contract_id:', contract_id);
      const binary = atob(pdf_base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      pdfBytes = bytes.buffer;
      docLabel = contract_label || 'Contrat';
      console.log('[yousign-create] Mode A — pdf bytes:', pdfBytes.byteLength);

    } else if (document_id) {
      console.log('[yousign-create] Mode B — document_id:', document_id);
      const { data: docRow } = await sb.from('employee_documents')
        .select('storage_path, label, file_path').eq('id', document_id).single();
      if (!docRow) return new Response(JSON.stringify({ error: 'Document introuvable', detail: `id=${document_id}` }), { status: 404, headers: CORS });
      const storagePath = docRow.storage_path || docRow.file_path;
      if (!storagePath) return new Response(JSON.stringify({ error: 'Chemin fichier absent' }), { status: 400, headers: CORS });
      const { data: fileData, error: dlErr } = await sb.storage.from('employee-documents').download(storagePath);
      if (dlErr || !fileData) return new Response(JSON.stringify({ error: 'Téléchargement impossible', detail: dlErr?.message }), { status: 500, headers: CORS });
      pdfBytes = await fileData.arrayBuffer();
      docLabel = docRow.label || 'Document';
      console.log('[yousign-create] Mode B — pdf bytes:', pdfBytes.byteLength);

    } else {
      return new Response(JSON.stringify({ error: 'pdf_base64 ou document_id requis' }), { status: 400, headers: CORS });
    }

    // ── Step 1 : Créer la signature request ──────────────────────────────────
    const srUrl = `${YOUSIGN_API}/signature_requests`;
    const srPayload = {
      name: docLabel,
      delivery_mode: 'email',   // 'none' retournait 405 — test avec 'email'
      timezone: 'Europe/Paris',
      audit_trail_locale: 'fr',
      signers_allowed_to_decline: true,
    };
    console.log('[yousign-create] create_sr — URL:', srUrl);
    console.log('[yousign-create] create_sr — method: POST');
    console.log('[yousign-create] create_sr — headers: Authorization=Bearer[present=' + !!YOUSIGN_KEY + '] Content-Type=application/json');
    console.log('[yousign-create] create_sr — payload:', JSON.stringify(srPayload));
    const srRes = await ysError('create_sr',
      await ysFetch('create_sr', srUrl, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(srPayload),
      })
    );
    const sr = await srRes.json();
    const srId = sr.id as string;
    console.log('[yousign-create] SR created — id:', srId);

    // ── Step 2 : Upload PDF ───────────────────────────────────────────────────
    const form = new FormData();
    form.append('file', new Blob([pdfBytes], { type: 'application/pdf' }), 'document.pdf');
    form.append('nature', 'signable_document');
    form.append('parse_anchors', 'false');
    const docRes = await ysError('upload_pdf',
      await ysFetch('upload_pdf', `${YOUSIGN_API}/signature_requests/${srId}/documents`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}` },
        body: form,
      })
    );
    const ysDoc = await docRes.json();
    console.log('[yousign-create] doc uploaded — id:', ysDoc.id);

    // ── Normaliser le téléphone (E.164) ──────────────────────────────────────
    // Accepte : 0612345678, +33612345678, 33612345678 → +33612345678
    // Rejette tout ce qui ne matche pas E.164 après normalisation
    let normalizedPhone: string | undefined;
    if (signer_phone && String(signer_phone).trim()) {
      const raw = String(signer_phone).replace(/[\s.\-()]/g, '');
      let e164 = raw;
      if (/^0[1-9]\d{8}$/.test(raw)) {
        e164 = '+33' + raw.slice(1); // 06... → +336...
      } else if (/^33[1-9]\d{8}$/.test(raw)) {
        e164 = '+' + raw;
      }
      if (/^\+[1-9]\d{7,14}$/.test(e164)) {
        normalizedPhone = e164;
      } else {
        console.warn('[yousign-create] téléphone invalide ignoré:', signer_phone, '→', raw);
      }
    }
    console.log('[yousign-create] phone normalized:', normalizedPhone ?? 'absent');

    // ── Step 3 : Ajouter signataire ───────────────────────────────────────────
    const signerInfo: Record<string, unknown> = {
      first_name: signer_first_name,
      last_name:  signer_name,
      email:      signer_email,
      locale:     'fr',
    };
    if (normalizedPhone) signerInfo.phone_number = normalizedPhone;

    // Champ de signature : coordonnées mesurées côté frontend (sig_field) ou fallback hardcodé.
    // Unité : points (1pt = 1/72"), origine top-left de la page, système YouSign v3.
    const signerField = (sig_field && sig_field.page && sig_field.x != null && sig_field.y != null)
      ? { document_id: ysDoc.id, type: 'signature', page: sig_field.page, x: sig_field.x, y: sig_field.y, width: sig_field.width ?? 190, height: sig_field.height ?? 55 }
      : { document_id: ysDoc.id, type: 'signature', page: 1, x: 80, y: 680, width: 200, height: 70 };
    console.log('[yousign-create] signerField:', JSON.stringify(signerField));

    const signerRes = await ysError('add_signer',
      await ysFetch('add_signer', `${YOUSIGN_API}/signature_requests/${srId}/signers`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          info: signerInfo,
          signature_level: 'electronic_signature',
          fields: [signerField],
          signature_authentication_mode: normalizedPhone ? 'otp_sms' : 'otp_email',
        }),
      })
    );
    const signer = await signerRes.json();
    console.log('[yousign-create] signer added — id:', signer.id);

    // ── Step 3b : Ajouter signataire employeur (mode double signature) ────────
    let employerSigner: { id: string } | null = null;
    if (dual_signature && employer_email) {
      const [empFirst = '', ...empLastParts] = String(employer_name || '').split(' ');
      const empLast = empLastParts.join(' ') || empFirst || 'Employeur';
      const empFieldFallback = { document_id: ysDoc.id, type: 'signature', page: signerField.page, x: 80, y: signerField.y, width: 200, height: 55 };
      const empField = (sig_field_employer && sig_field_employer.page != null && sig_field_employer.x != null)
        ? { document_id: ysDoc.id, type: 'signature', page: sig_field_employer.page, x: sig_field_employer.x, y: sig_field_employer.y, width: sig_field_employer.width ?? 190, height: sig_field_employer.height ?? 55 }
        : empFieldFallback;
      console.log('[yousign-create] employer field:', JSON.stringify(empField));
      const empSignerRes = await ysError('add_employer_signer',
        await ysFetch('add_employer_signer', `${YOUSIGN_API}/signature_requests/${srId}/signers`, {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            info: { first_name: empFirst || 'Représentant', last_name: empLast, email: employer_email, locale: 'fr' },
            signature_level: 'electronic_signature',
            fields: [empField],
            signature_authentication_mode: 'otp_email',
          }),
        })
      );
      employerSigner = await empSignerRes.json() as { id: string };
      console.log('[yousign-create] employer signer added — id:', employerSigner.id);
    }

    // ── Step 4 : Activer ──────────────────────────────────────────────────────
    const actRes = await ysError('activate',
      await ysFetch('activate', `${YOUSIGN_API}/signature_requests/${srId}/activate`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${YOUSIGN_KEY}`, 'Content-Type': 'application/json' },
      })
    );
    const activated = await actRes.json();
    console.log('[yousign-create] activated — status:', activated.status);

    const activatedSigners = activated.signers as Array<{ id: string; signature_link?: string }> ?? [];
    const signatureLink = activatedSigners.find(s => s.id === signer.id)?.signature_link ?? signer.signature_link ?? '';
    const employerSignatureLink = employerSigner
      ? (activatedSigners.find(s => s.id === employerSigner!.id)?.signature_link ?? '')
      : null;

    // ── Step 5 : Enregistrer en base ──────────────────────────────────────────
    if (pdf_base64 && contract_id) {
      const { error: updErr } = await sb.from('generated_contracts').update({
        yousign_sr_id: srId,
        yousign_status: 'pending',
      }).eq('id', contract_id);
      if (updErr) console.warn('[yousign-create] generated_contracts update warn:', updErr.message);

      if (employee_id && hotel_id) {
        await sb.from('portal_messages').insert({
          hotel_id, employee_id,
          direction: 'manager_to_employee',
          body: '📝 Un contrat est en attente de votre signature électronique.',
        });
      }
      console.log('[yousign-create] Mode A done — sr_id:', srId, '— dual:', !!employerSigner);
      return new Response(JSON.stringify({
        success: true, sr_id: srId,
        signature_link: signatureLink,
        employer_signature_link: employerSignatureLink,
        dual_signature: !!employerSigner,
      }), { headers: CORS });

    } else {
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

  } catch (e: unknown) {
    console.error('[yousign-create] caught error:', String(e));
    // Erreurs YouSign structurées (lancées par ysError/ysFetch)
    if (e && typeof e === 'object') {
      const err = e as { message?: string; step?: string; detail?: string; httpStatus?: number };
      if (err.message?.startsWith('YOUSIGN_TIMEOUT:')) {
        return new Response(JSON.stringify({
          error: 'YOUSIGN_TIMEOUT',
          step: err.step ?? err.message.replace('YOUSIGN_TIMEOUT:', ''),
          detail: `Pas de réponse de YouSign après ${STEP_TIMEOUT_MS / 1000}s à l'étape "${err.step}". Vérifiez le statut sandbox YouSign.`,
        }), { status: 504, headers: CORS });
      }
      if (err.message?.startsWith('YOUSIGN_HTTP:')) {
        const detail = err.detail ?? '';
        // Erreur téléphone → message lisible
        if (detail.includes('phone_number') || detail.includes('phone')) {
          return new Response(JSON.stringify({
            error: 'Numéro de téléphone invalide pour la signature électronique',
            detail: 'Utilisez le format international : +33612345678',
            step: err.step,
          }), { status: 422, headers: CORS });
        }
        return new Response(JSON.stringify({
          error: 'YOUSIGN_API_ERROR',
          step: err.step,
          detail,
          httpStatus: err.httpStatus,
        }), { status: 502, headers: CORS });
      }
    }
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
