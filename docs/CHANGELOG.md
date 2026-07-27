# Flowtym RH — Changelog

## v1.4 — Refonte du module Pointage (terminaux)

### Principe
- Le QR Code n'identifie **plus** un salarié : il identifie **un terminal de pointage**.
- Un hôtel peut posséder plusieurs terminaux (Réception, Cuisine, Entrée du personnel…), chacun avec son propre QR.
- Le salarié est identifié via sa session Flowtym au moment du scan.
- Aucun QR à réimprimer lors des arrivées/départs des collaborateurs.

### Frontend — Portail salarié (`portal.html`)
- Le bouton principal **Pointer entrée / Pointer sortie** ouvre immédiatement la caméra (getUserMedia).
- Compatibilité étendue : Safari iOS (playsinline, muted, autoplay), Chrome Android, Chrome/Edge desktop, Firefox.
- Décodeur natif `BarcodeDetector` avec fallback automatique `jsQR` chargé à la demande.
- Détection de compatibilité (contexte sécurisé, présence de `mediaDevices.getUserMedia`) avec messages explicites.
- Gestion fine des erreurs de permission caméra (NotAllowedError, NotFoundError, NotReadableError, OverconstrainedError, SecurityError).
- La **saisie manuelle du code** est reléguée à un lien secondaire, accessible uniquement depuis l'écran scanner ou son panneau d'erreur.
- Nouveau design plein écran du scanner avec cadre-guide, feedback tactile (vibrate) à la détection.

### Frontend — Admin (`index.html`, onglet Paramètres › Pointage QR)
- Nouvelle interface de gestion multi-terminaux : lister, créer, nommer, associer à un hôtel, imprimer/télécharger, désactiver, réactiver, régénérer, supprimer.
- Chaque terminal affiche son QR en direct, son code, sa date de création.
- Impression optimisée avec nom d'hôtel + nom de terminal.

### Backend — Base de données (`sql/62_pointage_terminals.sql`)
- Nouvelle table `pointage_terminals(id, hotel_id, name, location, token, is_active, timestamps)` avec RLS multi-tenant.
- Colonne `terminal_id` ajoutée à `staff_clockings` (FK, ON DELETE SET NULL).
- Backfill idempotent : chaque hôtel disposant déjà d'un `hotel_qr_tokens` actif hérite d'un terminal « Réception » reprenant l'ancien token.
- Rétrocompatibilité totale : la table `hotel_qr_tokens` reste lisible par l'edge function en fallback.
- Fonction RPC `list_pointage_terminals(uuid)`.

### Backend — Edge function `clock-portal`
- Résolution du token contre `pointage_terminals` (nouveau) puis `hotel_qr_tokens` (legacy).
- Vérification que le salarié est autorisé à pointer dans l'hôtel du terminal (compatible multi-hôtels : shift planifié ou historique).
- Enregistrement de `terminal_id` sur le pointage (ou `qr_token_id` en fallback legacy).
- Codes d'erreur enrichis : `MISSING_TOKEN`, `AUTH_INVALID`, `EMP_NOT_FOUND`, `PORTAL_DISABLED`, `INVALID_TERMINAL`, `WRONG_HOTEL`, `QR_DISABLED`, `GPS_REQUIRED`, `GPS_TOO_FAR`.
- Réponse enrichie : `terminal_id`, `terminal_name`, `hotel_name`.

### Tests
- Nouveau fichier `tests/pointage-terminals.test.js` (19 tests) : extraction du token, décision clock_in/out, détection double-pointage, autorisation multi-hôtel.

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

## Roadmap restante (blueprint v2 — juin 2026)

> Ordre de priorité commerciale : Absences/CP-RTT → Recrutement → Paie → Portail salarié

### Phase 3
- **3A** — Signature électronique Yousign (table `signature_requests`, machine d'états, webhooks)
- **3B** — Gestion des absences et compteurs CP/RTT (workflow approbation, soldes, calendrier équipe)
- **3C** — Recrutement complet : pipeline Kanban candidats + transformation one-click candidat → salarié

### Phase 4
- **4A** — Éléments variables de paie + exports configurables par logiciel de paie hôtel
- **4B** — Formations obligatoires et échéances (catalogue, matrice salariés × formations, alertes)
- **4C** — Visites médicales périodiques (calcul automatique prochaine visite, alertes)
- **4D** — Matériel remis aux salariés (inventaire, décharges PDF, alerte retour à la sortie)
- **4E** — Organigramme hôtel (arborescence interactive, export PNG/PDF, basé sur `manager_id`)

### Phase 5
- Portail salarié **salarie.flowtym.com** — magic-link, planning, absences, documents, formations, matériel

### Phase 6
- Self check-in QR pour les collaborateurs
- Notifications push / email événements clés

### Transversal
- Attestation mutuelle, invitation utilisateurs, conservation légale paramétrable par pays
- Durcissement RLS par rôle

Voir `docs/BLUEPRINT.md` pour le détail complet.
