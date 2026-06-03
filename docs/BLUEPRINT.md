# Flowtym RH — Blueprint Produit (v2, juin 2026)

## Vision

Flowtym RH est une plateforme RH multi-hôtel destinée aux directeurs et équipes RH
de groupes hôteliers. Elle couvre le cycle de vie complet du collaborateur : recrutement,
onboarding, gestion quotidienne, offboarding — avec un portail self-service pour les
salariés.

---

## Décisions d'architecture validées

| Sujet | Décision |
|---|---|
| Authentification staff RH | Email / mot de passe (existant) |
| Authentification salarié | **Magic-link** uniquement (sans mot de passe) |
| Domaine portail salarié | **salarie.flowtym.com** (domaine séparé) |
| Conservation légale des documents | **Paramétrable par pays** (défaut : France 5 ans) |
| Signature électronique | **Yousign** (phase initiale) puis **DocuSign** (option entreprise) |
| Exports paie | À définir selon le logiciel réellement utilisé par chaque hôtel |
| Multi-tenancy | RLS Supabase par `hotel_id` — isolation stricte |
| Frontend | HTML/CSS/JS vanilla mono-fichier (pas de build) |

---

## Priorité commerciale (ordre de valeur pour un directeur d'hôtel)

> Absences/CP-RTT → Recrutement → Paie → Portail salarié

Les trois premiers créent la valeur immédiate ; le portail salarié amplifie et
fidélise.

---

## Modules et phases

### Socle existant (v1.0 → v1.3 — en production)

- Authentification, multi-hôtel, RLS
- Planning mensuel (édition en masse, import Excel)
- Pointage (saisie manuelle, sessions multiples)
- Personnel / Fiches collaborateurs (état civil RGPD, départs)
- Contrats : modèles versionnés, générateur PDF, variables `{{...}}`
- Documents RH : upload réel, alertes expiration, audit log
- Gestion des accès par rôle (direction, admin_hotel, comptabilité, réception)
- Reporting KPI, Paramètres services/rôles

---

### Phase 3 — Signature électronique + Absences + Recrutement

#### 3A — Signature électronique (Yousign)

- Table `signature_requests` (état : draft → sent → signed → archived)
- Machine d'états + webhooks Yousign
- Lancement signature depuis la génération de contrat
- Notifications email à chaque changement d'état
- Archivage automatique du PDF signé dans Supabase Storage

#### 3B — Gestion des absences et compteurs CP/RTT

- Table `absences` (type, dates, statut : demandé / approuvé / refusé / annulé)
- Table `leave_balances` (soldes CP, RTT, congé sans solde, etc. par salarié et période)
- Workflow d'approbation (salarié demande → manager approuve/refuse)
- Compteurs automatiques alimentés par les règles légales (France par défaut)
- Vue calendrier des absences de l'équipe
- Alertes solde négatif ou dépassement de quota
- Portail salarié : consultation soldes + dépôt de demande via magic-link

#### 3C — Recrutement complet + transformation candidat → salarié

- Table `job_postings` (poste, hôtel, statut : draft / ouvert / clôturé)
- Table `candidates` (candidature complète : CV, lettre, étapes pipeline)
- Pipeline Kanban : Nouveau → Présélectionné → Entretien → Offre → Embauché / Refusé
- Formulaire de candidature publique (lien partageable par hôtel/poste)
- **Transformation one-click** candidat accepté → fiche employé (pré-remplissage
  des données communes, choix du type de contrat, lancement de la génération)
- Historique des candidatures archivées par poste
- Tableau de bord recrutement (délai moyen de recrutement, taux de conversion)

---

### Phase 4 — Paie, Formations, Visites médicales, Matériel, Organigramme

#### 4A — Préparation des éléments variables de paie

- Table `payroll_elements` (heures sup, primes, indemnités, retenues)
- Agrégation automatique depuis Pointage + Absences
- Export configurable selon le logiciel de paie de l'hôtel (CSV générique dans
  un premier temps ; mapping vers logiciel cible défini hôtel par hôtel)
- Journal de paie mensuel, verrouillage de période

#### 4B — Gestion des formations obligatoires et leurs échéances

- Table `training_catalog` (titre, type : obligatoire / recommandé, périodicité)
- Table `employee_trainings` (salarié, formation, date réalisation, date expiration,
  organisme, certificat uploadé)
- Calcul automatique de la prochaine échéance selon la périodicité
- Alertes dashboard (formations expirées / expirant dans 30 j)
- Vue récapitulative par hôtel : matrice salariés × formations
- Portail salarié : consultation de son plan de formation

