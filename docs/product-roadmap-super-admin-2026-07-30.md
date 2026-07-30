# Roadmap produit — Portail Super Admin (`/admin`)

Date : 2026-07-30. Suite directe de `docs/product-audit-super-admin-2026-07-29.md` : aucun
nouveau problème cherché, uniquement une priorisation des 37 chantiers déjà identifiés. Version
détaillée et navigable (matrice Impact/Effort, cartes dépliables par chantier) : voir l'artefact
publié dans la conversation (`product-roadmap-super-admin.html`). **Aucun développement, aucune
migration, aucun changement de production** — livrable de planification seul.

---

## Méthode

Chacun des 37 chantiers est noté sur : valeur utilisateur, impact business, coût de développement,
risque technique, dépendances, gains UX, gains produit — puis synthétisé en **Impact (1–5)**,
**Effort (1–5)** et **priorité MoSCoW**. Répartition : **11 Must, 14 Should, 12 Could.**

Les 37 chantiers sont ensuite regroupés en 4 lots thématiques (pas les mêmes regroupements que les
tranches P0–P3 de l'audit initial, qui étaient organisées par urgence — ici par nature de travail) :

- **Lot A — Quick Wins UX** (8 items) : frictions et incohérences visibles, corrigibles isolément.
- **Lot B — Workflows & Productivité** (9 items) : sécuriser et accélérer les tâches répétitives.
- **Lot C — Pilotage & Analytics** (8 items) : rendre visibles des données déjà calculées.
- **Lot D — Plateforme & Scale** (12 items) : tenir à l'échelle, sécurité réelle, paiement réel.

---

## Matrice Impact / Effort — table de référence

| # | Chantier | Lot | Impact | Effort | Priorité |
|---|---|---|---|---|---|
| 1 | Dashboard — cloche cliquable | A | 2 | 1 | Should |
| 2 | Alertes — dismiss/reporter | A | 3 | 2 | Should |
| 3 | Alertes — compteur KPI | A | 2 | 1 | Could |
| 4 | Groupes — parité filtre/tri/export | A | 3 | 2 | **Must** |
| 5 | Utilisateurs — sélecteur admin remplacement | B | 5 | 2 | **Must** |
| 6 | Utilisateurs — exposer rapport de divergence | C | 4 | 3 | **Must** |
| 7 | Abonnements — griser bouton enforce | A | 2 | 1 | **Must** |
| 8 | Abonnements — objectifs MRR/ARR affichés | C | 3 | 2 | Should |
| 9 | Facturation — brancher `dunning_days_before` | B | 4 | 3 | **Must** |
| 10 | Audit — filtre par admin | A | 2 | 1 | Should |
| 11 | Audit — export complet | B | 3 | 3 | Should |
| 12 | Supervision — liens externes | A | 1 | 1 | Could |
| 13 | Paramètres — étiquetage réglages inactifs | A | 1 | 1 | **Must** |
| 14 | Pagination/recherche serveur (4 écrans) | D | 5 | 5 | **Must** |
| 15 | Abonnements — cron essais expirés | B | 5 | 4 | **Must** |
| 16 | Dashboard — delta vs période précédente | C | 3 | 3 | Should |
| 17 | MRR/ARR/churn réels | C | 5 | 4 | **Must** |
| 18 | Utilisateurs — révocation de session réelle | D | 5 | 5 | **Must** |
| 19 | Facturation — vrai moteur PDF | D | 4 | 5 | Should |
| 20 | Facturation — relances automatiques | B | 4 | 5 | Should |
| 21 | Audit — vue diff avant/après | C | 3 | 4 | Should |
| 22 | Supervision — instrumentation Sentry | D | 4 | 4 | **Must** |
| 23 | Actions groupées (Hôtels/Utilisateurs/Abonnements) | B | 4 | 4 | Should |
| 24 | Facturation multi-lignes | D | 3 | 4 | Could |
| 25 | Abonnements — plan différé/proraté | B | 3 | 4 | Should |
| 26 | Groupes — facturation consolidée | C | 3 | 4 | Could |
| 27 | Hôtels — score de santé | C | 3 | 3 | Should |
| 28 | Utilisateurs — gestion des sessions actives | D | 3 | 4 | Could |
| 29 | Palette de commandes (Cmd+K) | B | 3 | 4 | Could |
| 30 | Audit — détection d'anomalies | C | 3 | 4 | Could |
| 31 | Rôles Super Admin granulaires | D | 4 | 4 | Should |
| 32 | Prestataire de paiement réel | D | 5 | 5 | Should* |
| 33 | E-invoicing réel | D | 3 | 5 | Could |
| 34 | Webhooks/API plateforme | D | 3 | 4 | Could |
| 35 | Supervision — historique incidents + routage | D | 2 | 4 | Could |
| 36 | Hôtels — import CSV en masse | B | 2 | 4 | Could |
| 37 | Groupes — hiérarchie multi-niveaux | D | 2 | 4 | Could |

*\#32 : Should, mais bloqué en amont par une décision business (choix de prestataire) plutôt que
par l'équipe produit.*

---

## Les 4 lots

### Lot A — Quick Wins UX
**Objectif** : faire disparaître les frictions et incohérences visibles sans toucher à
l'architecture ; chaque item est indépendant et livrable isolément.
**Bénéfice utilisateur** : un portail qui paraît immédiatement plus fini et cohérent.
**Estimation globale** : ~2 semaines cumulées.
**Risques** : quasi nul techniquement ; le seul risque est la dispersion en trop de petites PR.
**Ordre recommandé** : 13 → 7 → 12 → 1 → 10 → 4 → 2 → 3.

### Lot B — Workflows & Productivité
**Objectif** : sécuriser et accélérer les tâches répétitives et les actions à risque du Super
Admin.
**Bénéfice utilisateur** : moins de clics, moins d'erreurs de saisie, moins de tâches qui reposent
sur la mémoire d'un humain.
**Estimation globale** : ~6–8 semaines cumulées.
**Risques** : le cron d'essais touche un flux financier (même rigueur de tests que les migrations
passées) ; les actions groupées demandent une UI de sélection cohérente sur 3 écrans.
**Ordre recommandé** : 5 → 9 → 15 → 11 → 25 → 23 → 36 → 20 → 29.

