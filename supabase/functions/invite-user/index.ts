import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const REDIRECT_MANAGER = 'https://rh.flowtym.com/auth/callback';
const REDIRECT_SALARIE  = 'https://rh.flowtym.com/salarie/auth/callback';

const ALLOWED = [
  'http://localhost','http://localhost:3000','http://localhost:5173',
  'https://flowtym.com','https://app.flowtym.com','https://rh.flowtym.com',
  'https://hzrzkvdebaadditvbqis.supabase.co',
];
const cors = (o: string|null) => ({
  'Access-Control-Allow-Origin': (o && ALLOWED.some(a=>o.startsWith(a))) ? o : ALLOWED[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
});

const VALID_ROLES = ['direction','admin_hotel','comptabilite','revenue_manager',
  'reception','gouvernante','maintenance','breakfast','femme_de_chambre'];

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s=200) =>
    new Response(JSON.stringify(b), { status:s, headers:{...h,'Content-Type':'application/json'} });

  try {
    const { email, full_name, role, hotel_id, access_type = 'manager' } = await req.json();

    if (!email || !role || !hotel_id) return json({error:'email, role et hotel_id sont requis'},400);
    if (!VALID_ROLES.includes(role))  return json({error:`Rôle inconnu : ${role}`},400);
    if (!['manager','salarie'].includes(access_type)) return json({error:'access_type invalide'},400);

    // --- Authentifier l'appelant ---
    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({error:'Non authentifié'},401);

    const anon = createClient(SUPABASE_URL, ANON_KEY, { global:{headers:{Authorization:authHdr}} });
    const { data:{user}, error:authErr } = await anon.auth.getUser();
    if (authErr || !user) return json({error:'Token invalide'},401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // --- Vérifier que l'appelant est direction/admin_hotel sur cet hôtel ---
    const { data: cu } = await admin.from('users').select('id').eq('auth_id',user.id).maybeSingle();
    if (!cu) return json({error:'Profil appelant introuvable'},403);

    const { data: ch } = await admin.from('user_hotels').select('role')
      .eq('hotel_id',hotel_id).eq('user_id',cu.id).maybeSingle();
    if (!ch || !['direction','admin_hotel'].includes(ch.role))
      return json({error:'Droits direction ou admin_hotel requis pour cet hôtel'},403);

    // --- Déterminer le redirectTo selon le type d'accès ---
    const redirectTo = access_type === 'salarie' ? REDIRECT_SALARIE : REDIRECT_MANAGER;

    // --- Chercher si l'utilisateur existe déjà dans Auth ---
    const { data: listData } = await admin.auth.admin.listUsers();
    const existing = (listData?.users ?? []).find((u: {email?:string;id:string}) =>
      (u.email ?? '').toLowerCase() === email.toLowerCase());

    let targetAuthId: string|null = null;
    let alreadyExisted = false;
    let magicLinkSent  = false;

    if (existing) {
      // Utilisateur existant : juste mettre à jour l'accès, envoyer un magic link
      alreadyExisted = true;
      targetAuthId = existing.id;

      const { error: mlErr } = await admin.auth.admin.generateLink({
        type: 'magiclink',
        email,
        options: { redirectTo },
      });
      magicLinkSent = !mlErr;

    } else {
      // Nouvel utilisateur : inviter par e-mail (l'utilisateur définit son mdp)
      const { data: inv, error: invErr } = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo,
        data: {
          full_name: full_name || '',
          invited_hotel_id: hotel_id,
          invited_role: role,
          access_type,
        },
      });

      if (invErr) return json({error:'Erreur envoi invitation : '+invErr.message},500);
      targetAuthId = inv?.user?.id ?? null;
    }

    if (!targetAuthId) return json({error:"Impossible de retrouver l'utilisateur Auth"},500);

    // --- Upsert atomique public.users + user_hotels ---
    const { data: userId, error: rpcErr } = await admin.rpc('rh_grant_hotel_access', {
      p_auth_id:   targetAuthId,
      p_email:     email,
      p_full_name: full_name || '',
      p_hotel_id:  hotel_id,
      p_role:      role,
    });
    if (rpcErr) return json({error:'Erreur base de données : '+rpcErr.message},500);

    // --- Pour le portail salarié : lier le compte Auth à la fiche employé ---
    if (access_type === 'salarie') {
      await admin.from('employees')
        .update({ portal_auth_id: targetAuthId, portal_enabled: true })
        .eq('email', email)
        .eq('hotel_id', hotel_id);
    }

    // --- Audit log (best-effort) ---
    try {
      await admin.rpc('gen_audit_log_invite', {
        p_hotel_id:    hotel_id,
        p_actor_id:    cu.id,
        p_actor_email: user.email,
        p_entity_id:   userId,
        p_details:     JSON.stringify({ email, role, access_type, already_existed: alreadyExisted }),
      });
    } catch(_) {
      // Fallback direct insert si la RPC n'existe pas
      try {
        await admin.from('hr_document_audit_logs').insert({
          id:            crypto.randomUUID(),
          hotel_id,
          actor_user_id: cu.id,
          actor_email:   user.email,
          action:        'invite_user',
          entity_type:   'user',
          entity_id:     userId ?? undefined,
          details:       { email, role, access_type, already_existed: alreadyExisted },
        });
      } catch(_2) {}
    }

    return json({
      success: true,
      user_id: userId,
      already_existed: alreadyExisted,
      magic_link_sent: magicLinkSent,
    });

  } catch(e) {
    console.error('invite-user fatal:', e);
    return json({error: String(e)}, 500);
  }
});
