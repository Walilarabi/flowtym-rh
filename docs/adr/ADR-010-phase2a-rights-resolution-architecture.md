# ADR-010 — Résolution des droits applicatifs et cycle de vie des abonnements (Phase 2A)

**Statut** : Accepté.

**Portée** : `sql/70_super_admin_phase2a_subscription_foundation.sql`. Complète ADR-009
(architecture générale du portail Super Admin) sur le périmètre spécifique introduit en
Phase 2A : modèle d'abonnement, résolution centralisée des droits, expiration des essais.

## Contexte

La Phase 2A introduit un modèle d'abonnement normalisé (`hotel_subscriptions` comme
source de vérité commerciale, `plan_modules` comme liaison plan↔application,
`hotel_subscription_events` comme historique immuable) et une fonction centrale de
résolution des droits destinée à être réutilisée par de futurs portails/RPC. Ce document
consigne les décisions structurantes qui gouvernent cette fonction et son cycle de vie —
en particulier pourquoi elle ne peut *jamais*, dans son état actuel, modifier un accès.

---

## 1. Mode observe / enforce — pourquoi enforce est verrouillé en dur

**Décision** : `_resolve_app_access_core` calcule six conditions (utilisateur actif, hôtel
autorisé, abonnement valide, application incluse ou add-on valide, essai non expiré, accès
individuel autorisé) et compare le droit théorique au droit réel (`user_app_access`), sans
jamais écrire nulle part. `admin_resolve_app_access(..., p_mode)` expose un paramètre
`p_mode` (`observe`/`enforce`) pour ne pas casser le contrat d'appel des futurs
consommateurs, mais **toute valeur `enforce` lève systématiquement une exception
(`errcode 55000`)** avant même d'atteindre la logique de résolution.

**Justification** : au moment de l'écriture de cette fonction, les 24 lignes
`user_app_access` réelles de la plateforme divergent *toutes* du droit théorique (aucun
`plan_modules` peuplé, 4 hôtels réels sans abonnement — cf. rapport d'observation en
annexe des livrables Phase 2A). Activer un mode d'application aujourd'hui couperait
l'intégralité des accès réels. Le verrou n'est donc pas une simple précaution : c'est la
garantie technique que la Décision CTO « aucun hôtel existant ne doit perdre son accès
pendant la normalisation » ne peut pas être violée par erreur de paramètre, de rôle, ou de
changement de code non revu.

**Condition de levée du verrou** (à documenter dans le commit qui l'effectuera) :
1. `plan_modules` peuplé pour les plans commerciaux réels (décision de catalogue,
   Phase 2E) ;
2. les 4 hôtels sans abonnement régularisés (Legacy Pilot ou plan commercial définitif) ;
3. le cas Folkestone tranché (cf. fiche de décision Phase 2A) ;
4. validation CTO explicite, documentée dans le commit du changement de code qui retire
   le `RAISE EXCEPTION`.

Retirer le verrou sans ces quatre conditions réunies est une régression de sécurité, pas
une simple activation de fonctionnalité.

---

## 2. Verrouillage concurrent de l'expiration des essais — SKIP LOCKED seul

**Décision** : `process_expired_subscription_trials()` utilise `FOR UPDATE SKIP LOCKED`
sans advisory lock.

**Distinction avec ADR-003** : `group_move_apply` (ADR-003) doit sérialiser des écritures
qui peuvent survenir **avant qu'aucune ligne n'existe** (déplacements créant des segments
`staff_planning` pour la première fois pour un `(employee_id, jour)`) — un verrou de ligne
ne protège rien tant qu'il n'y a rien à verrouiller, d'où l'advisory lock hashé sur la clé
logique. `process_expired_subscription_trials` est structurellement différente : elle
n'agit *que* sur des lignes `hotel_subscriptions`/`hotel_app_subscriptions` déjà
existantes. Le verrou de ligne standard suffit : deux exécutions concurrentes (le futur
job planifié et un déclenchement manuel admin, par exemple) ne traitent jamais deux fois
la même ligne — l'une prend le verrou, l'autre l'ignore silencieusement (comptabilisé dans
`skipped_locked`) sans attendre ni échouer.

**Limite assumée** : le blocage réel entre deux sessions strictement concurrentes n'a été
vérifié que par revue de code et par un test d'idempotence séquentiel (deux appels dans la
même session), pas par un test de wall-clock réel entre deux connexions distinctes — les
outils d'exécution SQL disponibles pendant ce lot ne permettaient pas de façon fiable
d'ouvrir deux sessions réellement simultanées contre la production. Le mécanisme
`SKIP LOCKED` est un comportement standard et documenté de PostgreSQL conçu précisément
pour ce cas d'usage de file de traitement ; à revérifier en conditions réelles au moment
de l'activation du job (point 3 ci-dessous).

