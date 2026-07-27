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
  archived_at?: string | null;
  geofence_radius_override_meters?: number | null;
  active_from_minute?: number | null;
  active_to_minute?: number | null;
  legacy: boolean;
};

// deno-lint-ignore no-explicit-any
async function resolveTerminal(admin: any, token: string): Promise<TerminalRow | null> {
  const { data: term } = await admin.from('pointage_terminals')
    .select('id,hotel_id,name,is_active,archived_at,geofence_radius_override_meters,active_from_minute,active_to_minute')
    .eq('token', token)
    .maybeSingle();
  if (term && term.is_active && !term.archived_at) return { ...term, legacy: false } as TerminalRow;
  if (term) return null; // désactivé ou archivé : refuser explicitement

  // Fallback legacy pour la fenêtre de compatibilité (voir migration 63,
  // TODO daté). NE PEUT PAS créer de nouveaux tokens ici, seulement en lire.
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
    name: 'Terminal historique (legacy)',
    is_active: true,
    legacy: true,
  };
}

/** Renvoie la minute locale (0-1439) d'un timestamp dans un fuseau donné. */
function localMinuteInZone(when: Date, timezone: string): number {
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone, hour: '2-digit', minute: '2-digit', hour12: false,
  });
  const parts = fmt.formatToParts(when);
  const h = parseInt(parts.find(p=>p.type==='hour')?.value  || '0', 10);
  const m = parseInt(parts.find(p=>p.type==='minute')?.value|| '0', 10);
  return h*60 + m;
}

