import { createClient } from 'jsr:@supabase/supabase-js@2';

// support-ticket-attachment-download-url — Lot 5 PR-07 (ADR-012 §3.5.5/§3.5.8).
// Seul point d'accès au CONTENU d'une pièce jointe (jamais un accès direct au
// bucket, aucune policy storage.objects n'existe pour ce bucket). Autorisation
// via la RPC centralisée _can_access_support_ticket (admin, ou hotel_user de
// l'hôtel du ticket). Exige status='clean' ET deleted_at IS NULL : aucun
// scanner antivirus n'est câblé dans ce lot (ADR-012 §3.5.8, correction round
// 5), donc 'clean' n'est jamais atteint automatiquement — conséquence honnête
// et assumée, aucune pièce jointe n'est donc téléchargeable en pratique tant
// qu'aucun scanner réel n'existe. Chaque émission d'URL est journalisée dans
// support_ticket_attachment_access_log (IP/user-agent capturés serveur,
// jamais transmis par le client).

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY      = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const BUCKET = 'support-ticket-attachments';
const SIGNED_URL_TTL_SECONDS = 600; // 10 minutes

const ALLOWED_ORIGINS = [
  'http://localhost', 'http://localhost:3000', 'http://localhost:5173',
  'https://flowtym.com', 'https://app.flowtym.com', 'https://rh.flowtym.com',
  'https://hzrzkvdebaadditvbqis.supabase.co',
  'https://flowtym-rh-git-main-walis-projects-e22749ce.vercel.app',
  'https://flowtym-rh.vercel.app',
];
const cors = (o: string | null) => {
  const allowed = o && (
    ALLOWED_ORIGINS.some(a => o.startsWith(a)) ||
    /^https:\/\/flowtym-[a-z0-9]+-walis-projects-e22749ce\.vercel\.app$/.test(o)
  ) ? o : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
};

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });

  try {
    const { attachment_id } = await req.json();
    if (!attachment_id) return json({ error: 'attachment_id est requis' }, 400);

    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({ error: 'Non authentifié' }, 401);

    const asCaller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHdr } } });
    const { data: { user }, error: authErr } = await asCaller.auth.getUser();
    if (authErr || !user) return json({ error: 'Token invalide' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: attachment } = await admin.from('support_ticket_attachments')
      .select('id, ticket_id, storage_path, status, deleted_at')
      .eq('id', attachment_id).maybeSingle();
    if (!attachment) return json({ error: 'Pièce jointe introuvable' }, 404);

    const { data: canAccess, error: accessErr } = await asCaller.rpc('_can_access_support_ticket', { p_ticket_id: attachment.ticket_id });
    if (accessErr || !canAccess) return json({ error: 'Accès refusé : ce ticket ne vous appartient pas' }, 403);

    if (attachment.deleted_at !== null) return json({ error: 'Pièce jointe supprimée' }, 410);
    if (attachment.status !== 'clean') {
      // Message honnête : tant qu'aucun scanner antivirus n'est câblé (ADR-012 §3.5.8),
      // 'clean' n'est jamais atteint — ce n'est pas un bug, c'est la limite assumée du lot.
      return json({ error: `Cette pièce jointe n'est pas encore téléchargeable (statut '${attachment.status}' — analyse antivirus non disponible dans ce lot)` }, 403);
    }

    const { data: signed, error: signErr } = await admin.storage.from(BUCKET)
      .createSignedUrl(attachment.storage_path, SIGNED_URL_TTL_SECONDS);
    if (signErr || !signed) return json({ error: `Génération de l'URL impossible : ${signErr?.message ?? 'erreur inconnue'}` }, 500);

    const forwardedFor = req.headers.get('x-forwarded-for');
    await admin.from('support_ticket_attachment_access_log').insert({
      attachment_id: attachment.id,
      ticket_id: attachment.ticket_id,
      user_id: user.id,
      action: 'download_url_issued',
      ip_address: forwardedFor ? forwardedFor.split(',')[0].trim() : null,
      user_agent: req.headers.get('user-agent'),
    });

    return json({ signed_url: signed.signedUrl, expires_in: SIGNED_URL_TTL_SECONDS });
  } catch (e) {
    return json({ error: `Erreur serveur : ${e instanceof Error ? e.message : String(e)}` }, 500);
  }
});
