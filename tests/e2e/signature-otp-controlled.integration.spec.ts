/**
 * TEST D'INTÉGRATION DU PARCOURS DE SIGNATURE AVEC OTP CONTRÔLÉ
 * =========================================================================
 * ⚠️ CECI N'EST PAS UN E2E COMPLET DE L'OTP. Ce test fixe un otp_hash connu
 * via service_role juste avant verify_otp. Il CONTOURNE donc volontairement :
 *   - la génération réelle de l'OTP par sig-send/sig-sign ;
 *   - son hachage initial ;
 *   - son envoi par e-mail (RESEND) ;
 *   - sa réception ;
 *   - l'extraction du code depuis le message reçu.
 * Il ne doit JAMAIS être présenté comme la preuve du fonctionnement complet de
 * l'envoi d'OTP. La preuve de l'envoi réel est couverte par le test séparé
 * tests/e2e/signature-real-email.spec.ts.
 *
 * Ce test reste utile pour valider de façon déterministe : refus avant OTP,
 * mauvais codes, incrément atomique des tentatives, passage à otp_verified,
 * accès au contrat, signature, stockage, hashes, événements, synchronisation.
 *
 * PRÉREQUIS (variables d'environnement) :
 *   SUPABASE_URL                 https://<ref>.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY    (assertions DB/storage uniquement — jamais exposé au navigateur)
 *   SUPABASE_ANON_KEY
 *   FLOWTYM_TEST_HOTEL_ID        hôtel de test (accessible au user ci-dessous)
 *   FLOWTYM_TEST_EMPLOYEE_ID     salarié de test
 *   FLOWTYM_TEST_CONTRACT_ID     contrat de test (status 'generated', generated_html non nul)
 *   FLOWTYM_MANAGER_JWT          JWT d'un manager ayant accès à l'hôtel (pour sig-send)
 *   FLOWTYM_TEST_EMAIL           email signataire de test
 *
 * LANCEMENT :
 *   npx playwright test tests/e2e/signature.spec.ts
 *
 * SEAM ASSUMÉ : l'OTP réel est livré par email (Resend). Le test ne lit pas
 * l'email ; il fixe un otp_hash connu via service_role juste avant verify_otp.
 * Tout le reste du parcours passe par les vraies fonctions déployées.
 */
import { test, expect, request as pwRequest } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { createHash } from 'node:crypto';

const URL   = process.env.SUPABASE_URL!;
const SVC   = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const FN     = `${URL}/functions/v1`;
const HOTEL  = process.env.FLOWTYM_TEST_HOTEL_ID!;
const EMP    = process.env.FLOWTYM_TEST_EMPLOYEE_ID!;
const CONTRACT = process.env.FLOWTYM_TEST_CONTRACT_ID!;
const MJWT   = process.env.FLOWTYM_MANAGER_JWT!;
const EMAIL  = process.env.FLOWTYM_TEST_EMAIL || 'e2e-signature@example.test';

const sb = createClient(URL, SVC, { auth: { persistSession: false } });
const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
const KNOWN_OTP = '135790';

// PNG 1x1 transparent → signature bidon valide
const SIG_PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

