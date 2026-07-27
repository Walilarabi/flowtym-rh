# Flowtym RH — Changelog

## v1.4.2 — Pointage v2 : hotfix production (post-déploiement)

### Corrections DB alignées prod
- **`generate_terminal_token()`** : appel `gen_random_bytes(24)` non qualifié + `SET search_path = public, extensions`. Corrige l'échec de la migration 63 sur Supabase (pgcrypto vit dans le schéma `extensions`, pas `public`).
- **`pointage_terminals_prevent_delete_if_used()`** : ajout `SET search_path = public` (advisor Supabase `function_search_path_mutable`).
- **`staff_clocking_idempotency`** : `ENABLE ROW LEVEL SECURITY` explicite (oubli du 63 initial ; l'advisor security a levé `rls_disabled_in_public`).
- **RPC admin** (`create/rename/regenerate/set_active/archive/set_security_pointage_terminal`, `employee_can_clock_at`) : `REVOKE EXECUTE ... FROM PUBLIC, anon` explicite après le GRANT à `authenticated`. Supabase ajoute par défaut anon au GRANT sur toute fonction publique — le REVOKE ferme cette voie même si les checks internes `pl_my_hotels()` bloquent déjà anon.
- **`record_clocking`** : `REVOKE ... FROM PUBLIC, anon, authenticated` (au lieu du seul FROM PUBLIC), preuve directe via `has_function_privilege` : `anon=false, authenticated=false, service_role=true`.

### Table de remédiation `sql/64_pointage_remediation_log.sql`
- Nouvelle table `staff_clockings_remediation_log(id, clocking_id, hotel_id, employee_id, original_row jsonb, remediation_type, remediation_reason, remediated_at, remediated_by, remediated_by_email)`.
- RLS active, `SELECT` réservé aux hôtels via `pl_my_hotels()`.
- Utilisée par l'opération de remédiation atomique des deux pointages orphelins pré-v2 (`2026-06-07`) : `clock_out_ts = clock_in_ts + 1 µs` (contrainte `clock_out_after_in` impose `>`), `clock_status='suspicious'`, `anomaly_flags += 'orphan_open_shift_pre_pointage_v2'`.

### Tests CI
- Le fixture `sql/tests/pointage_minimal_schema.sql` conserve pgcrypto dans `public` (search_path par défaut) mais crée aussi le schéma `extensions` pour compatibilité avec les migrations qui qualifient `extensions.gen_random_bytes(...)`.
- Nouveau test **17** dans `sql/tests/pointage_hardening.sql` : RLS `staff_clocking_idempotency` + RPC admin non exécutables par `anon` (create, regenerate, archive, employee_can_clock_at).
- Le runner CI requiert désormais `NB_OK >= 17`.

### Résultats
- 289 tests Jest (inchangés) + **17 tests SQL** (+1) + 3 scénarios de concurrence — tous verts localement et en CI.
- Advisor Supabase : findings du module Pointage passés de **3** (1 ERROR + 2 WARN structurels) à **0**.

## v1.4.1 — Pointage v2 : durcissement post-audit

### Autorisation multi-hôtel — plus stricte
- Retrait total du critère "historique" : posséder un ancien pointage dans un hôtel n'autorise plus rien.
- Nouvelle fonction SQL `employee_can_clock_at(employee, hotel, day)` — 4 critères OU, chacun explicite et actuel :
  hôtel principal + employé actif · `employee_hotel_assignments` active · `employee_extra_activations` active ce mois-ci · `staff_planning` P ce jour.
- L'edge function `clock-portal` refuse l'accès des employés désactivés (`EMP_INACTIVE`).

### Terminaux — archivage
- Nouveaux champs `archived_at`, `archived_by`, `archived_by_email`.
- Trigger `pointage_terminals_prevent_delete_if_used` → toute tentative de `DELETE` sur un terminal référencé par `staff_clockings` lève `foreign_key_violation` avec un HINT.
- Contrainte `pointage_terminals_archived_not_active` : archivé ⇒ inactif.
- Index unique `(hotel_id, lower(name))` sur les terminaux actifs non archivés.
- UI : bouton **Archiver** proposé sur les terminaux utilisés ; **Supprimer** disparaît dès qu'il y a un pointage attaché.

### Régénération de token — atomique + auditée
- Nouvelle fonction crypto `generate_terminal_token()` (`gen_random_bytes(24)`, 192 bits d'entropie).
- Nouvelles RPC `SECURITY DEFINER` : `create_pointage_terminal`, `rename_pointage_terminal`, `regenerate_pointage_terminal_token`, `set_pointage_terminal_active`, `archive_pointage_terminal`, `set_pointage_terminal_security`.
- Isolation multi-tenant vérifiée dans chaque RPC (`hotel_id IN pl_my_hotels()`).
- Verrou pessimiste `SELECT ... FOR UPDATE` sur la ligne pendant la régénération.
- Journal `pointage_terminal_events(action, actor_user_id, actor_auth_id, actor_email, details)` en INSERT-only pour les clients (RLS SELECT-only par hôtel).

### Fallback `hotel_qr_tokens` — stratégie de transition
- Commentaire SQL `OBSOLÈTE` posé sur la table (visible dans Studio Supabase).
- Aucun nouveau token `hotel_qr_tokens` créé par l'app (l'UI admin est passée à `create_pointage_terminal`).
- L'edge function accepte encore la lecture legacy pendant la fenêtre 90 j documentée dans `docs/pointage-v2-deploy.md` ; le flag `terminal_legacy:true` remonte au client pour la télémétrie.
- TODO daté ancré dans `sql/63_pointage_terminals_hardening.sql` § 13 pour la migration 65 (drop).

### Protection SQL contre le double-pointage
- Index unique partiel `staff_clockings_one_open_per_employee` sur `employee_id WHERE clock_out_ts IS NULL` — au plus un pointage ouvert par employé, tous hôtels et terminaux confondus.
- Table dédiée `staff_clocking_idempotency(key PK, clocking_id, action, created_at)` — un retry réseau avec la même clé retourne la même écriture.
- Nouvelle RPC `record_clocking(...)` (SECURITY INVOKER, réservée à `service_role`) qui combine :
  1) advisory lock par `hashtextextended(employee_id, 62)` (sérialisation stricte),
  2) lecture idempotence après verrou,
  3) `UPDATE ... WHERE clock_out_ts IS NULL` pour éviter les doubles clock_out concurrents,
  4) `INSERT` avec catch `unique_violation` pour idempotence à l'insert.

