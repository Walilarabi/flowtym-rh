/**
 * Edge Function : invite-user
 * Invites a user to the app and grants them access to a hotel.
 *
 * POST body: { email, full_name, role, hotel_id }
 *
 * Security:
 *  - Caller must be authenticated and have role 'direction' or 'admin_hotel' for hotel_id
 *  - Uses service_role key server-side to call auth.admin.inviteUserByEmail
 *  - No service_role key is ever exposed to the frontend
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getCorsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY      = Deno.env.get('SUPABASE_ANON_KEY')!;

const VALID_ROLES = [
  'direction','admin_hotel','comptabilite','revenue_manager',
  'reception','gouvernante','maintenance','breakfast','femme_de_chambre',
];

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin');
  const cors = getCorsHeaders(origin);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors });
  }

  const j = (body: unknown, status = 200) => makeJson(cors, body, status);

  try {
    // 1. Parse body
    const { email, full_name, role, hotel_id } = await req.json();
    if (!email || !role || !hotel_id) {
      return j({ error: 'email, role et hotel_id sont requis' }, 400);
    }
    if (!VALID_ROLES.includes(role)) {
      return j({ error: `Rôle inconnu : ${role}` }, 400);
    }

    // 2. Identify caller from JWT
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return j({ error: 'Non authentifié' }, 401);

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return j({ error: 'Token invalide' }, 401);

    // 3. Check caller is admin/direction for this hotel (via service client to bypass RLS)
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: callerUser } = await admin
      .from('users')
      .select('id')
      .eq('auth_id', user.id)
      .maybeSingle();
    if (!callerUser) return j({ error: 'Utilisateur introuvable' }, 403);

    const { data: callerHotel } = await admin
      .from('user_hotels')
      .select('role')
      .eq('hotel_id', hotel_id)
      .eq('user_id', callerUser.id)
      .maybeSingle();
    if (!callerHotel || !['direction','admin_hotel'].includes(callerHotel.role)) {
      return j({ error: 'Accès refusé : droits administrateur requis pour cet hôtel' }, 403);
    }

    // 4. Invite via auth.admin
    const { data: inviteData, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(
      email,
      { data: { full_name: full_name || '', invited_hotel_id: hotel_id, invited_role: role } }
    );
    if (inviteErr) {
      // If already registered, just grant access
      if (!inviteErr.message.includes('already registered')) {
        return j({ error: inviteErr.message }, 400);
      }
    }

    // 5. Find or create user record in public.users
    let { data: targetUser } = await admin
      .from('users')
      .select('id')
      .eq('email', email)
      .maybeSingle();

    if (!targetUser && inviteData?.user) {
      const { data: nu } = await admin
        .from('users')
        .insert({ auth_id: inviteData.user.id, email, full_name: full_name || '' })
        .select('id')
        .single();
      targetUser = nu;
    }
    if (!targetUser) return j({ error: 'Impossible de créer le profil utilisateur' }, 500);

    // 6. Grant hotel access (upsert)
    const { error: grantErr } = await admin
      .from('user_hotels')
      .upsert({ hotel_id, user_id: targetUser.id, role }, { onConflict: 'hotel_id,user_id' });
    if (grantErr) return j({ error: grantErr.message }, 500);

    // 7. Audit log
    await admin.from('hr_document_audit_logs').insert({
      hotel_id,
      actor_user_id: callerUser.id,
      actor_email: user.email,
      action: 'invite_user',
      entity_type: 'user',
      entity_id: targetUser.id,
      details: { email, role },
    }).maybeSingle();

    return j({ success: true, user_id: targetUser.id });

  } catch (e) {
    return j({ error: String(e) }, 500);
  }
});

// cors is captured per-request in the outer handler scope
// For error responses before cors is set, fall back to deny-all
function makeJson(cors: Record<string, string>, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