#### 4C — Gestion des visites médicales périodiques

- Table `medical_visits` (salarié, type : embauche / périodique / reprise,
  date réalisée, date prochaine, médecin, aptitude)
- Calcul automatique de la prochaine visite (2 ans droit commun, 1 an poste
  à risque — paramétrable)
- Alertes dashboard (visites à planifier)
- Blocage soft à l'embauche si visite d'embauche non planifiée

#### 4D — Gestion du matériel remis aux salariés

- Table `equipment` (référence, catégorie : uniforme / badge / clé / matériel
  informatique / autre, hôtel)
- Table `employee_equipment` (salarié, équipement, date remise, date retour,
  état : remis / retourné / perdu, valeur)
- Signature de décharge à la remise (PDF généré via le même moteur contrats)
- Alerte retour manquant à la date de départ du salarié
- Inventaire par hôtel

#### 4E — Organigramme hôtel

- Vue arborescente interactive par hôtel (D3.js ou bibliothèque légère)
- Basé sur `employees.manager_id` (colonne à ajouter)
- Filtres : hôtel, service, statut actif/inactif
- Export PNG / PDF
- Édition inline du manager par drag-and-drop (optionnel v2)

---

### Phase 5 — Portail salarié (salarie.flowtym.com)

Accès via **magic-link** envoyé par email. Aucun mot de passe.

Pages initiales :

| Page | Contenu |
|---|---|
| Accueil | Mes infos, hôtel, poste, manager |
| Mes documents | Contrat, bulletins, attestations — téléchargement via URL signée 60 s |
| Mes absences | Soldes CP/RTT, demandes en cours, historique |
| Mon planning | Lecture seule du planning du mois |
| Mes formations | Plan de formation, prochaines échéances |
| Mon matériel | Liste du matériel remis, décharges |

Contraintes techniques :

- Domaine séparé `salarie.flowtym.com` → CORS configuré côté Supabase
- Conservation des documents : paramétrable par pays (défaut France 5 ans)
- Aucune donnée sensible en localStorage
- Interface responsive mobile-first (les salariés consultent sur téléphone)

---

### Phase 6 — Self check-in QR + Notifications push

- QR code par salarié → pointage entrée/sortie sans accès RH
- Notifications push / email sur les événements clés (absence approuvée,
  document disponible, formation à renouveler)

---

## Modules transversaux (à intégrer dès que possible)

- **Attestation mutuelle** : même moteur que contrats, table
  `mutual_certificate_templates`, variables `{{...}}` dédiées
- **Invitation utilisateurs** : page d'invitation RH avec lien tokenisé
- **Conservation légale paramétrable** : table `legal_retention_rules(country, doc_type, years)`
- **Durcissement RLS par rôle** : bloquer lecture `hr_document_audit_logs` aux
  non-admin ; isoler les champs RGPD sensibles

---

## Schéma des nouvelles tables (P3 → P4)

```
absences              (id, employee_id, hotel_id, type, start_date, end_date, status, approved_by, note)
leave_balances        (id, employee_id, hotel_id, year, type, entitled, taken, remaining)
job_postings          (id, hotel_id, title, department, contract_type, status, opened_at, closed_at)
candidates            (id, job_posting_id, first_name, last_name, email, cv_url, stage, notes, converted_employee_id)
training_catalog      (id, hotel_id, title, is_mandatory, periodicity_months, description)
employee_trainings    (id, employee_id, training_id, done_at, expires_at, certificate_url, organizer)
medical_visits        (id, employee_id, visit_type, done_at, next_due_at, doctor, aptitude, hotel_id)
equipment             (id, hotel_id, reference, category, description, value)
employee_equipment    (id, employee_id, equipment_id, given_at, returned_at, state, discharge_doc_url)
signature_requests    (id, employee_id, document_id, provider, external_id, status, sent_at, signed_at)
```

Colonnes à ajouter sur `employees` :
- `manager_id UUID REFERENCES employees(id)` — pour l'organigramme

---

## Questions encore ouvertes

| Sujet | Statut |
|---|---|
| Logiciel de paie cible par hôtel | À recueillir hôtel par hôtel avant de coder les exports |
| Règles CP/RTT spécifiques (hôtellerie, CCN HCR) | À confirmer avec un juriste RH |
| Périodicité visites médicales postes à risque hôtel | À lister (plongeur, cuisinier feux, etc.) |
| Volume de candidatures attendu / nécessité d'un ATS plus poussé | À valider à l'usage |
