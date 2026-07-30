# Audit produit — Portail Super Admin (`/admin`)

Date : 2026-07-29. Lecture PM / UX / CTO, pas une revue de code. Périmètre : les 10 écrans
demandés (Dashboard, Hôtels, Groupes, Abonnements, Plans, Utilisateurs, Facturation, Audit,
Alertes, Supervision) + Paramètres plateforme (bonus, existant). Méthode : lecture exhaustive de
`admin.html` (3 077 lignes) et des migrations `sql/68` à `78`, zéro supposition non vérifiée dans
le code. **Aucune migration, aucun changement de code, aucun changement en production** — livrable
100% documentaire.

Version détaillée, visuelle et navigable : voir l'artefact publié dans la conversation
(`product-audit-super-admin.html`). Ce document est la version texte de référence pour le dépôt.

---

## Résumé exécutif

**Note UX moyenne : 6.4/10 — Note Produit moyenne : 5.7/10 — 37 chantiers classés P0→P3.**

Ce qui est vrai : la discipline d'ingénierie derrière ce portail est réelle et rare — 63 fonctions
`admin_*` toutes au même profil ACL, zéro écart de sécurité laissé ouvert, une modélisation
facturation (statut documentaire ≠ état financier) plus rigoureuse que bien des SaaS en
production, et une honnêteté produit inhabituelle (Supervision affiche un badge gris plutôt qu'un
faux vert quand une donnée n'est pas mesurée).

Ce qui manque : ce portail est encore un **panneau d'administration**, pas un **produit SaaS**.
Aucun graphique nulle part. Aucune action groupée sur aucun écran. Deux réglages de plateforme
(`dunning_days_before`, les objectifs MRR/ARR) existent et ne déclenchent rigoureusement rien. Un
rapport de divergence de droits est construit côté serveur et invisible côté écran. Le traitement
des essais expirés dépend d'un humain qui pense à cliquer un bouton. Le chargement de la liste des
hôtels tire six requêtes non bornées côté client — indolore à 7 hôtels, dangereux à 200.

**Le fil rouge** : presque chaque écran a le même profil — un back-end plus riche que ce que
l'écran expose. Le premier réflexe produit n'est pas de construire du nouveau, c'est de **relier
ce qui existe déjà** et de rendre visible ce qui est déjà calculé.

| Écran | UX | Produit | Priorité | Constat en une ligne |
|---|---|---|---|---|
| Tableau de bord | 6.5 | 5.5 | P0 | KPI solides, zéro tendance, zéro graphique |
| Alertes | 6 | 5 | P0 | 9 détecteurs solides, aucun geste (résoudre/reporter) |
| Hôtels | 7.5 | 6 | P1 | Meilleur écran de la liste — mais tout est chargé sans limite |
| Groupes | 5 | 5 | P0 | Petit frère négligé des Hôtels — sans filtre, tri, export |
| Utilisateurs | 6.5 | 7 | P0 | Modèle d'accès très complet, gâché par un champ ID libre |
| Abonnements | 7 | 6 | P1 | Machine à états propre, un bouton manuel tient lieu de cron |
| Plans | 6 | 6 | P2 | Catalogue fonctionnel, granularité app on/off seulement |
| Facturation | 7.5 | 6 | P1 | Modélisation exemplaire, zéro prestataire de paiement réel |
| Audit | 7 | 6.5 | P0 | Très bien filtré, export limité à la page affichée |
| Supervision | 6 | 4.5 | P1 | Honnête par construction, ne surveille encore rien |
| Paramètres (bonus) | 6 | 5 | P0 | Des réglages sans effet réel derrière eux |

---

## Dossiers par écran

### Tableau de bord (`admin.html:881-998`)
- **Existant** : 18 KPI sur 5 blocs (Plateforme, Abonnements, Applications, Facturation,
  Utilisateurs), 4 périodes préréglées, alertes cliquables vers l'entité.
- **Manques** : aucune tendance/comparaison à N-1, aucun graphique, aucun export, aucun filtre
  hôtel/groupe, aucun dashboard personnalisable.
- **Incohérence** : les alertes sont cliquables, les KPI ne le sont pas ; la cloche de
  notifications (6 dernières `platform_logs`) n'est pas cliquable non plus.
- **Quick wins (P0)** : cloche cliquable (réutiliser le mapping déjà écrit pour les alertes).
- **Majeur (P1)** : MRR/ARR/churn/conversion essai→payant réels — les données existent déjà ;
  delta % par KPI ; plage de dates personnalisée.
- Estimation : 2-3 j (quick win) / 1-2 sem (KPI revenus).

### Alertes (`admin.html:940-992`, widget du Dashboard)
- **Existant** : 9 types (3 high / 4 medium / 2 low), triés par sévérité, navigation croisée.
- **Manques** : pas d'écran dédié, pas d'historique, pas de statut "traité", plafond 25 lignes.
- **Incohérence** : perçu comme un menu de premier niveau par l'utilisateur, mais c'est un simple
  widget dans le code.
- **Quick wins (P0)** : bouton ignorer/reporter par alerte ; compteur "N alertes actives" en KPI
  Dashboard.
- **Majeur (P1/P2)** : écran Alertes à part entière avec historique et filtres ; digest
  hebdomadaire email/Slack.
- Estimation : 1 j (dismiss) / 3-5 j (écran dédié).

### Hôtels (`admin.html:998-1336`)
- **Existant** : liste, 4 filtres, tri, recherche, export CSV (lignes filtrées), fiche détail
  riche, formulaire complet, rattachement de groupe, cycle de vie de statut à 4 valeurs.
- **Manques** : aucune action groupée, aucun score de santé/risque, aucune analytique d'usage.
- **Incohérence** : Hôtels a l'export/tri que Groupes n'a pas alors que ce sont des écrans jumeaux.
- **Faille CTO** : **6 requêtes en parallèle, sans limite**, tout le dataset rapatrié côté client à
  chaque visite — tenable à 7 hôtels, dangereux à 200+.
- **Majeur (P1)** : pagination et recherche côté serveur — la dette de scaling la plus sérieuse du
  portail ; actions groupées (changer de plan/suspendre/exporter en masse).
- Estimation : pagination serveur 1-2 sem, actions groupées 1 sem.

### Groupes (`admin.html:1336-1476`)
- **Existant** : liste, compteur actif/archivé, création/édition, archivage bloqué si non vide,
  restauration.
- **Manques** : filtre statut, tri, export CSV, recherche au-delà du nom, vue financière
  consolidée.
- **Incohérence** : "Groupes archivés" est une section à faire défiler alors que Hôtels traite le
  même besoin avec un filtre standard.
- **Quick wins (P0)** : aligner sur les patterns déjà écrits pour Hôtels (filtre statut, tri, CSV)
  — copier-coller de code existant, pas de nouveau composant.
- **Majeur (P2)** : facturation consolidée par groupe ; rattachement en masse ; (P3) hiérarchie
  multi-niveaux.
- Estimation : 2-3 j.

### Utilisateurs (`admin.html:1476-1883`)
- **Existant** : fiche à 5 sections, grant/revoke par hôtel et par groupe, gestion des Super
  Admins (motif obligatoire au retrait), invitation, historique 50 événements, comptes non liés
  exposés en lecture seule.
- **Manques** : `admin_rights_divergence_report` construit côté serveur, invisible côté écran ;
  aucune section "accès applications" dans la fiche malgré la table peuplée.
- **Incohérence majeure** : retirer le dernier admin d'un hôtel ouvre un **champ texte libre** pour
  saisir l'UUID de remplacement — sur l'écran le plus soigné du portail, pour une action
  irréversible. Le texte "perdra immédiatement tout accès" à la désactivation surpromet : aucune
  révocation de session réelle n'est faite (juste un flag `is_active`).
- **Quick wins (P0)** : sélecteur d'admin scopé à l'hôtel au lieu du champ texte ; exposer le
  rapport de divergence (backend déjà prêt).
- **Majeur (P1)** : vraie révocation de session (API Admin Supabase) pour tenir la promesse déjà
  affichée à l'écran.
- Estimation : sélecteur 1-2 j, révocation de session 3-5 j.

### Abonnements (`admin.html:1883-2323`)
- **Existant** : liste + drawer riche (plan, essai, add-ons, historique), bandeau de
  régularisation "Legacy Pilot" en un clic, résiliation programmée réversible.
- **Manques** : changement de plan immédiat uniquement, aucune proration ; aucun MRR/ARR/churn
  affiché malgré les objectifs saisis en Paramètres.
- **Incohérence** : le bouton "mode enforce" (résolution d'accès) existe et échoue systématiquement
  par construction (verrouillé côté serveur, ADR-010) — devrait être grisé, pas cliquable.
- **Risque opérationnel** : "Traiter les essais expirés" est un **bouton manuel** — aucun cron ne
  l'exécute seul. C'est le point le plus fragile du portail : la logique de fin d'essai dépend
  d'un humain qui pense à cliquer.
- **Quick wins (P0)** : griser le bouton enforce avec tooltip ; afficher les objectifs MRR/ARR en
  comparaison réelle.
- **Majeur (P1)** : cron réel de traitement des essais expirés.
- Estimation : cron 3-5 j, proration 1-2 sem.

### Plans (`admin.html:2323-2485`, onglet interne d'Abonnements)
- **Existant** : création/édition/archivage motivé/désarchivage, checklist d'apps par plan.
- **Manques** : aucune colonne "N hôtels sur ce plan", granularité fonctionnalité (uniquement
  app on/off).
- Priorité P2 — solide, pas urgent. Estimation colonne "N hôtels" : 1 j.

### Facturation (`admin.html:2485-2881`)
- **Existant** : dashboard facturation, statut documentaire ≠ état financier (modélisation
  exemplaire), paiement partiel/total, avoirs, numérotation séquentielle réelle
  (`FLOW-AAAA-NNNNNN`), CSV.
- **Manques** : aucun prestataire de paiement réel connecté, facture à ligne unique, aucune
  relance automatique.
- **Incohérence** : `dunning_days_before` existe en Paramètres et ne pilote **aucune** relance
  réelle — un réglage sans effet.
- **Quick wins (P0)** : brancher `dunning_days_before` à un signal réel (a minima une liste "à
  relancer sous X jours").
- **Majeur (P1/P2)** : vrai moteur PDF (le code confirme honnêtement `window.print()` aujourd'hui) ;
  relances automatiques ; intégration prestataire de paiement réel (Stripe Billing / GoCardless /
  SEPA) — le chantier financier le plus structurant.
- Estimation : dunning 2-3 j, PDF réel 1-2 sem, prestataire de paiement 3-6 sem.

### Audit (`admin.html:2881-2965`)
- **Existant** : la seule pagination **serveur** réelle du portail (25/page, borne 200), payload
  formaté + JSON brut, 6 filtres, recherche texte.
- **Manques** : filtre par admin non exposé côté UI bien que la RPC le supporte déjà ; export
  limité à la page affichée (pas à la période filtrée entière).
- **Quick wins (P0)** : ajouter le filtre Admin ; "Exporter tout" en paginant côté serveur jusqu'à
  épuisement du filtre.
- **Majeur (P1/P2)** : vue diff avant/après lisible ; détection d'anomalie (rafale de révocations,
  actions hors-heures).
- Estimation : 2-3 j pour les deux quick wins.

### Supervision (`admin.html:3038-3072`)
- **Existant** : honnête par construction — jamais de faux badge vert ; section dédiée "signaux non
  instrumentés" (erreurs de mutation, erreurs Edge Functions, forcés à `false`).
- **Manques** : aucun monitoring d'erreurs réel, aucun historique d'incident, aucune alerte routée.
- **Quick wins (P0)** : liens externes cliquables vers Vercel/Supabase.
- **Majeur (P1)** : instrumentation réelle (Sentry ou équivalent) frontend + Edge Functions — à
  construire en préservant l'honnêteté actuelle de l'écran, pas en la maquillant.
- Estimation : liens externes 0.5 j, Sentry 1 sem.

### Paramètres plateforme (`admin.html:2967-3036`, bonus)
- **Existant** : 16 clés typées, validation client miroir du serveur, motif consigné dans l'audit.
- **Incohérence** : `dunning_days_before`, `mrr_target`, `arr_target`, `churn_alert_rate` se
  règlent ici et ne pilotent **aucun** comportement ailleurs — des réglages décoratifs.
- **Quick win (P0)** : étiqueter "Informatif, non actif" les réglages sans comportement branché,
  le temps de les câbler (partagé avec Dashboard/Abonnements/Facturation).
- Estimation étiquetage : 0.5 j.

---

## Plan de traitement consolidé

**P0 — Combler (13 chantiers, jours)** : cloche cliquable, dismiss alerte + compteur Dashboard,
parité Groupes/Hôtels (filtre/tri/export), sélecteur d'admin de remplacement, exposer le rapport
de divergence, griser le bouton enforce, objectifs MRR/ARR affichés, brancher `dunning_days_before`,
filtre Admin + export complet sur Audit, liens externes Supervision, étiquetage Paramètres.

**P1 — Fiabiliser (10 chantiers, semaines)** : pagination/recherche serveur (Hôtels, Utilisateurs,
Abonnements, Facturation), cron réel essais expirés, delta KPI Dashboard, MRR/ARR/churn réels,
révocation de session réelle, vrai moteur PDF, relances automatiques, vue diff Audit,
instrumentation Sentry, actions groupées.

**P2 — Différencier (8 chantiers, 1-2 mois)** : facturation multi-lignes, changement de plan
différé/proraté, facturation consolidée par groupe, score de santé hôtel, gestion de sessions,
palette de commandes (Cmd+K), détection d'anomalies Audit, rôles Super Admin granulaires.

**P3 — Vision (6 chantiers, dépendant de décisions business)** : prestataire de paiement réel,
e-invoicing réel, webhooks/API plateforme, historique d'incidents + routage d'alertes, import CSV
en masse, hiérarchie de groupes multi-niveaux.

---

## Roadmap — 3 prochaines versions

- **v2 — Fiabilisation** (3-4 sem) : les 13 chantiers P0 + cron essais expirés + amorce d'actions
  groupées sur Hôtels. Thème : combler les trous visibles, désamorcer les risques silencieux.
- **v3 — Scale & Finance** (6-8 sem après v2) : pagination/recherche serveur généralisée,
  MRR/ARR/churn réels avec tendance, révocation de session réelle, moteur PDF réel, relances
  automatiques, instrumentation Sentry. Thème : passer à l'échelle, professionnaliser la finance.
- **v4 — Plateforme ouverte** (8-12 sem après v3) : prestataire de paiement réel, rôles granulaires,
  palette de commandes, facturation consolidée par groupe, webhooks/API, changement de plan
  différé/proraté. Thème : devenir une vraie plateforme SaaS, pas seulement un panneau
  d'administration.

Estimations à titre indicatif. Le seul chantier dont le coût dépend d'un tiers externe (pas
seulement de l'équipe produit) est l'intégration d'un prestataire de paiement réel — à cadrer une
fois la décision business prise (Stripe Billing / GoCardless / SEPA / autre).
