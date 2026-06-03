# Flowtym RH — Changelog

## v1.0 — Lancement production

### Frontend
- Application mono-fichier avec **11 onglets** organisés en 5 groupes (Pilotage, Équipe, Temps, Acquisition, Réglages).
- Barre latérale rétractable avec préférence persistée localement.
- Authentification Supabase, multi-hôtel via `user_active_hotel`.
- **Tableau de bord** : KPI temps réel (effectif, jours travaillés, CP, fiches incomplètes), équipe, activité.
- **Planning** : grille mensuelle, colonnes nom/rôle figées adaptatives.
  - Édition cellule par cellule (popover) et **édition en masse** (glisser, Ctrl/Cmd-clic, Maj-clic, indicateur de cellules modifiées, Enregistrer/Annuler).
  - Recherche, filtres rôle/service/statut (Actif/Parti/Tous).
  - Synthèse par collaborateur, totaux par jour.
  - Import Excel (.xlsx) avec normalisation des noms et mapping des codes.
- **Reporting** : graphes effectif par service/rôle, top jours travaillés, top CP, répartition par statut.
- **Personnel** : cartes avec recherche et filtre statut.
- **Contrats** : tableau récapitulatif avec dates d'entrée et de départ.
- **Documents** : matrice complète, toggle Fourni/Manquant.
- **Paramètres** : CRUD services et rôles par hôtel.
- **Fiche collaborateur** : info complètes, documents, gestion Actif/Parti avec date de départ et réactivation possible.
- **Masquage automatique** des collaborateurs partis à partir du mois suivant leur date de départ ; historique préservé.

### Base de données
- 7 tables avec `hotel_id` partout, **RLS active** sur toutes (policy `hotel_id IN (SELECT pl_my_hotels())`).
- Contraintes CHECK sur statuts (P/CP/RTT/MAL/MAT/CSS/AE/F), types de contrat, statuts de documents, durée, dates.
- Unicité `(hotel_id, employee_id, day)` sur le planning. Triggers `updated_at`, index, vue `v_staff_month_summary`.
- Référentiels semés par hôtel (6 départements + 12 rôles).

### Migration
- Migration de données du prototype `pl_*` vers le nouveau modèle, sans perte (4 346 entrées validées identiques).
- Suppression propre des tables `pl_*` après vérification.

### Types
- Fichier `flowtym_rh.types.ts` aligné sur Supabase avec interfaces, types unions, helpers `Insert<>`/`Update<>` et type `RHDatabase`.

### Tests
- **52 tests jsdom** (rendu, navigation, édition, persistance, départs, sidebar).
- Tests SQL (contraintes, upsert, cascade, vue, dates).

## Roadmap (post-v1.0)

- **Pointage** : timestamps d'arrivée/départ.
- **Suivi du temps** : consolidation heures réelles vs planifiées.
- **Paie** : éléments variables, indemnités, export DSN.
- **Recrutement** : pipeline candidatures.
- **Upload réel des documents RH** via Supabase Storage.
- **Historique multi-période** des contrats dans `employee_contracts`.
- **Portage dans le monorepo React** (StaffPlanning.jsx & co.).
