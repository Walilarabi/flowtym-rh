import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SITE_URL     = Deno.env.get('SITE_URL') ?? 'https://rh.flowtym.com';

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
    const { email, full_name, role, hotel_id } = await req.json();
    if (!email || !role || !hotel_id) return json({error:'email, role et hotel_id sont requis'},400);
    if (!VALID_ROLES.includes(role)) return json({error:`Role inconnu: ${role}`},400);

    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({error:'Non authentifie'},401);
    const anon = createClient(SUPABASE_URL, ANON_KEY, {global:{headers:{Authorization:authHdr}}});
    const { data:{user}, error:authErr } = await anon.auth.getUser();
    if (authErr || !user) return json({error:'Token invalide'},401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: cu } = await admin.from('users').select('id').eq('auth_id',user.id).maybeSingle();
    if (!cu) return json({error:'Profil appelant introuvable'},403);
    const { data: ch } = await admin.from('user_hotels').select('role')
      .eq('hotel_id',hotel_id).eq('user_id',cu.id).maybeSingle();
    if (!ch || !['direction','admin_hotel'].includes(ch.role))
      return json({error:'Droits direction ou admin_hotel requis'},403);

    let targetAuthId: string|null = null;
    let alreadyExisted = false;
    let inviteLink: string|null = null;

    // generateLink creates user if needed AND returns the actual URL — no email dependency
    const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
      type: 'invite',
      email,
      options: {
        redirectTo: SITE_URL,
        data: { full_name: full_name||'', invited_hotel_id: hotel_id, invited_role: role },
      },
    });

    if (linkErr) {
      const msg = linkErr.message||'';
      if (!msg.toLowerCase().includes('already') && !msg.toLowerCase().includes('exists')) {
        return json({error: msg},400);
      }
      // User already exists — generate a magic link instead
      alreadyExisted = true;
      const { data: mlData, error: mlErr } = await admin.auth.admin.generateLink({
        type: 'magiclink',
        email,
        options: { redirectTo: SITE_URL },
      });
      if (!mlErr && mlData?.properties?.action_link) {
        inviteLink = mlData.properties.action_link;
      }
      // Find the existing auth user id
      const { data: list } = await admin.auth.admin.listUsers();
      const found = (list?.users??[]).find((u:{email?:string;id:string}) =>
        (u.email??'').toLowerCase()===email.toLowerCase());
      targetAuthId = found?.id ?? null;
    } else {
      targetAuthId = linkData?.user?.id ?? null;
      inviteLink = linkData?.properties?.action_link ?? null;
    }

    if (!targetAuthId) return json({error:"Impossible de retrouver l'utilisateur dans auth"},500);

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
      action:'invite_user', entity_type:'user', entity_id: userId,
      details:{email, role, already_existed: alreadyExisted},
    }).maybeSingle().catch(()=>{});

    return json({ success:true, user_id: userId, already_existed: alreadyExisted, invite_link: inviteLink });

  } catch(e) {
    console.error('invite-user fatal:', e);
    return json({error:String(e)},500);
  }
});
