/**
 * E2E RÉEL AVEC RÉCEPTION D'E-MAIL — Moteur de signature Flowtym v2
 * =========================================================================
 * Contrairement au test d'intégration (signature.spec.ts, OTP contrôlé), ce
 * test NE modifie PAS otp_hash. Il prouve la chaîne complète de l'OTP :
 *   1. génération réelle du code par sig-send ;
 *   2. envoi via RESEND ;
 *   3. réception du message dans une boîte de test ;
 *   4. extraction de l'OTP depuis le corps de l'e-mail ;
 *   5. utilisation de cet OTP dans le parcours public sig-sign.
 *
 * DÉPENDANCE MANQUANTE (à fournir avant exécution) :
 *   Une boîte e-mail de test interrogeable par API. Deux options :
 *   (a) Mailosaur  — MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID ; l'adresse
 *       signataire devient <id>@<server>.mailosaur.net.
 *   (b) Domaine de test RESEND + webhook stockant les messages reçus dans une
 *       table interrogeable (ex. inbound_test_emails) ; le test lit alors la
 *       dernière ligne pour l'adresse cible.
 *   Tant que l'une de ces deux dépendances n'est pas configurée, ce test est
 *   marqué test.skip — il ne peut pas s'exécuter et ne doit pas être compté
 *   comme une preuve.
 *
 * PRÉREQUIS ENV (en plus de ceux du test d'intégration) :
 *   MAILOSAUR_API_KEY, MAILOSAUR_SERVER_ID     (option a)
 *   FLOWTYM_MANAGER_JWT, FLOWTYM_TEST_HOTEL_ID, FLOWTYM_TEST_EMPLOYEE_ID,
 *   FLOWTYM_TEST_CONTRACT_ID, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */
import { test, expect, request as pwRequest } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL!;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const FN  = `${URL}/functions/v1`;
const MJWT = process.env.FLOWTYM_MANAGER_JWT!;
const HOTEL = process.env.FLOWTYM_TEST_HOTEL_ID!;
const EMP = process.env.FLOWTYM_TEST_EMPLOYEE_ID!;
const CONTRACT = process.env.FLOWTYM_TEST_CONTRACT_ID!;

const MAILOSAUR_KEY = process.env.MAILOSAUR_API_KEY;
const MAILOSAUR_SERVER = process.env.MAILOSAUR_SERVER_ID;
const HAS_MAILBOX = !!(MAILOSAUR_KEY && MAILOSAUR_SERVER);

const sb = createClient(URL, SVC, { auth: { persistSession: false } });

// Récupère l'OTP à 6 chiffres depuis le dernier e-mail reçu (Mailosaur).
async function fetchOtpFromEmail(toEmail: string): Promise<string> {
  const api = await pwRequest.newContext();
  // Mailosaur : recherche du message le plus récent pour l'adresse cible.
  const r = await api.post(
    `https://mailosaur.com/api/messages/search?server=${MAILOSAUR_SERVER}&timeout=30000`,
    {
      headers: { Authorization: 'Basic ' + Buffer.from(`${MAILOSAUR_KEY}:`).toString('base64'), 'Content-Type': 'application/json' },
      data: { sentTo: toEmail },
    },
  );
  if (!r.ok()) throw new Error('Mailosaur search failed: ' + await r.text());
  const items = (await r.json()).items;
  if (!items?.length) throw new Error('Aucun e-mail reçu');
  const msgId = items[0].id;
  const full = await api.get(`https://mailosaur.com/api/messages/${msgId}`, {
    headers: { Authorization: 'Basic ' + Buffer.from(`${MAILOSAUR_KEY}:`).toString('base64') },
  });
  const body = (await full.json()).html?.body || (await full.json()).text?.body || '';
  const m = body.match(/\b(\d{6})\b/);
  if (!m) throw new Error('OTP introuvable dans l\'e-mail');
  return m[1];
}

test.describe.serial('Signature v2 — E2E réel avec réception e-mail', () => {
  test.skip(!HAS_MAILBOX, 'Dépendance manquante : boîte e-mail de test (MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID)');

  let requestId = '';
  let signerEmail = '';

  test('génère + envoie via sig-send (email réel)', async () => {
    signerEmail = `sig-e2e.${Date.now()}@${MAILOSAUR_SERVER}.mailosaur.net`;
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-send`, {
      headers: { Authorization: `Bearer ${MJWT}`, 'Content-Type': 'application/json' },
      data: { contract_id: CONTRACT, employee_id: EMP, hotel_id: HOTEL, signer_name: 'E2E Email', signer_email: signerEmail },
    });
    expect(r.ok(), await r.text()).toBeTruthy();
    requestId = (await r.json()).request_id;
    expect(requestId).toBeTruthy();
  });

  test('reçoit l\'e-mail, extrait l\'OTP, complète le parcours public', async () => {
    const otp = await fetchOtpFromEmail(signerEmail);
    expect(otp).toMatch(/^\d{6}$/);
    const api = await pwRequest.newContext();
    // vérifie avec le vrai code reçu — aucune manipulation de otp_hash
    const v = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'verify_otp', otp } });
    expect(v.ok(), await v.text()).toBeTruthy();
    const { data: sr } = await sb.from('signature_requests').select('status').eq('id', requestId).single();
    expect(sr!.status).toBe('otp_verified');
  });
});
