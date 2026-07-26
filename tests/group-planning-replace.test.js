'use strict';
const { planConfirmCall, functionalErrorMessage } = require('./lib/groupPlanningReplace');
const fs = require('fs');
const path = require('path');

const PAYLOAD = { employee_id:'e1', from_hotel_id:'FO', to_hotel_id:'VO',
                  slots:[{date:'2026-07-25'}] };

// ── planConfirmCall ──────────────────────────────────────────────────────────

describe('Planning Groupe · planConfirmCall — create vs replace atomique', () => {
  test('sans replaceOldId → create classique (chaîne 4 RPC)', () => {
    const p = planConfirmCall({ replaceOldId: null, payload: PAYLOAD, idempotencyKey: 'k1' });
    expect(p.op).toBe('create');
    expect(p.calls.map(c => c.name)).toEqual([
      'gmpCreate', 'gmpSubmit', 'gmpApprovalDecide', 'gmpApply',
    ]);
  });

  test('avec replaceOldId → replace atomique (1 seule RPC)', () => {
    const p = planConfirmCall({ replaceOldId: 'p-old', payload: PAYLOAD, idempotencyKey: 'k2' });
    expect(p.op).toBe('replace');
    expect(p.calls.length).toBe(1);
    expect(p.calls[0].name).toBe('gmpReplaceApplied');
    expect(p.calls[0].args[0]).toBe('p-old');
    expect(p.calls[0].args[1]).toBe(PAYLOAD);
    expect(p.calls[0].args[2]).toBe('replace_k2');
  });

  test('payload manquant → noop', () => {
    expect(planConfirmCall({ replaceOldId: null, payload: null }).op).toBe('noop');
  });

  test('idempotency key stable : deux appels identiques produisent la même clé serveur', () => {
    const a = planConfirmCall({ replaceOldId: 'p-old', payload: PAYLOAD, idempotencyKey: 'kX' });
    const b = planConfirmCall({ replaceOldId: 'p-old', payload: PAYLOAD, idempotencyKey: 'kX' });
    expect(a.calls[0].args[2]).toBe(b.calls[0].args[2]);
  });
});

// ── functionalErrorMessage — masque les détails techniques ────────────────

describe('Planning Groupe · functionalErrorMessage — messages métier', () => {
  const t = (raw, expected) =>
    expect(functionalErrorMessage(new Error(raw))).toBe(expected);

  test('Proposition introuvable', () => t(
    'Proposition introuvable',
    'Cette affectation n\'existe plus.'
  ));

  test('Seule une affectation appliquée peut être remplacée', () => t(
    'Seule une affectation appliquée peut être remplacée (statut : cancelled)',
    'Cette affectation a déjà été modifiée ou annulée.'
  ));

  test('Accès refusé', () => t(
    'Accès refusé',
    'Vous n\'avez pas les droits nécessaires sur cet établissement.'
  ));

  test('Proposition bloquée', () => t(
    'Proposition bloquée',
    'La nouvelle affectation est bloquée par des contraintes.'
  ));

  test('Fingerprint modifié', () => t(
    'Données modifiées depuis la simulation : re-simulation requise',
    'Les données ont changé, la vérification est nécessaire à nouveau.'
  ));

  test('PostgREST : function not found', () => t(
    'Could not find the function public.foo in the schema cache',
    'Fonctionnalité indisponible actuellement — rechargez la page.'
  ));

  test('Concurrence prioritaire', () => t(
    'Proposition concurrente prioritaire : revalidation nécessaire',
    'Une autre affectation concurrente doit être traitée en premier.'
  ));

  test('Double clic idempotence', () => t(
    'Remplacement déjà en cours pour cette clé',
    'Opération déjà en cours, veuillez patienter.'
  ));

  test('Service inconnu de la destination', () => t(
    'ensure_visibility: service Cuisine introuvable sur l hotel de destination',
    'Le service de destination est inconnu de cet établissement.'
  ));

  test('JWT / RLS', () => t(
    'permission denied for table staff_planning',
    'Vous n\'avez pas les droits nécessaires.'
  ));

  test('Erreur inconnue → fallback', () => expect(
    functionalErrorMessage(new Error('kaboom'), 'Impossible d\'annuler cette affectation.')
  ).toBe('Impossible d\'annuler cette affectation.'));
});

