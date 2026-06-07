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
  // Vercel deployments (production alias + branch previews)
  'https://flowtym-rh-git-main-walis-projects-e22749ce.vercel.app',
  'https://flowtym-rh.vercel.app',
];
const cors = (o: string|null) => {
  const allowed = o && (
    ALLOWED.some(a => o.startsWith(a)) ||
    // Allow any flowtym Vercel preview deploy
    /^https:\/\/flowtym-[a-z0-9]+-walis-projects-e22749ce\.vercel\.app$/.test(o)
  ) ? o : ALLOWED[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
};

const VALID_ROLES = ['direction','admin_hotel','comptabilite','revenue_manager',
  'reception','gouvernante','maintenance','breakfast','femme_de_chambre'];

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s=200) =>
    new Response(JSON.stringify(b), { status:s, headers:{...h,'Content-Type':'application/json'} });

  try {
    const { email, full_name, role, hotel_id, access_type = 'manager', employee_id } = await req.json();

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
    const { data: listData } = await admin.auth.admin.listUsers({ perPage: 1000 });
    const existing = (listData?.users ?? []).find((u: {email?:string;id:string}) =>
      (u.email ?? '').toLowerCase() === email.toLowerCase());

    let targetAuthId: string|null = null;
    let alreadyExisted = false;
    let magicLinkSent  = false;

    if (existing) {
      alreadyExisted = true;
      targetAuthId = existing.id;

      const { error: mlErr } = await admin.auth.admin.generateLink({
        type: 'magiclink',
        email,
        options: { redirectTo },
      });
      magicLinkSent = !mlErr;

    } else {
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

    let userId: string|null = null;

    if (access_type === 'salarie') {
      // --- Portail salarié : lier le compte Auth à la fiche employé UNIQUEMENT ---
      // On NE crée PAS de user_hotels : le salarié ne doit pas avoir accès manager.
      // On identifie l'employé par employee_id (priorité) ou par email.
      const empPatch = { portal_auth_id: targetAuthId, portal_enabled: true, must_change_password: true };
      const empQuery = employee_id
        ? admin.from('employees').update(empPatch).eq('id', employee_id).eq('hotel_id', hotel_id)
        : admin.from('employees').update(empPatch).eq('email', email).eq('hotel_id', hotel_id);

      const { error: empErr } = await empQuery;
      if (empErr) console.error('employees portal link error:', empErr.message);

      userId = targetAuthId;

    } else {
      // --- Manager : upsert public.users + user_hotels ---
      const { data: uid, error: rpcErr } = await admin.rpc('rh_grant_hotel_access', {
        p_auth_id:   targetAuthId,
        p_email:     email,
        p_full_name: full_name || '',
        p_hotel_id:  hotel_id,
        p_role:      role,
      });
      if (rpcErr) return json({error:'Erreur base de données : '+rpcErr.message},500);
      userId = uid;
    }

    // --- Audit log (best-effort) ---
    try {
      await admin.from('hr_document_audit_logs').insert({
        hotel_id,
        actor_user_id: cu.id,
        actor_email:   user.email,
        action:        'invite_user',
        entity_type:   access_type === 'salarie' ? 'employee_portal' : 'user',
        details:       { email, role, access_type, already_existed: alreadyExisted },
      });
    } catch(_) {}

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
