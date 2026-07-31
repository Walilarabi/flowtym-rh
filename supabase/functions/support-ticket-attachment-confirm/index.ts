import { createClient } from 'jsr:@supabase/supabase-js@2';

// support-ticket-attachment-confirm — Lot 5 PR-07 (ADR-012 §3.5.5/§3.5.8).
// Phase 2/2 de l'upload : l'appelant doit être l'auteur de l'upload
// (uploaded_by), la ligne doit être en 'pending_upload'. Vérifie contre l'API
// Storage réelle (jamais une simple confiance déclarative du client) que
// l'objet existe et que sa taille correspond à celle annoncée, puis fait
// passer le statut à 'scan_pending' — JAMAIS directement à 'clean' : aucun
// scanner antivirus n'est câblé dans ce lot (ADR-012 §3.5.8, correction round
// 5), la transition vers 'clean' reste réservée à un futur traitement dédié.
// Conséquence assumée : tant qu'aucun scanner n'existe, aucune pièce jointe
// n'est donc jamais téléchargeable en pratique (cf. support-ticket-attachment-
// download-url, qui exige status='clean').

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY      = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const BUCKET = 'support-ticket-attachments';

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
      .select('id, storage_path, size_bytes, status, uploaded_by')
      .eq('id', attachment_id).maybeSingle();
    if (!attachment) return json({ error: 'Pièce jointe introuvable' }, 404);
    if (attachment.uploaded_by !== user.id) return json({ error: 'Accès refusé : vous n\'êtes pas l\'auteur de cet upload' }, 403);
    if (attachment.status !== 'pending_upload') {
      return json({ error: `Confirmation impossible : statut actuel '${attachment.status}' (attendu 'pending_upload')` }, 400);
    }

    const dir = attachment.storage_path.split('/').slice(0, -1).join('/');
    const base = attachment.storage_path.split('/').pop() as string;
    const { data: listing, error: listErr } = await admin.storage.from(BUCKET).list(dir, { search: base });
    const found = listing?.find(f => f.name === base);
    if (listErr || !found) {
      return json({ error: 'Fichier introuvable dans le stockage : l\'upload a-t-il abouti ?' }, 400);
    }
    const actualSize = (found.metadata as Record<string, unknown> | null)?.size;
    if (typeof actualSize === 'number' && actualSize !== attachment.size_bytes) {
      return json({ error: `Taille de fichier incohérente (annoncée ${attachment.size_bytes}, réelle ${actualSize})` }, 400);
    }

    const { error: updErr } = await admin.from('support_ticket_attachments')
      .update({ status: 'scan_pending', confirmed_at: new Date().toISOString() })
      .eq('id', attachment_id).eq('status', 'pending_upload');
    if (updErr) return json({ error: `Confirmation impossible : ${updErr.message}` }, 500);

    return json({ ok: true, status: 'scan_pending' });
  } catch (e) {
    return json({ error: `Erreur serveur : ${e instanceof Error ? e.message : String(e)}` }, 500);
  }
});
