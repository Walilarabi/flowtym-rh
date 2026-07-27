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

function canEmployeeClockAtHotel({primaryHotelId, targetHotelId, hasShiftAtTarget, hasPastClockingAtTarget}){
  if(primaryHotelId === targetHotelId) return true;
  return !!(hasShiftAtTarget || hasPastClockingAtTarget);
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

// ── Autorisation multi-hôtel ─────────────────────────────────────────────────
describe('canEmployeeClockAtHotel', () => {
  test('hôtel principal → autorisé', () => {
    expect(canEmployeeClockAtHotel({
      primaryHotelId:'h1', targetHotelId:'h1',
      hasShiftAtTarget:false, hasPastClockingAtTarget:false,
    })).toBe(true);
  });

  test('hôtel secondaire avec shift planifié → autorisé', () => {
    expect(canEmployeeClockAtHotel({
      primaryHotelId:'h1', targetHotelId:'h2',
      hasShiftAtTarget:true, hasPastClockingAtTarget:false,
    })).toBe(true);
  });

  test('hôtel secondaire avec historique de pointage → autorisé', () => {
    expect(canEmployeeClockAtHotel({
      primaryHotelId:'h1', targetHotelId:'h2',
      hasShiftAtTarget:false, hasPastClockingAtTarget:true,
    })).toBe(true);
  });

  test('hôtel étranger sans rattachement → refusé', () => {
    expect(canEmployeeClockAtHotel({
      primaryHotelId:'h1', targetHotelId:'h3',
      hasShiftAtTarget:false, hasPastClockingAtTarget:false,
    })).toBe(false);
  });
});
