# Rapport de clôture du pilote — Flowtym RH (modèle)

À remplir **à la fin du pilote**, **strictement factuel**, fondé sur les données
observées (registres + KPI + synthèses hebdo). Sert de base à la décision finale.

**Groupe pilote** : ___ · **Période** : du ___ au ___ (___ semaines) ·
**Utilisateurs** : ___ · **Hôtels** : ___ · **Auteur** : Release Manager.

## 1. Résumé exécutif
- Objectif du pilote (rappel) :
- Résultat global (1 paragraphe factuel) :
- **Recommandation** : GO Version 1.0 · RC2 · Prolongation · Retour arrière.

## 2. Données d'usage (cumulé pilote)
| Métrique | Valeur |
|---|---|
| Déplacements appliqués | |
| Plannings modifiés (lots) | |
| Modifications totales | |
| Utilisateurs actifs | |
| Jours d'activité | |

## 3. Incidents (depuis `pilot-incidents.md`)
| Gravité | Nombre | Reproductibles | Corrigés | Ouverts |
|---|---|---|---|---|
| Critique | | | | |
| Élevé | | | | |
| Moyen | | | | |
| Faible | | | | |

- Bugs critiques : liste + cause racine + correctif.
- Incidents par hôtel / par utilisateur (points chauds) :

## 4. KPI consolidés (depuis `kpi-product.md`)
| KPI | Moyenne pilote | Cible | Atteint ? |
|---|---|---|---|
| Délai remplacement (médiane) | | ≤ 1 j | |
| Modifications/jour | | > 0 | |
| Usage déplacement | | > 0/sem | |
| Satisfaction (1–5) | | ≥ 4 | |
| Incidents/utilisateur | | ≤ 0,5 | |
| Jours verts (stabilité) | | 100 % | |

## 5. Retours utilisateurs (depuis `user-feedback.md`)
- Top irritants UX :
- Top fonctions manquantes :
- Points de compréhension / formation :
- Signaux positifs :

## 6. Stabilité & sécurité
- Jours verts / total : __/__.
- Invariants (chevauchements, orphelins, double compte) : incidents ? ___
- Garde-fou paie (`FL001`) : déclenchements légitimes ? faux positifs ?
- Sécurité : ERROR advisor en prod = ___ (attendu 0).
- Rollback flag testé en réel : Oui/Non — résultat.

## 7. Écart RC1 vs terrain
- Comportements observés conformes aux preuves de labo (24/24, 7/7) ? Divergences :
- Différences local (PG16) vs prod (PG17) constatées : ___

## 8. Dettes & risques confirmés par le terrain
- (mettre à jour `rc2-backlog.md` / `RC2-roadmap.md` selon les constats)

## 9. Décision proposée (à valider en revue CTO)
Cocher **une** option, avec justification factuelle :
- [ ] **GO Version 1.0** — critères `rc2-entry-criteria.md` E1–E8 satisfaits + décision d'ouverture production séparée.
- [ ] **Ouverture RC2** — pilote concluant ; reprise du développement selon la roadmap.
- [ ] **Prolongation du pilote** — données insuffisantes (durée/adoption/perf).
- [ ] **Retour arrière** — bug critique non maîtrisé ou risque avéré ; flag → legacy, post-mortem.

**Justification** :
- ...

## 10. Annexes
- Synthèses hebdomadaires (S1…Sn).
- Extraits de registres (incidents, décisions, retours).
- Journal de stabilité quotidienne.