/** Vérifie que le terminal accepte les scans à cette minute (plage optionnelle). */
function isWithinActiveWindow(t: TerminalRow, hotelTimezone: string): boolean {
  const from = t.active_from_minute, to = t.active_to_minute;
  if (from == null && to == null) return true;
  if (from == null || to == null) return true;   // config partielle → ignorée
  const nowMin = localMinuteInZone(new Date(), hotelTimezone || 'Europe/Paris');
  if (from <= to) return nowMin >= from && nowMin <= to;
  return nowMin >= from || nowMin <= to;         // plage traversant minuit
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });

  try {
    const authHdr = req.headers.get('Authorization');
    if (!authHdr) return json({ error: 'Non authentifié', code:'AUTH_MISSING' }, 401);

    const body = await req.json().catch(() => ({}));
    const { qr_token, gps_lat, gps_lng, gps_accuracy, device_info } = body || {};
    const idempotencyKey: string | null =
      (req.headers.get('Idempotency-Key') || body?.idempotency_key || '').toString().slice(0, 128) || null;

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
      .select('id,hotel_id,first_name,last_name,portal_enabled,active')
      .eq('portal_auth_id', user.id)
      .maybeSingle();
    if (!emp)                return json({ error: 'Employé introuvable', code: 'EMP_NOT_FOUND' }, 403);
    if (!emp.portal_enabled) return json({ error: 'Accès portail désactivé', code: 'PORTAL_DISABLED' }, 403);
    if (!emp.active)         return json({ error: 'Compte salarié désactivé', code: 'EMP_INACTIVE' }, 403);

    // 3. Résoudre le TERMINAL
    const terminal = await resolveTerminal(admin, token);
    if (!terminal)
      return json({ error: 'QR Code invalide, désactivé ou archivé. Demandez à votre responsable.', code: 'INVALID_TERMINAL' }, 400);

    const targetHotelId = terminal.hotel_id;

    // 4. Config hôtel cible (fuseau + géofence)
    const { data: hotel } = await admin.from('hotels')
      .select('name,timezone,latitude,longitude,geofence_radius_meters,qr_clocking_enabled')
      .eq('id', targetHotelId).single();

    if (!hotel?.qr_clocking_enabled)
      return json({ error: 'Le pointage QR est désactivé pour cet hôtel', code: 'QR_DISABLED' }, 400);

    // 5. Plage horaire du terminal (optionnelle)
    if (!isWithinActiveWindow(terminal, hotel.timezone || 'Europe/Paris')) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: targetHotelId, employee_id: emp.id, anomaly_type: 'outside_time_window',
        details: { terminal_id: terminal.id, from: terminal.active_from_minute, to: terminal.active_to_minute },
      }).then(null, () => {});
      return json({ error: 'Ce terminal n\'accepte pas les scans à cette heure.', code: 'OUTSIDE_TIME_WINDOW' }, 400);
    }

    // 6. AUTORISATION STRICTE — critères actuels uniquement, jamais l'historique.
    //    Règle documentée dans sql/63_pointage_terminals_hardening.sql fn 9.
    const localDayResult = await admin.rpc('pl_hotel_local_day', { p_hotel: targetHotelId });
    const localDay: string = localDayResult.data as string;

    const { data: canClock, error: canErr } = await admin.rpc('employee_can_clock_at', {
      p_employee: emp.id, p_hotel: targetHotelId, p_day: localDay,
    });
    if (canErr) return json({ error: 'Contrôle d\'autorisation en erreur: '+canErr.message, code:'AUTH_CHECK_FAILED' }, 500);
    if (!canClock) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: targetHotelId, employee_id: emp.id, anomaly_type: 'wrong_hotel',
        details: { employee_hotel: emp.hotel_id, terminal_hotel: targetHotelId, terminal_id: terminal.id, ip, device_info },
      }).then(null, () => {});
      return json({
        error: "Vous n'êtes pas autorisé à pointer dans cet hôtel aujourd'hui. Aucune affectation active, aucun shift planifié, aucune activation Extra en cours.",
        code: 'WRONG_HOTEL',
      }, 403);
    }

    // 7. Validation GPS (obligatoire si hôtel géolocalisé). Le rayon par
    //    terminal (geofence_radius_override_meters) l'emporte sur l'hôtel.
    const anomalies: string[] = [];
    let distanceMeters: number | null = null;

    if (hotel.latitude != null && hotel.longitude != null) {
      if (gps_lat == null || gps_lng == null)
        return json({ error: 'Géolocalisation requise. Autorisez l\'accès à votre position.', code: 'GPS_REQUIRED' }, 400);

      distanceMeters = Math.round(haversine(gps_lat, gps_lng, hotel.latitude, hotel.longitude));
      const radius = terminal.geofence_radius_override_meters ?? hotel.geofence_radius_meters ?? 150;

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

    // 8. Enregistrement ATOMIQUE via RPC (advisory lock + unique partiel +
    //    idempotency table). Résiste au double-clic, deux onglets, retry
    //    réseau, deux terminaux scannés simultanément, poste de nuit.
    const auditPayload = {
      gps_lat: gps_lat ?? null,
      gps_lng: gps_lng ?? null,
      gps_accuracy: gps_accuracy ?? null,
      distance_meters: distanceMeters,
      device_info: device_info ?? null,
      ip_address: ip,
      clock_status: anomalies.length > 0 ? 'suspicious' : 'valid',
      anomaly_flags: anomalies.length > 0 ? anomalies : null,
    };

    const { data: rec, error: recErr } = await admin.rpc('record_clocking', {
      p_employee_id:     emp.id,
      p_hotel_id:        targetHotelId,
      p_terminal_id:     terminal.legacy ? null : terminal.id,
      p_source:          'qr',
      p_idempotency_key: idempotencyKey,
      p_audit:           auditPayload,
    });
    if (recErr) return json({ error: 'Erreur enregistrement : ' + recErr.message, code:'RECORD_FAILED' }, 500);

    // 9. Journaliser les anomalies avec référence au pointage
    for (const anom of anomalies) {
      await admin.from('time_clock_anomalies').insert({
        hotel_id: targetHotelId, employee_id: emp.id, clocking_id: rec?.id,
        anomaly_type: anom,
        details: { distance_meters: distanceMeters, gps_accuracy, ip, device_info, terminal_id: terminal.id },
      }).then(null, () => {});
    }

    const labels: Record<string, string> = {
      clock_in:  'Entrée enregistrée ✓',
      clock_out: 'Sortie enregistrée ✓',
    };

    return json({
      success: true,
      action: rec?.action ?? 'clock_in',
      message: labels[rec?.action ?? 'clock_in'],
      timestamp: new Date().toISOString(),
      employee_name: `${emp.first_name} ${emp.last_name}`,
      hotel_id: targetHotelId,
      hotel_name: hotel?.name,
      terminal_id: terminal.legacy ? null : terminal.id,
      terminal_name: terminal.name,
      terminal_legacy: terminal.legacy || false,
      distance_meters: distanceMeters,
      anomalies,
      clocking_id: rec?.id,
      day: rec?.day,
      idempotent: !!rec?.idempotent,
    });

  } catch (e) {
    console.error('clock-portal fatal:', e);
    return json({ error: String(e), code:'FATAL' }, 500);
  }
});
