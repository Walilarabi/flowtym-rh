'use strict';

// ── Tests unitaires : module Pointage v2 (terminaux) ──────────────────────────
// Vérifie la logique pure du nouveau modèle :
//   • extraction du token depuis un contenu QR (URL ou brut)
//   • détermination de l'action clock_in/clock_out d'après l'état du jour
//   • détection d'anomalie double-pointage
//   • résolution multi-hôtel (le salarié peut pointer dans un hôtel secondaire)
//
// Ces fonctions dupliquent délibérément la logique de l'edge function
// supabase/functions/clock-portal/index.ts pour être testables sans Deno.
// Toute évolution doit rester synchronisée.

function extractToken(raw){
  if(!raw) return null;
  const trimmed = String(raw).trim();
  try{
    const u = new URL(trimmed);
    const t = u.searchParams.get('token');
    if(t) return t.trim();
  }catch(_){/* pas une URL */}
  return trimmed || null;
}

function decideAction(todayRows){
  const rows = (todayRows||[]).slice().sort((a,b)=> (b.clock_in_ts||'').localeCompare(a.clock_in_ts||''));
  const openShift = rows.find(r=>!r.clock_out_ts);
  return openShift ? {action:'clock_out', targetId:openShift.id} : {action:'clock_in', targetId:null};
}

function detectDoubleClocking(todayRows, nowMs, thresholdMs=3*60*1000){
  const rows = (todayRows||[]).slice().sort((a,b)=> (b.clock_in_ts||'').localeCompare(a.clock_in_ts||''));
  const last = rows[0];
  if(!last || !last.clock_out_ts) return false;
  const gap = nowMs - new Date(last.clock_out_ts).getTime();
  return gap < thresholdMs;
}

// Version STRICTE de l'autorisation (post-audit). L'historique de pointage
// n'est plus un critère. Cette fonction reflète en pur JS la logique de la
// SQL fn employee_can_clock_at(uuid,uuid,date) définie en
// sql/63_pointage_terminals_hardening.sql § 9.
function canEmployeeClockAtHotel({
  employeeActive, primaryHotelId, targetHotelId, day,
  hasActivePermanentAssignment, hasActiveExtraForMonth, hasPShiftOnDay,
}){
  if(!employeeActive) return false;                    // salarié désactivé
  if(primaryHotelId === targetHotelId) return true;    // (a) principal + actif
  if(hasActivePermanentAssignment)     return true;    // (b) affectation permanente
  if(hasActiveExtraForMonth)           return true;    // (c) extra ce mois-ci
  if(hasPShiftOnDay)                   return true;    // (d) shift P planifié ce jour
  return false;
}

// Générateur de clé d'idempotence : réplique la logique de portal.html
// (crypto.randomUUID préféré, fallback tableau random). Sert à vérifier
// que la clé est stable, opaque et suffisamment unique.
function newIdempotencyKey(){
  try{ if(globalThis.crypto?.randomUUID) return 'ptg-'+globalThis.crypto.randomUUID(); }catch(_){}
  const buf=new Uint8Array(16);
  (globalThis.crypto || {getRandomValues:()=>{for(let i=0;i<buf.length;i++) buf[i]=Math.floor(Math.random()*256);}}).getRandomValues?.(buf);
  return 'ptg-'+Array.from(buf).map(b=>b.toString(16).padStart(2,'0')).join('');
}

// Plage horaire d'un terminal (minute locale hôtel).
function isWithinActiveWindow(activeFrom, activeTo, nowMinuteLocal){
  if(activeFrom == null && activeTo == null) return true;
  if(activeFrom == null || activeTo == null) return true;
  if(activeFrom <= activeTo) return nowMinuteLocal >= activeFrom && nowMinuteLocal <= activeTo;
  return nowMinuteLocal >= activeFrom || nowMinuteLocal <= activeTo; // traverse minuit
}

// ── Extraction du token ──────────────────────────────────────────────────────
describe('extractToken', () => {
  test('URL complète avec ?action=clock&token=…', () => {
    expect(extractToken('https://rh.flowtym.com/salarie?action=clock&token=ftt_deadbeef'))
      .toBe('ftt_deadbeef');
  });

  test('URL avec token en fin de query', () => {
    expect(extractToken('https://rh.flowtym.com/salarie?foo=bar&token=abc123'))
      .toBe('abc123');
  });

  test('chaîne brute sans URL renvoyée telle quelle', () => {
    expect(extractToken('ftt_1234567890abcdef')).toBe('ftt_1234567890abcdef');
  });

  test('espaces autour du token nettoyés', () => {
    expect(extractToken('   ftt_xyz   ')).toBe('ftt_xyz');
  });

  test('vide → null', () => {
    expect(extractToken('')).toBeNull();
    expect(extractToken(null)).toBeNull();
    expect(extractToken(undefined)).toBeNull();
  });

  test('URL sans paramètre token → URL brute conservée', () => {
    // Le backend le rejettera ; on ne fait pas d'inférence côté client.
    expect(extractToken('https://exemple.fr/pointage')).toBe('https://exemple.fr/pointage');
  });
});

