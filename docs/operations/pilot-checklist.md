# Checklist de pilote — Flowtym RH RC1

Checklists **avant / pendant / après** déploiement, **critères GO/NO-GO**, et **QA
fonctionnelle** (scénarios utilisateur réels). Les colonnes *Résultat obtenu* /
*PASS-FAIL* de la QA sont à **remplir par l'équipe** lors de l'exécution sur le groupe
pilote (chemin authentifié non exécutable hors production).

---

## A. Checklist AVANT déploiement

| # | Contrôle | Attendu | OK ? |
|---|---|---|---|
| A1 | PR #2 approuvée + CI verte | 2 jobs verts | ☐ |
| A2 | Protection de branche `main` active (checks requis) | activée | ☐ |
| A3 | Reconstruction depuis le dépôt rejouée | P0 24/24 · A–G 7/7 | ☐ |
| A4 | Advisors sécurité (staging) | **0 ERROR** | ☐ |
| A5 | Groupe pilote identifié (1 groupe, ≥1 hôtel) | id noté | ☐ |
| A6 | Fenêtre de déploiement (faible activité) planifiée | planifiée | ☐ |
| A7 | Astreinte briefée + `incident-runbook.md` communiqué | fait | ☐ |
| A8 | Sauvegarde/point de restauration DB prod récent | confirmé | ☐ |
| A9 | Référent paie disponible pour la QA | confirmé | ☐ |

**GO** si A1–A9 = OK. Sinon **NO-GO**.

## B. Checklist PENDANT déploiement

| # | Contrôle | Attendu | OK ? |
|---|---|---|---|
| B1 | Migration `sql/54` appliquée (staging puis prod) | sans erreur | ☐ |
| B2 | Migration `sql/55` appliquée | sans erreur | ☐ |
| B3 | Objets présents (4 fonctions + `staff_payroll_periods`) | présents | ☐ |
| B4 | Vue `v_staff_day_flags` = `security_invoker=on` | oui | ☐ |
| B5 | Front prod déployé (Vercel Ready) | Ready | ☐ |
| B6 | **Flag encore legacy partout** (aucun changement utilisateur) | legacy | ☐ |
| B7 | Advisors sécurité prod | **0 ERROR** | ☐ |

**GO activation flag** si B1–B7 = OK.

## C. Checklist APRÈS déploiement (activation flag pilote)

| # | Contrôle | Attendu | OK ? |
|---|---|---|---|
| C1 | Flag `segments` activé sur le **seul** groupe pilote | oui | ☐ |
| C2 | Journal `hotel_group_flag_audit` trace la bascule | oui | ☐ |
| C3 | QA fonctionnelle (§E) verte | tous PASS | ☐ |
| C4 | Invariants (`daily-checklist` Bloc 1) à 0 | 0 | ☐ |
| C5 | Hôtel hors pilote inchangé (legacy) | inchangé | ☐ |
| C6 | Checklist quotidienne armée | armée | ☐ |

**Pilote lancé** si C1–C6 = OK.

---

## D. Critères GO / NO-GO (synthèse)

**GO** : A1–A9, B1–B7, C1–C6 tous OK ; 0 ERROR sécurité ; P0 24/24 ; A–G 7/7 ;
0 anomalie ; rollback flag testé à blanc.

**NO-GO** (arrêter/rollback) si l'un de :
- Migration en erreur non résolue.
- ERROR sécurité résiduel.
- Un test QA critique (E3, E4, E5, E7) en FAIL.
- Une anomalie de données (chevauchement, orphelin, double compte).

---

## E. QA fonctionnelle — scénarios utilisateur réels

Prérequis communs : groupe pilote en `segments`, 2 hôtels du groupe (FO/VO), 1 manager
avec accès aux 2 hôtels, 1 collaborateur de test, référent paie présent.

> Équivalents DB déjà validés (base reconstruite du dépôt) : **24/24** (`scripts/p0`).
> La QA ci-dessous valide le **parcours navigateur** de bout en bout.

### E1 — Créer un collaborateur
- **Prérequis** : manager connecté, hôtel FO sélectionné.
- **Étapes** : Collaborateurs → Ajouter → renseigner nom/service/contrat/horaire → Enregistrer.
- **Attendu** : collaborateur listé, service et barème horaire (`hpd`) corrects.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E2 — Créer un planning
- **Prérequis** : E1 fait.
- **Étapes** : Planning → mois courant → poser des présences (P) 08–16 sur plusieurs jours → Enregistrer.
- **Attendu** : cases P enregistrées ; compteurs de grille cohérents.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E3 — Déplacer un collaborateur (inter-hôtels) — **critique**
- **Prérequis** : présence FO 08–16 le jour J ; VO en sous-effectif.
- **Étapes** : Planning Groupe → proposition de renfort FO→VO le jour J (créneau partiel 08–12) → soumettre → approuver → appliquer.
- **Attendu** : segments créés (VO 08–12 destination, FO 12–16 origine) ; grille VO=PE, FO ajustée ; **aucune erreur**.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E4 — Calcul des heures (jour déplacé) — **critique**
- **Prérequis** : E3 fait.
- **Étapes** : ouvrir la fiche heures du salarié / requête `SELECT staff_hours_day('<EMP>','<J>')`.
- **Attendu** : **net = 8 h** (FO 4 h + VO 4 h), **pas 16 h** ; ventilation par hôtel correcte.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E5 — Paie (éléments variables) — **critique**
- **Prérequis** : E3/E4 faits.
- **Étapes** : Paie → mois du déplacement → vérifier les heures planifiées du salarié.
- **Attendu** : heures = **part réelle par hôtel** (segments), **aucun double compte** ; croiser avec `staff_hotel_hours_range`.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E6 — Export (CSV paie)
- **Prérequis** : E5 fait.
- **Étapes** : Paie → Export CSV logiciel de paie.
- **Attendu** : colonnes heures = valeurs segments (jour fractionné correct) ; fichier ouvrable.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E7 — Garde-fou paie clôturée — **critique**
- **Prérequis** : créer une période de paie **close** couvrant le jour J (table `staff_payroll_periods`).
- **Étapes** : tenter de modifier le planning / rejouer un déplacement sur le jour J.
- **Attendu** : **refus explicite (`FL001`)**, message clair, **aucune écriture partielle**.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E8 — Suivi du temps (C2)
- **Étapes** : Suivi du temps → mois du déplacement.
- **Attendu** : heures planifiées = segments ; écart planifié/pointé cohérent.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E9 — Réversibilité (flag)
- **Étapes** : `set_group_hours_source('<GROUP>','legacy')` → recharger Paie → puis re-`segments`.
- **Attendu** : bascule immédiate legacy↔segments ; journal tracé ; aucune perte de données.
- **Obtenu** : __________ · **PASS/FAIL** : ☐

### E10 — Isolation (hors pilote)
- **Étapes** : ouvrir un hôtel d'un **autre** groupe (legacy).
- **Attendu** : comportement **inchangé** (calcul legacy).
- **Obtenu** : __________ · **PASS/FAIL** : ☐

**Verdict QA** : GO si E3, E4, E5, E7 (critiques) = PASS **et** aucun autre FAIL bloquant.
