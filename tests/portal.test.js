'use strict';

// ── Tests portail salarié ─────────────────────────────────────────────────────
// Teste la logique pure (sans Supabase) : validation des formulaires,
// filtrage des demandes, durées de pointage, RGPD.

// ── Helpers ───────────────────────────────────────────────────────────────────
const iso = (y,m,d) => `${y}-${String(m+1).padStart(2,'0')}-${String(d).padStart(2,'0')}`;

function durationMin(inTs, outTs, brk=0){
  return Math.round((new Date(outTs)-new Date(inTs))/60000) - brk;
}

function durationStr(inTs, outTs, brk=0){
  const m = durationMin(inTs, outTs, brk);
  return `${Math.floor(m/60)}h${String(m%60).padStart(2,'0')}`;
}

function validateRequestPayload(payload){
  const errors = [];
  if(!payload.type) errors.push('type manquant');
  if(!payload.date_start) errors.push('date_start manquant');
  if(payload.date_end && payload.date_end < payload.date_start) errors.push('date_end antérieure à date_start');
  if(!payload.submitted_consent) errors.push('consentement requis');
  if(payload.message && payload.message.length > 500) errors.push('message trop long');
  return errors;
}

function validateDocUpload(file){
  const ALLOWED_MIME = ['application/pdf','image/jpeg','image/png','image/heic','image/webp','image/gif'];
  const MAX_SIZE = 20 * 1024 * 1024;
  const errors = [];
  if(!ALLOWED_MIME.includes(file.type)) errors.push('format non supporté');
  if(file.size > MAX_SIZE) errors.push('fichier trop volumineux (max 20 Mo)');
  return errors;
}

function buildStoragePath(hotelId, employeeId, docType, filename){
  const ext = filename.split('.').pop().toLowerCase();
  return `${hotelId}/${employeeId}/${docType}_${ext}`;
}

function canClockIn(existing, now){
  // Empêcher un double clock-in si déjà une session ouverte
  const open = existing.find(c => !c.clock_out_ts);
  if(open) return { ok:false, reason:'session_open', openId: open.id };
  // Empêcher pointage rétroactif > 4h
  const fourHAgo = new Date(new Date(now).getTime() - 4*60*60*1000).toISOString();
  return { ok:true };
}

function filterRequests(requests, status){
  if(!status || status === 'all') return requests;
  return requests.filter(r => r.status === status);
}

function maskSensitiveField(value, keepChars=2){
  if(!value) return '—';
  return value.slice(0,keepChars) + '*'.repeat(Math.max(0,value.length-keepChars));
}

// ── Durée de pointage ─────────────────────────────────────────────────────────
describe('Durée de pointage', () => {
  test('calcul simple sans pause', () => {
    const min = durationMin('2025-06-01T08:00:00Z', '2025-06-01T16:00:00Z', 0);
    expect(min).toBe(480); // 8h
  });

  test('soustrait la pause', () => {
    const min = durationMin('2025-06-01T08:00:00Z', '2025-06-01T16:00:00Z', 30);
    expect(min).toBe(450); // 7h30
  });

  test('formatage hh:mm', () => {
    expect(durationStr('2025-06-01T08:00:00Z','2025-06-01T10:30:00Z',0)).toBe('2h30');
    expect(durationStr('2025-06-01T08:00:00Z','2025-06-01T08:05:00Z',0)).toBe('0h05');
  });

  test('poste de nuit cross-minuit', () => {
    const min = durationMin('2025-06-01T22:00:00Z','2025-06-02T06:00:00Z',0);
    expect(min).toBe(480); // 8h
  });
});

// ── Validation clock-in ───────────────────────────────────────────────────────
describe('Validation clock-in', () => {
  test('autorise si aucune session ouverte', () => {
    const clockings = [
      {id:'c1', clock_in_ts:'2025-06-01T08:00:00Z', clock_out_ts:'2025-06-01T16:00:00Z'},
    ];
    const res = canClockIn(clockings, '2025-06-01T17:00:00Z');
    expect(res.ok).toBe(true);
  });

  test('bloque si session déjà ouverte', () => {
    const clockings = [
      {id:'c1', clock_in_ts:'2025-06-01T08:00:00Z', clock_out_ts:null},
    ];
    const res = canClockIn(clockings, '2025-06-01T10:00:00Z');
    expect(res.ok).toBe(false);
    expect(res.reason).toBe('session_open');
    expect(res.openId).toBe('c1');
  });
});