### Heure serveur + fuseau hôtel
- `clock_in_ts` / `clock_out_ts` = `now()` (jamais l'heure du téléphone).
- Nouvelle fonction `pl_hotel_local_day(hotel, ts)` : date civile locale de l'hôtel (fallback `Europe/Paris`).
- `staff_clockings.day` calculé côté SQL avec ce fuseau, robuste aux DST et postes de nuit.

### Extensibilité sécurité QR
- Nouveaux champs par terminal : `geofence_radius_override_meters`, `active_from_minute`, `active_to_minute`.
- L'edge function applique le rayon terminal → hôtel (fallback), et refuse les scans hors plage (code `OUTSIDE_TIME_WINDOW`, plage traversant minuit gérée).

### Cycle de vie caméra
- Verrous `qrOpening` (empêche 2 scanners simultanés sur double-clic) et `qrDetected` (empêche 2 handlers d'aboutir sur la même image).
- `stopCameraStream()` invoqué sur `visibilitychange`, `pagehide`, `beforeunload`, et systématiquement au début d'un nouveau `startCamera()`.
- Chargeur `jsQR` : loader singleton, retry possible après échec réseau, script balise retirée sur erreur.

### Idempotency-Key côté client
- `portal.html` génère une clé `ptg-<uuid>` par tentative utilisateur, envoyée en header HTTP `Idempotency-Key` + body ; un retry porte la même clé, le serveur retourne la même écriture.

### Tests
- Suite Jest : 289 tests verts (avant : 273).
- Suite SQL : 12 tests dans `sql/tests/pointage_hardening.sql` (autorisation, archivage, régénération, idempotence, day fuseau, privilèges).
- Test de concurrence `scripts/test-pointage-concurrency.sh` : 3 scénarios parallèles verts (clés distinctes, même clé, 2 terminaux du même hôtel).

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
