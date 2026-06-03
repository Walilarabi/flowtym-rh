# Flowtym RH — Changelog

## v1.1 — Gestion des accès par rôle

### Frontend
- **Matrice de permissions** pour les 9 rôles existants (direction, admin_hotel, comptabilite, revenue_manager, reception, gouvernante, maintenance, breakfast, femme_de_chambre) — alignée sur le référentiel `admin_user_role` partagé avec le PMS.
- **Filtrage automatique des onglets** dans la barre latérale selon le rôle de l'utilisateur connecté pour l'hôtel actif.
- **Fiche collaborateur restreinte** pour les rôles opérationnels : nom, prénom, poste, service, statut, téléphone et e-mail uniquement. Pas de documents, pas d'adresse personnelle, pas de contact d'urgence, pas d'action Modifier ni Marquer comme parti.
- **Badge du rôle dans la topbar** pour que l'utilisateur sache toujours dans quel contexte il opère.
- Nouveau bloc **Accès et permissions** dans Paramètres :
  - Liste des utilisateurs rattachés à l'hôtel avec leur rôle (dropdown éditable).
  - Confirmation avant chaque changement de rôle, rollback en cas d'erreur API.
  - Matrice de référence des permissions en lecture sous le tableau.
- **Refresh complet de la shell** au changement d'hôtel (le rôle peut différer d'un hôtel à l'autre pour un même utilisateur).
- **Exports Planning Excel et PDF** (PDF en A4 paysage, table pleine page, cellules colorées selon les statuts, multi-page avec en-tête répété et numéro de page).

### Base de données
- Migration `05_rh_access_management_functions.sql` :
  - `rh_my_role(p_hotel)` : retourne le rôle de l'utilisateur courant pour un hôtel donné.
  - `rh_list_users_for_hotel(p_hotel)` : liste tous les utilisateurs rattachés à l'hôtel. Réservée aux rôles `direction` et `admin_hotel`.
  - `rh_update_user_role(p_hotel, p_user_id, p_role)` : modifie le rôle d'un utilisateur. Réservée aux rôles `direction` et `admin_hotel`. Empêche l'auto-modification.
- Toutes en `SECURITY DEFINER` avec vérification du rôle de l'appelant à chaque appel. N'affecte ni les tables existantes ni les policies du PMS.

### Tests
- 68 tests jsdom (rendu, navigation, édition, persistance, départs, sidebar, exports, permissions).

## v1.0 — Lancement production

### Frontend
- Application mono-fichier avec **11 onglets** organisés en 5 groupes (Pilotage, Équipe, Temps, Acquisition, Réglages).
- Barre latérale rétractable avec préférence persistée localement.
- Authentification Supabase, multi-hôtel via `user_active_hotel`.
- **Tableau de bord** : KPI temps réel (effectif, jours travaillés, CP, fiches incomplètes).
- **Planning** : grille mensuelle, colonnes nom/rôle figées, édition cellule par cellule et **édition en masse** (glisser, Ctrl/Cmd-clic, Maj-clic).
- **Reporting** : graphes effectif par service/rôle, top jours travaillés, top CP, répartition par statut.
- **Personnel, Contrats, Documents, Paramètres** : CRUD complet.
- **Masquage automatique** des collaborateurs partis à partir du mois suivant.

### Base de données
- 7 tables avec `hotel_id` partout, **RLS active** sur toutes.
- Contraintes CHECK strictes, unicité `(hotel_id, employee_id, day)` sur le planning.
- Référentiels semés par hôtel (6 départements + 12 rôles).

### Migration
- Migration de données du prototype `pl_*` vers le nouveau modèle, sans perte (4 346 entrées validées).

### Tests
- 56 tests jsdom + tests SQL.

## Roadmap

- **Pointage** : timestamps d'arrivée/départ par collaborateur.
- **Suivi du temps** : consolidation des heures réelles vs planifiées.
- **Paie** : calcul des éléments variables, export DSN.
- **Recrutement** : pipeline candidatures jusqu'à l'embauche.
- **Page d'invitation** : créer un compte utilisateur + rattachement à un hôtel depuis l'UI Paramètres.
- **Policies RLS par rôle** pour `employee_documents` et autres tables sensibles (durcissement complémentaire au gating frontend).
