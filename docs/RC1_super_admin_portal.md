# RC1 — Portail Super Admin (`/admin`) — Dossier de préparation

Statut : Lots 0 à 5 livrés et validés par le CTO. Ce document couvre la préparation de la
release candidate 1 (RC1). Conformément à la clôture du Lot 5, **aucun ajout fonctionnel
n'a été démarré après ce dossier** — mode stabilisation RC1.

Projet Supabase : `hzrzkvdebaadditvbqis`. Branche : `claude/flowtym-super-admin-portal-sf4hei`.
Dernier commit fonctionnel : `c749a2e` (Lot 5). Commit de référence Lot 4 : `9db62f0`.

---

## A. Migrations (Lots 0 à 5)

Toutes appliquées en production via `mcp__Supabase__apply_migration`, dans cet ordre, et
committées dans `sql/`. Aucune n'a de rollback SQL dédié (additive uniquement — cohérent avec
la contrainte du projet : jamais de `DROP`/perte de données ; un rollback réel repasserait par
une nouvelle migration corrective, jamais par un script inverse).

| Fichier | Lot | Contenu | Statut prod |
|---|---|---|---|
| `sql/68_super_admin_phase1_foundation.sql` | Lot 0 | RLS `hotel_groups`/`audit_logs`/`invoices`/`payments`, RPC `admin_create_hotel`/`admin_create_group`/etc., `platform_dashboard_kpis()` | Appliqué |
| `sql/69_super_admin_phase1_security_hardening.sql` | Lot 0 (hotfix) | Durcissement ACL/atomicité suite revue adversariale | Appliqué |
| `sql/70_super_admin_phase2a_subscription_foundation.sql` | Lot 0.5 | Fondations abonnement/essai, `hotel_subscription_events`, resolver `_resolve_app_access_core` | Appliqué |
| `sql/71_super_admin_phase2b_lot1_workflows.sql` | Lot 1 | RPC changement de plan, catalogue plans/applications | Appliqué |
| `sql/72_super_admin_phase2c_lot2_hotels_groups.sql` | Lot 2 | Écrans Hôtels/Groupes : RPC manquantes | Appliqué |
| `sql/73_super_admin_phase2d_lot3_users_access.sql` | Lot 3 | ACL `user_hotels`, RPC `platform_admin` | Appliqué |
| `sql/74_super_admin_phase2d_lot3b_users_frontend_support.sql` | Lot 3b | Support frontend module Utilisateurs | Appliqué |
| `sql/75_super_admin_phase2e_lot4_billing.sql` | Lot 4 | Schéma facturation plateforme, RPC facture/paiement/avoir | Appliqué |
| `sql/76_super_admin_phase2f_lot5_dashboard_audit_settings_supervision.sql` | Lot 5 | Réserves Lot 4 + Dashboard/Alertes/Audit/Paramètres/Supervision | Appliqué (validé 26/26, commit `c749a2e`) |
| `sql/77_super_admin_rc1_acl_hygiene.sql` | RC1 (stabilisation) | REVOKE/GRANT sur `admin_set_default_hotel`/`grant_superadmin_on_new_hotel` — aucun changement de comportement | Appliqué, vérifié non-destructivement (cf. B.3) |

Chaque fichier possède un test SQL versionné correspondant sous `sql/tests/` (sauf 68/69/70/71/72,
antérieurs à l'introduction de ce pattern — validés à l'époque par script combiné en transaction
`BEGIN...ROLLBACK`, non re-conservés en fichier séparé).

---

## B. Inventaire RPC + ACL (automatable, requête réelle exécutée le 2026-07-29)

Généré par introspection directe (`pg_proc` + `has_function_privilege` + recherche littérale de
`is_platform_admin()`/`_platform_log(` dans le corps de fonction via `pg_get_functiondef`), pas
un rapport rédigé à la main. Reproductible avec :

```sql
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
  CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'SECURITY INVOKER' END AS sec,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_exec,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_exec,
  (pg_get_functiondef(p.oid) ILIKE '%is_platform_admin()%') AS has_super_admin_guard,
  (pg_get_functiondef(p.oid) ILIKE '%_platform_log(%') AS calls_platform_log
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND (p.proname LIKE 'admin\_%' OR p.proname LIKE 'org\_%' OR p.proname LIKE 'platform\_%'
       OR p.proname IN ('is_platform_admin','_platform_log','_resolve_app_access_core',
         '_recompute_invoice_paid_at','_next_platform_invoice_number',
         '_next_platform_credit_note_number','grant_superadmin_on_new_hotel'))
ORDER BY p.proname;
```

### B.1 Fonctions `admin_*` (RPC Super Admin — 100% conformes au modèle attendu)

