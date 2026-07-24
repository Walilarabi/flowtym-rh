# Procédure de déploiement — Flowtym RH RC1 (pilote interne)

Procédure complète et reproductible : **PR validée → merge → CI → staging →
validation → production → activation du flag → vérifications → fin**. Toutes les
commandes sont fournies. **Périmètre RC1 : migrations `sql/54` + `sql/55` et le
frontend associé (C1/C2).** Aucune évolution fonctionnelle.

## Acteurs & accès requis
- **Release Manager** : coordonne, valide les GO/NO-GO.
- **DBA / dev backend** : applique les migrations (accès Supabase projet prod
  `hzrzkvdebaadditvbqis` + branche de staging).
- **Frontend/DevOps** : suit le déploiement Vercel.
- Accès : GitHub (merge), Supabase (SQL editor / MCP `apply_migration`), Vercel.

## Artefacts déployés
| Artefact | Rôle |
|---|---|
| `sql/54_p0_hours_canonical.sql` | fonction canonique, garde-fou paie, flag, service_id |
| `sql/55_security_hardening.sql` | `security_invoker` sur la vue + `search_path` figé |
| `index.html` (C1/C2) | écrans paie/suivi branchés sur la fonction canonique (derrière flag) |
| `db/reconstruct/`, `scripts/ci/` | reconstruction + CI (déjà mergés) |

---

## Étape 0 — Pré-déploiement (voir `pilot-checklist.md` §avant)
GO/NO-GO initial. Ne pas continuer si un critère est NO-GO.

## Étape 1 — PR validée → Merge
```bash
# La PR #2 doit être verte (CI) et approuvée.
# Protection de branche `main` : exiger les checks 'frontend-syntax' et 'db-tests'.
# Merge via l'interface GitHub (squash recommandé) OU :
gh pr merge 2 --squash --delete-branch=false    # si gh disponible
```
**Vérification** : `main` contient `sql/54`, `sql/55`, `db/reconstruct/`, la CI verte.

## Étape 2 — CI (bloquante)
Au merge/push sur `main`, `.github/workflows/ci.yml` s'exécute :
- `frontend-syntax` (parse JS, refuse `debugger`) ;
- `db-tests` (reconstruit la base du dépôt + P0 24/24 + concurrence A–G).
```bash
# suivre le run
gh run list --branch main --limit 3
gh run watch      # ou via l'onglet Actions
```
**GO** si les 2 jobs sont verts. **NO-GO** sinon → corriger (correctif critique
uniquement), nouvelle PR, retour Étape 1.

## Étape 3 — Déploiement STAGING (branche Supabase)
> Pas de 2ᵉ projet Supabase disponible → on utilise une **branche de base de données**
> Supabase comme staging jetable (isolée de la prod).

```
# Via MCP Supabase (ou CLI supabase branches create) :
#   create_branch(project_id=hzrzkvdebaadditvbqis, name='rc1-staging')
# Puis appliquer les migrations SUR LA BRANCHE (jamais sur prod à ce stade) :
#   apply_migration(project_id=<branch_ref>, name='p0_hours', query=<contenu sql/54>)
#   apply_migration(project_id=<branch_ref>, name='security', query=<contenu sql/55>)
```
Alternative locale (au choix) : rejouer la reconstruction complète et les tests :
```bash
# sur une instance PostgreSQL jetable
PSQL="psql -d flowtym" db/reconstruct/rebuild.sh
psql -d flowtym -f scripts/p0/10_hours_tests.sql
psql -d flowtym -f scripts/p0/20_payroll_lock_tests.sql
psql -d flowtym -c "SELECT count(*) FILTER (WHERE pass)||'/'||count(*) FROM p0_results"  # attendu 24/24
```

