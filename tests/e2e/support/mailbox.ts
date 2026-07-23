/**
 * Abstraction "boîte e-mail de test" — découple l'E2E réel de tout fournisseur.
 * =========================================================================
 * Le test E2E réel a besoin de récupérer un OTP depuis un e-mail réellement
 * envoyé. Plutôt que de coupler le test à Mailosaur, on définit une interface
 * MailboxProvider et une fabrique pilotée par la variable MAILBOX_PROVIDER.
 *
 * Fournisseurs supportés (MAILBOX_PROVIDER) :
 *   - mailosaur      : MAILOSAUR_API_KEY, MAILOSAUR_SERVER_ID
 *   - resend_inbound : lit une table Supabase alimentée par un webhook inbound
 *                      (INBOUND_TABLE, défaut 'inbound_test_emails') via SUPABASE_*
 *   - mailpit        : MAILPIT_URL (ex. http://localhost:8025)
 *   - mailhog        : MAILHOG_URL (ex. http://localhost:8025)
 *   - smtp_local     : alias de mailpit/mailhog selon SMTP_UI_KIND ('mailpit'|'mailhog')
 *
 * Toutes les implémentations exposent la même méthode :
 *   waitForOtp(toEmail, opts?) : Promise<string>   // OTP 6 chiffres
 *   address(localPart?)        : string            // adresse d'envoi propre au provider
 *
 * Ajouter un fournisseur = implémenter MailboxProvider et l'enregistrer dans
 * la fabrique. Aucun test n'a à connaître le fournisseur concret.
 */
import { request as pwRequest, type APIRequestContext } from '@playwright/test';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export interface MailboxProvider {
  /** Adresse d'envoi à utiliser pour ce fournisseur (unicité via localPart). */
  address(localPart?: string): string;
  /** Attend le dernier e-mail pour `toEmail` et en extrait l'OTP à 6 chiffres. */
  waitForOtp(toEmail: string, opts?: { timeoutMs?: number; pollMs?: number }): Promise<string>;
}

const OTP_RE = /\b(\d{6})\b/;
function extractOtp(text: string): string | null {
  const m = (text || '').match(OTP_RE);
  return m ? m[1] : null;
}
async function poll<T>(fn: () => Promise<T | null>, timeoutMs: number, pollMs: number, label: string): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const v = await fn();
    if (v != null) return v;
    if (Date.now() > deadline) throw new Error(`Timeout (${label}) après ${timeoutMs}ms`);
    await new Promise(r => setTimeout(r, pollMs));
  }
}

// ── Mailosaur ────────────────────────────────────────────────────────────────
class MailosaurProvider implements MailboxProvider {
  constructor(private key = process.env.MAILOSAUR_API_KEY!, private server = process.env.MAILOSAUR_SERVER_ID!) {}
  private auth() { return 'Basic ' + Buffer.from(`${this.key}:`).toString('base64'); }
  address(localPart = `sig-${Date.now()}`) { return `${localPart}@${this.server}.mailosaur.net`; }
  async waitForOtp(toEmail: string, opts?: { timeoutMs?: number; pollMs?: number }): Promise<string> {
    const api = await pwRequest.newContext();
    return poll(async () => {
      const r = await api.post(`https://mailosaur.com/api/messages/search?server=${this.server}&timeout=20000`, {
        headers: { Authorization: this.auth(), 'Content-Type': 'application/json' },
        data: { sentTo: toEmail },
      });
      if (!r.ok()) return null;
      const items = (await r.json()).items;
      if (!items?.length) return null;
      const full = await api.get(`https://mailosaur.com/api/messages/${items[0].id}`, { headers: { Authorization: this.auth() } });
      const j = await full.json();
      return extractOtp(j.html?.body || j.text?.body || '');
    }, opts?.timeoutMs ?? 60000, opts?.pollMs ?? 3000, 'mailosaur');
  }
}

// ── Mailpit / MailHog (self-host, même logique, endpoints différents) ─────────
class HttpInboxProvider implements MailboxProvider {
  constructor(private base: string, private kind: 'mailpit' | 'mailhog', private domain = process.env.TEST_MAIL_DOMAIN || 'test.local') {}
  address(localPart = `sig-${Date.now()}`) { return `${localPart}@${this.domain}`; }
  async waitForOtp(toEmail: string, opts?: { timeoutMs?: number; pollMs?: number }): Promise<string> {
    const api = await pwRequest.newContext();
    return poll(async () => {
      if (this.kind === 'mailpit') {
        const r = await api.get(`${this.base}/api/v1/search?query=${encodeURIComponent('to:' + toEmail)}`);
        if (!r.ok()) return null;
        const msgs = (await r.json()).messages || [];
        if (!msgs.length) return null;
        const full = await api.get(`${this.base}/api/v1/message/${msgs[0].ID}`);
        const j = await full.json();
        return extractOtp(j.Text || j.HTML || '');
      } else {
        const r = await api.get(`${this.base}/api/v2/search?kind=to&query=${encodeURIComponent(toEmail)}`);
        if (!r.ok()) return null;
        const items = (await r.json()).items || [];
        if (!items.length) return null;
        const body = items[0].Content?.Body || '';
        return extractOtp(body);
      }
    }, opts?.timeoutMs ?? 60000, opts?.pollMs ?? 2000, this.kind);
  }
}

// ── Resend Inbound (webhook → table Supabase interrogeable) ───────────────────
class ResendInboundProvider implements MailboxProvider {
  private sb: SupabaseClient;
  constructor(private table = process.env.INBOUND_TABLE || 'inbound_test_emails', private domain = process.env.TEST_MAIL_DOMAIN || 'inbound.flowtym.test') {
    this.sb = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  }
  address(localPart = `sig-${Date.now()}`) { return `${localPart}@${this.domain}`; }
  async waitForOtp(toEmail: string, opts?: { timeoutMs?: number; pollMs?: number }): Promise<string> {
    return poll(async () => {
      const { data } = await this.sb.from(this.table)
        .select('subject, text_body, html_body, created_at')
        .eq('to_address', toEmail).order('created_at', { ascending: false }).limit(1);
      const row = data?.[0];
      if (!row) return null;
      return extractOtp(row.text_body || row.html_body || row.subject || '');
    }, opts?.timeoutMs ?? 60000, opts?.pollMs ?? 3000, 'resend_inbound');
  }
}

export function getMailboxProvider(): MailboxProvider | null {
  const kind = (process.env.MAILBOX_PROVIDER || '').toLowerCase();
  switch (kind) {
    case 'mailosaur':
      if (!process.env.MAILOSAUR_API_KEY || !process.env.MAILOSAUR_SERVER_ID) return null;
      return new MailosaurProvider();
    case 'mailpit':
      if (!process.env.MAILPIT_URL) return null;
      return new HttpInboxProvider(process.env.MAILPIT_URL, 'mailpit');
    case 'mailhog':
      if (!process.env.MAILHOG_URL) return null;
      return new HttpInboxProvider(process.env.MAILHOG_URL, 'mailhog');
    case 'smtp_local': {
      const ui = (process.env.SMTP_UI_KIND || 'mailpit') as 'mailpit' | 'mailhog';
      const base = process.env.MAILPIT_URL || process.env.MAILHOG_URL;
      if (!base) return null;
      return new HttpInboxProvider(base, ui);
    }
    case 'resend_inbound':
      if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) return null;
      return new ResendInboundProvider();
    default:
      return null; // aucun fournisseur configuré → le test E2E réel se met en skip
  }
}
