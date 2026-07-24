# Design — futur moteur de couverture basé sur les segments (extension, non implémenté)

But : permettre demain une couverture calculée **directement depuis
`staff_planning_segments`** (présence réelle par tranche horaire), sans casser la
V1 basée sur le résumé. Ce document décrit le **design** et les **points
d'extension**. Aucune implémentation n'est demandée à ce stade.

## État V1 (rappel)
`group_planning(service, from, to)` calcule un **headcount par hôtel/jour** à
partir du **statut** de la grille (`CMAP.cat='worked'`). Granularité = jour.
Sûr pour la couverture journalière ; ne connaît pas la présence par tranche.

## Cible (segments)
Couverture par **hôtel × service × jour × tranche horaire**, dérivée des segments :
un jour fractionné contribue à chaque hôtel pour ses **heures exactes**.

## Points d'extension

### E1 — Sélecteur de source (sans rupture)
Config `hotel_groups.features.coverage.source ∈ {summary, segments}` (défaut
`summary`). `group_planning` lit ce flag et délègue :
- `summary` → chemin actuel (headcount/jour via statut) ;
- `segments` → nouveau chemin (ci-dessous).
Seam : une fonction `group_coverage(service, from, to, p_granularity)` qui, en V1,
appelle le chemin résumé ; en V2, le chemin segments. `group_planning` devient un
mince adaptateur.

### E2 — Dimension SERVICE sur les segments (seule migration nécessaire)
Aujourd'hui `staff_planning_segments` porte `hotel_id, kind, status`, **pas le
service**. Pour attribuer une présence à un service, ajouter **`service_id uuid`
(référence structurée vers `staff_departments.id`)** au segment — le **nom** de
service peut changer ou être dupliqué, l'identifiant doit donc être la référence ;
`service_name` reste une simple donnée d'affichage (dénormalisée, optionnelle).
Le segment sera rempli par `group_move_apply` depuis les services d'accueil /
d'origine résolus en **identifiants** (`host_service_id` pour l'Extra, sinon le
service principal). C'est **le** point d'extension structurant. (À défaut,
jointure via `source_proposal_id → group_move_proposals`, moins direct et non
structuré.)

### E3 — Requis par tranche (déjà prêt)
`group_staffing_requirements.shift` existe déjà (V1 = shift NULL au jour). Le
moteur segments comparera la présence d'une tranche au **requis de la tranche**
(`shift` non nul), réutilisant la logique centralisée `COVERAGE_LEVEL(prévu,
requis, seuils)` — **inchangée**.

### E4 — Calcul de présence par tranche
Découper la journée en tranches (ex. 30 min ou les shifts M/S/N). Pour chaque
hôtel/service/tranche :
`prévu = count(DISTINCT employee_id)` parmi les segments `kind IN (destination,origin)`
au statut travaillé dont l'intervalle `[seg_start_min, seg_end_min)` **chevauche**
la tranche. La contrainte d'exclusion garantit l'unicité (pas de double présence).

### E5 — Indicateurs déjà disponibles
`v_staff_day_flags` (is_segmented, has_multiple_statuses…) permet au moteur et aux
écrans de savoir quand basculer du résumé vers les segments.

## Contrat de sortie cible (indicatif)
```
group_coverage(service, from, to, granularity 'day'|'slot') -> cells[
  { hotel_id, day, slot?, prevu, requis, level, source: 'summary'|'segments' }
]
```
Le champ `source` rend explicite d'où vient chaque cellule (traçabilité).

## Migration progressive (non demandée maintenant)
1. Ajouter `service_name` aux segments (E2) + le remplir dans `group_move_apply`.
2. Implémenter le chemin `segments` de `group_coverage` (E1/E4).
3. Basculer `coverage.source=segments` par groupe, en observation, avant
   généralisation.
Aucune de ces étapes n'est réalisée ici : uniquement le design et les seams.
