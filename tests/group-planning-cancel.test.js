'use strict';
const { findMoveRow, planCancelCall } = require('./lib/groupPlanningCancel');
const fs = require('fs');
const path = require('path');

// ── findMoveRow ──────────────────────────────────────────────────────────────

describe('Planning établissement · findMoveRow — détection d\'une ligne issue d\'un déplacement', () => {
  const eid = 'e1', day = '2026-07-25', hid = 'FO';

  test('ligne normale (pas de source_proposal_id) → null', () => {
    const rows = [{ employee_id: eid, day, status: 'P', source_proposal_id: null }];
    expect(findMoveRow(rows, eid, day, hid)).toBeNull();
  });

  test('source_proposal_id absent (undefined) → null', () => {
    const rows = [{ employee_id: eid, day, status: 'P' }];
    expect(findMoveRow(rows, eid, day, hid)).toBeNull();
  });

  test('source_proposal_id renseigné → objet identifiant le déplacement', () => {
    const rows = [{
      employee_id: eid, day, status: 'PE',
      source_proposal_id: '66807e63-0375-4ed4-b35e-aabeff10aade',
      origin_hotel_id: 'VO',
    }];
    expect(findMoveRow(rows, eid, day, hid)).toEqual({
      proposal_id: '66807e63-0375-4ed4-b35e-aabeff10aade',
      employee_id: eid, day,
      hotel_id: hid, origin_hotel_id: 'VO',
    });
  });

  test('pas de ligne pour (eid, day) → null', () => {
    const rows = [{ employee_id: 'e2', day, source_proposal_id: 'x' }];
    expect(findMoveRow(rows, eid, day, hid)).toBeNull();
  });

  test('planningRows vide ou absent → null (pas de crash)', () => {
    expect(findMoveRow(undefined, eid, day, hid)).toBeNull();
    expect(findMoveRow([], eid, day, hid)).toBeNull();
    expect(findMoveRow(null, eid, day, hid)).toBeNull();
  });
});

// ── planCancelCall ───────────────────────────────────────────────────────────

describe('Planning établissement · planCancelCall — spec de gmpCancelApplied', () => {
  test('annulation totale (scope=full) → onlyDay=null', () => {
    expect(planCancelCall({ proposalId: 'p1', day: '2026-07-25', scope: 'full' })).toEqual({
      call: { name: 'gmpCancelApplied', args: ['p1', null] },
    });
  });

  test('annulation d\'un seul segment (scope=segment) → onlyDay=day', () => {
    expect(planCancelCall({ proposalId: 'p1', day: '2026-07-25', scope: 'segment' })).toEqual({
      call: { name: 'gmpCancelApplied', args: ['p1', '2026-07-25'] },
    });
  });

  test('scope=segment sans day → refus explicite', () => {
    expect(planCancelCall({ proposalId: 'p1', day: null, scope: 'segment' })).toEqual({
      call: null, reason: 'jour requis pour un scope segment',
    });
  });

  test('proposalId manquant → refus', () => {
    expect(planCancelCall({ proposalId: null, day: '2026-07-25', scope: 'full' })).toEqual({
      call: null, reason: 'proposition manquante',
    });
  });
});

// ── Contrat SQL — migration 59 ──────────────────────────────────────────────