// ── Détermination de l'action ────────────────────────────────────────────────
describe('decideAction', () => {
  test('journée vide → clock_in', () => {
    expect(decideAction([])).toEqual({action:'clock_in', targetId:null});
  });

  test('shift ouvert → clock_out ciblé', () => {
    const rows = [{id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:null}];
    expect(decideAction(rows)).toEqual({action:'clock_out', targetId:'c1'});
  });

  test('shift terminé → clock_in (nouvelle vacation)', () => {
    const rows = [{id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:'2026-07-27T12:00:00Z'}];
    expect(decideAction(rows).action).toBe('clock_in');
  });

  test('plusieurs vacations, dernière ouverte → clock_out', () => {
    const rows = [
      {id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:'2026-07-27T12:00:00Z'},
      {id:'c2', clock_in_ts:'2026-07-27T18:00:00Z', clock_out_ts:null},
    ];
    expect(decideAction(rows)).toEqual({action:'clock_out', targetId:'c2'});
  });

  test('ordre d\'entrée non trié → résultat stable', () => {
    const rows = [
      {id:'c2', clock_in_ts:'2026-07-27T18:00:00Z', clock_out_ts:null},
      {id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:'2026-07-27T12:00:00Z'},
    ];
    expect(decideAction(rows).targetId).toBe('c2');
  });
});

// ── Détection double-pointage ────────────────────────────────────────────────
describe('detectDoubleClocking', () => {
  const nowMs = new Date('2026-07-27T12:02:00Z').getTime();

  test('pointage il y a 2 min → anomalie', () => {
    const rows = [{id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:'2026-07-27T12:00:00Z'}];
    expect(detectDoubleClocking(rows, nowMs)).toBe(true);
  });

  test('pointage il y a 10 min → OK', () => {
    const rows = [{id:'c1', clock_in_ts:'2026-07-27T07:00:00Z', clock_out_ts:'2026-07-27T11:52:00Z'}];
    expect(detectDoubleClocking(rows, nowMs)).toBe(false);
  });

  test('shift encore ouvert → pas de double (c\'est un clock_out)', () => {
    const rows = [{id:'c1', clock_in_ts:'2026-07-27T08:00:00Z', clock_out_ts:null}];
    expect(detectDoubleClocking(rows, nowMs)).toBe(false);
  });

  test('journée vide → pas d\'anomalie', () => {
    expect(detectDoubleClocking([], nowMs)).toBe(false);
  });
});

// ── Autorisation multi-hôtel STRICTE ─────────────────────────────────────────
// Ces tests miroir des cas SQL — voir sql/tests/pointage_hardening.sql tests 1-5.
describe('canEmployeeClockAtHotel (règles actuelles uniquement)', () => {
  const base = {
    employeeActive:true, primaryHotelId:'h1', targetHotelId:'h1',
    day:'2026-07-27',
    hasActivePermanentAssignment:false, hasActiveExtraForMonth:false, hasPShiftOnDay:false,
  };

  test('hôtel principal + employé actif → autorisé', () => {
    expect(canEmployeeClockAtHotel(base)).toBe(true);
  });

  test('salarié désactivé → refusé même dans son hôtel principal', () => {
    expect(canEmployeeClockAtHotel({...base, employeeActive:false})).toBe(false);
  });

  test('hôtel étranger sans aucun droit → refusé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2'})).toBe(false);
  });

  test('affectation permanente active → autorisé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasActivePermanentAssignment:true})).toBe(true);
  });

  test('activation extra active ce mois-ci → autorisé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasActiveExtraForMonth:true})).toBe(true);
  });

  test('shift P planifié ce jour dans cet hôtel → autorisé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasPShiftOnDay:true})).toBe(true);
  });

  test('shift planifié dans un AUTRE hôtel → refusé pour l\'hôtel cible', () => {
    // Le caller passe hasPShiftOnDay=false pour l'hôtel cible.
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasPShiftOnDay:false})).toBe(false);
  });

  test('extra expiré ou hors mois → refusé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasActiveExtraForMonth:false})).toBe(false);
  });

  test('affectation permanente désactivée → refusé', () => {
    expect(canEmployeeClockAtHotel({...base, targetHotelId:'h2', hasActivePermanentAssignment:false})).toBe(false);
  });

  test('ANCIEN salarié ayant déjà pointé mais désactivé → refusé', () => {
    // Historique de pointage n'est plus un critère.
    expect(canEmployeeClockAtHotel({
      ...base, targetHotelId:'h2', employeeActive:false,
    })).toBe(false);
  });

  test('ancien salarié actif MAIS sans droit actuel → refusé', () => {
    // La règle audit refuse même si l'employé a un historique dans l'hôtel.
    expect(canEmployeeClockAtHotel({
      ...base, targetHotelId:'h2',   // aucun droit actuel
    })).toBe(false);
  });
});

