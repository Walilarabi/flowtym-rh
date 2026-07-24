# Migration P0 — Audit des consommateurs & règles fonctionnelles (à valider)

> Périmètre P0 : router **tous les calculs critiques d'heures / paie / exports**
> vers `staff_planning_segments` comme **source de vérité**, `staff_planning`
> restant une **projection journalière**. **Aucun code n'est modifié dans ce
> document** (Étapes 2 & 3). Hors périmètre : Drag & Drop, activation générale
> des déplacements, P1, facturation premium.

## Rappel — primitives canoniques déjà en base (Modèle A)

Deux fonctions existent déjà en base et constituent la **base canonique** de la
migration (extraites verbatim du schéma live) :

```sql
-- Total JOUR d'un salarié (cross-hôtel), segments-first, sinon grille :
staff_day_hours(p_emp uuid, p_day date, p_default_hpd numeric DEFAULT 7) RETURNS numeric
--   = round(sum(seg_end_min-seg_start_min)/60,2) s'il existe des segments ;
--     sinon coalesce(hours, durée shift, hpd) depuis la grille ; sinon 0.

-- Ventilation PAR HÔTEL d'un jour (exact, depuis les segments) :
staff_segment_hours(p_emp uuid, p_day date) RETURNS TABLE(hotel_id, minutes, hours)
```

`staff_day_hours` **ne double jamais** un jour fractionné (somme des minutes de
présence). `staff_segment_hours` donne la part **par hôtel** (pour une paie/coût
par établissement). Ce sont les deux seules dimensions nécessaires en P0.

---

## Étape 2 — Audit P0 définitif des consommateurs

Légende risque : 🔴 élevé (financier direct) · 🟠 moyen (seuils légaux / RH) ·
🟡 faible (affichage). « cross-hôtel » = sur-compte d'un jour fractionné/déplacé.

### C1 — 🔴 Paie · Éléments variables (export logiciel de paie)
- **Fichier / fonction** : `index.html` — `drawPayroll()` (~L14320), `exportPayrollCSV()` (~L14409).
- **Requête actuelle** : `BE.listMonthPlanning(hotelId,y,m)` → `staff_planning`
  (par hôtel), + `listClockingsByRange` (pointages).
- **Source actuelle** : grille. `presenceH += (cell.hours>0 ? cell.hours : hpd)`
  par jour `P`/`PE` ; HS (25 %/50 %) dérivées de `presenceH` planifié et pointages.
- **Risque métier** : 🔴 **double compte cross-hôtel** — un jour `PE` déplacé est
  compté **hpd complet côté destination** ET conserve une présence côté origine
  ⇒ heures planifiées et **éléments variables de paie faussés** ; export envoyé
  au logiciel de paie.
- **Stratégie de migration** : remplacer le cumul par jour par
  `staff_segment_hours(emp,day)` filtré sur `hotel_id` courant (paie **par
  établissement**) ; total salarié via `staff_day_hours`. Fallback grille
  **uniquement** si aucun segment ET jour non déplacé.
- **Tests** : T1, T3, T4, T5, T6, T10, T13, T15 (cf. Étape 5).

### C2 — 🟠 Suivi du temps (planifié vs pointé)
- **Fichier / fonction** : `index.html` — `drawTracking()` (~L14170),
  `exportTrackingCSV()` (~L14255).
- **Requête / source** : `staff_planning` par hôtel ; heures planifiées =
  `hours` sinon `hpd` par jour travaillé.
- **Risque** : 🟠 heures planifiées **sur-comptées** sur jours fractionnés ;
  l'écart planifié/pointé devient trompeur (KPI de pilotage, non paie directe).
- **Migration** : heures planifiées via `staff_segment_hours` (part hôtel) ;
  total via `staff_day_hours`.
- **Tests** : T1, T3, T4, T5, T10.

### C3 — 🟠 Compteurs légaux & alertes (seuils 35/39/48 h, 6-7 j consécutifs)
- **Fichier / fonction** : `index.html` — `_planLegalAlerts()` (~L2985) et le
  bloc compteurs de `renderPlanning`/`drawGrid` (~L2904-3010) : `_hpdMap`,
  `e.hours = e.hours + hpd`.
- **Source** : statut de la grille × `hpd` (barème), **pas** les heures réelles.
- **Risque** : 🟠 heures hebdo = jours travaillés × hpd ⇒ un jour partiel/déplacé
  compte **une journée pleine** ; seuils légaux (48 h, HS) calculés faux.
- **Migration** : heures hebdo du salarié via **`staff_day_hours` par jour**
  (total cross-hôtel exact), agrégées par semaine ISO ; conserver le comptage de
  **jours** (statut) pour la règle « 6/7 jours consécutifs ».
- **Tests** : T1, T2, T3, T4, T5, T10, T11.

### C4 — 🟠 Vue `v_staff_month_summary`
- **Fichier** : `sql/01_rh_staff_module_schema.sql:148`.
- **Requête / source** : `sum(duration) FILTER (status='P')` par hôtel/mois
  (grille).
- **Risque** : 🟠 `worked_days` **sur-compté cross-hôtel** sur jours déplacés ;
  consommée par RH / synthèses.
- **Migration** : ajouter une vue/colonne dérivée des segments pour les **heures**
  (les *jours* de couverture restent OK au statut) ; documenter que
  `worked_days` = jours de couverture, **pas** des heures.
- **Tests** : T4, T10, T14.

