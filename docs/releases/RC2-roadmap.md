# Roadmap RC2 — Flowtym RH

Classement de **toutes** les demandes du backlog (`docs/operations/rc2-backlog.md`) en
4 catégories, avec priorité, impact utilisateur, complexité, dépendances, estimation et
justification. **Rien n'est développé pendant le pilote** ; cette roadmap s'active à
l'ouverture de RC2 (voir `rc2-entry-criteria.md`).

## Échelles
- **Priorité** : P1 (avant/à l'ouverture RC2) · P2 (RC2) · P3 (ultérieur).
- **Impact utilisateur** : Élevé / Moyen / Faible.
- **Complexité** : S (petite) / M (moyenne) / L (grande).
- **Estimation** : ordre de grandeur (jours-homme), indicatif.

---

## A — Corrections critiques (fiabilité, sécurité, reproductibilité, exploitation)

| ID | Demande | Prio | Impact | Cplx | Dépendances | Est. | Justification |
|---|---|---|---|---|---|---|---|
| A1 (`RC2-OPS-2`) | Activer la protection de branche `main` (checks CI requis) | P1 | Moyen | S | CI en place | 0.5 j | Rendre la CI réellement bloquante avant toute fusion. |
| A2 (`RC2-DB-1`) | Baseline **produit complète** reproductible depuis le dépôt | P1 | Élevé | L | schéma live | 5–8 j | Reproductibilité/DR au-delà du périmètre pilote (exigence prod). |
| A3 (`RC2-SEC-1`) | Revue de la surface `anon` (SECURITY DEFINER) | P2 | Élevé | M | — | 2–3 j | Réduire la surface d'exécution non authentifiée avant prod générale. |
| A4 (`RC2-DB-2`) | Migrations Supabase natives (`supabase db reset`) | P2 | Moyen | M | A2 | 2 j | Chaîne de migration standardisée et rejouable. |

## B — Améliorations UX

| ID | Demande | Prio | Impact | Cplx | Dépendances | Est. | Justification |
|---|---|---|---|---|---|---|---|
| B1 (`RC2-FE-4`) | Affichage exact des jours fractionnés (portail, exports informatifs) | P2 | Moyen | M | segments | 3 j | Cohérence visuelle pour le salarié déplacé. |
| B2 (`RC2-FE-1`) | Compteurs légaux de la grille : exposer les heures canoniques hors édition | P2 | Moyen | M | ADR-006 | 3 j | Aligner l'affichage grille sur la vérité sans casser l'édition. |
| B3 (`RC2-FE-5`) | Découpe du monolithe `index.html` | P3 | Faible | L | — | 8–15 j | Maintenabilité ; pré-requis à une accélération d'équipe. |

## C — Fonctionnalités métier

| ID | Demande | Prio | Impact | Cplx | Dépendances | Est. | Justification |
|---|---|---|---|---|---|---|---|
| C1 (`RC2-COV-1`) | Saisie native `service_id` + moteur de couverture par tranche | P2 | Élevé | L | ADR-001 | 8–12 j | Couverture fine par service/tranche (P1 fonctionnel). |
| C2 (`RC2-FE-2/3`) | `v_staff_month_summary` + `check_replacement_constraints` via segments | P3 | Moyen | M | ADR-006 | 3 j | Finaliser la migration des consommateurs d'heures. |
| C3 (`RC2-PAIE-1`) | Règle HS 25/50 % conventionnelle (validée cabinet paie) | P2 | Élevé | M | métier paie | 3–5 j | Conformité de la ventilation heures sup. |
| C4 | **Drag & Drop** du déplacement (UX) | P3 | Élevé | L | pilote OK | 8–12 j | Explicitement hors RC1 ; à évaluer après retours pilote. |

## D — Innovations (exploratoire, non engagé)

| ID | Demande | Prio | Impact | Cplx | Dépendances | Est. | Justification |
|---|---|---|---|---|---|---|---|
| D1 | Observabilité runtime (logs structurés + alerting) | P2 | Moyen | M | — | 3–5 j | Passer d'un audit métier à une observabilité exploitation. |
| D2 | Optimisations perf à l'échelle (`auth_rls_initplan`, FK indexées) | P2 | Moyen | M | volume | 3–5 j | Tenue en charge au-delà du pilote (voir `RC2-PERF-*`). |
| D3 | Suggestions IA de renfort (aide à la décision) | P3 | Inconnu | L | données pilote | ? | À cadrer **après** validation métier ; hors périmètre actuel. |

---

## Règle de priorisation
Une demande ne passe de la roadmap au développement que si : (1) RC2 est ouverte
(`rc2-entry-criteria.md`), (2) la demande est reliée à une User Story et à des critères
d'acceptation, (3) ses dépendances sont satisfaites. Les retours du pilote
(`user-feedback.md`) peuvent **réordonner** cette roadmap.
