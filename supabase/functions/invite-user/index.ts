import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const ALLOWED = [
  'http://localhost','http://localhost:3000','http://localhost:5173',
  'https://flowtym.com','https://app.flowtym.com','https://rh.flowtym.com',
  'https://hzrzkvdebaadditvbqis.supabase.co',
];
const cors = (o: string|null) => ({
  'Access-Control-Allow-Origin': (o && ALLOWED.some(a=>o.startsWith(a))) ? o : '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
});

const VALID_ROLES = ['direction','admin_hotel','comptabilite','revenue_manager',
  'reception','gouvernante','maintenance','breakfast','femme_de_chambre'];

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s=200) => new Response(JSON.stringify(b),{status:s,headers:{...h,'Content-Type':'application/json'}});

  try {
    const { email, full_name, role, hotel_id, password } = await req.json();
    if (!email || !role || !hotel_id) return json({error:'email, role et hotel_id sont requis'},400);
    if (!VALID_ROLES.includes(role)) return json({error:`Role inconnu: ${role}`},400);
    if (!password || password.length < 6) return json({error:'Mot de passe requis (6 caractères minimum)'},400);

    // Vérifier le JWT de l'appelant
    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({error:'Non authentifie'},401);
    const anon = createClient(SUPABASE_URL, ANON_KEY, {global:{headers:{Authorization:authHdr}}});
    const { data:{user}, error:authErr } = await anon.auth.getUser();
    if (authErr || !user) return json({error:'Token invalide'},401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Vérifier que l'appelant est direction ou admin_hotel pour cet hôtel
    const { data: cu } = await admin.from('users').select('id').eq('auth_id',user.id).maybeSingle();
    if (!cu) return json({error:'Profil appelant introuvable'},403);
    const { data: ch } = await admin.from('user_hotels').select('role')
      .eq('hotel_id',hotel_id).eq('user_id',cu.id).maybeSingle();
    if (!ch || !['direction','admin_hotel'].includes(ch.role))
      return json({error:'Droits direction ou admin_hotel requis'},403);

    let targetAuthId: string|null = null;
    let alreadyExisted = false;

    // Chercher si l'utilisateur existe déjà dans auth
    const { data: list } = await admin.auth.admin.listUsers();
    const existing = (list?.users ?? []).find((u: {email?:string;id:string}) =>
      (u.email ?? '').toLowerCase() === email.toLowerCase());

    if (existing) {
      // Mettre à jour le mot de passe de l'utilisateur existant
      alreadyExisted = true;
      targetAuthId = existing.id;
      const { error: updErr } = await admin.auth.admin.updateUserById(existing.id, {
        password,
        email_confirm: true,
      });
      if (updErr) return json({error:'Erreur mise à jour mot de passe: '+updErr.message},500);
    } else {
      // Créer un nouvel utilisateur avec email + mot de passe
      const { data: newUser, error: createErr } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true, // pas besoin de vérification email
        user_metadata: { full_name: full_name||'', invited_hotel_id: hotel_id, invited_role: role },
      });
      if (createErr) return json({error:'Erreur création compte: '+createErr.message},500);
      targetAuthId = newUser?.user?.id ?? null;
    }

    if (!targetAuthId) return json({error:"Impossible de créer ou retrouver le compte"},500);

    // Upsert atomique dans public.users + user_hotels
    const { data: userId, error: rpcErr } = await admin.rpc('rh_grant_hotel_access', {
      p_auth_id:   targetAuthId,
      p_email:     email,
      p_full_name: full_name||'',
      p_hotel_id:  hotel_id,
      p_role:      role,
    });
    if (rpcErr) return json({error:'Erreur base de donnees: '+rpcErr.message},500);

    await admin.from('hr_document_audit_logs').insert({
      hotel_id, actor_user_id: cu.id, actor_email: user.email,
      action:'create_user_access', entity_type:'user', entity_id: userId,
      details:{email, role, already_existed: alreadyExisted},
    }).maybeSingle().catch(()=>{});

    return json({ success:true, user_id: userId, already_existed: alreadyExisted });

  } catch(e) {
    console.error('invite-user fatal:', e);
    return json({error:String(e)},500);
  }
});
