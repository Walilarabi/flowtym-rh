# Flowtym RH — Changelog

## v1.3 — Contrats & Documents (Phases 1b + 2)

### Frontend
- **Vue Contrats refondue avec sous-onglets** : Vue d'ensemble, Modèles, Générer un contrat.
- **Onglet Modèles** : CRUD de modèles HTML versionnés, archivage, création d'une nouvelle version (archive automatique de l'ancienne), 25 variables documentées en référence.
- **Assistant de génération de contrat en 4 étapes** :
  1. Choix du collaborateur (avec alertes sur données civiles manquantes)
  2. Choix du modèle (filtrage automatique par service/rôle, suggérés en tête)
  3. Saisie des champs spécifiques (dates, période d'essai, rémunération, lieu, manager, convention collective)
  4. Aperçu HTML rendu + bouton **Générer le PDF** qui :
     - substitue les variables `{{...}}` (variables manquantes surlignées en jaune dans l'aperçu)
     - génère le PDF via jsPDF
     - upload dans Supabase Storage bucket `hr-documents`
     - crée un document type « contrat » sur la fiche collaborateur
     - télécharge la copie pour l'utilisateur
     - écrit une entrée dans `hr_document_audit_logs`
- **Fiche collaborateur enrichie** :
  - Section État civil avec date/lieu de naissance, nationalité, n° sécu, titre de séjour (visible seulement aux rôles RH/direction)
  - Section Documents RH avec **upload réel de fichiers** (PDF/JPEG/PNG, 10 Mo max), date d'émission, date d'expiration, badge automatique (Valide / Expire dans X j / Expiré / Manquant), téléchargement via URL signée 60 s, suppression
  - Audit log à chaque upload/download/delete
- **Formulaire collaborateur étendu** avec bloc *État civil* conditionnel selon les permissions.
- **Tableau de bord** : nouveau bloc **Alertes documents** (top 10 alertes documents expirés / expirant / manquants), clic ouvre la fiche concernée.
- **Référentiel DOC_TYPES** aligné sur les 13 types de la base (`document_types`).

### Base de données et stockage (Phase 1a, déjà appliqué)
- Migration 07 : 6 champs civils sur `employees` (RGPD sensible)
- Migration 08 : référentiel `document_types` (13 types normalisés)
- Migration 09 : `contract_templates` versionnables
- Migration 10 : enrichissement `employee_documents` + vue `v_employee_documents_alerts`
- Migration 11 : `hr_document_audit_logs` avec accès restreint admin/comptabilité
- Migration 12 : 2 buckets Supabase Storage privés (hr-templates, hr-documents) + 8 policies RLS

### Permissions
- Champs civils, État civil, Documents RH : visibles seulement pour `direction`, `admin_hotel`, `comptabilite` (via `canFicheFull()`).
- Alertes documents dashboard : seulement pour les rôles avec accès fiche complète.

### Tests
- 92 tests jsdom (17 nouveaux : sous-onglets contrats, création modèle, substitution variables, fallback variables manquantes, upload doc, types DOC, champs civils form, masquage réception, alertes dashboard).

### À venir (Phases 3 & 4)
- **Phase 3 — Signature électronique Yousign** : table signature_requests, machine d'états, intégration API. Provider recommandé : Yousign (FR, eIDAS, 9 à 25 €/mois selon volume).
- **Phase 4 — Attestation mutuelle + compléments** : même moteur que les contrats, table `mutual_certificate_templates` dédiée, notifications email.

## v1.2 — Module Pointage

Saisie manuelle, vue par jour, sessions multiples, calcul auto des heures, modal CRUD. RLS par hôtel. 75 tests.

## v1.1 — Gestion des accès par rôle

Matrice de permissions, filtrage onglets, fiche restreinte, badge rôle, bloc Accès dans Paramètres, 3 fonctions RPC sécurisées. 68 tests.

## v1.0 — Lancement production

11 onglets, édition en masse planning, 7 tables RH avec RLS, migrations rejouables. 56 tests.

## Roadmap restante

- **Phase 3** : Yousign + state machine signature.
- **Phase 4** : Attestation mutuelle, page d'invitation utilisateurs, durcissement RLS par rôle.
- Suivi du temps, Paie, Recrutement : modules consommateurs du Pointage.
- Self check-in QR pour les collaborateurs.
