import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

/** Distance Haversine en mètres entre deux points GPS */
function haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const φ1 = lat1 * Math.PI / 180, φ2 = lat2 * Math.PI / 180;
  const Δφ = (lat2 - lat1) * Math.PI / 180, Δλ = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(Δφ/2)**2 + Math.cos(φ1)*Math.cos(φ2)*Math.sin(Δλ/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}

const ALLOWED = [
  'https://rh.flowtym.com','https://flowtym.com',
  'http://localhost','http://localhost:3000','http://localhost:5173',
  'https://hzrzkvdebaadditvbqis.supabase.co',
  'https://flowtym-rh.vercel.app',
  'https://flowtym-rh-git-main-walis-projects-e22749ce.vercel.app',
];
const cors = (o: string|null) => {
  const allowed = o && (
    ALLOWED.some(a => o.startsWith(a)) ||
    /^https:\/\/flowtym-[a-z0-9]+-walis-projects-e22749ce\.vercel\.app$/.test(o)
  ) ? o : ALLOWED[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
};

/** Extrait le token brut du contenu QR (URL avec ?token= ou chaîne brute). */
function extractToken(raw: string): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  try {
    const u = new URL(trimmed);
    const t = u.searchParams.get('token');
    if (t) return t.trim();
  } catch (_) { /* pas une URL */ }
  return trimmed || null;
}

type TerminalRow = {
  id: string;
  hotel_id: string;
  name: string | null;
  is_active: boolean;
  legacy: boolean;
};

/** Résout un token contre pointage_terminals (nouveau), puis hotel_qr_tokens (legacy). */
async function resolveTerminal(admin: ReturnType<typeof createClient>, token: string): Promise<TerminalRow | null> {
  const { data: term } = await admin.from('pointage_terminals')
    .select('id,hotel_id,name,is_active')
    .eq('token', token)
    .eq('is_active', true)
    .maybeSingle();
  if (term) return { ...term, legacy: false } as TerminalRow;

  // Fallback rétrocompatibilité : ancien QR par hôtel
  const { data: legacy } = await admin.from('hotel_qr_tokens')
    .select('id,hotel_id,is_active,expires_at')
    .eq('token', token)
    .eq('is_active', true)
    .maybeSingle();
  if (!legacy) return null;
  if (legacy.expires_at && new Date(legacy.expires_at) < new Date()) return null;

  return {
    id: legacy.id,
    hotel_id: legacy.hotel_id,
    name: 'Terminal historique',
    is_active: true,
    legacy: true,
  };
}

