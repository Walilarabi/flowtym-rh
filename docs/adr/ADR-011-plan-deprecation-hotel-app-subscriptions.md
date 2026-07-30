# ADR-011 — Plan de dépréciation de `hotel_app_subscriptions`

**Statut** : Approuvé sur le principe — **Phase 1 (retrait du consommateur "portail Super
Admin") exécutée par la PR #18**, en attente de merge. Les phases suivantes (observation de
`invite-hotel-primary-contact`, retrait de `current_user_has_app()`, archivage, suppression)
restent des chantiers distincts, non ouverts, chacun nécessitant sa propre validation CTO.

**Amendement du 30/07/2026** : le contrat de la prévisualisation exigeait que "prévisualisation
manuelle = exécution manuelle = `hotel_subscriptions` uniquement" — un écart entre ce que la
prévisualisation annonçait (uniquement l'abonnement principal) et ce que l'exécution réelle
modifiait (l'abonnement principal **et** `hotel_app_subscriptions`, via l'ancienne
`process_expired_subscription_trials()`) a été jugé inacceptable pour une action Super Admin.
La PR #18 retire donc ce consommateur interne : `admin_run_expired_trials_processing()` appelle
désormais une fonction dédiée, `process_expired_hotel_subscription_trials()`, qui ne touche que
`hotel_subscriptions`. C'est la première étape **effective** de la Phase "retrait des
consommateurs internes" prévue en §1/§3 ci-dessous — décrite ici avec la précision que ce
chantier appelait, le reste (`current_user_has_app`, l'Edge Function, l'archivage, la
suppression) demeurant à l'état de plan.

**Portée** : complète ADR-009 (architecture générale du portail) et ADR-010 (résolution des
droits, Phase 2A) sur un point qu'aucun des deux ne tranchait : l'avenir de la table
`hotel_app_subscriptions` elle-même, une fois établi qu'elle est un composant legacy en fin de
vie (cf. étude de dépréciation, conversation CTO du 30/07/2026).

---

## Contexte — pourquoi cette table est en fin de vie

Résumé des faits établis par introspection directe de la base de production
(`hzrzkvdebaadditvbqis`), du dépôt, et des Edge Functions déployées :

- **Aucune policy RLS**, vue ou trigger ne consulte `hotel_app_subscriptions` ou
  `current_user_has_app()` pour accorder un accès réel. L'accès RH (`employees`,
  `staff_planning`) et PMS (`reservations`, `rooms`) repose exclusivement sur
  `pl_my_hotels()` / `get_user_hotel_id()` / `pl_portal_employee_id()` — appartenance à
  l'hôtel, indépendamment de tout statut d'abonnement applicatif.
- Le chemin de création d'hôtel réellement câblé dans `admin.html`
  (`admin_create_hotel_with_subscription`) n'alimente jamais cette table.
- Son seul chemin d'écriture potentiel restant, l'Edge Function
  `invite-hotel-primary-contact` (v9, `status: ACTIVE`), est déployée mais sans aucune
  invocation enregistrée (`platform_logs` : 0 ligne `hotel_primary_contact_invited`), non
  appelée par aucun code frontend, et documentée par ADR-009 comme *« laissée intacte, hors
  périmètre »*.
- Aucune table ne référence ses lignes par clé étrangère (`pg_constraint.confrelid` : 0
  résultat) — rien ne dépend structurellement d'elle.
- Volumétrie réelle : 2 lignes (Folkestone RH/PMS), contre 24 lignes `user_app_access` et 5
  lignes `hotel_subscriptions` — elle ne peut structurellement pas être le mécanisme qui donne
  accès à la majorité des utilisateurs réels.

**Conséquence** : la dépréciation ne consiste pas à retirer un système actif, mais à clore
formellement un système déjà inerte en pratique — avec un seul point d'incertitude résiduel
(un appelant externe non identifiable depuis ce dépôt), traité ci-dessous par une phase
d'observation avant toute suppression de schéma.

---

## 1. Étapes techniques de dépréciation

Six phases, chacune un jalon distinct nécessitant sa propre validation CTO avant de passer à
la suivante. La phase 1 se scinde en deux sous-étapes indépendantes l'une de l'autre — le
retrait du consommateur "portail" ne dépend techniquement pas de l'observation de l'Edge
Function externe (aucun lien de cause entre les deux), c'est pourquoi il a pu être exécuté
sans attendre :