## Étape 4 — Validation STAGING
Sur la branche/staging, exécuter les vérifications post-migration (§7) + un
sous-ensemble de la QA fonctionnelle (`pilot-checklist.md`). **GO** requis pour la prod.
```sql
-- objets présents ?
SELECT proname FROM pg_proc WHERE proname IN
 ('staff_hours_day','staff_hotel_hours_range','set_group_hours_source','_assert_payroll_open')
 ORDER BY 1;                                        -- attendu : 4 lignes
SELECT to_regclass('public.staff_payroll_periods'); -- non NULL
-- 0 ERROR advisor sécurité (via MCP get_advisors security) attendu.
```

## Étape 5 — Déploiement PRODUCTION (migrations)
> **Fenêtre de faible activité.** Migrations **additives** (aucune donnée modifiée) :
> nouvelles tables/fonctions/triggers + 1 vue recréée (`security_invoker`).

```
# Via MCP Supabase sur le PROJET PROD hzrzkvdebaadditvbqis :
#   apply_migration(project_id=hzrzkvdebaadditvbqis, name='54_p0_hours_canonical', query=<sql/54>)
#   apply_migration(project_id=hzrzkvdebaadditvbqis, name='55_security_hardening', query=<sql/55>)
```
**Important** : à ce stade, le flag reste `legacy` partout ⇒ **aucun changement de
comportement** pour les utilisateurs. Le moteur segments est déployé mais **inactif**.

## Étape 6 — Déploiement PRODUCTION (frontend)
Le merge sur `main` déclenche le déploiement Vercel de production automatiquement.
```bash
# vérifier le déploiement prod Ready
# (Vercel : projet flowtym-rh, déploiement de la branche main -> Production)
```
**Vérification** : l'app se charge, écrans paie/suivi affichent les valeurs **legacy**
(inchangées) tant que le flag n'est pas basculé.

## Étape 7 — Vérifications post-migration (prod, flag encore legacy)
```sql
-- garde-fou paie opérationnel (aucune période close par défaut)
SELECT count(*) FROM staff_payroll_periods WHERE status='closed';   -- 0 attendu au départ
-- vue sécurisée
SELECT reloptions FROM pg_class WHERE relname='v_staff_day_flags';  -- {security_invoker=on}
-- fonctions durcies
SELECT proname, proconfig FROM pg_proc
 WHERE proname IN ('trg_staff_planning_move_guard','_gmp_subtract');
```

## Étape 8 — Activation du Feature Flag (groupe pilote UNIQUEMENT)
```sql
-- identifier le groupe pilote
SELECT id, name FROM hotel_groups ORDER BY name;
-- activer
SELECT set_group_hours_source('<GROUP_PILOTE_ID>', 'segments');
-- confirmer + journal
SELECT id, name, features->'hours'->>'source' FROM hotel_groups WHERE id='<GROUP_PILOTE_ID>';
SELECT * FROM hotel_group_flag_audit ORDER BY changed_at DESC LIMIT 3;
```

## Étape 9 — Vérifications post-activation
Dérouler la **QA fonctionnelle** (`pilot-checklist.md`) sur le groupe pilote +
les contrôles d'anomalies (`daily-checklist.md`). Vérifier qu'un hôtel **hors** groupe
pilote reste en legacy (inchangé).

## Étape 10 — Fin de déploiement
- Consigner : horodatage, versions (`git rev-parse HEAD`), qui a fait quoi.
- Armer la **checklist quotidienne** (`daily-checklist.md`) pour la durée du pilote.
- Communiquer le **runbook d'incident** (`incident-runbook.md`) à l'astreinte.

---

## Récapitulatif GO / NO-GO par étape
| Étape | Critère GO | Sinon |
|---|---|---|
| 2 CI | 2 jobs verts | NO-GO → correctif |
| 4 Staging | objets présents + P0 24/24 + 0 ERROR advisor + QA partielle OK | NO-GO → ne pas passer en prod |
| 7 Post-migration prod | vue/fonctions durcies + garde-fou en place, comportement legacy inchangé | rollback migrations (`rollback.md`) |
| 9 Post-activation | QA fonctionnelle verte + 0 anomalie | rollback flag (`rollback.md`) |
