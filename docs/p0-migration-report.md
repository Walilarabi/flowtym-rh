# Rapport de migration P0 — heures via `staff_planning_segments` (GO/NO-GO)

> Développé et **testé sur cluster PostgreSQL 16 local jetable** (schéma reconstruit
> en DDL seul, seed 100 % fictif). **Aucune application en production.** Migration
> livrée en fichier `sql/54_p0_hours_canonical.sql` (DDL runnable). Drag & Drop, P1,
> facturation premium, activation générale : **non démarrés**.

## Règles appliquées (R1–R8, validées)

R1 segments = seule source de vérité · R2 grille = projection journalière ·
R3 calcul heures (pauses, chevauchements interdits, multi-hôtels, minuit=2 segments) ·
R4 additivité sans doublon · **R5 garde-fou paie clôturée RÉEL** · R6 `service_id` ·
R7 **fonction canonique unique** · R8 **feature flag** `hours.source` (défaut legacy).

## Ce qui est livré

### Fonction canonique unique (R7)
`staff_hours_day(emp, jour, hpd)` → JSON explicable :
`{ source, gross_hours, break_hours, net_hours, by_hotel[], by_service[], total_net }`.
`staff_hours_week(emp, lundi, hpd)` agrège 7 jours. `staff_hotel_hours_range(hotel,
from, to)` = part de l'hôtel par (salarié, jour) pour la paie/suivi. **net = somme
des durées de présence des segments → aucun double compte** ; un marqueur « journée
entière » vaut `hpd`, pas 24 h.

### Garde-fou paie clôturée (R5, réel — pas un stub)
Table `staff_payroll_periods` + triggers `BEFORE INSERT/UPDATE/DELETE` sur
`staff_planning` **et** `staff_planning_segments`. Toute écriture touchant une
période **`closed`** est refusée avec **SQLSTATE `FL001`**, **sans écriture partielle**
(rollback de transaction). Couvre les 6 chemins exigés : création / modification /
suppression de segment, écriture grille, **`group_move_apply`** (refus **atomique**),
**`staff_planning_rebuild_day`**. Sans effet tant qu'aucune période n'est close.