---

## 3. Activation future du job planifié — procédure obligatoire

**Décision** : `sql/70_...` ne crée ni n'active aucun `cron.job`. La ligne
`cron.schedule('process_expired_subscription_trials', ...)` existe uniquement en
commentaire, à titre de documentation de l'intention.

**Procédure d'activation** (quand elle sera autorisée) :
1. Migration **séparée et dédiée** (pas un ajout discret à une migration existante) ne
   contenant que l'appel `cron.schedule(...)`.
2. Préconditions : les mêmes que la levée du verrou `enforce` (§1) — un job qui expire des
   essais alors que `plan_modules` n'est pas peuplé ou que Folkestone n'est pas tranché
   produirait des effets sur des données dont l'état cible n'est pas encore défini.
3. Validation CTO explicite portant sur cette migration précise, pas une validation
   générique de la Phase 2A.
4. Une fois activé, le job reste inoffensif pour toute ligne `trial_ends_at IS NULL`
   (jamais traitée — cf. §4) : Folkestone ne sera jamais expiré automatiquement tant que
   sa date d'essai réelle n'est pas renseignée, qu'un job tourne ou non.

---

## 4. Doctrine de régularisation — snapshot incomplet toléré, jamais corrigé automatiquement

**Décision** : une ligne `hotel_subscriptions` historique incomplète (ex. Folkestone :
`trial_ends_at NULL`, colonnes `snapshot_*` toutes NULL après application de la Phase 2A)
**reste valide et lisible**. Aucune contrainte `NOT NULL` n'est ajoutée sur ces colonnes.
Aucun backfill, même approximatif, n'est effectué par la migration.

Ceci a deux conséquences délibérées :
- `_resolve_app_access_core` traite l'absence de `trial_ends_at` comme une **cause**
  (`trial_missing_end_date`) distincte d'une expiration — jamais comme un accès coupé.
- Le rapport d'observation signale ces lignes via la cause `incomplete_contract_snapshot`
  (`snapshot_effective_at IS NULL`), rendant le problème visible sans jamais le corriger
  seul.

La correction, quand elle aura lieu, passera exclusivement par les RPC de cycle de vie
(`admin_update_price_snapshot`, `admin_extend_trial`, etc.), chacune actionnée par un
Platform Admin avec motif et audit atomique — jamais par un `UPDATE` de masse.

---

## 5. Hypothèse add-on ↔ application : relation 1:1, pas encore M2M

**Décision** : `add_ons.app_id` (nullable, FK vers `platform_apps.id`) suppose qu'un
add-on ne couvre qu'**une seule** application. C'est une hypothèse de modélisation
documentée, pas un fait vérifié contre un cahier des charges commercial — au moment de
l'écriture, `hotel_addon_subscriptions` compte 0 ligne en production, donc aucune donnée
réelle ne permet de trancher.

**Si cette hypothèse s'avère fausse** (un add-on métier doit un jour couvrir plusieurs
apps), la migration de correction est connue à l'avance : remplacer `add_ons.app_id` par
une table `add_on_apps (addon_id, app_id)` symétrique à `plan_modules`, migrer les valeurs
existantes de `app_id` vers une ligne `add_on_apps` chacune (opération réversible, aucune
perte d'information), puis retirer la colonne. Documenté ici pour qu'un futur
développeur ne redécouvre pas cette question depuis zéro.

**Un add-on sans `app_id`** (mapping non renseigné) ne donne aucun droit théorique et est
signalé via la cause `addon_missing_app_mapping` — jamais silencieusement ignoré, jamais
traité comme une erreur bloquante.

---

## Impacts futurs

- Toute nouvelle cause de divergence ajoutée au résolveur doit suivre le même principe :
  un code distinct dans le tableau `causes`, jamais fusionné dans une catégorie générique.
- Toute fonction future qui bypasserait `_resolve_app_access_core` pour recalculer des
  droits par un autre chemin est une violation de cet ADR — la fonction est *la* source de
  vérité de la résolution, catégorie 2 (helper interne), jamais dupliquée.
- La levée du verrou `enforce` et l'activation du job planifié sont deux actions
  distinctes, chacune nécessitant sa propre validation CTO explicite — l'une n'implique
  pas l'autre.