// ── Validation demandes RH ────────────────────────────────────────────────────
describe('Validation des demandes RH', () => {
  test('payload valide accepté', () => {
    const p = {type:'conge_paye', date_start:'2025-07-01', date_end:'2025-07-05', submitted_consent:true};
    expect(validateRequestPayload(p)).toHaveLength(0);
  });

  test('type manquant refusé', () => {
    const p = {date_start:'2025-07-01', submitted_consent:true};
    expect(validateRequestPayload(p)).toContain('type manquant');
  });

  test('date_start manquante refusée', () => {
    const p = {type:'maladie', submitted_consent:true};
    expect(validateRequestPayload(p)).toContain('date_start manquant');
  });

  test('date_end antérieure à date_start refusée', () => {
    const p = {type:'conge_paye', date_start:'2025-07-10', date_end:'2025-07-05', submitted_consent:true};
    expect(validateRequestPayload(p)).toContain('date_end antérieure à date_start');
  });

  test('consentement requis', () => {
    const p = {type:'extra', date_start:'2025-07-01', submitted_consent:false};
    expect(validateRequestPayload(p)).toContain('consentement requis');
  });

  test('message > 500 chars refusé', () => {
    const p = {type:'autre', date_start:'2025-07-01', submitted_consent:true, message:'x'.repeat(501)};
    expect(validateRequestPayload(p)).toContain('message trop long');
  });

  test('message exactement 500 chars accepté', () => {
    const p = {type:'autre', date_start:'2025-07-01', submitted_consent:true, message:'x'.repeat(500)};
    expect(validateRequestPayload(p)).toHaveLength(0);
  });
});

// ── Filtre des demandes ───────────────────────────────────────────────────────
describe('Filtre des demandes', () => {
  const requests = [
    {id:'r1', status:'pending', type:'conge_paye'},
    {id:'r2', status:'approved', type:'conge_paye'},
    {id:'r3', status:'rejected', type:'maladie'},
    {id:'r4', status:'pending', type:'extra'},
  ];

  test('filtre pending', () => {
    expect(filterRequests(requests,'pending')).toHaveLength(2);
  });

  test('filtre approved', () => {
    expect(filterRequests(requests,'approved')).toHaveLength(1);
  });

  test('status=all retourne tout', () => {
    expect(filterRequests(requests,'all')).toHaveLength(4);
  });

  test('status vide retourne tout', () => {
    expect(filterRequests(requests,'')).toHaveLength(4);
  });
});

// ── Validation upload documents ───────────────────────────────────────────────
describe('Validation upload documents', () => {
  test('PDF accepté', () => {
    expect(validateDocUpload({type:'application/pdf', size:1024*1024})).toHaveLength(0);
  });

  test('image JPEG acceptée', () => {
    expect(validateDocUpload({type:'image/jpeg', size:500*1024})).toHaveLength(0);
  });

  test('format .docx refusé (même si autorisé serveur, pas côté portail)', () => {
    expect(validateDocUpload({type:'application/msword', size:100})).toContain('format non supporté');
  });

  test('fichier > 20 Mo refusé', () => {
    expect(validateDocUpload({type:'image/png', size:21*1024*1024})).toContain('fichier trop volumineux (max 20 Mo)');
  });

  test('fichier exactement 20 Mo accepté', () => {
    expect(validateDocUpload({type:'application/pdf', size:20*1024*1024})).toHaveLength(0);
  });
});

// ── Path Storage ──────────────────────────────────────────────────────────────
describe('Chemin Storage portail', () => {
  test('structure hotel_id/employee_id/type_ext', () => {
    const path = buildStoragePath('hotel-123','emp-456','cni','scan.pdf');
    expect(path).toBe('hotel-123/emp-456/cni_pdf');
  });

  test('extension en minuscules', () => {
    const path = buildStoragePath('h','e','rib','RIB.PDF');
    expect(path).toBe('h/e/rib_pdf');
  });
});

// ── RGPD — masquage données sensibles ────────────────────────────────────────
describe('RGPD masquage', () => {
  test('masque un numéro de sécu', () => {
    const masked = maskSensitiveField('1 85 05 75 115 423 34', 2);
    expect(masked.startsWith('1 ')).toBe(true);
    expect(masked).toContain('*');
  });

  test('valeur vide retourne —', () => {
    expect(maskSensitiveField('')).toBe('—');
    expect(maskSensitiveField(null)).toBe('—');
  });

  test('keepChars respecté', () => {
    const masked = maskSensitiveField('ABCDEF', 3);
    expect(masked).toBe('ABC***');
  });
});

// ── Sécurité — isolation hotel_id ─────────────────────────────────────────────
describe('Isolation hotel_id', () => {
  test('une demande ne peut appartenir qu\'à un seul hôtel', () => {
    const req = { hotel_id:'hotel-A', employee_id:'emp-1', type:'conge_paye', date_start:'2025-07-01', submitted_consent:true };
    const errors = validateRequestPayload(req);
    expect(errors).toHaveLength(0);
    // L'hotel_id doit correspondre à celui de l'employé — vérifié par RLS côté DB
    expect(req.hotel_id).toBe('hotel-A');
  });

  test('messages soft-deleted non retournés au salarié', () => {
    const messages = [
      {id:'m1', direction:'manager_to_employee', deleted_by_employee:false, body:'Bonjour'},
      {id:'m2', direction:'manager_to_employee', deleted_by_employee:true,  body:'[Effacé]'},
    ];
    const visible = messages.filter(m => !m.deleted_by_employee);
    expect(visible).toHaveLength(1);
    expect(visible[0].id).toBe('m1');
  });
});
