# Runbook d'incident — pilote Flowtym RH

À utiliser dès qu'une anomalie est détectée pendant le pilote (checklist quotidienne,
signalement utilisateur, alerte). **Priorité absolue : préserver l'intégrité de la
paie.** En cas de doute → **rollback flag immédiat** (§4), on diagnostique ensuite.

## 1. Qui intervient ?

| Rôle | Responsabilité | Quand |
|---|---|---|
| **Release Manager** | pilote l'incident, décide GO/NO-GO du rollback, communique | tout incident |
| **DBA / dev backend** | exécute requêtes de diagnostic, rollback flag/migration | anomalie données/DB |
| **Frontend/DevOps** | rollback Vercel, vérifie l'affichage | anomalie UI |
| **Référent paie (métier)** | valide l'impact paie, confirme le réel | anomalie heures/paie |

Escalade : Release Manager → responsable technique → responsable produit.

## 2. Classifier l'incident

| Symptôme | Gravité | Action immédiate |
|---|---|---|
| Heures **doublées** en paie (jour déplacé) | **CRITIQUE** | Rollback flag (§4) **maintenant** |
| Écriture aboutie sur une **période close** | **CRITIQUE** | Rollback flag + §6 (vérifier garde-fou) |
| Chevauchement de segments (1b ≠ 0) | **CRITIQUE** | Rollback flag + §6 |
| `orphan_processing` ≠ 0 | Élevé | §3 diagnostic ; souvent transitoire |
| Refus `FL001` sur période **ouverte** | Élevé | §6 (vérifier périodes) |
| Écart heures inexpliqué (non doublé) | Moyen | §3 ; comparer segments vs grille |
| Régression UI (écran paie/suivi) | Moyen | Rollback front (§5) |

## 3. Diagnostiquer

```sql
-- Vue d'ensemble des invariants (cf. daily-checklist Bloc 1)
SELECT
 (SELECT count(*) FROM group_move_applications WHERE status='processing') AS orphan_processing,
 (SELECT count(*) FROM staff_planning_segments s WHERE EXISTS (SELECT 1 FROM staff_planning_segments t
    WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
      AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min))) AS overlaps;

-- Détail d'un salarié/jour suspect
SELECT staff_hours_day('<EMP_ID>','<JOUR>');                       -- décomposition attendue
SELECT * FROM staff_segment_hours('<EMP_ID>','<JOUR>');            -- part par hôtel
SELECT hotel_id, day, seg_start_min, seg_end_min, kind, status, source_proposal_id
FROM staff_planning_segments WHERE employee_id='<EMP_ID>' AND day='<JOUR>' ORDER BY seg_start_min;
SELECT hotel_id, day, status, shift_start, shift_end, source_proposal_id
FROM staff_planning WHERE employee_id='<EMP_ID>' AND day='<JOUR>';

-- Traçabilité d'une application de déplacement
SELECT * FROM group_move_proposal_events WHERE proposal_id='<PID>' ORDER BY created_at;
SELECT operation_id, count(*) FROM planning_audit WHERE employee_id='<EMP_ID>' GROUP BY operation_id;

-- Logs projet (via MCP Supabase get_logs / dashboard)
```

## 4. Revenir en legacy / désactiver le Feature Flag (RECOURS N°1)

```sql
-- Désactive le moteur segments pour le groupe pilote (instantané, réversible)
SELECT set_group_hours_source('<GROUP_PILOTE_ID>', 'legacy');
-- confirmer
SELECT id, name, coalesce(features->'hours'->>'source','legacy') FROM hotel_groups
WHERE id='<GROUP_PILOTE_ID>';
SELECT * FROM hotel_group_flag_audit ORDER BY changed_at DESC LIMIT 3;
```
Les écrans paie/suivi repassent **immédiatement** au calcul legacy. Aucune donnée
détruite. Voir `rollback.md` Niveau 1.

## 5. Rollback frontend (si régression UI)
`rollback.md` Niveau 2 (Vercel Instant Rollback ou `git revert`).

## 6. Vérifier la cohérence des données

```sql
-- 6a. Reconstruction : la grille se reprojette-t-elle exactement depuis les segments ?
--     (rejouer sur un salarié/jour, en transaction annulée pour ne rien changer)
BEGIN;
SELECT staff_planning_rebuild_day('<EMP_ID>','<JOUR>');
SELECT hotel_id, status, shift_start, shift_end FROM staff_planning
 WHERE employee_id='<EMP_ID>' AND day='<JOUR>' ORDER BY hotel_id;
ROLLBACK;

-- 6b. Garde-fou paie effectif ? (tester sur une période close, en transaction annulée)
BEGIN;
-- doit lever FL001 :
UPDATE staff_planning SET status=status WHERE employee_id='<EMP_ID>' AND day='<JOUR_CLOS>';
ROLLBACK;

-- 6c. Aucune divergence résumé/segments non tracée (garde d'intégrité)
--     Les lignes source_proposal_id non nulles ne peuvent être modifiées hors RPC.
```

Si 6a diverge, 6b n'échoue pas sur période close, ou 1b/overlaps ≠ 0 →
**incident CRITIQUE confirmé** : maintenir le rollback flag, geler les déplacements
sur le groupe, escalader, envisager `rollback.md` Niveau 3.

## 7. Clôture d'incident
- Rétablir l'état stable (flag legacy) et confirmer les invariants à 0.
- Rédiger un post-mortem : symptôme, cause, correctif, prévention.
- Décision Release Manager : reprise du pilote (re-`segments`) ou arrêt.

## Critères d'arrêt immédiat du pilote (kill-switch)
- Double compte d'heures en paie **confirmé**.
- Écriture aboutie sur période close (garde-fou défaillant).
- Chevauchement de segments persistant.
- Toute divergence paie non explicable et non corrigée sous 24 h.