// ── Contrat SQL — migration 60 ──────────────────────────────────────────────

describe('Planning Groupe · contrat SQL — group_move_replace_applied', () => {
  const migration = fs.readFileSync(
    path.join(__dirname, '..', 'sql', '60_group_move_replace_applied.sql'),
    'utf8'
  );

  test('migration crée la RPC avec 3 paramètres nommés', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\.group_move_replace_applied\(\s*p_old_id uuid,\s*p_new_payload jsonb,\s*p_idempotency_key text DEFAULT NULL/);
  });

  test('migration crée la table d\'idempotence group_move_replacements', () => {
    expect(migration).toMatch(/CREATE TABLE IF NOT EXISTS group_move_replacements/);
    expect(migration).toMatch(/idempotency_key text PRIMARY KEY/);
  });

  test('migration verrouille l\'ancienne proposition (FOR UPDATE) et exige status=applied', () => {
    expect(migration).toMatch(/FROM group_move_proposals WHERE id = p_old_id FOR UPDATE/);
    expect(migration).toMatch(/v_old\.status <> 'applied'/);
  });

  test('migration délègue à group_move_cancel_applied puis group_move_apply — même transaction', () => {
    expect(migration).toMatch(/public\.group_move_cancel_applied\(p_old_id, NULL, 'replace:' \|\| v_key\)/);
    expect(migration).toMatch(/public\.group_move_proposal_create\(p_new_payload\)/);
    expect(migration).toMatch(/public\.group_move_apply\(v_new_id, 'replace_apply:' \|\| v_key\)/);
  });

  test('migration bypasse le workflow (approbation automatique) via UPDATE status=approved', () => {
    expect(migration).toMatch(/UPDATE group_move_proposals SET status = 'approved'[^;]+WHERE id = v_new_id/);
  });

  test('migration vérifie _gmp_can_access', () => {
    expect(migration).toMatch(/_gmp_can_access\(v_old\.from_hotel_id, v_old\.to_hotel_id\)/);
  });
});

// ── Contrat frontend — flow Modifier non destructif ─────────────────────────

describe('Frontend · flow Modifier ne modifie rien avant confirmation', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  test('BE expose gmpReplaceApplied appelant la RPC group_move_replace_applied', () => {
    expect(html).toMatch(/async gmpReplaceApplied[\s\S]{0,200}rpc\('group_move_replace_applied'/);
  });

  test('openMoveEdit N\'APPELLE PLUS gmpCancelApplied (aucune écriture avant confirmation)', () => {
    const idx = html.indexOf('async function openMoveEdit');
    const next = html.indexOf('\nasync function ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 3000);
    expect(body).not.toMatch(/BE\.gmpCancelApplied/);
    // openMoveEdit ne fait que : lecture (gmpProposalGet) + set _gpReplaceOldId
    // + ouverture du formulaire (gpOpenSimFormPrefilled).
    expect(body).toMatch(/_gpReplaceOldId\s*=\s*prop\.id/);
    expect(body).toMatch(/gpOpenSimFormPrefilled/);
    expect(body).toMatch(/BE\.gmpProposalGet/);
  });

  test('gpConfirmAffectation route vers gmpReplaceApplied si _gpReplaceOldId est set', () => {
    const idx = html.indexOf('async function gpConfirmAffectation');
    const next = html.indexOf('\nasync function ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 3000);
    expect(body).toMatch(/_gpReplaceOldId/);
    expect(body).toMatch(/BE\.gmpReplaceApplied\(/);
    expect(body).toMatch(/_gpReplaceOldId\s*=\s*null/);
  });

  test('closeModal remet _gpReplaceOldId à null (fermeture sans confirmer)', () => {
    expect(html).toMatch(/function closeModal\(\)\s*\{[\s\S]*_gpReplaceOldId\s*=\s*null/);
  });

  test('_fnErrorMsg cartographie les messages techniques → fonctionnels', () => {
    expect(html).toMatch(/function _fnErrorMsg/);
    // Les apostrophes sont échappées dans la source JS ('n\'existe' etc.).
    expect(html).toMatch(/Cette affectation n\\?'existe plus/);
    expect(html).toMatch(/Vous n\\?'avez pas les droits/);
    expect(html).toMatch(/rechargez la page/);
  });
});
