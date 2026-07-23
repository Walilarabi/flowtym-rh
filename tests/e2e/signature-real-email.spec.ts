/**
 * E2E RÉEL AVEC RÉCEPTION D'E-MAIL — Moteur de signature Flowtym v2
 * =========================================================================
 * Contrairement au test d'intégration (signature-otp-controlled.integration.spec.ts,
 * OTP contrôlé), ce test NE modifie PAS otp_hash. Il prouve la chaîne complète :
 *   1. génération réelle du code par sig-send ;
 *   2. envoi via RESEND ;
 *   3. réception du message dans une boîte de test ;
 *   4. extraction de l'OTP depuis le corps de l'e-mail ;
 *   5. utilisation de cet OTP dans le parcours public sig-sign.
 *
 * FOURNISSEUR DE BOÎTE DÉCOUPLÉ : le test ne connaît aucun fournisseur concret.
 * Il utilise getMailboxProvider() (tests/e2e/support/mailbox.ts), piloté par
 * MAILBOX_PROVIDER = mailosaur | resend_inbound | mailpit | mailhog | smtp_local.
 * Si aucun fournisseur n'est configuré → test.skip (dépendance manquante, ne
 * compte pas comme une preuve).
 *
 * PRÉREQUIS ENV : SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, FLOWTYM_MANAGER_JWT,
 *   FLOWTYM_TEST_HOTEL_ID, FLOWTYM_TEST_EMPLOYEE_ID, FLOWTYM_TEST_CONTRACT_ID,
 *   MAILBOX_PROVIDER (+ variables propres au fournisseur, cf. support/mailbox.ts).
 */
import { test, expect, request as pwRequest } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { getMailboxProvider } from './support/mailbox';

const URL = process.env.SUPABASE_URL!;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const FN  = `${URL}/functions/v1`;
const MJWT = process.env.FLOWTYM_MANAGER_JWT!;
const HOTEL = process.env.FLOWTYM_TEST_HOTEL_ID!;
const EMP = process.env.FLOWTYM_TEST_EMPLOYEE_ID!;
const CONTRACT = process.env.FLOWTYM_TEST_CONTRACT_ID!;

const mailbox = getMailboxProvider();
const sb = createClient(URL, SVC, { auth: { persistSession: false } });

test.describe.serial('Signature v2 — E2E réel avec réception e-mail', () => {
  test.skip(!mailbox, 'Dépendance manquante : configurez MAILBOX_PROVIDER (mailosaur | resend_inbound | mailpit | mailhog | smtp_local)');

  let requestId = '';
  let signerEmail = '';

  test('génère + envoie via sig-send (email réel)', async () => {
    signerEmail = mailbox!.address(`sig-e2e-${Date.now()}`);
    const api = await pwRequest.newContext();
    const r = await api.post(`${FN}/sig-send`, {
      headers: { Authorization: `Bearer ${MJWT}`, 'Content-Type': 'application/json' },
      data: { contract_id: CONTRACT, employee_id: EMP, hotel_id: HOTEL, signer_name: 'E2E Email', signer_email: signerEmail },
    });
    expect(r.ok(), await r.text()).toBeTruthy();
    requestId = (await r.json()).request_id;
    expect(requestId).toBeTruthy();
  });

  test('reçoit l\'e-mail, extrait l\'OTP, complète la vérification', async () => {
    const otp = await mailbox!.waitForOtp(signerEmail);
    expect(otp).toMatch(/^\d{6}$/);
    const api = await pwRequest.newContext();
    // vérifie avec le vrai code reçu — aucune manipulation de otp_hash
    const v = await api.post(`${FN}/sig-sign`, { data: { request_id: requestId, action: 'verify_otp', otp } });
    expect(v.ok(), await v.text()).toBeTruthy();
    const { data: sr } = await sb.from('signature_requests').select('status').eq('id', requestId).single();
    expect(sr!.status).toBe('otp_verified');
  });
});