test.describe.serial('Signature v2 — intégration (OTP contrôlé, envoi e-mail contourné)', () => {
  let requestId = '';

  test('1-2. sig-send crée la demande (moteur v2)', async () => {
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-send`, {
      headers: { Authorization: `Bearer ${MJWT}`, 'Content-Type': 'application/json' },
      data: { contract_id: CONTRACT, employee_id: EMP, hotel_id: HOTEL, signer_name: 'E2E Test', signer_email: EMAIL },
    });
    expect(r.ok(), await r.text()).toBeTruthy();
    const body = await r.json();
    expect(body.request_id).toBeTruthy();
    requestId = body.request_id;

    const { data: sr } = await sb.from('signature_requests').select('status, document_hash_sha256').eq('id', requestId).single();
    expect(sr!.status).toBe('otp_sent');
    expect(sr!.document_hash_sha256, 'hash source du document doit être calculé à l\'envoi').toBeTruthy();
  });

  test('3-4. GET page publique NE CONTIENT PAS le contenu du contrat', async () => {
    const api = await pwRequest.newContext();
    const r = await api.get(`${FN}/sig-sign?request_id=${requestId}`);
    expect(r.status()).toBe(200);
    const html = await r.text();
    // Le HTML du contrat ne doit jamais apparaître avant OTP.
    const { data: c } = await sb.from('generated_contracts').select('generated_html').eq('id', CONTRACT).single();
    const needle = (c!.generated_html || '').replace(/\s+/g, ' ').slice(0, 40).trim();
    if (needle) expect(html.includes(needle), 'FUITE : contenu du contrat présent dans le GET').toBeFalsy();
    // Ni les données sensibles usuelles
    for (const kw of ['salaire', 'rémunération', 'adresse', 'IBAN', 'sécurité sociale']) {
      expect(html.toLowerCase().includes(kw.toLowerCase()), `FUITE potentielle: "${kw}" dans GET`).toBeFalsy();
    }
  });

  test('5. get_document SANS OTP → 403', async () => {
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'get_document' } });
    expect(r.status()).toBe(403);
  });

  test('6-7. OTP erroné → refus + incrément compteur', async () => {
    const api = await pwRequest.newContext();
    const { data: before } = await sb.from('signature_requests').select('otp_attempts').eq('id', requestId).single();
    const r = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'verify_otp', otp: '000000' } });
    expect(r.status()).toBe(400);
    const { data: after } = await sb.from('signature_requests').select('otp_attempts').eq('id', requestId).single();
    expect(after!.otp_attempts).toBeGreaterThan(before!.otp_attempts ?? 0);
    const { count } = await sb.from('signature_events').select('*', { count: 'exact', head: true }).eq('request_id', requestId).eq('type', 'otp_failed');
    expect(count).toBeGreaterThanOrEqual(1);
  });

  test('8. Bon OTP → otp_verified', async () => {
    // seam : on fixe un otp_hash connu (l'email réel n'est pas lu par le test)
    await sb.from('signature_requests').update({ otp_hash: sha256(KNOWN_OTP), otp_expires_at: new Date(Date.now() + 3600000).toISOString() }).eq('id', requestId);
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'verify_otp', otp: KNOWN_OTP } });
    expect(r.ok(), await r.text()).toBeTruthy();
    const { data: sr } = await sb.from('signature_requests').select('status').eq('id', requestId).single();
    expect(sr!.status).toBe('otp_verified');
  });

  test('9. get_document APRÈS OTP → 200 + contenu du contrat', async () => {
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'get_document' } });
    expect(r.status()).toBe(200);
    const d = await r.json();
    expect(d.contract_html, 'le contrat doit être servi après OTP').toBeTruthy();
  });

  test('10-17. Signature → PDF archivé réel + sync + hashes + events', async () => {
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'sign', signature_image: SIG_PNG } });
    expect(r.ok(), await r.text()).toBeTruthy();

    const { data: sr } = await sb.from('signature_requests')
      .select('status, signed_pdf_storage_path, signed_document_hash_sha256, signer_ip, signer_ua, signed_at, accepted_terms_at').eq('id', requestId).single();
    expect(sr!.status).toBe('signed');
    expect(sr!.signed_document_hash_sha256, 'hash du document signé').toBeTruthy();
    expect(sr!.signed_pdf_storage_path).toBeTruthy();
    expect(sr!.accepted_terms_at).toBeTruthy();

    // 13-14. PDF RÉELLEMENT présent dans le bucket privé + taille > 0
    const { data: dl, error: dlErr } = await sb.storage.from('hr-documents').download(sr!.signed_pdf_storage_path!);
    expect(dlErr, 'PDF absent du storage').toBeFalsy();
    const buf = await dl!.arrayBuffer();
    expect(buf.byteLength, 'PDF vide').toBeGreaterThan(1000);
    // en-tête PDF
    expect(new TextDecoder().decode(buf.slice(0, 5))).toBe('%PDF-');

    // 15. Hash recalculé DEPUIS LES OCTETS TÉLÉCHARGÉS == valeur stockée
    const recomputed = createHash('sha256').update(Buffer.from(buf)).digest('hex');
    expect(recomputed, 'le SHA-256 du PDF archivé doit égaler signed_document_hash_sha256')
      .toBe(sr!.signed_document_hash_sha256);

    // 16. chaîne d'événements attendue
    const { data: evts } = await sb.from('signature_events').select('type').eq('request_id', requestId).order('created_at');
    const types = (evts || []).map(e => e.type);
    for (const t of ['created', 'otp_sent', 'otp_verified', 'terms_accepted', 'signed', 'pdf_archived']) {
      expect(types.includes(t), `événement manquant: ${t}`).toBeTruthy();
    }

    // 17. synchronisation generated_contracts
    const { data: gc } = await sb.from('generated_contracts')
      .select('status, signed_pdf_storage_path, signed_document_hash_sha256, signature_request_id').eq('id', CONTRACT).single();
    expect(gc!.status).toBe('signed');
    expect(gc!.signed_pdf_storage_path).toBe(sr!.signed_pdf_storage_path);
    expect(gc!.signature_request_id).toBe(requestId);
  });

  test('19-20. Réouverture après signature → état terminal, plus signable', async () => {
    const api = await pwRequest.newContext();
    const g = await api.get(`${FN}/sig-sign?request_id=${requestId}`);
    expect((await g.text()).includes('Déjà signé') || (await g.text()).includes('Deja signe')).toBeTruthy();
    const s = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'sign', signature_image: SIG_PNG } });
    expect(s.status()).toBe(409); // déjà signé
  });

  test('NR. moteur v1 (contract-send-signature) désactivé → 410', async () => {
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/contract-send-signature`, {
      headers: { Authorization: `Bearer ${MJWT}`, 'Content-Type': 'application/json' },
      data: { contract_id: CONTRACT, signer_email: EMAIL },
    });
    expect(r.status()).toBe(410);
  });
});