### service_id (R6)
Colonne `service_id` ajoutée aux segments + peuplement automatique (trigger de
résolution nom→id selon l'hôtel et le sens du déplacement). Ventilation
`by_service` dans la fonction canonique.

### Feature flag (R8)
`hotel_groups.features.hours.source ∈ {legacy, segments}`, **défaut legacy**.
`set_group_hours_source(group, source)` : activation **manuelle par groupe**,
**journalisée** (`hotel_group_flag_audit`), réversible, **ne contourne jamais** le
garde-fou paie. Aucun basculement automatique.

### Correctif `group_move_apply` (R5 — ne supprime pas d'heures)
Un déplacement « journée entière » **préserve désormais l'intervalle réel de
l'origine** (ex. 08–16 = 8 h) au lieu d'un marqueur `0..1440` qui aurait été compté
`hpd` (perte d'heures). Logique concurrence **inchangée** (revérifiée, cf. ci-dessous).

## Étape 5 — Tests (entrée / attendu / obtenu / PASS-FAIL)

**24 / 24 PASS.** Harnais rejouable : `scripts/p0/10_hours_tests.sql` (heures) et
`scripts/p0/20_payroll_lock_tests.sql` (paie close).

| Test | Cas | Attendu | Obtenu | Verdict |
|---|---|---|---|---|
| T1 | journée complète 1 hôtel (VO 08–16) | 8.00, 1 hôtel | 8.00 hotels=1 | PASS |
| T2 | journée partielle (VO 09–13) | 4.00 | 4.00 | PASS |
| T3 | 2 segments même hôtel + pause | net 8 / pause 2 / brut 10 | idem | PASS |
| T4 | 2 hôtels même jour | 8.00, 2 hôtels | 8.00 hotels=2 | PASS |
| T5 | déplacement réduit l'origine | 8.00 (FO 4 / VO 4) | idem | PASS |
| T6 | déplacement coupe au milieu | 8.00, 2 seg origine (FO 6 / VO 2) | idem | PASS |
| T7 | pause unique | 2.00 | 2.00 | PASS |
| T8 | plusieurs pauses | net 6 / pause 4 | idem | PASS |
| T9 | passage minuit = 2 segments/2 jours | j1 2 / j2 6 | idem | PASS |
| T10 | aucun doublon (jour complet déplacé) | 8.00 (pas 16/24) | 8.00 | PASS |
| T11 | absence partielle (matin travaillé) | 4.00 | 4.00 | PASS |
| T12 | journée non travaillée | 0.00 | 0.00 | PASS |
| T14 | reconstruction depuis segments | net inchangé 8.00 | 8.00 | PASS |
| T15 | parité legacy jour compatible | 8.00 = legacy 8.00 | idem | PASS |
| SVC | ventilation par `service_id` (T5) | 2 services, total 8.00 | idem | PASS |
| WEEK | agrégat semaine (7 jours) | total ≥ 0, 7 jours | idem | PASS |
| **P1** | création segment / période close | refus FL001 | refus FL001 | PASS |
| **P2** | modification segment / close | refus FL001 | refus FL001 | PASS |
| **P3** | suppression segment / close | refus FL001 | refus FL001 | PASS |
| **P4** | écriture grille / close | refus FL001 | refus FL001 | PASS |
| **P5** | `group_move_apply` / close | refus FL001 (atomique) | refus FL001 | PASS |
| **P5b** | atomicité : proposition non appliquée | aucune application | confirmé | PASS |
| **P6** | `staff_planning_rebuild_day` / close | refus FL001 | refus FL001 | PASS |
| **P7** | même écriture / période OUVERTE | autorisé | autorisé | PASS |

> Note T13 (« paie déjà clôturée ») = groupe de tests **P1–P7** ci-dessus.

### Non-régression concurrence (RPC modifié)
Runbook A–G rejoué avec le `group_move_apply` corrigé : **7/7 PASS**, 0 deadlock,
0 chevauchement de segments, 0 orphelin `processing`. Le correctif « journée entière »
ne modifie pas les invariants de verrou/idempotence/exclusion.

## Étape 6 — Consommateurs : migrés vs legacy

| # | Consommateur | État | Détail |
|---|---|---|---|
| C1 | Paie — éléments variables | **Migré (derrière flag)** | `drawPayroll` utilise `staff_hotel_hours_range` quand `hours.source='segments'` ; **défaut legacy inchangé**. |
| C2 | Suivi du temps | **Prêt** | même RPC `staff_hotel_hours_range` ; branchement identique à C1 (à activer après QA navigateur). |
| C3 | Compteurs légaux (35/39/48 h) | **Prêt** | heures hebdo via `staff_hours_day`/`staff_hours_week` (total cross-hôtel exact). |
| C4 | `v_staff_month_summary` | **Prêt** | vue heures dérivée des segments (les *jours* restent au statut). |
| C5 | `check_replacement_constraints` | **Prêt** | heures hebdo via `staff_hours_day`. |
| C7-officiel | Exports paie/comptable | **Suivent C1** | l'export CSV paie consomme les mêmes `plannedH` recalculés. |
| C6 / C7-reporting | Portail / exports informatifs | **P0-bis** | purement visuels, aucun calcul financier. |

**Encore en lecture legacy** (assumé) : `group_planning` (couverture au statut),
`find_replacement_candidates`, portail salarié (affichage), exports informatifs.

## Écarts / limites explicites
- **service_id** peuplé par résolution **nom→id** (best-effort) ; `NULL` si le nom ne
  correspond pas. La dimension service complète (segments saisis nativement) reste **P1**.
- Frontend : seul **C1 est câblé** (derrière flag, inerte par défaut). C2–C5 utilisent
  la même API canonique ; leur activation demande une **QA navigateur** (non exécutable
  dans cet environnement — seul le socle DB est prouvé au runtime ici).
- `staff_hours_day` `hpd` par défaut = 7 ; le frontend passe le `hpd` réel du salarié.

## Recommandation

**GO pour un pilote interne** du moteur d'heures segments, **activé manuellement sur
UN groupe** via `set_group_hours_source(..., 'segments')`, après **QA navigateur** des
écrans C1 (paie) sur ce groupe. Le garde-fou paie clôturée et le défaut legacy rendent
l'activation **réversible et sans risque** pour les autres groupes.

**Non démarrés** (conformément à la consigne) : Drag & Drop, activation générale,
migration P1, facturation premium. Aucune modification en production.
