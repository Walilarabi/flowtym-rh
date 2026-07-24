# Checklist quotidienne — pilote Flowtym RH (moteur segments)

À exécuter **chaque jour ouvré** pendant toute la durée du pilote, par l'astreinte
ou le Release Manager. Objectif : détecter toute dérive **avant** qu'elle n'impacte la
paie. Toutes les requêtes ci-dessous doivent renvoyer le résultat attendu ; sinon →
`incident-runbook.md`.

## Bloc 1 — Invariants de données (doivent tous être à 0)

```sql
-- 1a. Aucun verrou d'idempotence coincé
SELECT count(*) AS orphan_processing FROM group_move_applications WHERE status='processing';
-- attendu : 0

-- 1b. Aucun chevauchement de segments (double présence)
SELECT count(*) AS segment_overlap FROM staff_planning_segments s
WHERE EXISTS (SELECT 1 FROM staff_planning_segments t
  WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
    AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min));
-- attendu : 0

-- 1c. operation_id unique par application (pas de mélange)
SELECT count(*) AS multi_operation FROM (
  SELECT sp.source_proposal_id
  FROM staff_planning sp JOIN group_move_proposals p ON p.id=sp.source_proposal_id
  WHERE p.applied_operation_id IS NOT NULL
  GROUP BY sp.source_proposal_id, p.applied_operation_id
  HAVING count(DISTINCT p.applied_operation_id) > 1) z;
-- attendu : 0

-- 1d. Écriture planning issue d'un déplacement SANS audit correspondant
SELECT count(*) AS audit_mismatch FROM staff_planning sp
JOIN group_move_proposals p ON p.id=sp.source_proposal_id
WHERE p.applied_operation_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM planning_audit a WHERE a.operation_id=p.applied_operation_id);
-- attendu : 0
```

## Bloc 2 — Feature flag & périmètre

```sql
-- 2a. Seul le groupe pilote est en 'segments'
SELECT id, name, coalesce(features->'hours'->>'source','legacy') AS src
FROM hotel_groups ORDER BY src DESC, name;
-- attendu : uniquement le groupe pilote en 'segments', tous les autres 'legacy'

-- 2b. Aucune bascule de flag non planifiée dans les dernières 24 h
SELECT changed_at, group_id, old_value, new_value, changed_by
FROM hotel_group_flag_audit
WHERE flag_path='hours.source' AND changed_at > now() - interval '24 hours'
ORDER BY changed_at DESC;
-- attendu : uniquement des bascules connues/planifiées
```

## Bloc 3 — Garde-fou paie

```sql
-- 3a. Aucune écriture bloquée inattendue : vérifier les périodes closes
SELECT hotel_id, period_start, period_end, status FROM staff_payroll_periods
WHERE status='closed' ORDER BY period_start DESC;
-- attendu : uniquement les périodes réellement clôturées par la paie
```
> Un refus `FL001` côté application est **normal** si l'utilisateur tente de modifier
> une période close. Ce n'est un incident que s'il survient sur une période **ouverte**.

## Bloc 4 — Rapprochement paie (échantillon)

```sql
-- 4a. Comparer, pour un salarié déplacé, la part par hôtel (doit sommer au réel)
SELECT * FROM staff_hotel_hours_range('<HOTEL_ID>', date_trunc('month',now())::date, now()::date);
-- 4b. Total salarié/jour (cross-hôtel, sans double compte)
SELECT staff_hours_day('<EMP_ID>', '<JOUR>');   -- net_hours = somme réelle des présences
```
Croiser avec l'écran Paie : **les heures d'un jour déplacé ne doivent jamais être
doublées** entre les deux hôtels.

## Journal quotidien (à remplir)

| Date | 1a | 1b | 1c | 1d | 2a | 2b | 3a | Rappro paie | Incident ? | Par |
|---|---|---|---|---|---|---|---|---|---|---|
| | 0 | 0 | 0 | 0 | OK | OK | OK | OK | non | |

**Si une seule case ≠ attendu → déclencher `incident-runbook.md`.**
