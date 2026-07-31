import { createClient } from 'jsr:@supabase/supabase-js@2';

// support-ticket-attachment-request-upload — Lot 5 PR-07 (ADR-012 §3.5.5/§3.5.8).
// Phase 1/2 de l'upload : authentifie l'appelant, vérifie son droit d'accès au
// ticket via la RPC centralisée _can_access_support_ticket (admin ou hotel_user
// de l'hôtel du ticket, jamais déduit d'un champ envoyé par le client), valide
// mime_type/size_bytes contre les mêmes règles que les CHECK de la table, crée
// la ligne de métadonnées en statut 'pending_upload' (storage_path généré
// exclusivement ici, jamais dérivé du nom de fichier client) puis renvoie une
// URL d'upload signée. Le client doit ensuite appeler
// support-ticket-attachment-confirm une fois l'upload terminé — aucune
// transition vers 'uploaded' n'a lieu ici.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY      = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const BUCKET = 'support-ticket-attachments';
const ALLOWED_MIME = [
  'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/webp', 'image/gif',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
];
const MAX_SIZE_BYTES = 10485760;
// Seul 'ferme' est un état réellement terminal parmi les 6 valeurs de
// support_tickets_status_check ('resolu' reste rouvrable et peut légitimement
// recevoir une pièce jointe complémentaire avant fermeture définitive).
const CLOSED_TICKET_STATUSES = ['ferme'];

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

function sanitizeFilenameForPath(name: string): string {
  return name.normalize('NFKD').replace(/[^\w.\-]/g, '_').slice(-120) || 'fichier';
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });

  try {
    const { ticket_id, original_filename, mime_type, size_bytes } = await req.json();
    if (!ticket_id || !original_filename || !mime_type || !size_bytes) {
      return json({ error: 'ticket_id, original_filename, mime_type et size_bytes sont requis' }, 400);
    }
    if (!ALLOWED_MIME.includes(mime_type)) return json({ error: `Type de fichier non autorisé : ${mime_type}` }, 400);
    if (typeof size_bytes !== 'number' || size_bytes <= 0 || size_bytes > MAX_SIZE_BYTES) {
      return json({ error: 'Taille de fichier invalide (max 10 Mo)' }, 400);
    }

    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({ error: 'Non authentifié' }, 401);

    // Client scopé au JWT de l'appelant : sert à la fois pour auth.getUser() et pour
    // que auth.uid() soit correctement résolu à l'intérieur de _can_access_support_ticket.
    const asCaller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHdr } } });
    const { data: { user }, error: authErr } = await asCaller.auth.getUser();
    if (authErr || !user) return json({ error: 'Token invalide' }, 401);

    const { data: canAccess, error: accessErr } = await asCaller.rpc('_can_access_support_ticket', { p_ticket_id: ticket_id });
    if (accessErr || !canAccess) return json({ error: 'Accès refusé : ce ticket ne vous appartient pas' }, 403);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: ticket } = await admin.from('support_tickets').select('status').eq('id', ticket_id).maybeSingle();
    if (!ticket) return json({ error: 'Ticket introuvable' }, 404);
    if (CLOSED_TICKET_STATUSES.includes(ticket.status)) {
      return json({ error: 'Impossible d\'ajouter une pièce jointe à un ticket fermé' }, 400);
    }

    const storagePath = `${ticket_id}/${crypto.randomUUID()}-${sanitizeFilenameForPath(original_filename)}`;

    const { data: attachment, error: insErr } = await admin.from('support_ticket_attachments').insert({
      ticket_id, storage_path: storagePath, original_filename, mime_type, size_bytes,
      status: 'pending_upload', uploaded_by: user.id,
    }).select('id').single();
    if (insErr || !attachment) return json({ error: `Création de la pièce jointe impossible : ${insErr?.message ?? 'erreur inconnue'}` }, 500);

    const { data: signed, error: signErr } = await admin.storage.from(BUCKET).createSignedUploadUrl(storagePath);
    if (signErr || !signed) {
      // Nettoyage : pas d'URL d'upload utilisable, la ligne 'pending_upload' orpheline
      // n'a aucune valeur et empêcherait de réutiliser proprement ce storage_path.
      await admin.from('support_ticket_attachments').delete().eq('id', attachment.id);
      return json({ error: `Génération de l'URL d'upload impossible : ${signErr?.message ?? 'erreur inconnue'}` }, 500);
    }

    return json({
      attachment_id: attachment.id,
      storage_path: storagePath,
      signed_url: signed.signedUrl,
      token: signed.token,
    });
  } catch (e) {
    return json({ error: `Erreur serveur : ${e instanceof Error ? e.message : String(e)}` }, 500);
  }
});