/** Vrai si l'employé est autorisé à pointer dans cet hôtel (principal ou secondaire). */
async function employeeCanClockAt(
  admin: ReturnType<typeof createClient>,
  employeeId: string,
  primaryHotelId: string,
  targetHotelId: string,
): Promise<boolean> {
  if (primaryHotelId === targetHotelId) return true;
  // Un salarié multi-hôtel peut être planifié dans un hôtel secondaire :
  // on considère qu'un shift ou un pointage récent dans l'hôtel cible vaut autorisation.
  const { data: shift } = await admin.from('staff_planning')
    .select('id')
    .eq('employee_id', employeeId)
    .eq('hotel_id', targetHotelId)
    .limit(1)
    .maybeSingle();
  if (shift) return true;
  const { data: prev } = await admin.from('staff_clockings')
    .select('id')
    .eq('employee_id', employeeId)
    .eq('hotel_id', targetHotelId)
    .limit(1)
    .maybeSingle();
  return !!prev;
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });

  try {
    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({ error: 'Non authentifié' }, 401);

    const body = await req.json();
    const { qr_token, gps_lat, gps_lng, gps_accuracy, device_info } = body;
    const token = extractToken(String(qr_token || ''));
    if (!token) return json({ error: 'qr_token requis', code: 'MISSING_TOKEN' }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const anon  = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHdr } } });
    const ip    = req.headers.get('x-forwarded-for')?.split(',')[0].trim()
               || req.headers.get('cf-connecting-ip')
               || 'unknown';

    // 1. Vérifier la session salarié
    const { data: { user }, error: authErr } = await anon.auth.getUser();
    if (authErr || !user) return json({ error: 'Session invalide', code: 'AUTH_INVALID' }, 401);

    // 2. Récupérer l'employé par portal_auth_id
    const { data: emp } = await admin.from('employees')
      .select('id,hotel_id,first_name,last_name,portal_enabled')
      .eq('portal_auth_id', user.id)
      .maybeSingle();
    if (!emp)                return json({ error: 'Employé introuvable', code: 'EMP_NOT_FOUND' }, 403);
    if (!emp.portal_enabled) return json({ error: 'Accès portail désactivé', code: 'PORTAL_DISABLED' }, 403);

    // 3. Résoudre le TERMINAL (nouveau modèle) ou l'ancien token hotel
    const terminal = await resolveTerminal(admin, token);
    if (!terminal)
      return json({ error: 'QR Code invalide ou désactivé. Demandez à votre responsable de vérifier le terminal.', code: 'INVALID_TERMINAL' }, 400);

    const targetHotelId = terminal.hotel_id;

    // 4. L'employé doit être autorisé à pointer dans l'hôtel du terminal.
    //    Compatible multi-hôtels (planning ou historique de pointage).
    const allowed = await employeeCanClockAt(admin, emp.id, emp.hotel_id, targetHotelId);
    if (!allowed) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: targetHotelId, employee_id: emp.id, anomaly_type: 'wrong_hotel',
        details: { employee_hotel: emp.hotel_id, terminal_hotel: targetHotelId, terminal_id: terminal.id, ip, device_info },
      }).then(null, () => {});
      return json({
        error: "Vous n'êtes pas autorisé à pointer dans cet hôtel. Contactez votre responsable.",
        code: 'WRONG_HOTEL',
      }, 403);
    }

    // 5. Config hôtel cible
    const { data: hotel } = await admin.from('hotels')
      .select('name,latitude,longitude,geofence_radius_meters,qr_clocking_enabled')
      .eq('id', targetHotelId).single();

    if (!hotel?.qr_clocking_enabled)
      return json({ error: 'Le pointage QR est désactivé pour cet hôtel', code: 'QR_DISABLED' }, 400);

    const anomalies: string[] = [];
    let distanceMeters: number | null = null;

    // 6. Validation GPS (obligatoire si hôtel géolocalisé)
    if (hotel.latitude != null && hotel.longitude != null) {
      if (gps_lat == null || gps_lng == null)
        return json({ error: 'Géolocalisation requise. Autorisez l\'accès à votre position.', code: 'GPS_REQUIRED' }, 400);

      distanceMeters = Math.round(haversine(gps_lat, gps_lng, hotel.latitude, hotel.longitude));
      const radius = hotel.geofence_radius_meters ?? 150;

      if (distanceMeters > radius) {
        await admin.from('time_clock_anomalies').insert({
          hotel_id: targetHotelId, employee_id: emp.id, anomaly_type: 'gps_too_far',
          details: { distance_meters: distanceMeters, radius, gps_lat, gps_lng, gps_accuracy, ip, device_info, terminal_id: terminal.id },
        }).then(null, () => {});
        return json({
          error: `Vous êtes à ${distanceMeters}m de l'hôtel (limite : ${radius}m). Pointage impossible.`,
          code: 'GPS_TOO_FAR', distance_meters: distanceMeters, max_meters: radius,
        }, 400);
      }
      if (gps_accuracy != null && gps_accuracy > 100) anomalies.push('gps_imprecise');
    }

    // 7. Déterminer l'action (auto) sur l'hôtel du terminal
    const today = new Date().toISOString().slice(0, 10);
    const { data: rows } = await admin.from('staff_clockings')
      .select('id,clock_in_ts,clock_out_ts')
      .eq('employee_id', emp.id).eq('hotel_id', targetHotelId).eq('day', today)
      .order('clock_in_ts', { ascending: false });

    const todayRows = rows || [];
    const openShift = todayRows.find(r => !r.clock_out_ts);
    const action = openShift ? 'clock_out' : 'clock_in';

    // Détecter double pointage (dernier pointage il y a moins de 3 minutes)
    if (action === 'clock_in' && todayRows.length > 0 && todayRows[0]?.clock_out_ts) {
      const gap = Date.now() - new Date(todayRows[0].clock_out_ts).getTime();
      if (gap < 3 * 60 * 1000) anomalies.push('double_clocking');
    }

    const now   = new Date().toISOString();
    const status = anomalies.length > 0 ? 'suspicious' : 'valid';

    const auditFields: Record<string, unknown> = {
      gps_lat, gps_lng, gps_accuracy,
      distance_meters: distanceMeters,
      device_info, ip_address: ip,
      clock_status: status,
      anomaly_flags: anomalies.length > 0 ? anomalies : null,
    };
    // Nouveau modèle : on stocke l'id du terminal.
    // Legacy : on conserve qr_token_id pour ne pas casser les rapports existants.
    if (terminal.legacy) auditFields.qr_token_id = terminal.id;
    else                 auditFields.terminal_id  = terminal.id;

    // 8. Enregistrer le pointage
    let clockingId: string | null = null;

    if (action === 'clock_in') {
      const { data: newClock, error: insErr } = await admin.from('staff_clockings').insert({
        hotel_id: targetHotelId, employee_id: emp.id,
        day: today, clock_in_ts: now, source: 'qr', ...auditFields,
      }).select('id').single();
      if (insErr) return json({ error: 'Erreur enregistrement : ' + insErr.message }, 500);
      clockingId = newClock?.id ?? null;
    } else {
      const { error: updErr } = await admin.from('staff_clockings').update({
        clock_out_ts: now, ...auditFields,
      }).eq('id', openShift!.id);
      if (updErr) return json({ error: 'Erreur enregistrement : ' + updErr.message }, 500);
      clockingId = openShift!.id;
    }

    // 9. Journaliser les anomalies restantes avec référence au pointage
    for (const anom of anomalies) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: targetHotelId, employee_id: emp.id, clocking_id: clockingId,
        anomaly_type: anom,
        details: { distance_meters: distanceMeters, gps_accuracy, ip, device_info, terminal_id: terminal.id },
      }).then(null, () => {});
    }

    const labels: Record<string, string> = { clock_in: 'Entrée enregistrée ✓', clock_out: 'Sortie enregistrée ✓' };

    return json({
      success: true,
      action,
      message: labels[action],
      timestamp: now,
      employee_name: `${emp.first_name} ${emp.last_name}`,
      hotel_id: targetHotelId,
      hotel_name: hotel?.name,
      terminal_id: terminal.legacy ? null : terminal.id,
      terminal_name: terminal.name,
      distance_meters: distanceMeters,
      anomalies,
      clocking_id: clockingId,
    });

  } catch (e) {
    console.error('clock-portal fatal:', e);
    return json({ error: String(e) }, 500);
  }
});