Toutes les **63 fonctions `admin_*`** interrogées présentent exactement le même profil ACL :
`anon_exec=false`, `authenticated_exec=true`, `service_role_exec=false`,
`has_super_admin_guard=true` (sauf 6 fonctions de lecture pure listées ci-dessous où le guard est
présent mais `calls_platform_log=false` car une lecture n'a rien à auditer). Aucune exception,
aucun oubli détecté.

| Fonction | Lot | Type | Audit (`_platform_log`) |
|---|---|---|---|
| `admin_attach_addon` | 1 | mutation | oui |
| `admin_attach_hotel_to_group` | 0 | mutation | oui |
| `admin_cancel_platform_invoice` | 4/5 | mutation | oui |
| `admin_cancel_subscription_immediate` | 1 | mutation | non |
| `admin_change_subscription_plan` | 1 | mutation | non |
| `admin_convert_trial_to_active` | 1 | mutation | non |
| `admin_create_group` | 0 | mutation | oui |
| `admin_create_hotel` | 0 | mutation | oui |
| `admin_create_hotel_with_subscription` | 1 | mutation | oui |
| `admin_create_plan` | 1 | mutation | oui |
| `admin_create_platform_credit_note` | 4 | mutation | oui |
| `admin_create_platform_invoice` | 4 | mutation | oui |
| `admin_create_subscription` | 1 | mutation | oui |
| `admin_delete_group` | 2 | mutation | oui |
| `admin_detach_addon` | 1 | mutation | oui |
| `admin_detach_hotel_from_group` | 2 | mutation | oui |
| `admin_extend_trial` | 1 | mutation | non |
| `admin_get_platform_invoice_detail` | 4/5 | **lecture** | — |
| `admin_get_user_detail` | 3 | **lecture** | — |
| `admin_grant_hotel` | 3 | mutation | oui |
| `admin_grant_hotel_group_access` | 3 | mutation | non |
| `admin_grant_platform_admin` | 3 | mutation | oui |
| `admin_issue_platform_invoice` | 4 | mutation | oui |
| `admin_list_platform_audit_log` | 5 | **lecture** | — |
| `admin_list_platform_invoices` | 4/5 | **lecture** | — |
| `admin_list_unlinked_auth_users` | 0 | **lecture** | — |
| `admin_list_user_access` | 3 | **lecture** | — |
| `admin_platform_alerts` | 5 | **lecture** | — |
| `admin_platform_overview_kpis` | 5 | **lecture** | — |
| `admin_reactivate_subscription` | 1 | mutation | non |
| `admin_record_platform_payment` | 4/5 | mutation | oui |
| `admin_regularize_legacy_subscription` | 0.5 | mutation | oui |
| `admin_renew_subscription` | 1 | mutation | non |
| `admin_resolve_app_access` | 1 | mutation | non |
| `admin_restore_group` | 2 | mutation | oui |
| `admin_reverse_platform_payment` | 5 | mutation | oui |
| `admin_revert_scheduled_cancellation` | 1 | mutation | non |
| `admin_revoke_hotel` | 3 | mutation | oui |
| `admin_revoke_hotel_group_access` | 3 | mutation | non |
| `admin_revoke_platform_admin` | 3 | mutation | oui |
| `admin_rights_divergence_report` | 3 | **lecture** | — |
| `admin_run_expired_trials_processing` | 1 | mutation (batch) | oui |
| `admin_schedule_subscription_cancellation` | 1 | mutation | non |
| `admin_set_app_access` | 3 | mutation | non |
| `admin_set_default_hotel` | pré-existant | mutation | non — **cf. B.3** |
| `admin_set_hotel_role` | 3 | mutation | oui |
| `admin_set_hotel_status` | 0 | mutation | oui |
| `admin_set_plan_active` | 1 | mutation | oui |
| `admin_set_plan_archived` | 1 | mutation | oui |
| `admin_set_plan_modules` | 1 | mutation | oui |
| `admin_set_user_status` | pré-existant | mutation | oui |
| `admin_supervision_status` | 5 | **lecture** | — |
| `admin_suspend_subscription` | 1 | mutation | non |
| `admin_suspend_subscription_for_nonpayment` | 4 | mutation (wrapper) | non (délègue à `admin_suspend_subscription`) |
| `admin_update_group` | 2 | mutation | oui |
| `admin_update_hotel` | 0 | mutation | oui |
| `admin_update_hotel_full` | 2 | mutation | oui |
| `admin_update_plan` | 1 | mutation | oui |
| `admin_update_platform_payment_status` | 4/5 | mutation | oui |
| `admin_update_platform_setting` | 5 | mutation | oui |
| `admin_update_price_snapshot` | 1 | mutation | non |
| `admin_void_platform_credit_note` | 4 | mutation | oui |

### B.2 Helpers internes (`_`-préfixés — jamais exposés côté client)

| Fonction | anon | authenticated | service_role | Notes |
|---|---|---|---|---|
| `_platform_log` | false | false | false | centralise l'écriture `platform_logs` |
| `_recompute_invoice_paid_at` | false | false | false | Lot 5, réserve 2 |
| `_resolve_app_access_core` | false | false | false | resolver divergence observe/enforce |
| `_next_platform_invoice_number` | false | false | false | séquence atomique |
| `_next_platform_credit_note_number` | false | false | false | séquence atomique |

Les 5 sont fermées sur les 4 rôles clients — conforme au doctrine du projet (jamais de `GRANT`
sur un helper interne, quel que soit le rôle).

### B.3 Fonctions historiques hors périmètre — écarts ACL analysés et corrigés

Analyse détaillée demandée par le CTO avant merge (signature, owner, ACL brute via `proacl`,
présence de garde interne, usage, risque réel, décision). Les deux écarts identifiés en première
passe ont été **vérifiés en profondeur (lecture du corps de fonction, pas seulement du nom) puis
corrigés** par `sql/77_super_admin_rc1_acl_hygiene.sql` (appliqué en production), un correctif de
sécurité pur autorisé pendant le freeze, sans changement de comportement :

- **`admin_set_default_hotel(p_user_id uuid, p_hotel_id uuid)`** — `RETURNS void`, owner
  `postgres`, `SECURITY DEFINER`. **Correction d'une erreur de la première passe de ce dossier** :
  ce n'est **pas** une fonction self-service comme initialement supposé sans lecture du code — la
  lecture du corps de fonction confirme qu'elle contient bien
  `IF NOT public.is_platform_admin() THEN RAISE EXCEPTION ... '42501'` : c'est une **véritable
  mutation Super Admin** (elle permet de définir l'hôtel par défaut d'un utilisateur *arbitraire*,
  pas seulement de l'appelant). ACL brute avant correctif : `{=X/postgres,...,anon=X/postgres,
  authenticated=X/postgres,service_role=X/postgres}` — c'est-à-dire un grant PUBLIC (donc anon/
  authenticated/service_role) jamais révoqué depuis sa création, seule fonction `admin_*` du
  projet dans ce cas. **Usage** : fonction frontend potentielle (pas appelée par `admin.html`
  aujourd'hui, mais exposée). **Risque réel avant correctif** : faible mais réel — un appelant
  anonyme pouvait invoquer la fonction (elle aurait échoué avec 42501 grâce à la garde interne,
  donc aucune exploitation possible), mais la défense en profondeur (ACL fermée) manquait,
  contrairement aux 61 autres fonctions `admin_*`. **Décision : A — correction obligatoire avant
  merge**, appliquée : `REVOKE ALL ... FROM PUBLIC, anon, service_role; GRANT EXECUTE ... TO
  authenticated;`. Vérifié après coup : `anon_exec=false`, `authenticated_exec=true`,
  `service_role_exec=false`, `public_exec_via_acl=false`.
- **`grant_superadmin_on_new_hotel()`** — `RETURNS trigger`, owner `postgres`,
  `SECURITY DEFINER`, fonction du trigger `trg_grant_superadmin_on_new_hotel`
  (`AFTER INSERT ON hotels`, cf. section D.6), **pas une RPC**. Corps de fonction confirmé :
  référence `NEW.id`/`NEW.name`, non défini hors contexte trigger — Postgres refuse
  structurellement tout appel direct d'une fonction `RETURNS trigger` en dehors d'un déclenchement
  de trigger, indépendamment de son ACL. **Risque réel : nul, prouvé** (protection au niveau du
  moteur, pas seulement applicative). ACL brute avant correctif : même grant PUBLIC jamais
  révoqué. **Usage** : interne (trigger uniquement), aucun usage frontend. **Décision : le risque
  nul rendait ceci une dette B (acceptable après RC1) au sens strict, mais corrigé quand même par
  cohérence et par prudence** (coût nul, même migration que ci-dessus) :
  `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role;`. **Vérifié non-destructivement**
  après application : un test en transaction `BEGIN...ROLLBACK` confirme que le trigger continue
  de fonctionner normalement après le `REVOKE EXECUTE` (l'insertion d'une nouvelle ligne dans
  `hotels` déclenche toujours l'attribution automatique au Super Admin actif) — la révocation
  d'EXECUTE sur une fonction n'affecte jamais son invocation par le mécanisme de trigger, qui
  s'exécute indépendamment des privilèges du rôle appelant sur la fonction elle-même.
- **`org_create_hotel` / `org_update_hotel` / `org_set_hotel_status` / `org_detach_hotel` /
  `org_get` / `org_provision`** — ouvertes à `anon`/`authenticated`/`service_role` par design :
  ce sont les RPC self-service tenant utilisées par `index.html`, **non liées au portail Super
  Admin**, hors périmètre de ce chantier. Non modifiées.
- **`is_platform_admin()` / `platform_admin_role()` / `platform_dashboard_kpis()`** — ouvertes à
  tous les rôles par design : ce sont des fonctions de lecture bon marché (retournent
  `false`/`null` pour un non-admin) utilisées comme garde en amont par le frontend lui-même ;
  aucune donnée sensible n'est retournée à un appelant non-admin. Non modifiées.

**Aucun écart ACL restant ouvert dans le périmètre du portail Super Admin après ce correctif.**

### B.4 Tables sensibles — ACL vérifiée

| Table | anon SELECT | anon DML | service_role DML |
|---|---|---|---|
| `platform_invoices` | false | false | false |
| `platform_contracts` | false | false | false |
| `platform_payments` | false | false | false |
| `platform_credit_notes` | false | false | false |
| `platform_settings` | false | false | false |
| `platform_logs` | false | false | false |
| `platform_schema_markers` | false | false | false |
| `platform_admins` | false | false | (hérité Lot 0, non re-testé ce lot) |

---

## C. Edge Functions

Inventaire réel (`mcp__Supabase__list_edge_functions`), 20 fonctions actives au total sur le
projet. Seules 2 concernent le portail Super Admin :

| Slug | Version | `verify_jwt` | Rôle | Lien Super Admin |
|---|---|---|---|---|
| `invite-user` | 26 | true | Invitation d'un utilisateur hôtel | Patchée Lot 3 : bypass Super Admin ajouté pour permettre l'invitation cross-hôtel sans appartenance préalable |
| `invite-platform-admin` | 10 | **false** | Invitation d'un Super Admin | `verify_jwt=false` — l'authentification/autorisation doit être vérifiée dans le corps de la fonction elle-même, pas déléguée à la gateway. **À auditer explicitement avant tout usage financier ou d'accès élargi** (non re-audité dans ce chantier ; le module a été utilisé mais son code source n'a pas été relu ligne à ligne ici) |

Les 18 autres (`send-whatsapp`, `attachment-access`, `gdpr-erase-guest`, `yousign-*`,
`clock-portal`, `rh-assistant`, `contract-*`, `sig-*`, `trigger-backup`, `send-dispute-email`,
`html-test`) appartiennent à l'application hôtel (`index.html`) / module Checkout / RH — hors
périmètre du portail Super Admin, non modifiées par ce projet.

**Dette confirmée (déjà signalée Lot 4)** : aucun harnais de test automatisé pour les Edge
Functions n'existe dans ce repo (ni pour celles-ci, ni pour les autres). Reporté post-RC1.

---

## D. Sécurité

### D.1 Matrice des rôles (self-consistante avec B)

| Rôle | Portée | Exemple de garde |
|---|---|---|
| `anon` | Aucun accès aux RPC/tables `admin_*`/`platform_*` de ce projet | `REVOKE ALL ... FROM anon` systématique |
| `authenticated` non-Super-Admin | Refusé par `IF NOT is_platform_admin() THEN RAISE EXCEPTION ... '42501'` à l'intérieur de chaque RPC | Testé explicitement (Test 20, Lot 5 : 5 RPC vérifiées, chacune avec un booléen `v_refused` dédié) |
| `authenticated` Super Admin (`platform_admins.role='super_admin'`, `is_active=true`) | Accès complet aux RPC `admin_*` | — |
| `service_role` | Volontairement exclu de toutes les RPC/tables `admin_*`/`platform_*` — aucune voie de contournement même depuis un contexte serveur | `REVOKE ALL ... FROM service_role` systématique |

### D.2 Helpers internes

Voir B.2 — 5 helpers, tous fermés sur les 4 rôles clients.

### D.3 Fonctions frontend directement appelées par `admin.html`

Toutes les fonctions de la section B.1 sauf celles marquées "pré-existant" en B.3, plus
`is_platform_admin()` (garde d'accès au shell) et `platform_admin_role()` (affichage du rôle
dans l'en-tête).

### D.4 Tables sensibles

Voir B.4.

### D.5 Écart ACL restant sur les fonctions historiques

Voir B.3 — 6 fonctions/triggers hors périmètre documentées, aucune ne représente un risque
d'exploitation directe avérée (auto-vérification interne ou nature non-RPC), mais 2 corrections
d'hygiène (renommage `admin_set_default_hotel`, revoke `grant_superadmin_on_new_hotel`) sont
recommandées en RC1 ou juste après.

### D.6 Trigger `trg_grant_superadmin_on_new_hotel` (documenté, non modifié)

Trigger `AFTER INSERT ON public.hotels`, `SECURITY DEFINER`, fonction
`grant_superadmin_on_new_hotel()`. Comportement : sélectionne le `platform_admins` actif avec
`role='super_admin'` le plus ancien (`ORDER BY pa.created_at LIMIT 1`) et lui insère une ligne
`user_hotels(role='direction', is_default=false)` sur le nouvel hôtel, via
`ON CONFLICT (user_id, hotel_id) DO NOTHING`. Effet de bord découvert pendant le Lot 5 : **tout
hôtel nouvellement créé a donc, par défaut, un administrateur de fait** — un test Lot 5
("hôtel sans administrateur détecté") a dû explicitement supprimer cette ligne pour vérifier le
scénario "aucun admin". C'est un comportement de production légitime (évite qu'un hôtel fraîchement
créé ne soit orphelin), mais il doit être connu de quiconque écrit un futur test ou une future
alerte sur ce sujet — sinon on obtient un faux négatif silencieux, pas une exception.

### D.7 Constat transversal — anon et privilèges table-level (non corrigé, point de décision RC1)

Un balayage `information_schema.role_table_grants` (fait en Lot 5) montre que `anon` possède des
privilèges INSERT/UPDATE/DELETE au niveau TABLE sur plus de 250 tables du schéma `public` —
bien au-delà des seules tables `platform_*` déjà retrofixées lots précédents. C'est un
paramétrage de privilèges par défaut au niveau du projet (vraisemblablement un
`ALTER DEFAULT PRIVILEGES` appliqué une fois, avant ce chantier), sur lequel toute l'application
hôtel (`index.html`) repose déjà, RLS étant la seule ligne de défense réelle. C'est un modèle
Supabase standard et défendable, mais sans la défense en profondeur (revoke explicite au niveau
table + fonction) appliquée aux tables touchées par ce projet (Lots 0/2/3/4/5).

**Décision requise du CTO avant tout traitement** : corriger ce point à l'échelle du schéma
entier dépasse le mandat de ce projet et risque de casser des flux anonymes légitimes jamais
audités ici (portails de signature, auto-check-in...). Recommandation : **ne pas traiter avant
RC1**, et si un traitement est décidé, le faire comme un chantier dédié avec son propre audit des
flux anonymes existants.

### D.8 Vérification ciblée — `group_move_cancellations` / `group_move_replacements` (findings advisors Checkout)

Vérification demandée avant merge : aucune fonction `admin_*`/`platform_*` du portail Super
Admin, aucune vue nommée `admin*`, et aucune ligne d'`admin.html` ne référencent ces deux tables.
Confirmé par deux requêtes directes (`pg_get_functiondef` sur toutes les fonctions
`admin_*`/`platform_*` + `pg_views.definition`, et `grep` sur `admin.html` et les 10 fichiers de
migration Super Admin) : **zéro occurrence**. Les deux seules fonctions qui les référencent dans
tout le schéma sont `group_move_cancel_applied` et `group_move_replace_applied` — le workflow de
remplacement du module Planning de groupe (Checkout), sans lien avec le portail Super Admin.
**Conclusion : risque strictement confiné au module Checkout, aucun chemin d'exposition via le
portail Super Admin. Dette documentée, non traitée dans cette branche (hors mandat).**

---

## E. Tests

### E.1 Tests SQL par lot (transaction `BEGIN...ROLLBACK`, jamais commités)

| Lot | Scénarios | Résultat final |
|---|---|---|
| Lot 0 (68/69) | ~15 (sécurité/atomicité, non conservés en fichier séparé) | 100% PASS |
| Lot 0.5 (70) | 38 | 100% PASS |
| Lot 1 (71) | non isolé en fichier dédié | 100% PASS (validé au moment du lot) |
| Lot 2 (72) | non isolé en fichier dédié | 100% PASS |
| Lot 3 (73/74) | 19 (`phase2d_lot3...` — cf. historique, corrigé/re-validé) | 19/19 PASS |
| Lot 4 (75) | 19 (`sql/tests/phase2e_lot4_billing.sql`) | 19/19 PASS |
| Lot 5 (76) | 26 (`sql/tests/phase2f_lot5_dashboard_audit_settings_supervision.sql`) | **26/26 PASS** |

Le fichier Lot 5 couvre explicitement les 9 scénarios de réserve Lot 4 (paiement partiel/total,
double confirmation idempotente, surpaiement refusé, avoir partiel/total, annulation d'avoir,
renversement de paiement, annulation interdite avec avoir émis) en plus des scénarios propres au
Lot 5 (KPIs, alertes, audit filtré, paramètres, ACL, non-écriture des RPC de lecture, supervision
honnête).

Deux bugs de test (pas de produit) ont été trouvés et corrigés pendant la validation Lot 5 :
une erreur de précédence d'opérateur PL/pgSQL (`v_kpis->'clé'::text` au lieu de
`(v_kpis->'clé')::text`), et une hypothèse de test invalide sur `trg_grant_superadmin_on_new_hotel`
(cf. D.6) — corrigée en supprimant explicitement la ligne auto-attribuée avant l'assertion.

### E.2 Tests Jest

**499/499 tests, 21 suites**, dont 43 nouveaux pour les 7 helpers purs introduits au Lot 5
(`severityBadge`, `periodLabel`, `alertTypeIcon`, `sortAlertsBySeverity`, `settingValueType`,
`validateSettingValue`, `formatPayloadValue`). Aucune régression sur les 456 tests préexistants
(couvrant aussi bien le module Super Admin que le reste de l'application — planning, paie,
pointage, absences, etc.).

### E.3 Intégration frontend (backend mocké)

Qualifiée honnêtement de **"test d'intégration frontend avec backend mocké"**, jamais de test
E2E réel — le sandbox de développement ne peut pas atteindre les domaines Supabase/Vercel réels
(confirmé par des 403 systématiques via le proxy). Un faux client Supabase (mêmes signatures que
`@supabase/supabase-js`) + interception `page.route()` sur le CDN jsdelivr simulent les réponses
RPC. Couverture Lot 5 : chargement du tableau de bord + changement de période, navigation
transversale depuis une alerte (hôtel sans admin → ouverture de sa fiche), consultation de
l'audit avec filtres + détail lisible du payload, modification d'un paramètre avec confirmation +
toast + refus de valeur invalide côté client, refus d'accès pour un utilisateur non-admin. Zéro
erreur JS sur l'ensemble du parcours.

### E.4 Tests manquants (dette confirmée)

- Aucun harnais de test pour les Edge Functions (`invite-user`, `invite-platform-admin`) — jamais
  construit sur l'ensemble du projet, pas seulement le portail Super Admin.
- Aucun test E2E réel (contre un vrai navigateur + vrai backend Supabase) — contrainte réseau du
  sandbox, jamais levée durant ce chantier.

---

## F. Déploiement

| Élément | État |
|---|---|
| Backend | Appliqué en production (`hzrzkvdebaadditvbqis`), migrations 68 à 77 |
| Frontend | **Fusionné et déployé en production** — PR [#17](https://github.com/Walilarabi/flowtym-rh/pull/17), commit de merge `eaa204b126f47b04ce1c1f73f9fc8bbf81007d79` |
| Branche source | `claude/flowtym-super-admin-portal-sf4hei` (fusionnée, squash merge) |
| Branche cible | `main` |
| Déploiement Vercel production | `dpl_J6TV1RMvAU83QSYRWHJmkGwsZPmf`, `target: production`, `READY`, SHA `eaa204b1` confirmé identique au commit de merge, 0 erreur de build, 0 erreur runtime |
| Migrations appliquées | 68, 69, 70, 71, 72, 73, 74, 75, 76, 77 (toutes, dans cet ordre, aucune en attente, idempotence confirmée via `list_migrations`) |
| Edge Functions déployées | `invite-user` v26 (contenu déployé vérifié identique au fichier du dépôt), `invite-platform-admin` v10 (aucune nouvelle Edge Function introduite par ce projet) |
| Routing `/admin` | `vercel.json` — `/admin` et `/admin/(.*)` → `admin.html`, avant la règle catch-all `/(.*)→/index.html` |
| CI GitHub | 4/4 checks verts (`Front — syntaxe & code de debug`, `DB — reconstruction dépôt + tests`, `DB — pointage terminals + hardening`, `Vercel Preview Comments`) — périmètre historique, ne couvre pas directement `admin.html`/`sql/68-77` (cf. dette CI ci-dessous) |

---

## G. Dettes et limites

### G.1 Bloquants avant merge

**Aucun.** Tous les tests SQL (26/26), Jest (499/499) et l'intégration frontend mockée passent ;
l'ACL est vérifiée exhaustivement sur toutes les fonctions/tables introduites ou modifiées ;
aucune donnée de test résiduelle en production (vérifié par requête directe) ; l'interface se
charge sans erreur JS sur le parcours testé.

### G.2 À traiter avant tout usage financier réel

- **PDF de facture** : actuellement `window.print()` sur une zone dédiée avec CSS
  `@media print`, honnêtement libellé "Imprimer / enregistrer en PDF" (pas de génération PDF
  définitive). Dette technique explicite pour un vrai moteur documentaire : rendu déterministe,
  PDF immuable, duplicata identique bit-à-bit, stockage, numérotation définitive, empreinte
  (hash) optionnelle.
- **Prestataire de paiement réel** : aucun (Stripe/GoCardless/SEPA) n'est connecté — les
  paiements sont enregistrés manuellement par le Super Admin (`admin_record_platform_payment`).
- **Moteur e-invoicing (Chorus Pro / PDP)** : aucun connecté ; les colonnes/format de
  `platform_invoices` sont compatibles avec une intégration future mais rien n'est câblé.
- **Edge Function `invite-platform-admin`** (`verify_jwt=false`) : à auditer ligne à ligne avant
  tout élargissement de son usage — son code source n'a pas été relu dans ce chantier.

### G.3 Reportables après RC1

- Changement de plan planifié (aujourd'hui immédiat uniquement, pas de prise d'effet différée).
- Révocation globale des sessions d'un utilisateur (aujourd'hui : désactivation du compte, pas
  d'invalidation de session active en cours).
- Harnais de test complet pour les Edge Functions.
- Supervision : `mutation_error_monitoring_available` et
  `edge_function_error_monitoring_available` restent honnêtement `false` — aucune instrumentation
  réelle n'existe (une `RAISE EXCEPTION` fait un rollback avant tout log d'erreur possible ; aucun
  pipeline d'erreur Edge Function n'existe). Pas de faux badge vert affiché à la place.
- Constat transversal anon/table-level (D.7) — décision CTO requise avant tout traitement, portée
  bien au-delà de ce projet.
- **Dette CI** (prioritaire avant les prochaines évolutions majeures du portail) : étendre le
  workflow CI GitHub pour couvrir syntaxe et chargement de `admin.html`, Jest Super Admin,
  migrations `sql/68` à `sql/77` en rollback, contrôle automatisé des ACL, tests des Edge
  Functions du portail, vérification du dossier d'inventaire RC. Le workflow actuel (4 checks
  verts sur la PR #17) ne couvre que `index.html`/`portal.html` et le périmètre pilote
  `sql/54`-`56` — la validation du portail Super Admin repose entièrement sur les suites SQL/Jest/
  intégration frontend exécutées manuellement et documentées ici, pas sur cette CI.
- **Smoke test réel navigateur non exécuté** : l'environnement d'exécution de cette session bloque
  tout accès réseau sortant vers `rh.flowtym.com`, l'alias `*.vercel.app` et l'endpoint REST
  Supabase (politique réseau du sandbox, confirmée via `connect_rejected` sur les trois hôtes,
  indépendamment du domaine). Impossible d'y exécuter un test de navigation réel (connexion,
  clic, capture de console JS) dans cette session. Compensé par une vérification maximale
  possible sans navigateur : appels RPC réels (non mockés) contre la production, sous l'identité
  du compte Super Admin réel (`walilarabi@gmail.com`), couvrant dashboard/alertes/audit/
  supervision/facturation/utilisateurs, plus refus non-admin réel — cf. H.4. **Un test de
  navigation réel par un humain (ou une session avec accès réseau) reste recommandé avant de
  considérer le parcours UI complet comme validé.**
- Deux hôtels historiques `ZZ Deploy Check Self` / `ZZ Deploy Check Admin` (statut `archived`,
  créés le 2026-07-28 lors de la vérification de déploiement du hotfix Lot 0 — antérieurs à ce
  travail, non nettoyés par cette branche) subsistent en base, déjà archivés, sans impact
  fonctionnel. Suppression physique non effectuée (hors mandat de cette session, action
  destructive non demandée) — signalé pour une éventuelle purge décidée par le CTO.

*(Les deux écarts ACL sur `admin_set_default_hotel` et `grant_superadmin_on_new_hotel`, initialement
listés ici, ont été corrigés avant merge — cf. B.3 et `sql/77_super_admin_rc1_acl_hygiene.sql`.)*

---

## H. Checklists

### H.1 Checklist de merge

- [x] 26/26 tests SQL Lot 5 (dont réserves Lot 4) — PASS
- [x] Migrations `sql/76` et `sql/77` appliquées en production
- [x] ACL vérifiée (functions + tables) via requête directe post-déploiement
- [x] 499/499 tests Jest
- [x] Intégration frontend mockée validée, zéro erreur JS
- [x] Syntaxe JS validée (`node --check` sur le script extrait)
- [x] Aucune donnée de test résiduelle en production (de cette session)
- [x] Commit unique Lot 5 + commit de stabilisation ACL poussés sur la branche désignée
- [x] 2 écarts ACL historiques analysés en profondeur et corrigés avant merge
- [x] Vérification ciblée des findings advisors Checkout (aucun lien avec le portail Super Admin)
- [x] CI GitHub verte (4/4 checks) sur la PR
- [x] Revue finale du diff PR vs `main` (aucun fichier inattendu, aucun secret détecté)
- [x] Fusion contrôlée vers `main` — PR #17, commit `eaa204b`

### H.2 Checklist de déploiement production frontend

- [x] Fusion de `claude/flowtym-super-admin-portal-sf4hei` vers `main` (squash merge, commit
      `eaa204b126f47b04ce1c1f73f9fc8bbf81007d79`)
- [x] Déploiement Vercel production déclenché automatiquement par la fusion, `target: production`,
      `READY`, SHA confirmé identique au commit de merge
- [x] `/admin` routé (règle `vercel.json` déjà en place, non modifiée par ce merge)
- [ ] Connexion effective d'un vrai compte Super Admin **via un navigateur réel** en production —
      non exécutable depuis cette session (accès réseau sortant bloqué vers `rh.flowtym.com`,
      voir G.3). Compensé par un appel RPC réel sous l'identité du compte réel (H.4).
- [x] Chargement du tableau de bord avec les vraies données de production — vérifié via appel RPC
      réel (non mocké), pas via navigateur (cf. ci-dessus)

### H.3 Checklist de rollback

- Aucune migration de ce projet ne supprime de colonne/table/fonction existante — un rollback de
  schéma, si nécessaire, se ferait par une nouvelle migration corrective (jamais un script
  inverse automatique, cohérent avec la doctrine "jamais de perte de données" du projet).
- Rollback frontend : revert du commit de merge `eaa204b` sur `main` ; aucune dépendance de
  schéma cassante n'empêche `index.html` de continuer à fonctionner sans `admin.html` (fichier
  strictement indépendant).
- Aucune donnée n'est perdue en cas de rollback frontend seul (le backend reste additif et
  inoffensif pour l'app hôtel existante).
- Vercel conserve l'historique des déploiements production précédents (`isRollbackCandidate`) —
  un rollback frontend peut aussi se faire par réassignation d'alias vers le déploiement
  précédent (`dpl_CMM5Daez2Li2QCGfJdD5qWUrEtdt`, commit `cb23f90`) sans attendre un revert Git.

### H.4 Smoke tests réels post-fusion — résultats

**Exécutés avec succès (appels RPC réels, non mockés, contre la production `hzrzkvdebaadditvbqis`,
sous l'identité du compte Super Admin réel `walilarabi@gmail.com`, en lecture seule) :**

- Dashboard (`admin_platform_overview_kpis('this_month', NULL, NULL)`) : 7 hôtels (4 actifs, 3
  inactifs/archivés), 1 groupe, 14 utilisateurs (13 actifs, 1 désactivé), 1 Super Admin, 1
  abonnement en essai (plan Flow Starter), 0 facture (module facturation pas encore utilisé en
  production — cohérent), 4 utilisateurs sans accès, 0 hôtel sans admin.
- Alertes (`admin_platform_alerts()`) : 4 alertes réelles retournées, aucune erreur.
- Audit (`admin_list_platform_audit_log(...)`) : entrées réelles retournées (`group.detach_hotel`,
  `group.attach_hotel`, `hotel.auto_grant_superadmin_access`), niveau `info`.
- Supervision (`admin_supervision_status()`) : `last_migration_name` = migration Lot 5 confirmée,
  signaux non mesurés honnêtement à `false`, aucun faux badge vert.
- Facturation (`admin_list_platform_invoices()`) : 0 ligne, aucune erreur.
- Utilisateurs (`admin_list_user_access()`) : 14 lignes retournées, aucune erreur.
- Refus non-admin réel : un utilisateur `auth.users` synthétique non-Super-Admin se voit refuser
  `admin_platform_overview_kpis` avec `SQLSTATE 42501`, confirmé (transaction rollback, 0 résidu).

**Non exécutable depuis cette session — limite d'environnement, pas un échec produit :** connexion
navigateur réelle, clic à travers chaque module, capture de la console JS en conditions réelles.
L'accès réseau sortant vers `rh.flowtym.com`, l'alias `*.vercel.app` et l'endpoint REST Supabase
est bloqué par la politique du sandbox (`connect_rejected`, confirmé sur les trois hôtes). Un test
de navigation réel par un humain (ou une session avec accès réseau) reste recommandé pour valider
le rendu visuel et l'absence d'erreur console, en complément des vérifications backend réelles
ci-dessus.
8. Tester une mutation par module déjà livré (Hôtels : changer un statut ; Utilisateurs : révoquer
   un accès secondaire, jamais le dernier admin d'un hôtel ; Facturation : créer une facture
   proforma sur un hôtel de test puis l'annuler).

---

## Prochaine étape

Conformément à l'instruction du CTO ("Après cette livraison, arrête les ajouts fonctionnels et
passe en mode stabilisation RC1"), **aucun nouveau lot fonctionnel ne doit démarrer** sans
instruction explicite. Ce dossier est l'unique livrable attendu à ce stade ; les points G.2/G.3
restent des décisions du CTO, pas des blocages techniques.