1. **Retrait des consommateurs internes, sous-étape 1a — le portail Super Admin**
   — ✅ **Exécuté (PR #18)**. `admin_run_expired_trials_processing()` n'appelle plus
   `process_expired_subscription_trials()` (qui touchait aussi `hotel_app_subscriptions`) mais
   `process_expired_hotel_subscription_trials()`, dédiée à `hotel_subscriptions` uniquement.
   L'ancienne fonction reste en base, intacte, non supprimée — simplement sans appelant.
1bis. **Gel et observation** de l'unique chemin d'écriture externe restant
   (`invite-hotel-primary-contact`) — *non commencé, chantier distinct*.
2. **Retrait des consommateurs internes, sous-étape 1b — `current_user_has_app()`**
   — *non commencé*, à traiter une fois la phase 1bis confirmée sans invocation réelle (par
   prudence de méthode : clore l'observation du seul chemin d'écriture avant de retirer le
   dernier chemin de lecture, même si les deux sont techniquement indépendants).
3. **Archivage** des lignes réelles existantes (actuellement 2 : Folkestone RH/PMS).
4. **Suppression du schéma** (`DROP TABLE`), après une fenêtre de sécurité post-étape 2.
5. **Amendement documentaire** (ADR-010 et le présent document, clôturés).

## 2. Migrations successives

| # | Contenu | Précondition | Statut |
|---|---|---|---|
| N | `sql/79_super_admin_p0_trial_app_access_coherence.sql` (PR #18) : crée `process_expired_hotel_subscription_trials()` (hotel_subscriptions uniquement) et repointe `admin_run_expired_trials_processing()` vers elle. **N'édite pas** `process_expired_subscription_trials()` — la laisse intacte, orpheline (0 appelant). Migration additive au sens strict : aucune donnée existante modifiée, `hotel_app_subscriptions` non touchée. | Contrat de prévisualisation (prévisualisation = exécution = `hotel_subscriptions`) validé par le CTO. | ✅ **Exécuté** (en attente de merge de la PR #18). |
| N+1 | Ajoute une instrumentation temporaire sur `invite-hotel-primary-contact` (log distinct de `hotel_primary_contact_invited`, déclenché même en cas d'échec de la fonction) OU désactive la fonction (`supabase functions delete` / passage en `status: inactive` si l'outil le permet) — décision de méthode à trancher au moment de l'exécution, pas ici. | Validation CTO explicite du présent plan (obtenue sur le principe ; reste à ouvrir comme chantier). | Non commencé. |
| N+2 | `DROP FUNCTION public.current_user_has_app(text)` — dernier chemin de lecture, déjà sans appelant réel (cf. Contexte). | Phase N+1 confirmée : 0 invocation réelle de `invite-hotel-primary-contact` sur la fenêtre d'observation (critère précis en §7). | Non commencé. |
| N+3 | Archive les lignes réelles restantes (stratégie détaillée en §4), puis `DROP TABLE public.hotel_app_subscriptions`. | Archivage vérifié restituable (§4) + fenêtre de sécurité post-N+2 écoulée sans anomalie signalée. | Non commencé. |
| N+4 | Migration purement documentaire : amendement d'ADR-010 (§6 ci-dessous), clôture du présent ADR-011 avec statut "Exécuté". | N+3 appliquée et vérifiée en production. | Non commencé. |

Chaque migration reste individuellement re-jouable en transaction `BEGIN...ROLLBACK` avant
application réelle, conformément à la doctrine déjà appliquée sur ce dossier (P0 précédent).

## 3. Conditions de bascule (entre phases)

- **Gel → Retrait des consommateurs internes** : fenêtre d'observation d'une durée à fixer par
  le CTO (proposition : 30 jours, alignée sur la durée d'un essai) sans aucune invocation
  réelle détectée de `invite-hotel-primary-contact`. Si une invocation réelle survient pendant
  cette fenêtre, la phase suivante est suspendue et le cas est traité individuellement (qui
  appelle cette fonction, pour quel usage, migration de cet appelant vers
  `admin_create_hotel_with_subscription` avant de poursuivre).
- **Retrait des consommateurs internes → Archivage/Suppression** : le retrait du consommateur
  "portail" (migration N, déjà exécuté) ne déclenche par lui-même aucune fenêtre de sécurité
  supplémentaire — il ne change rien pour `hotel_app_subscriptions` elle-même, seulement pour
  son ancien appelant. La fenêtre de sécurité s'applique au retrait de `current_user_has_app`
  (N+2) : aucune régression détectée sur les tests SQL/Jest/Playwright après son retrait —
  proposée à 14 jours en production avant la migration N+3.
- **Chaque bascule est un acte CTO explicite**, documenté dans le commit qui l'exécute — jamais
  une continuation automatique d'une phase à l'autre.

## 4. Stratégie d'archivage

Doctrine du projet, déjà appliquée à `hotel_subscriptions`/`hotel_subscription_events` :
**aucune perte d'historique, jamais un simple `DELETE`.**

Deux options techniques, à trancher au moment de l'exécution (pas ici) :

- **Option A — table d'archive dédiée** : `hotel_app_subscriptions_archive`, copie exacte du
  schéma au moment de l'archivage + colonnes `archived_at`, `archived_reason`,
  `archived_by`. Simple, isolée, ne pollue aucune table active.
- **Option B — événement dans `hotel_subscription_events`** : un événement
  `legacy_app_subscription_archived` par ligne archivée, rattaché à l'abonnement principal de
  l'hôtel concerné (`subscription_id`), avec le contenu complet de la ligne dans
  `metadata_before`. Avantage : reste dans le flux d'audit déjà consulté par le portail
  Super Admin (drawer "Historique") ; inconvénient : mélange deux niveaux de granularité
  (abonnement principal vs accès applicatif legacy) dans une même table.

**Recommandation à ce stade** (à confirmer lors de l'exécution) : Option A, pour la même
raison qui a fait préférer `hotel_addon_subscriptions` à une extension de
`hotel_subscription_events` en Phase 2A — ne pas mélanger deux objets métier distincts dans
une même table d'audit.

Dans les deux cas : l'archivage porte sur la totalité des lignes existantes au moment de
l'exécution (aujourd'hui 2, potentiellement plus si de nouvelles lignes apparaissent pendant
la phase d'observation — traité comme une anomalie, cf. §3).

## 5. Critères de suppression définitive

La migration N+3 (`DROP TABLE`) ne doit être exécutée que si **toutes** les conditions
suivantes sont vérifiées simultanément :

1. Retrait du consommateur "portail" (migration N) mergé et déployé sans anomalie — déjà
   satisfait dès le merge de la PR #18.
2. Fenêtre d'observation de la phase N+1 écoulée sans invocation réelle de
   `invite-hotel-primary-contact` (§3).
3. `current_user_has_app()` retirée (migration N+2) depuis au moins la fenêtre de sécurité
   définie en §3, sans anomalie signalée (support, audit, ou alerte plateforme).
4. Archivage exécuté et vérifié restituable (une requête de contrôle post-archivage doit
   confirmer que chaque ligne source a son équivalent exact dans l'archive, avant le `DROP`).
5. Aucune nouvelle ligne `hotel_app_subscriptions` apparue depuis le début de la phase
   d'observation (sinon, reprise du cas au §3).
6. Validation CTO explicite portant sur cette migration précise — pas une validation
   générique du présent plan.

## 6. Impacts sur ADR-010

- **§1 (conditions de levée du verrou `enforce`)** : la condition 3 (« le cas Folkestone
  tranché ») est satisfaite par la disparition de `hotel_app_subscriptions` elle-même plutôt
  que par une synchronisation permanente avec `hotel_subscriptions` — clôture plus nette que
  ce qu'ADR-010 envisageait initialement (qui ne prévoyait qu'une régularisation de contenu,
  pas un retrait de table). Les conditions 1, 2 et 4 d'ADR-010 restent inchangées et
  indépendantes de ce plan.
- **§2 (verrouillage `SKIP LOCKED`)** : sans impact — ne concerne que le comportement de
  `process_expired_subscription_trials` sur les lignes `hotel_subscriptions`, boucle
  conservée.
- **§3 (activation du job planifié)** : sans impact direct, mais la migration N (déjà exécutée)
  simplifie déjà la précondition « le traitement des essais expirés ne doit plus produire
  d'effet sur une table dont l'état cible n'est pas défini » — `admin_run_expired_trials_processing`
  ne concerne plus que `hotel_subscriptions`, une seule table au lieu de deux.
- **§4 (doctrine de régularisation)** : continue de s'appliquer telle quelle à
  `hotel_subscriptions` (le cas Folkestone y reste un exemple de référence) ; ne s'étend pas à
  `hotel_app_subscriptions`, qui sort du périmètre de cette doctrine une fois supprimée.
- **§5 et §6** : sans lien avec ce plan (add-ons, unicité de l'abonnement principal).

Ce plan n'annule aucune décision d'ADR-010 — il referme une des conditions qu'il avait
laissées ouvertes, par un chemin différent (suppression plutôt que synchronisation
perpétuelle).

## 7. Critères de validation avant suppression (checklist d'exécution)

À produire comme preuve, au moment de proposer la migration N+3 au CTO :

- [x] Migration N (retrait du consommateur "portail") mergée et déployée sans anomalie.
- [ ] Requête d'audit `platform_logs`/logs d'invocation Edge Function couvrant l'intégralité
      de la fenêtre d'observation (§3), montrant 0 invocation réelle.
- [ ] Confirmation que `current_user_has_app()` est retirée depuis au moins la fenêtre de
      sécurité définie, sans ticket support ni alerte plateforme associée.
- [ ] Résultat de la requête de contrôle post-archivage (comptage lignes source = lignes
      archivées, colonne par colonne sur un échantillon).
- [ ] Suite SQL rejouée en transaction `BEGIN...ROLLBACK` sur la migration N+3 elle-même,
      confirmant qu'aucune contrainte (`pg_constraint.confrelid`) ne bloque le `DROP`.
- [x] Jest complet (499/499) + tests SQL en transaction `ROLLBACK` (14/14, PR #18) confirmant
      qu'aucune ligne `hotel_app_subscriptions` n'est modifiée par le portail Super Admin.
- [ ] Validation CTO explicite, documentée dans le commit de la migration N+3.

---

## Prochaine étape

Ce document est soumis pour validation. Aucune migration n'est écrite ni appliquée à ce
stade — l'exécution (phases 1 à 5) fera l'objet d'un chantier dédié, ouvert seulement après
approbation explicite du présent plan.
