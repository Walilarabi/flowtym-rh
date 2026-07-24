# Critères d'entrée en RC2 — Flowtym RH

Conditions **objectives** à réunir pour autoriser la **reprise du développement** (fin du
gel RC1). Tant qu'un critère bloquant n'est pas satisfait, RC2 **ne démarre pas**.

## Critères bloquants (tous requis)

| # | Critère | Mesure objective | Source de preuve |
|---|---|---|---|
| E1 | **Pilote terminé** | Durée planifiée atteinte (≥ 2–4 semaines) et clôturé formellement | `pilot-decisions.md` |
| E2 | **Aucun bug critique ouvert** | 0 incident de gravité *Critique* au statut ≠ Fermé | `pilot-incidents.md` |
| E3 | **Sécurité validée** | **0 ERROR** advisor sécurité en production ; surface `anon` revue ou risque accepté formellement | MCP `get_advisors` ; `pilot-decisions.md` |
| E4 | **Stabilité confirmée** | 0 anomalie d'invariant sur la période (orphelins/chevauchements/double compte = 0 tous les jours) | `daily-checklist.md` (journal) |
| E5 | **Performance validée** | Temps de réponse des écrans paie/suivi acceptables au volume pilote ; aucun incident perf ouvert | Journal + `pilot-incidents.md` |
| E6 | **Utilisateurs satisfaits** | Synthèse `user-feedback.md` : pas d'irritant bloquant non traité ; retour paie positif sur la justesse des heures | `user-feedback.md` |
| E7 | **Backlog priorisée** | Toutes les demandes classées A/B/C/D avec priorité et estimation | `RC2-roadmap.md` |
| E8 | **Décisions du pilote documentées** | Registre décisions complet et signé (Release Manager) | `pilot-decisions.md` |

## Critères de qualité (fortement recommandés)

| # | Critère | Mesure |
|---|---|---|
| Q1 | Reproductibilité prod | Reconstruction depuis le dépôt rejouée verte (CI) sur la version pilote |
| Q2 | Rollback éprouvé | Bascule flag → legacy testée **au moins une fois** en conditions réelles |
| Q3 | Protection de branche active | Checks `frontend-syntax` + `db-tests` requis sur `main` |
| Q4 | Post-mortem pilote | Rédigé et diffusé (alimente `lessons-learned.md`) |

## Décision d'ouverture RC2

RC2 est ouverte **par le Release Manager** lorsque **E1–E8 = satisfaits**. La décision
est consignée dans `pilot-decisions.md`. À défaut, deux options :
- **Prolonger le pilote** (si E1/E4/E5/E6 non atteints) ;
- **Rester en RC1 corrective** (si E2/E3 non atteints) : uniquement correctifs critiques.

## Ce qui NE conditionne PAS l'entrée en RC2
- Les dettes classées P3 (améliorations de fond) — traitées **dans** RC2, pas avant.
- Les innovations (catégorie D) — exploratoires, non bloquantes.