// ── Idempotency key ──────────────────────────────────────────────────────────
describe('newIdempotencyKey', () => {
  test('préfixe ptg- + valeur non vide', () => {
    const k = newIdempotencyKey();
    expect(k.startsWith('ptg-')).toBe(true);
    expect(k.length).toBeGreaterThan(10);
  });

  test('deux appels successifs produisent 2 clés distinctes', () => {
    const a = newIdempotencyKey();
    const b = newIdempotencyKey();
    expect(a).not.toBe(b);
  });

  test('n\'utilise que caractères sûrs pour HTTP header', () => {
    const k = newIdempotencyKey();
    expect(k).toMatch(/^ptg-[a-f0-9-]{16,}$/);
  });
});

// ── Construction du payload audit (edge fn clock-portal) ────────────────────
// La clé anomaly_flags DOIT être ABSENTE quand le tableau est vide — la RPC
// serveur record_clocking utilisait `p_audit ? 'anomaly_flags'` qui matchait
// même une valeur null → jsonb_array_elements_text(null) → 22023. Fix client :
// omettre la clé au lieu d'envoyer null. Fix serveur : jsonb_typeof=array.
function buildAuditPayload({gps_lat, gps_lng, gps_accuracy, distance_meters, device_info, ip_address, anomalies}){
  return {
    gps_lat: gps_lat ?? null,
    gps_lng: gps_lng ?? null,
    gps_accuracy: gps_accuracy ?? null,
    distance_meters,
    device_info: device_info ?? null,
    ip_address,
    clock_status: anomalies.length > 0 ? 'suspicious' : 'valid',
    ...(anomalies.length > 0 ? { anomaly_flags: anomalies } : {}),
  };
}

describe('buildAuditPayload — anomaly_flags omission', () => {
  test('anomalies vide → clé anomaly_flags ABSENTE (pas null)', () => {
    const p = buildAuditPayload({anomalies:[], ip_address:'127.0.0.1'});
    expect('anomaly_flags' in p).toBe(false);
    expect(p.clock_status).toBe('valid');
  });

  test('anomalies non vide → clé présente avec tableau', () => {
    const p = buildAuditPayload({anomalies:['gps_accuracy_low'], ip_address:'127.0.0.1'});
    expect(p.anomaly_flags).toEqual(['gps_accuracy_low']);
    expect(p.clock_status).toBe('suspicious');
  });

  test('sérialisation JSON n\'inclut pas anomaly_flags quand vide', () => {
    const raw = JSON.stringify(buildAuditPayload({anomalies:[], ip_address:'x'}));
    expect(raw).not.toContain('anomaly_flags');
  });
});

// ── Plage horaire d'un terminal ──────────────────────────────────────────────
describe('isWithinActiveWindow', () => {
  test('sans plage → toujours actif', () => {
    expect(isWithinActiveWindow(null,null,600)).toBe(true);
  });

  test('plage 06:00-14:00, midi → actif', () => {
    expect(isWithinActiveWindow(6*60, 14*60, 12*60)).toBe(true);
  });

  test('plage 06:00-14:00, 22:00 → inactif', () => {
    expect(isWithinActiveWindow(6*60, 14*60, 22*60)).toBe(false);
  });

  test('plage traversant minuit 22:00-06:00, 23:30 → actif', () => {
    expect(isWithinActiveWindow(22*60, 6*60, 23*60+30)).toBe(true);
  });

  test('plage traversant minuit 22:00-06:00, 04:00 → actif', () => {
    expect(isWithinActiveWindow(22*60, 6*60, 4*60)).toBe(true);
  });

  test('plage traversant minuit 22:00-06:00, 12:00 → inactif', () => {
    expect(isWithinActiveWindow(22*60, 6*60, 12*60)).toBe(false);
  });
});
