# Flowtym RH — Changelog

## v1.2 — Module Pointage

### Frontend
- **Onglet Pointage fonctionnel** (n'est plus un stub) pour `direction`, `admin_hotel`, `comptabilite`.
- **Vue par jour** : date picker + bouton « Aujourd'hui » + recherche par nom/rôle.
- **Tableau collaborateurs** avec, pour chaque ligne :
  - Statut planifié (issu du planning du même jour, lecture seule)
  - Liste des **sessions pointées** (badges colorés ; orange pour les sessions en cours sans clock-out)
  - **Heures réelles** calculées automatiquement (arrivée → départ moins la pause)
  - Bouton + pour ajouter rapidement un pointage pour ce collaborateur
- **4 KPI du jour** en haut : pointés, prévus non pointés, sessions en cours, heures totales.
- **Modal d'ajout / édition / suppression** : sélection du collaborateur, jour, heure d'arrivée, heure de départ (facultative pour les sessions en cours), pause en minutes, notes. Gestion automatique des shifts de nuit (heure de sortie < arrivée → lendemain).
- Cliquez sur un badge de session pour l'éditer ou la supprimer.

### Base de données
- Migration `06_rh_staff_clockings_module.sql` :
  - Table `staff_clockings` avec `hotel_id`, `employee_id`, `day`, `clock_in_ts`, `clock_out_ts`, `break_minutes`, `notes`, `source` (`manual` / `qr` / `self`).
  - Contraintes CHECK strictes : break_minutes ∈ [0, 480], clock_out_ts > clock_in_ts.
  - **RLS active** : `hotel_id IN (SELECT pl_my_hotels())` en USING et WITH CHECK.
  - Index sur `(hotel_id, day)` et `(employee_id, day desc)` pour les requêtes courantes.
  - Trigger `updated_at`.

### Tests
- 75 tests jsdom (7 nouveaux pour Pointage : KPI, table, modal d'ajout, création d'un pointage, calcul des heures, masquage pour la réception).

## v1.1 — Gestion des accès par rôle

### Frontend
- **Matrice de permissions** pour les 9 rôles existants — alignée sur le référentiel `admin_user_role` partagé avec le PMS.
- **Filtrage automatique des onglets** dans la sidebar selon le rôle.
- **Fiche collaborateur restreinte** pour les rôles opérationnels (nom, prénom, poste, service, statut, téléphone, e-mail uniquement).
- **Badge du rôle dans la topbar**.
- Bloc **Accès et permissions** dans Paramètres : liste éditable + matrice de référence en lecture.
- **Refresh complet de la shell** au changement d'hôtel.
- **Exports Planning Excel et PDF** (A4 paysage, table pleine page, multi-page).

### Base de données
- Migration `05` : 3 fonctions `SECURITY DEFINER` (`rh_my_role`, `rh_list_users_for_hotel`, `rh_update_user_role`).

### Tests
- 68 tests jsdom.

## v1.0 — Lancement production

- 11 onglets, 7 fonctionnels + 4 stubs roadmap.
- Édition en masse du planning (drag/Ctrl-clic/Maj-clic).
- 7 tables RH avec RLS par hotel_id, migrations rejouables.
- 56 tests jsdom + tests SQL.

## Roadmap restante

- **Suivi du temps** : consolidation hebdomadaire / mensuelle des heures réelles vs planifiées.
- **Paie** : calcul des heures supplémentaires, indemnités, export DSN.
- **Recrutement** : pipeline candidatures.
- **Self check-in via QR code** : appli mobile pour que le collaborateur pointe lui-même.
- **Page d'invitation** : créer un compte utilisateur + rattachement hôtel depuis l'UI Paramètres.
- **Policies RLS par rôle** : durcissement complémentaire au gating frontend pour les tables sensibles.
