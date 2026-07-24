# Plan de rollback — Flowtym RH RC1

Trois niveaux de retour arrière, du plus rapide (préféré) au plus lourd. **Le
rollback par flag est le mécanisme de premier recours** : instantané, réversible,
sans perte de données.

## Niveau 1 — Rollback FLAG (recours immédiat, ~1 s)

**Quand** : anomalie de calcul d'heures / paie sur le groupe pilote, doute, incident.

```sql
SELECT set_group_hours_source('<GROUP_PILOTE_ID>', 'legacy');
-- confirmer
SELECT id, name, coalesce(features->'hours'->>'source','legacy')
FROM hotel_groups WHERE id='<GROUP_PILOTE_ID>';
SELECT * FROM hotel_group_flag_audit ORDER BY changed_at DESC LIMIT 3;
```
**Effet** : les écrans paie/suivi repassent **immédiatement** au calcul legacy
(comportement historique). **Aucune donnée détruite** : les segments et la grille
restent intacts ; on ne change que la source de lecture.

**Vérification post-rollback** : recharger l'écran paie du groupe → valeurs legacy.

## Niveau 2 — Rollback FRONTEND (Vercel)

**Quand** : régression d'affichage/JS introduite par le déploiement front (rare :
défaut legacy inerte).

```
# Vercel : projet flowtym-rh -> Deployments -> sélectionner le déploiement
# de production PRÉCÉDENT (stable) -> "Promote to Production" (Instant Rollback).
```
Alternative Git : `git revert <merge_commit>` sur `main` → redéploiement auto.
**Le rollback front n'affecte pas la base** ; combiner avec Niveau 1 si besoin.

## Niveau 3 — Rollback MIGRATIONS (base)

**Quand** : problème structurel avéré lié à `sql/54`/`55` (très improbable :
migrations additives, testées). **Les objets sont additifs** ⇒ leur retrait ne touche
pas les données métier existantes.

> ⚠️ Prérequis : le flag doit d'abord être en `legacy` (Niveau 1) pour tous les
> groupes, sinon le frontend appellera des RPC supprimés.

Ordre inverse (55 puis 54). Script de retrait ciblé :
```sql
BEGIN;
-- 55 : restaurer la vue (rester security_invoker est SANS risque ; retrait optionnel)
--   (aucune suppression nécessaire ; la vue reste valide)

-- 54 : retrait des objets P0 (dans l'ordre des dépendances)
DROP FUNCTION IF EXISTS public.staff_hotel_hours_range(uuid,date,date,numeric);
DROP FUNCTION IF EXISTS public.staff_hours_week(uuid,date,numeric);
DROP FUNCTION IF EXISTS public.staff_hours_day(uuid,date,numeric);
DROP FUNCTION IF EXISTS public.group_hours_source(uuid);
DROP FUNCTION IF EXISTS public.set_group_hours_source(uuid,text);
DROP TRIGGER  IF EXISTS trg_seg_fill_service ON public.staff_planning_segments;
DROP FUNCTION IF EXISTS public.trg_seg_fill_service();
DROP TRIGGER  IF EXISTS trg_payroll_lock_seg ON public.staff_planning_segments;
DROP TRIGGER  IF EXISTS trg_payroll_lock_sp  ON public.staff_planning;
DROP FUNCTION IF EXISTS public.trg_payroll_lock_segments();
DROP FUNCTION IF EXISTS public.trg_payroll_lock_planning();
DROP FUNCTION IF EXISTS public._assert_payroll_open(uuid,date);
DROP FUNCTION IF EXISTS public._payroll_period_locked(uuid,date);
-- service_id : conserver la colonne (inerte) ou la retirer explicitement :
-- ALTER TABLE public.staff_planning_segments DROP COLUMN IF EXISTS service_id;
DROP TABLE IF EXISTS public.hotel_group_flag_audit;
DROP TABLE IF EXISTS public.staff_payroll_periods;
-- restaurer group_move_apply dans sa version pré-P0 si nécessaire (voir historique
-- git : la version P0 est rétro-compatible ; un retrait n'est en général PAS requis).
COMMIT;
```
> Le `group_move_apply` corrigé (préservation des heures « journée entière ») est
> **rétro-compatible** avec la concurrence (revérifiée 7/7). Ne le restaurer que si un
> défaut spécifique est prouvé.

**Vérification post-rollback migrations** :
```sql
SELECT proname FROM pg_proc WHERE proname LIKE 'staff_hours%';  -- 0 ligne
SELECT to_regclass('public.staff_payroll_periods');            -- NULL
```

## Rollback COMPLET (séquence)
1. Niveau 1 (flag → legacy sur tous les groupes).
2. Niveau 2 (front → déploiement stable précédent).
3. Niveau 3 (migrations) **uniquement si** un défaut structurel est prouvé.
4. Vérifier la cohérence des données (`incident-runbook.md` §cohérence).
5. Post-mortem + décision de reprise.

## Ce qu'un rollback NE nécessite JAMAIS
- Restaurer un backup de données (aucune donnée métier n'est modifiée par P0 tant
  qu'aucun déplacement/segment n'est créé pendant le pilote).
- Toucher aux autres groupes (isolation par flag).
