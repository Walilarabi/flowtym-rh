# ADR-012 — Phase 2 du portail Super Admin : Lots 1 à 6, portail hôtel Support, divergence des droits

**Statut** : Accepté (backend/frontend livrés, aucune PR mergée, aucune migration appliquée en production — validation CTO finale en attente).

**Portée** : complète ADR-009 (architecture générale du portail Super Admin) et ADR-010
(résolution des droits, Phase 2A) sur l'ensemble du périmètre Phase 2 autorisé : Lot 1
(rétro-versionnement Support + durcissement ACL/RLS), Lot 2 (`platform_notifications`),
Lot 3 (licences en observation), Lot 4 (notifications d'essai J-7/J-3/J-1), Lot 5A/5B
(Support back-office + portail hôtel + pièces jointes), Lot 6 (statistiques + score de
santé), écran de divergence des droits. Paiements explicitement **hors périmètre** (§9).

Ce document consigne les décisions réellement prises pendant l'implémentation — y
compris les corrections d'hypothèses fausses découvertes en cours de route — pas un
plan a priori.

---

## 0. Organisation des PR et ordre de dépendance réel

9 PR ouvertes, empilées (`base` ≠ toujours `main` — voir tableau). L'empilement Git
reflète parfois une commodité de revue plutôt qu'une dépendance de contenu réelle ;
les deux sont distingués ci-dessous.

| PR | Lot | Branche | Base Git | Dépendance de contenu réelle |
|---|---|---|---|---|
| #21 | 1 PR-01 | `feat/lot1-pr01-support-retro-versioning` | `main` | Aucune |
| #22 | 1 PR-02 | `feat/lot1-pr02-support-acl-hardening` | `main` | Suppose sql/80 (PR #21) déjà en base — **doit merger après #21** |
| #23 | 2 | `feat/lot2-platform-notifications` | `main` | Aucune |
| #24 | 3 | `feat/lot3-license-usage-observation` | `main` | Aucune |
| #25 | 4 | `feat/lot4-trial-ending-notifications` | `feat/lot2-...` | Table `platform_notifications` (PR #23) |
| #26 | 5A | `feat/lot5a-support-backoffice` | `feat/lot1-pr02-...` | Policies corrigées (PR #22) + `platform_notifications` (PR #23, mergé dans la branche) |
| #27 | 5B | `feat/lot5b-support-hotel-portal` | `feat/lot5a-...` | `support_ticket_replies` (PR #26) |
| #28 | Divergence des droits | `feat/rights-divergence-screen` | `feat/lot5b-...` | **Aucune** (RPC déjà en production depuis Phase 2A) — empilée par commodité |
| #29 | 6 | `feat/lot6-statistics-health-score` | `feat/rights-divergence-...` | **Aucune** — empilée par commodité |

Ordre de merge recommandé : **#21 → #22 → #23 → #24 → #25 → #26 → #27 → #28 → #29**
(satisfait à la fois les dépendances de contenu et l'empilement Git).

---

## 1. Lot 1, PR-01 — Rétro-versionnement Support

Aucun changement d'architecture par rapport à ADR-009. Rétro-versionne à l'identique
`support_tickets`/`help_articles`/policies/triggers déjà en production (doctrine
"snapshot fidèle avant toute correction", cf. sql/80 pour le détail des 24 objets
capturés).

## 2. Lot 1, PR-02 — Durcissement ACL/RLS : découverte majeure

**Constat le plus grave de l'audit** : `TRUNCATE` sur une table avec RLS n'est **pas**
filtré par les policies — propriété documentée de PostgreSQL (RLS ne s'applique qu'aux
commandes DML ligne par ligne). Vérifié réellement en production (`BEGIN...ROLLBACK`) :
`anon` pouvait exécuter `TRUNCATE public.support_tickets` et vider la table entière,
tous hôtels confondus. Corrigé par `REVOKE ALL ... FROM anon` (aucun usage légitime de
toute façon, RLS bloquait déjà les autres commandes) et `REVOKE TRUNCATE, REFERENCES,
TRIGGER, DELETE FROM authenticated` (aucune policy ne permet DELETE pour ce rôle).

**Correction majeure de policy** (au-delà du périmètre GRANT/REVOKE initialement prévu) :
`support_select`/`support_insert`/`support_update` comparaient
`user_hotels.user_id = auth.uid()` directement. Or `user_hotels.user_id` référence
`public.users.id`, **pas** `auth.users.id` — `auth.uid()` renvoie l'`auth_id` du JWT,
une valeur différente de `public.users.id` pour tout utilisateur réel. Conséquence :
ces 3 policies ne matchaient **jamais** pour un utilisateur hôtel réel. Prouvé en
production avec un vrai compte hôtel (`reservation@grandhotelduhavre.com`) : un INSERT
légitime dans son propre hôtel était rejeté par RLS. Corrigé en passant par
`public.users.auth_id` (jointure `user_hotels uh JOIN public.users u ON u.id =
uh.user_id WHERE u.auth_id = auth.uid()`), seule jointure correcte.

**Portée du correctif — scope explicitement limité** : le même motif défectueux existe
sur `rms_decisions`, `salon_events`, `lighthouse_imports`, `lighthouse_days`,
`rms_settings`, `onboarding_tasks`, `mi_imported_events` (vérifié en lecture seule sur
`pg_policies`). **Aucune de ces 7 tables n'a été modifiée** : elles appartiennent à des
modules RH/RMS/Salon/Lighthouse actifs, hors périmètre Support et hors périmètre de
cette Phase 2, et nécessitent leur propre audit et leurs propres tests avant toute
correction. **C'est le point le plus prioritaire hors périmètre identifié dans toute
cette Phase 2** — recommandation : PR dédiée, propriétaire du domaine RH/RMS informé.

## 3. Lot 2 — `platform_notifications`

Fondation transverse : idempotence stricte par `dedupe_key UNIQUE`, retries bornés
(`max_attempts`), aucun cron actif (déclenchement Edge Function/manuel uniquement).
RLS activée avec **zéro policy** créée volontairement (défense en profondeur : même en
cas d'erreur de grant future, RLS bloque tout accès `anon`/`authenticated` — seul
`service_role`, qui bypasse RLS par construction, y accède).

## 4. Lot 3 — Licences en observation seule

Seuil d'alerte à 90 % (`approaching`) — **choix prudent, non définitif**, documenté
comme tel dans le code et ici. Statut `unavailable` quand `snapshot_limits` ne contient
pas de quota chiffré (abonnements Legacy Pilot notamment) — jamais traité comme
`exceeded` ou `ok` par défaut. Correctif post-hoc : `admin_list_license_usage()`
avait une fuite de privilège par défaut (voir §8, motif récurrent) — `REVOKE ALL`
explicite ajouté avant merge.

## 5. Lot 4 — Notifications d'essai J-7/J-3/J-1

**Doctrine centrale, respectée strictement** : le prédicat d'éligibilité de
`admin_preview_trial_ending_notifications()` et celui de
`admin_run_trial_ending_notifications()` sont **le même prédicat SQL**, jamais dupliqué
manuellement — évite toute divergence preview/exécution (cf. l'historique v1.5.2 déjà
documenté au CHANGELOG pour un bug de cette exacte nature sur un autre module).
Idempotence par `dedupe_key = 'trial:' || subscription_id || ':' || threshold_days`.
Calcul du palier en `Europe/Paris`, stockage strict en UTC. Cron non activé.

## 6. Lot 5A — Support back-office

`support_ticket_replies` : append-only strict (aucune policy UPDATE/DELETE pour
quiconque, y compris admin) — correction par nouvelle ligne (`corrects_reply_id`,
contrainte croisée vérifiée par trigger, une FK simple ne pouvant pas l'exprimer),
masquage audité (`hidden_at/by/reason`), jamais une notification silencieuse côté
hôtel. `_is_support_staff()` : moindre privilège (`super_admin`/`support_agent`
uniquement, jamais `billing_admin`).

**Découverte pendant ce lot (hors périmètre initial mais touchant une table de son
périmètre)** : la table neuve `support_ticket_replies` elle-même avait un trou de
default-privileges — `REVOKE ALL` oublié sur `authenticated`, qui conservait
INSERT/UPDATE directs malgré le `GRANT SELECT` prévu, violant la doctrine append-only.
Trouvé par un test qui simulait une modification directe en tant qu'hôtel réel
(succès inattendu), corrigé avant merge.

## 7. Lot 5B — Portail hôtel + pièces jointes

**Décision d'architecture majeure : nouveau fichier `support-portal.html`, ni
`portal.html` ni `index.html`.** Vérifié en production avant tout code frontend : sur
6 comptes du portail salarié actifs (table `employees`/`portal_auth_id`), seuls 2 ont
une ligne `public.users` correspondante et **1 seul** une ligne `user_hotels` assortie.
Le modèle d'autorisation de tout ce Lot 5 (`_can_access_support_ticket`, RLS
`support_tickets`/`support_ticket_replies`) repose entièrement sur
`public.users.auth_id` + `user_hotels` — l'ajouter à `portal.html` l'aurait rendu non
fonctionnel pour la majorité de ses comptes réels. `support-portal.html` réutilise donc
le modèle de compte de `index.html` (`signInWithPassword`, RPC déjà existante
`pl_my_hotels()` comme porte d'accès), sans jamais toucher `index.html` (monolithe
fragile, cf. skill `flowtym-architecture` — même doctrine d'isolation que `admin.html`
en Phase 1).

**Statuts antivirus honnêtes** (aucun fournisseur choisi dans ce lot, décision non
bloquante déléguée) : `pending_upload` → `uploaded` → `scan_pending` →
{`clean`|`quarantined`|`rejected`}. `clean` n'est **jamais** atteint automatiquement —
`support-ticket-attachment-confirm` fait toujours transiter vers `scan_pending`, jamais
directement `clean`. Conséquence assumée : **aucune pièce jointe n'est téléchargeable
en pratique tant qu'aucun scanner réel n'est câblé** — `support-ticket-attachment-
download-url` l'affiche honnêtement ("analyse antivirus non disponible dans ce lot"),
jamais un faux "disponible".

**Correction découverte pendant la validation** : l'upsert du bucket Storage
(`ON CONFLICT (id) DO UPDATE`) ne forçait pas `public = false` — une dérive manuelle
antérieure (`public = true`) aurait survécu à un rejeu de la migration. Corrigé en
ajoutant `public = false` explicitement dans le `DO UPDATE SET`, avec un test de
régression dédié (force la dérive, rejoue l'upsert, vérifie la correction).

## 8. Motif récurrent — default privileges Supabase

Trouvé et corrigé indépendamment **quatre fois** dans cette Phase 2 (sql/83, sql/84,
sql/85, sql/86 avant merge) : `ALTER DEFAULT PRIVILEGES` du rôle `postgres` sur le
schéma `public` accorde automatiquement `EXECUTE` sur toute nouvelle fonction et
`arwdDxtm` (tout DML) sur toute nouvelle table à `anon`/`authenticated`/`service_role`.
Sans un `REVOKE ALL ... FROM PUBLIC, anon, [authenticated,] service_role` explicite
avant chaque `GRANT` ciblé, **toute nouvelle fonction ou table de cette Phase 2 aurait
une fuite de privilège par défaut**. Devenu une règle standing pour tout objet neuf
(vérifié systématiquement dans les tests de ce lot et des suivants).

## 9. Écran de divergence des droits

**Aucune nouvelle migration.** `admin_rights_divergence_report()` existe en
production depuis Phase 2A (`sql/70`, déjà mergé sur `main`, déjà granté à
`authenticated`, déjà gated par `is_platform_admin()`). Écran 100 % frontend,
strictement en lecture seule : le mode `enforce` du résolveur sous-jacent
(`admin_resolve_app_access`) reste verrouillé en dur (`RAISE EXCEPTION`, cf. ADR-010
§1) — aucune réparation automatique, silencieuse ou non, n'est possible depuis cet
écran ni ailleurs tant que ce verrou n'est pas levé par une décision CTO explicite.

## 10. Lot 6 — Statistiques + score de santé client/hôtel

**Séparation stricte de la Supervision** (santé technique de la plateforme,
`admin_supervision_status`, sql/76 — vérifié par lecture directe du code avant
d'écrire une ligne : aucun chevauchement de métrique).

**Doctrine anti-fabrication, vérifiée sur données réelles avant écriture du code** :
- MRR/ARR **affiché** (calculable de manière fiable : `hotel_subscriptions.
  snapshot_price_net_ht` renseigné sur 9/10 abonnements trial/active réels), mais les
  4 seuls abonnements `active` sont au tarif Legacy Pilot (0 €, régularisation Phase 2A)
  — le MRR réel aujourd'hui est donc 0 €, affiché tel quel avec l'explication, jamais
  masqué ni remplacé par une estimation.
- Conversion essai → payant **non affichée** : aucun événement de conversion organique
  dans `hotel_subscription_events` (uniquement `created`/`trial_extended`/
  `regularized_legacy`) — les 4 abonnements actifs viennent tous d'une régularisation,
  jamais d'un vrai passage essai→payant. Un taux ici aurait fabriqué une performance
  commerciale inexistante.
- Score de santé "paiement" : `platform_invoices` vide en production → indisponible
  pour tous les hôtels aujourd'hui, **exclu du composite, jamais neutralisé à une
  valeur par défaut**. Redevient automatiquement calculable dès que de vraies factures
  existent (logique conditionnelle sur `EXISTS(...)`, jamais codée en dur sur `false`).
- Score "support" : indisponible par hôtel tant qu'aucun ticket n'existe pour cet
  hôtel (pas assez d'historique pour être significatif) — jamais neutralisé à 100
  ("aucun problème" ≠ "aucune visibilité").

**Pondération explicitement provisoire** (`adoption:20, activité:20, licences:20,
support:15, rétention:15, paiement:10` sur 100, renormalisée sur les seuls sous-scores
disponibles) — présentée comme telle partout (backend et frontend), jamais comme une
vérité métier définitive. Le composite affiche systématiquement le détail par
sous-score (définition, source, période, pondération, disponibilité), jamais une seule
note globale opaque.

**Duplication documentée, à résoudre à la fusion** : `_hotel_license_usage_rows()`
(Lot 6) redérive la même logique quota/consommation que `admin_list_license_usage()`
(Lot 3, sql/83) plutôt que d'appeler cette RPC — les deux branches sont encore
indépendantes à ce stade de la Phase 2. À fusionner en un helper commun une fois les
deux PR mergées.

---

## 11. Paiements — note d'architecture (hors périmètre, non développé)

Aucune intégration Paiements dans cette Phase 2, conformément à l'instruction CTO.
État réel constaté : `platform_invoices` existe déjà (schéma complet : montants
HT/TTC/TVA, `paid_at`, `subscription_id`) mais est **vide** en production — aucune
facture réelle n'a jamais été créée. Le menu Super Admin expose une entrée
"Paiements" marquée "Phase 2" (stub, aucune donnée mensongère).

**Questions ouvertes, à trancher par décision métier avant tout développement** :
1. Fournisseur de paiement (Stripe, GoCardless, autre) — **non choisi ici**, ne doit
   pas l'être sans validation CTO explicite (risque d'engagement contractuel/technique
   non réversible).
2. Modèle de rapprochement `platform_invoices` ↔ transactions du fournisseur choisi
   (webhook, réconciliation manuelle, les deux).
3. Gestion des échecs de prélèvement / relances (```dunning_templates```/
   ```dunning_logs``` existent déjà en schéma, jamais connectés à un flux réel).
4. Calcul TVA/prorata/remboursement : **aucune hypothèse prise** dans ce lot — le
   calcul actuel de MRR (Lot 6) reste volontairement simple (`snapshot_price_net_ht`
   brut), pas un calcul de facturation réel.

**Dépendances futures** : Lot 6 (MRR/ARR) devra être recalculé sur `platform_invoices`
réel une fois le fournisseur choisi (actuellement basé sur le prix contractuel figé,
pas sur l'encaissement réel) ; le score de santé "paiement" deviendra automatiquement
disponible dès la première facture réelle créée (aucun changement de code requis, cf.
§10).

---

## 12. Dette de reconstruction du socle Super Admin — documentée, non corrigée dans cette Phase 2

`db/reconstruct/` (mécanisme de reconstruction depuis Git seul, sur instance
PostgreSQL vierge) couvre **exclusivement le périmètre pilote** (déplacement
inter-hôtels, moteur d'heures segments, garde-fou paie — `00_bootstrap.sql` à
`sql/54`). **Aucun objet du portail Super Admin (sql/68 à sql/87, ~20 fichiers,
Phase 1 et Phase 2 entières) n'est couvert par ce mécanisme.**

**Impact réel** : une reconstruction from-scratch de la base ne recrée aujourd'hui ni
`hotel_subscriptions`, ni `platform_admins`, ni `support_tickets`/`support_ticket_
replies`/`support_ticket_attachments`, ni `platform_notifications`, ni aucune RPC
`admin_*` du portail Super Admin. Le job CI "DB — reconstruction dépôt + tests"
(vérifié vert sur toutes les PR de cette Phase 2) ne teste que le périmètre pilote —
**il ne prouve pas la reconstructibilité du socle Super Admin**, malgré son nom.

**Non corrigée dans cette Phase 2**, par choix assumé : construire un mécanisme de
reconstruction propre pour ~20 fichiers couvrant 6+ domaines fonctionnels (facturation,
support, notifications, licences, statistiques) est un chantier à part entière,
comparable en ampleur à `db/reconstruct/` lui-même (qui a fermé la même dette pour un
périmètre bien plus restreint) — le faire correctement dans le temps de cette Phase 2
aurait signifié soit le bâcler (stubs non exécutables, la dette originelle que
`db/reconstruct/` a justement fermée une première fois), soit retarder la livraison
fonctionnelle demandée.

**Plan de traitement recommandé** (PR dédiée, hors Phase 2) :
1. Inventorier tous les objets bootstrappés directement en production sans jamais
   être passés par une migration versionnée pour le domaine Super Admin (même
   anti-pattern déjà documenté deux fois dans ce dépôt pour `hotels`/`hotel_groups`/
   `platform_admins` — probablement pas isolé à ces trois tables).
2. Étendre `db/reconstruct/` avec un nouveau fichier ordonné (ex. `40_super_admin_
   foundation.sql`) rejouant `sql/68` à `sql/87` dans l'ordre, sur le modèle exact de
   `10_foundation.sql`/`30_functions.sql`.
3. Ajouter un job CI dédié (ou étendre le job existant) qui reconstruit ce périmètre
   sur une instance vierge et rejoue les suites `sql/tests/*` de la Phase 2.
4. Ne pas renommer le job CI actuel tant que ce travail n'est pas fait — son nom
   ("reconstruction dépôt") est aujourd'hui trompeur sur son périmètre réel.

---

## 13. Références

ADR-009 (architecture générale), ADR-010 (résolution des droits, Phase 2A), ADR-011
(dépréciation `hotel_app_subscriptions`). CHANGELOG.md pour l'historique chronologique
détaillé de chaque correctif.
