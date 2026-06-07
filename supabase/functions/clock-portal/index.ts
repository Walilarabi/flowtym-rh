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
    if (!qr_token) return json({ error: 'qr_token requis' }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const anon  = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHdr } } });
    const ip    = req.headers.get('x-forwarded-for')?.split(',')[0].trim()
               || req.headers.get('cf-connecting-ip')
               || 'unknown';

    // 1. Vérifier la session salarié
    const { data: { user }, error: authErr } = await anon.auth.getUser();
    if (authErr || !user) return json({ error: 'Session invalide' }, 401);

    // 2. Récupérer l'employé par portal_auth_id
    const { data: emp } = await admin.from('employees')
      .select('id,hotel_id,first_name,last_name,portal_enabled')
      .eq('portal_auth_id', user.id)
      .maybeSingle();
    if (!emp)             return json({ error: 'Employé introuvable' }, 403);
    if (!emp.portal_enabled) return json({ error: 'Accès portail désactivé' }, 403);

    // 3. Valider le token QR
    const { data: tokenRow } = await admin.from('hotel_qr_tokens')
      .select('id,hotel_id,expires_at,is_active')
      .eq('token', qr_token)
      .eq('is_active', true)
      .maybeSingle();

    if (!tokenRow)
      return json({ error: 'QR Code invalide ou désactivé', code: 'INVALID_TOKEN' }, 400);
    if (tokenRow.expires_at && new Date(tokenRow.expires_at) < new Date())
      return json({ error: 'QR Code expiré — demandez à votre manager de le régénérer', code: 'EXPIRED_TOKEN' }, 400);

    // 4. L'employé doit appartenir à l'hôtel du QR
    if (emp.hotel_id !== tokenRow.hotel_id) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: tokenRow.hotel_id, employee_id: emp.id, anomaly_type: 'wrong_hotel',
        details: { employee_hotel: emp.hotel_id, token_hotel: tokenRow.hotel_id, ip, device_info },
      }).then(null, () => {});
      return json({ error: "Ce QR Code n'est pas celui de votre hôtel", code: 'WRONG_HOTEL' }, 403);
    }

    const hotelId = emp.hotel_id;

    // 5. Config hôtel
    const { data: hotel } = await admin.from('hotels')
      .select('name,latitude,longitude,geofence_radius_meters,qr_clocking_enabled')
      .eq('id', hotelId).single();

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
          hotel_id: hotelId, employee_id: emp.id, anomaly_type: 'gps_too_far',
          details: { distance_meters: distanceMeters, radius, gps_lat, gps_lng, gps_accuracy, ip, device_info },
        }).then(null, () => {});
        return json({
          error: `Vous êtes à ${distanceMeters}m de l'hôtel (limite : ${radius}m). Pointage impossible.`,
          code: 'GPS_TOO_FAR', distance_meters: distanceMeters, max_meters: radius,
        }, 400);
      }
      if (gps_accuracy != null && gps_accuracy > 100) anomalies.push('gps_imprecise');
    }

    // 7. Déterminer l'action (auto)
    const today = new Date().toISOString().slice(0, 10);
    const { data: rows } = await admin.from('staff_clockings')
      .select('id,clock_in_ts,clock_out_ts')
      .eq('employee_id', emp.id).eq('hotel_id', hotelId).eq('day', today)
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

    const auditFields = {
      gps_lat, gps_lng, gps_accuracy,
      distance_meters: distanceMeters,
      device_info, ip_address: ip,
      qr_token_id: tokenRow.id,
      clock_status: status,
      anomaly_flags: anomalies.length > 0 ? anomalies : null,
    };

    // 8. Enregistrer le pointage
    let clockingId: string | null = null;

    if (action === 'clock_in') {
      const { data: newClock, error: insErr } = await admin.from('staff_clockings').insert({
        hotel_id: hotelId, employee_id: emp.id,
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
        hotel_id: hotelId, employee_id: emp.id, clocking_id: clockingId,
        anomaly_type: anom,
        details: { distance_meters: distanceMeters, gps_accuracy, ip, device_info },
      }).then(null, () => {});
    }

    const labels: Record<string, string> = { clock_in: 'Entrée enregistrée ✓', clock_out: 'Sortie enregistrée ✓' };

    return json({
      success: true,
      action,
      message: labels[action],
      timestamp: now,
      employee_name: `${emp.first_name} ${emp.last_name}`,
      distance_meters: distanceMeters,
      anomalies,
      clocking_id: clockingId,
    });

  } catch (e) {
    console.error('clock-portal fatal:', e);
    return json({ error: String(e) }, 500);
  }
});