### Lot C — Pilotage & Analytics
**Objectif** : transformer les données déjà stockées en décisions visibles.
**Bénéfice utilisateur** : répond à "est-ce que ça va bien ?" en un coup d'œil.
**Estimation globale** : ~6–7 semaines cumulées ; le calcul MRR/ARR/churn (#17) est structurant.
**Risques** : le calcul de revenu récurrent doit être défini une fois, précisément, avant tout
code — un MRR mal défini est pire que l'absence de MRR.
**Ordre recommandé** : 6 → 17 → 8 → 16 → 27 → 21 → 26 → 30.

### Lot D — Plateforme & Scale
**Objectif** : tenir à l'échelle (7 → 500 hôtels), rendre réelles les promesses de sécurité et de
paiement.
**Bénéfice utilisateur** : rapidité conservée à l'échelle, sécurité et paiement réellement
effectifs.
**Estimation globale** : ~4–5 mois cumulés — le lot le plus lourd, à traiter par sous-vagues.
**Risques** : seul lot avec une dépendance à un tiers externe non contrôlable (#32, prestataire de
paiement) ; #14 et #18 touchent des chemins déjà en production — zéro régression tolérée.
**Ordre recommandé** : 14 → 22 → 18 → 31 → 19 → 28 → 24 → 34 → 32 → 33 → 35 → 37.

---

## Planning de livraison

| Version | Thème | Contenu | Durée indicative |
|---|---|---|---|
| **v2.1** | Fiabiliser & rassurer | Lot A en entier + #5* | ~3 semaines |
| **v2.2** | Automatiser les workflows | Reste du Lot B + #6* | ~6–7 semaines |
| **v2.3** | Piloter avec de vraies données | Reste du Lot C | ~6–7 semaines |
| **v3.0** | Plateforme ouverte & à l'échelle | Lot D en entier | ~4–5 mois |

\* #5 et #6 sont avancés devant leur lot d'origine (B, C) parce qu'ils sont tous deux **Must** et
bon marché (Effort ≤ 3) — conformément à la consigne de prioriser par ratio impact/effort plutôt
que par ordre d'apparition.

**Clause de dérogation** : #14 (pagination serveur) et #22 (Sentry) restent classés v3.0 par
cohérence de lot, mais les deux sont Must. Si le rythme de signature de nouveaux hôtels s'accélère
nettement avant la fin de v2.3, avancer #14 en urgence — c'est le seul risque du portail qui
grandit avec le succès commercial lui-même.

**Chantier hors contrôle de l'équipe produit** : #32 (prestataire de paiement réel) a un effort
estimé qui dépend d'un choix business (prestataire, marché) non encore arbitré ; à confirmer avant
le début effectif de v3.0.

Durées données à titre indicatif. v3.0 est volontairement large et justifiera probablement un
découpage interne (v3.0/v3.1) une fois entamée — non anticipé ici pour rester fidèle aux 4
versions demandées.
