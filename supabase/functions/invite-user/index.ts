import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

const ALLOWED_ORIGINS = [
  'http://localhost','http://localhost:3000','http://localhost:5173',
  'https://flowtym.com','https://app.flowtym.com','https://rh.flowtym.com',
  'https://hzrzkvdebaadditvbqis.supabase.co',
];

function cors(origin: string | null) {
  const ok = origin && ALLOWED_ORIGINS.some(o => origin.startsWith(o));
  return {
    'Access-Control-Allow-Origin': ok ? origin! : '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

const VALID_ROLES = [
  'direction','admin_hotel','comptabilite','revenue_manager',
  'reception','gouvernante','maintenance','breakfast','femme_de_chambre',
];

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin');
  const h = cors(origin);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...h, 'Content-Type': 'application/json' } });

  try {
    const { email, full_name, role, hotel_id } = await req.json();
    if (!email || !role || !hotel_id) return json({ error: 'email, role et hotel_id sont requis' }, 400);
    if (!VALID_ROLES.includes(role)) return json({ error: `Role inconnu: ${role}` }, 400);

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Non authentifie' }, 401);

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return json({ error: 'Token invalide' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Vérifier que l'appelant est direction/admin pour cet hôtel
    const { data: callerUser } = await admin.from('users').select('id').eq('auth_id', user.id).maybeSingle();
    if (!callerUser) return json({ error: 'Utilisateur introuvable' }, 403);

    const { data: callerHotel } = await admin.from('user_hotels').select('role')
      .eq('hotel_id', hotel_id).eq('user_id', callerUser.id).maybeSingle();
    if (!callerHotel || !['direction','admin_hotel'].includes(callerHotel.role))
      return json({ error: 'Acces refuse: droits direction ou admin_hotel requis' }, 403);

    // Inviter ou retrouver l'utilisateur Auth
    let targetAuthId: string | null = null;
    const { data: inviteData, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { full_name: full_name || '', invited_hotel_id: hotel_id, invited_role: role },
    });
    if (inviteErr) {
      const msg = inviteErr.message || '';
      if (!msg.includes('already') && !msg.includes('email_exists')) {
        return json({ error: msg }, 400);
      }
      // Email déjà enregistré — trouver l'auth_id
      const { data: listData } = await admin.auth.admin.listUsers();
      const found = (listData?.users ?? []).find((u: { email?: string; id: string }) =>
        (u.email ?? '').toLowerCase() === email.toLowerCase()
      );
      if (found) targetAuthId = found.id;
    } else {
      targetAuthId = inviteData?.user?.id ?? null;
    }

    // Trouver ou créer le profil dans public.users
    // La table users a: id, auth_id, hotel_id (NOT NULL), email, full_name, role (NOT NULL)
    let targetUserId: string | null = null;

    const { data: byEmail } = await admin.from('users').select('id').eq('email', email).maybeSingle();
    if (byEmail) {
      targetUserId = byEmail.id;
    } else if (targetAuthId) {
      const { data: byAuth } = await admin.from('users').select('id').eq('auth_id', targetAuthId).maybeSingle();
      if (byAuth) {
        targetUserId = byAuth.id;
      } else {
        // Créer le profil avec hotel_id et role (colonnes NOT NULL)
        const { data: created, error: insErr } = await admin.from('users')
          .insert({ auth_id: targetAuthId, email, full_name: full_name || email, hotel_id, role })
          .select('id').single();
        if (insErr) {
          console.error('Insert user error:', insErr);
          return json({ error: 'Erreur creation profil: ' + insErr.message }, 500);
        }
        if (created) targetUserId = created.id;
      }
    }

    if (!targetUserId) return json({ error: 'Impossible de creer le profil utilisateur (auth_id introuvable)' }, 500);

    // Accorder l'accès à l'hôtel (upsert dans user_hotels)
    const { error: grantErr } = await admin.from('user_hotels')
      .upsert({ hotel_id, user_id: targetUserId, role }, { onConflict: 'hotel_id,user_id' });
    if (grantErr) return json({ error: 'Erreur acces hotel: ' + grantErr.message }, 500);

    // Audit log (best effort)
    await admin.from('hr_document_audit_logs').insert({
      hotel_id, actor_user_id: callerUser.id, actor_email: user.email,
      action: 'invite_user', entity_type: 'user', entity_id: targetUserId,
      details: { email, role },
    }).maybeSingle().catch(() => {});

    return json({ success: true, user_id: targetUserId });

  } catch (e) {
    console.error('invite-user error:', e);
    return json({ error: String(e) }, 500);
  }
});