### C5 — 🟠 `check_replacement_constraints` (heures hebdo pour remplacements)
- **Emplacement** : fonction en base (définie via migration MCP ; **absente du
  dépôt** — à extraire du schéma live pour la migration).
- **Source** : `shift_start/end` + `hours` de la grille.
- **Risque** : 🟠 heures hebdo inexactes sur jours fractionnés → décisions de
  remplacement biaisées (pas de paie directe).
- **Migration** : heures hebdo via `staff_day_hours`.
- **Tests** : T3, T4, T5.

### C6 — 🟡 Portail salarié (affichage planning)
- **Fichier** : `portal.html` (~L898-1030) — affichage `shift_start/end`,
  `hours`, statut par hôtel/jour. (Les **pointages** y sont calculés depuis les
  clockings, hors périmètre.)
- **Risque** : 🟡 affichage : un salarié déplacé voit `08-16` à l'origine alors
  qu'il est partiellement ailleurs.
- **Migration** : afficher les **segments** pour les jours `source_proposal_id`.
- **Tests** : T5, T6, T9 (affichage).

### C7 — 🟡 Exports PDF / Excel du planning & grille manager
- **Fichier** : `index.html` — `exportExcel()`, `exportPDF()`, rendu grille.
- **Risque** : 🟡 bornes `08-16` non exactes pour un jour fractionné (document
  visuel / pièce sociale).
- **Migration** : annoter/afficher les segments sur les jours déplacés.
- **Tests** : T5, T6, T14.

### Consommateurs NON-P0 (rappel, restent en lecture legacy)
`group_planning` (couverture au **statut**, sûr), `find_replacement_candidates`
(disponibilité au statut), `pl_portal_hotels`, `portal_request_decide`,
`portal_leave_balances`, Edge Functions/cron (aucun calcul d'heures). Aucune
migration requise ; documenté comme legacy assumé.

---

## Étape 3 — Règles fonctionnelles (À VALIDER avant tout développement)

### R1 — Source de vérité unique
`staff_planning_segments` est **la seule source de vérité des heures et durées**.
Aucun calcul financier ou d'heures ne lit `end - start` sur la grille d'un jour
fractionné, ni ne cumule des jours travaillés entre hôtels.

### R2 — Rôle de `staff_planning`
Projection **journalière** réservée à : (a) affichage synthétique, (b)
compatibilité temporaire, (c) **statuts** journaliers et couverture. Jamais
traitée comme source de vérité des heures.

### R3 — Calcul des heures travaillées
Toujours dérivé de : `seg_start_min`, `seg_end_min`, pauses (exclues du temps de
présence), **chevauchements interdits** (contrainte d'exclusion GiST), **segments
multi-hôtels** (un segment par présence), **segments partiels**, et **passage à
minuit** représenté par **deux segments sur deux jours** (aucun segment ne
franchit minuit ; borné 0..1440).

### R4 — Additivité sans doublon
Une journée à plusieurs segments **additionne les durées de présence** ; aucune
période continue n'est déduite de `min(start)…max(end)`. Total salarié =
`staff_day_hours` ; ventilation par hôtel = `staff_segment_hours`.

### R5 — Invariants du déplacement inter-hôtels
Un déplacement ne doit **jamais** : (a) doubler des heures, (b) supprimer des
heures, (c) doubler des pauses, (d) **modifier rétroactivement une paie déjà
clôturée**. ⇒ Toute recomputation d'un jour appartenant à une **période de paie
verrouillée** est **refusée** (garde de période close, à implémenter ; par défaut
aucune période n'est close tant que le verrou n'existe pas — comportement
inchangé).

### R6 — Clé fonctionnelle service
Utiliser **`service_id`** (référence vers `staff_departments.id`) comme clé
fonctionnelle, jamais `service_name` (affichage/dénormalisé). *Note* : les
segments ne portent pas encore `service_id` (extension E2 du design couverture) ;
le calcul d'heures P0 **ne dépend pas du service** (heures par hôtel), donc R6
s'applique dès qu'un service sert de clé (requis/couverture) et conditionne P1.

### R7 — Fonction canonique unique (principe d'implémentation)
Un **seul** point de calcul des heures (au-dessus de `staff_day_hours` /
`staff_segment_hours`) ; interdiction de dupliquer la formule dans plusieurs
modules. Les consommateurs C1-C7 l'appellent au lieu de lire la grille.

### R8 — Déploiement progressif
Nouveau moteur derrière un **feature flag par groupe/hôtel**
(`hotel_groups.features.hours.source ∈ {legacy, segments}`, défaut `legacy`).
**Pas d'activation générale automatique** ; fallback legacy explicite et
documenté tant que le flag est `legacy`.

---

## Ce que j'attends de votre validation

1. **Périmètre P0** : C1-C7 sont-ils les bons consommateurs ? (C6/C7 sont
   affichage — à inclure en P0 ou repousser ?)
2. **Règles R1-R8**, en particulier **R5** (garde de période de paie close : la
   crée-t-on maintenant ou la stub-t-on ?) et **R8** (nom exact du feature flag).
3. **R6/service_id** : confirmez que P0 se limite aux **heures** (sans toucher au
   service) et que l'ajout de `service_id` aux segments reste **P1**.

Après validation, j'implémente l'Étape 4 (fonction canonique + branchement des
lectures critiques derrière le flag), puis l'Étape 5 (15 tests avec entrée /
attendu / obtenu / PASS-FAIL) et l'Étape 6 (rapport GO/NO-GO pilote interne).
**Je ne démarre rien avant votre feu vert.**
