import { createClient } from 'jsr:@supabase/supabase-js@2';

// platform-send-notification — Lot 2 (ADR-012 §3.0).
// Point d'appel unique à Resend pour platform_notifications. service_role
// uniquement, jamais invocable côté client (aucun JWT utilisateur accepté).
// Traite une notification 'pending' -> 'sending' -> 'sent'/retry/'abandoned'.
// Templates versionnés dans ce fichier (pas en base) ; payload structuré,
// jamais de secret dans les logs.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SVC = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RESEND_KEY   = Deno.env.get('RESEND_API_KEY') ?? '';
const INTERNAL_KEY = Deno.env.get('PLATFORM_NOTIFICATION_INTERNAL_KEY') ?? '';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-internal-key',
  'Content-Type': 'application/json',
};

function json(d: unknown, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: CORS });
}

// Registre de templates versionné — le contenu HTML vit ici, jamais en base
// (doctrine ADR-012 §3.0). Chaque template déclare son objet et son corps à
// partir du payload structuré de la notification.
const TEMPLATES: Record<string, (p: Record<string, unknown>) => { subject: string; html: string }> = {
  trial_ending_soon: (p) => ({
    subject: `Votre essai Flowtym se termine dans ${p.days_remaining ?? '?'} jour(s)`,
    html: `<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px">
      <h3>Bonjour,</h3>
      <p>L'essai de votre hôtel <strong>${escapeHtml(String(p.hotel_name ?? ''))}</strong> se termine
      dans <strong>${escapeHtml(String(p.days_remaining ?? ''))} jour(s)</strong>, le
      ${escapeHtml(String(p.trial_ends_at ?? ''))}.</p>
      <p>Contactez votre interlocuteur Flowtym pour poursuivre sans interruption.</p>
    </div>`,
  }),
  ticket_status_changed: (p) => ({
    subject: `Votre ticket support ${p.ticket_number ?? ''} a été mis à jour`,
    html: `<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px">
      <h3>Ticket ${escapeHtml(String(p.ticket_number ?? ''))}</h3>
      <p>Nouveau statut : <strong>${escapeHtml(String(p.new_status ?? ''))}</strong></p>
    </div>`,
  }),
  ticket_new_reply: (p) => ({
    subject: `Nouvelle réponse sur votre ticket ${p.ticket_number ?? ''}`,
    html: `<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px">
      <h3>Ticket ${escapeHtml(String(p.ticket_number ?? ''))}</h3>
      <p>Une nouvelle réponse a été ajoutée. Connectez-vous à Flowtym pour la consulter.</p>
    </div>`,
  }),
};

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

async function sendViaResend(to: string, subject: string, html: string): Promise<void> {
  const resp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: 'Flowtym <noreply@flowtym.com>', to: [to], subject, html }),
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => '');
    // Jamais la clé Resend ni le payload complet dans les logs — seulement le statut HTTP.
    throw new Error(`Resend HTTP ${resp.status}: ${txt.slice(0, 200)}`);
  }
}

function backoffMinutes(attempts: number): number {
  // 5 min, 30 min, 2h — plafonné, jamais illimité.
  const steps = [5, 30, 120];
  return steps[Math.min(attempts, steps.length - 1)];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // Authentification service-à-service uniquement — jamais un JWT utilisateur.
  // Appelée par les RPC admin_run_* (via pg_net) ou par un déclenchement manuel
  // authentifié côté Super Admin avec la clé interne dédiée, jamais le client.
  const internalKey = req.headers.get('x-internal-key') ?? '';
  if (!INTERNAL_KEY || internalKey !== INTERNAL_KEY) {
    return json({ error: 'Non autorisé' }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const notificationId = body?.notification_id;
  if (!notificationId) return json({ error: 'notification_id requis' }, 400);

  const sb = createClient(SUPABASE_URL, SUPABASE_SVC);

  // Passage pending -> sending, garde de concurrence (une seule exécution gagne).
  const { data: claimed, error: claimErr } = await sb
    .from('platform_notifications')
    .update({ status: 'sending', processed_at: new Date().toISOString() })
    .eq('id', notificationId)
    .eq('status', 'pending')
    .select('id, category, recipient_email, template, template_payload, attempts, max_attempts')
    .maybeSingle();

  if (claimErr) {
    console.error('[platform-send-notification] claim error', claimErr.message);
    return json({ error: 'Erreur interne' }, 500);
  }
  if (!claimed) {
    // Déjà traitée par un autre appel concurrent, ou statut non 'pending' —
    // comportement attendu de la garde de concurrence, pas une erreur.
    return json({ success: true, skipped: true, reason: 'not_pending' });
  }

  const renderer = TEMPLATES[claimed.template];
  if (!renderer) {
    await sb.from('platform_notifications').update({
      status: 'abandoned', failed_at: new Date().toISOString(),
      final_error: `Template inconnu: ${claimed.template}`,
    }).eq('id', notificationId);
    return json({ success: false, error: 'Template inconnu' }, 422);
  }

  try {
    const { subject, html } = renderer(claimed.template_payload ?? {});
    await sendViaResend(claimed.recipient_email, subject, html);
    await sb.from('platform_notifications').update({
      status: 'sent', sent_at: new Date().toISOString(), attempts: claimed.attempts + 1,
    }).eq('id', notificationId);
    console.log('[platform-send-notification] sent', notificationId, claimed.category);
    return json({ success: true, status: 'sent' });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    const nextAttempts = claimed.attempts + 1;
    const abandoned = nextAttempts >= claimed.max_attempts;
    await sb.from('platform_notifications').update(
      abandoned
        ? { status: 'abandoned', attempts: nextAttempts, last_error: msg, final_error: msg, failed_at: new Date().toISOString() }
        : { status: 'pending', attempts: nextAttempts, last_error: msg, next_attempt_at: new Date(Date.now() + backoffMinutes(nextAttempts) * 60_000).toISOString() }
    ).eq('id', notificationId);
    console.error('[platform-send-notification] failed', notificationId, msg);
    return json({ success: false, status: abandoned ? 'abandoned' : 'pending', error: msg }, 502);
  }
});
