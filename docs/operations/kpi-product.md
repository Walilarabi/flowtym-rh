# KPI produit — pilote Flowtym RH

Indicateurs pour évaluer **objectivement** le succès du pilote, **sans modifier le
code**. Pour chacun : définition · mode de calcul · objectif cible · seuil d'alerte ·
**mesurabilité** (ce qui est calculable depuis les données existantes vs ce qui exige
une saisie manuelle / une instrumentation reportée en RC2).

> Sources de données existantes : `planning_audit` (écritures planning, `operation_id`,
> `source`, `created_at`), `group_move_proposal_events` (cycle de vie des déplacements),
> `group_move_applications`, `hotel_group_flag_audit`, `staff_planning_segments`,
> registres `pilot-incidents.md` / `user-feedback.md`. **Aucune nouvelle table n'est
> créée pour le pilote** (gel).

---

## 1. Temps moyen de création d'un planning
- **Définition** : durée entre la première et la dernière écriture d'un même lot de
  saisie de planning (mois/hôtel).
- **Calcul (proxy)** : par `operation_id` dans `planning_audit`,
  `max(created_at) − min(created_at)`. *Proxy* : mesure la durée d'enregistrement, pas
  le temps de réflexion utilisateur.
  ```sql
  SELECT operation_id, count(*) AS lignes,
         (max(created_at)-min(created_at)) AS duree_saisie
  FROM planning_audit WHERE created_at::date = CURRENT_DATE
  GROUP BY operation_id ORDER BY duree_saisie DESC;
  ```
- **Cible** : ≤ 10 min pour un mois complet d'un hôtel (indicatif).
- **Seuil d'alerte** : > 30 min récurrent, ou abandons signalés.
- **Mesurabilité** : ⚠️ proxy (le temps réel « front » exigerait une instrumentation RC2).

## 2. Temps moyen d'un remplacement (déplacement inter-hôtels)
- **Définition** : durée entre la création d'une proposition de renfort et son application.
- **Calcul** : depuis `group_move_proposal_events`, `applied.created_at − created.created_at`.
  ```sql
  SELECT p.id,
         min(e.created_at) FILTER (WHERE e.action='created')  AS cree,
         min(e.created_at) FILTER (WHERE e.action='applied')  AS applique,
         (min(e.created_at) FILTER (WHERE e.action='applied')
          - min(e.created_at) FILTER (WHERE e.action='created')) AS delai
  FROM group_move_proposals p JOIN group_move_proposal_events e ON e.proposal_id=p.id
  WHERE p.status='applied' GROUP BY p.id ORDER BY delai;
  ```
- **Cible** : médiane ≤ 1 jour ouvré (création → application).
- **Seuil d'alerte** : médiane > 3 jours (frein d'adoption).
- **Mesurabilité** : ✅ mesurable.

## 3. Nombre de modifications quotidiennes (activité planning)
- **Définition** : volume d'écritures planning par jour sur le groupe pilote.
- **Calcul** :
  ```sql
  SELECT created_at::date AS jour, count(*) AS ecritures,
         count(DISTINCT operation_id) AS lots, count(DISTINCT actor_auth_id) AS acteurs
  FROM planning_audit
  WHERE created_at >= CURRENT_DATE - 7 GROUP BY 1 ORDER BY 1;
  ```
- **Cible** : activité régulière et non nulle les jours ouvrés (preuve d'usage réel).
- **Seuil d'alerte** : 0 écriture plusieurs jours ouvrés consécutifs (désengagement).
- **Mesurabilité** : ✅ mesurable.

## 4. Taux d'utilisation des fonctionnalités
- **Définition** : part relative des usages (saisie planning, déplacement, paie/suivi).
- **Calcul (proxy)** : répartition de `planning_audit.source` + nombre de déplacements
  (`group_move_applications`) + nombre d'exports (non tracé DB → observation manuelle).
  ```sql
  SELECT source, count(*) FROM planning_audit
  WHERE created_at >= CURRENT_DATE - 7 GROUP BY source ORDER BY 2 DESC;
  ```
- **Cible** : le déplacement inter-hôtels (cœur du pilote) est réellement utilisé (> 0 /semaine).
- **Seuil d'alerte** : fonctionnalité cible du pilote **jamais** utilisée sur une semaine.
- **Mesurabilité** : ⚠️ partiel (exports/paie non instrumentés côté DB → observation).

## 5. Satisfaction utilisateur
- **Définition** : perception de justesse et d'utilité (surtout justesse des heures/paie).
- **Calcul** : mini-enquête hebdo (échelle 1–5) + synthèse `user-feedback.md`.
- **Cible** : moyenne ≥ 4/5 ; **retour paie positif** sur la justesse des heures.
- **Seuil d'alerte** : moyenne < 3/5 ou tout signalement « heures fausses ».
- **Mesurabilité** : ✍️ manuel (enquête).

## 6. Incidents par utilisateur
- **Définition** : nombre d'incidents rapportés rapporté au nombre d'utilisateurs actifs.
- **Calcul** : `# incidents (pilot-incidents.md) / # utilisateurs actifs` sur la période.
- **Cible** : ≤ 0,5 incident / utilisateur / semaine.
- **Seuil d'alerte** : > 1 incident / utilisateur / semaine, ou tout incident **critique**.
- **Mesurabilité** : ✍️ manuel (registre).

## 7. Incidents par hôtel
- **Définition** : concentration des incidents par établissement.
- **Calcul** : agrégation `pilot-incidents.md` par colonne *Hôtel*.
- **Cible** : répartition homogène, aucun hôtel « point chaud ».
- **Seuil d'alerte** : un hôtel concentrant > 50 % des incidents.
- **Mesurabilité** : ✍️ manuel (registre).

## 8. Stabilité quotidienne
- **Définition** : respect des invariants de données chaque jour (cf. `daily-checklist.md`).
- **Calcul** : les 4 contrôles doivent renvoyer **0** :
  ```sql
  SELECT
   (SELECT count(*) FROM group_move_applications WHERE status='processing') AS orphelins,
   (SELECT count(*) FROM staff_planning_segments s WHERE EXISTS (SELECT 1 FROM staff_planning_segments t
      WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id
        AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min))) AS chevauchements;
  ```
- **Cible** : **100 % de jours « verts »** (tous invariants à 0).
- **Seuil d'alerte** : **tout** jour non vert (déclenche `incident-runbook.md`).
- **Mesurabilité** : ✅ mesurable (bloquant).

---

## Tableau de bord hebdomadaire (à remplir)

| KPI | Cette semaine | Cible | Seuil alerte | État |
|---|---|---|---|---|
| 1. Temps création planning (proxy) | | ≤ 10 min | > 30 min | |
| 2. Délai remplacement (médiane) | | ≤ 1 j | > 3 j | |
| 3. Modifications/jour | | > 0 (ouvrés) | 0 plusieurs jours | |
| 4. Usage déplacement /sem. | | > 0 | 0 | |
| 5. Satisfaction (1–5) | | ≥ 4 | < 3 | |
| 6. Incidents/utilisateur | | ≤ 0,5 | > 1 | |
| 7. Hôtel « point chaud » | | non | > 50 % | |
| 8. Jours verts (stabilité) | | 100 % | tout jour rouge | |

> **Note d'honnêteté** : les KPI marqués ⚠️/✍️ ne sont pas pleinement instrumentés dans
> RC1 (gel). Leur instrumentation « produit » (mesure front, événements d'usage) est une
> demande **RC2** (`D1 observabilité`). Pendant le pilote, on s'appuie sur les proxys DB
> et la saisie manuelle décrits ci-dessus.