describe('Planning Groupe · contrat SQL — group_move_cancel_applied', () => {
  const migration = fs.readFileSync(
    path.join(__dirname, '..', 'sql', '59_group_move_cancel_applied.sql'),
    'utf8'
  );

  test('migration crée la RPC group_move_cancel_applied avec 3 paramètres', () => {
    expect(migration).toMatch(/CREATE OR REPLACE FUNCTION public\.group_move_cancel_applied\(\s*p_id uuid,\s*p_only_day date DEFAULT NULL,\s*p_idempotency_key text DEFAULT NULL/);
  });

  test('migration crée la table d\'idempotence group_move_cancellations', () => {
    expect(migration).toMatch(/CREATE TABLE IF NOT EXISTS group_move_cancellations/);
    expect(migration).toMatch(/idempotency_key text PRIMARY KEY/);
  });

  test('migration vérifie le droit d\'accès via _gmp_can_access sur les deux hôtels', () => {
    expect(migration).toMatch(/_gmp_can_access\(r\.from_hotel_id, r\.to_hotel_id\)/);
  });

  test('migration verrouille par (employee, day) via pg_advisory_xact_lock', () => {
    expect(migration).toMatch(/pg_advisory_xact_lock/);
  });

  test('migration désactive employee_extra_activations si plus aucune mission ne les justifie', () => {
    expect(migration).toMatch(/UPDATE employee_extra_activations[\s\S]*SET active = false/);
    expect(migration).toMatch(/NOT EXISTS[\s\S]*FROM staff_planning/);
  });

  test('migration passe la proposition à cancelled (full) ou met à jour ses slots (day)', () => {
    expect(migration).toMatch(/SET status = 'cancelled'/);
    expect(migration).toMatch(/v_remaining_slots/);
  });

  test('migration insère un événement d\'audit', () => {
    expect(migration).toMatch(/INSERT INTO group_move_proposal_events/);
    expect(migration).toMatch(/cancelled_after_apply|cancelled_segment/);
  });

  // Régression : migration 61 corrige le bug SQL 42803 (GROUP BY manquant)
  // et le bug 42702 (colonne « d » ambiguë). Vérifier que le fix est présent
  // dans le repo pour éviter toute régression future.
  test('migration 61 corrective présente : GROUP BY hotel_id + alias renommé', () => {
    const fix = fs.readFileSync(
      path.join(__dirname, '..', 'sql', '61_group_move_cancel_applied_fix.sql'),
      'utf8'
    );
    // Ré-écrit CREATE OR REPLACE
    expect(fix).toMatch(/CREATE OR REPLACE FUNCTION public\.group_move_cancel_applied/);
    // GROUP BY présent + LIMIT 1 (correctif 42803)
    expect(fix).toMatch(/GROUP BY (s\.)?hotel_id/);
    expect(fix).toMatch(/LIMIT 1/);
    // Alias renommé pour éviter la collision avec la variable d PL/pgSQL
    expect(fix).toMatch(/unnest\(v_days\) AS t\(dd\)/);
    // Restauration best-effort pour propositions historiques sans segments
    expect(fix).toMatch(/proposition historique|Propositions historiques/);
    expect(fix).toMatch(/status\s*=\s*'MAD'/);
  });
});

// ── Contrat frontend — dialog actionnable + BE method ────────────────────────

describe('Frontend · dialog actionnable Modifier / Annuler', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  test('BE expose gmpCancelApplied appelant la RPC group_move_cancel_applied', () => {
    expect(html).toMatch(/async gmpCancelApplied[\s\S]{0,200}rpc\('group_move_cancel_applied'/);
  });

  test('BE expose gmpProposalGet pour prérempler la fenêtre de modification', () => {
    expect(html).toMatch(/async gmpProposalGet/);
  });

  test('listMonthPlanning inclut source_proposal_id et origin_hotel_id', () => {
    expect(html).toMatch(/select\('employee_id,day,status[^']*,source_proposal_id,origin_hotel_id'/);
  });

  test('openMoveGuardModal existe et expose 3 boutons Modifier / Annuler / Fermer', () => {
    expect(html).toMatch(/function openMoveGuardModal/);
    expect(html).toMatch(/Modifier l'affectation/);
    expect(html).toMatch(/Annuler l'affectation/);
    // « Fermer » dans le contexte de la modale — présent au moins une fois.
    expect(html).toMatch(/id="mgClose"/);
  });

  test('openPop intercepte proactivement les lignes issues d\'un déplacement', () => {
    expect(html).toMatch(/function openPop\(td\)[\s\S]{0,400}findMoveRowInPlanning/);
    expect(html).toMatch(/openMoveGuardModal/);
  });

  test('saveChanges intercepte l\'erreur du trigger et propose le dialog actionnable', () => {
    expect(html).toMatch(/msg\.includes\('déplacement inter-hôtels'\)/);
    expect(html).toMatch(/openMoveGuardModal\(target\)/);
  });

  test('openMoveEdit ouvre le formulaire pré-rempli SANS modifier les données (regression: le remplacement est fait au submit)', () => {
    const idx = html.indexOf('async function openMoveEdit');
    expect(idx).toBeGreaterThan(-1);
    const next = html.indexOf('\nasync function ', idx + 30);
    const body = html.slice(idx, next > 0 ? next : idx + 3000);
    // Doit ouvrir le form pré-rempli.
    expect(body).toMatch(/gpOpenSimFormPrefilled/);
    // Ne DOIT PAS canceller — le remplacement atomique se fait au submit
    // via gpConfirmAffectation → BE.gmpReplaceApplied.
    expect(body).not.toMatch(/BE\.gmpCancelApplied/);
    // Aucune écriture directe planning :
    expect(body).not.toMatch(/savePlanning|from\('staff_planning'\)/);
  });

  test('openMoveCancel gère l\'annulation totale ET par segment (multi-day)', () => {
    expect(html).toMatch(/id="cxFull"/);
    expect(html).toMatch(/id="cxSeg"/);
    expect(html).toMatch(/Annuler uniquement ce segment/);
    expect(html).toMatch(/Annuler tout le déplacement/);
  });
});
