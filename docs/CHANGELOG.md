# Flowtym RH — Changelog

## v1.6.0 — Portail Super Admin, Phase 2 (Lots 1-6 + divergence des droits)

9 PR ouvertes et empilées (#21-#29, voir ADR-012 pour le détail complet et l'ordre de
merge), aucune mergée, aucune migration appliquée en production, aucun cron activé.

### Contenu
- **Lot 1** (PR #21, #22) : rétro-versionnement Support à l'identique + durcissement
  ACL/RLS. Deux failles réelles corrigées : `TRUNCATE` non filtré par RLS (`anon`
  pouvait vider `support_tickets`), et les policies `support_select/insert/update`
  qui ne matchaient jamais aucun utilisateur hôtel réel (`user_hotels.user_id`
  comparé directement à `auth.uid()` au lieu de passer par `public.users.auth_id`).
  Le même motif existe sur 7 autres tables RH/RMS/Salon/Lighthouse, volontairement
  non corrigé ici (hors périmètre, cf. ADR-012 §2).
- **Lot 2** (PR #23) : fondation `platform_notifications` (idempotence stricte,
  retries bornés, aucun cron).
- **Lot 3** (PR #24) : licences en observation seule (quota vs consommation réelle,
  seuil d'alerte 90 % non définitif, aucun blocage fonctionnel).
- **Lot 4** (PR #25) : notifications d'essai J-7/J-3/J-1, prédicat d'éligibilité
  strictement partagé entre prévisualisation et exécution.
- **Lot 5A** (PR #26) : back-office Support (`support_ticket_replies` append-only,
  masquage audité, moindre privilège `super_admin`/`support_agent`).
- **Lot 5B** (PR #27) : portail hôtel Support + pièces jointes. Nouveau fichier
  indépendant `support-portal.html` (ni `portal.html`, ni `index.html` — cf. ADR-012
  §7 pour la justification par les données réelles), 3 Edge Functions, statuts
  antivirus honnêtes (`clean` jamais atteint automatiquement, aucun scanner câblé).
- **Divergence des droits** (PR #28) : écran en lecture seule, aucune nouvelle
  migration (réutilise `admin_rights_divergence_report()`, en production depuis
  Phase 2A).
- **Lot 6** (PR #29) : statistiques Super Admin + score de santé client/hôtel.
  MRR/ARR affiché (0 € réel, abonnements actifs au tarif Legacy Pilot) ; conversion
  essai→payant explicitement non affichée (aucune conversion organique réelle) ;
  score paiement exclu du composite tant qu'aucune facture réelle n'existe.

### Défauts trouvés et corrigés pendant l'implémentation (jamais masqués)
- Default privileges Supabase (`ALTER DEFAULT PRIVILEGES`) accordant EXECUTE/DML à
  `anon`/`authenticated`/`service_role` sur toute nouvelle fonction/table — trouvé et
  corrigé indépendamment 4 fois (sql/83, 84, 85, 86) avant merge.
  `support_ticket_replies` avait spécifiquement conservé INSERT/UPDATE pour
  `authenticated`, violant sa propre doctrine append-only.
- Bucket Storage `support-ticket-attachments` : l'upsert de la migration ne forçait
  pas `public = false` dans son `ON CONFLICT DO UPDATE`, laissant une dérive
  manuelle antérieure (`public = true`) survivre à un rejeu — corrigé, testé.
- Écran Divergence des droits : cartes KPI avec des classes CSS inventées
  (`.lbl`/`.val`, absentes de la feuille de style) — corrigé avant que le lot
  suivant ne s'appuie dessus.

### Tests
Jest 522/522 (stable sur toutes les branches). Script de vérification syntaxique
frontend étendu à `support-portal.html`. Suites SQL dédiées par lot
(`sql/tests/support_acl_hardening.sql`, `trial_ending_notifications.sql`,
`support_ticket_replies.sql`, `support_ticket_attachments.sql`,
`lot6_statistics_health_score.sql`), toutes exécutées en `BEGIN...ROLLBACK` contre
la production réelle avec des comptes/hôtels réels — aucune donnée modifiée.
Playwright mocké (client Supabase intercepté au niveau réseau — CDN et API réelles
inaccessibles depuis ce sandbox) sur chaque nouvel écran frontend.

### Hors périmètre (documenté, non développé)
Paiements (aucun fournisseur choisi, `platform_invoices` vide en production, cf.
ADR-012 §11). Dette de reconstruction du socle Super Admin (`db/reconstruct/` ne
couvre que le périmètre pilote, pas `sql/68`-`87` — impact et plan documentés en
ADR-012 §12, non traité dans cette Phase 2).

## v1.5.2 — Portail Super Admin : contrat prévisualisation = exécution (essais expirés)

### Cause
Le traitement réel déclenché depuis `/admin` (« Traiter les essais expirés »,
`admin_run_expired_trials_processing`) continuait à modifier `hotel_app_subscriptions`
sous le capot via l'ancienne `process_expired_subscription_trials()`, alors que la
prévisualisation (`admin_preview_expired_trials_processing`) ne l'annonçait plus —
écart entre ce qu'une action Super Admin annonce et ce qu'elle exécute réellement,
jugé inacceptable par le CTO. Capturé sur le fait en production le 30/07/2026 à
10:53:57 UTC (un dernier déclenchement via l'ancien moteur, une minute avant
l'application du correctif) : les 2 lignes `hotel_app_subscriptions` de Folkestone
sont passées de `trial` à `expired` sans que la prévisualisation ne l'ait annoncé.

### Correctif
`sql/79_super_admin_p0_trial_app_access_coherence.sql` (PR #18) : nouvelle fonction
dédiée `process_expired_hotel_subscription_trials()`, qui reprend à l'identique la
logique `hotel_subscriptions` de l'ancienne fonction (même prédicat, même
verrouillage `FOR UPDATE SKIP LOCKED`, même audit) sans la seconde boucle
`hotel_app_subscriptions`. `admin_run_expired_trials_processing()` l'appelle
désormais à sa place. Contrat rétabli : prévisualisation manuelle = exécution
manuelle = `hotel_subscriptions` uniquement. `process_expired_subscription_trials()`
reste en base intacte mais orpheline (0 appelant, vérifié par introspection
`pg_proc`) — sa suppression relève d'une phase ultérieure.

Première étape effective du plan de dépréciation `docs/adr/ADR-011-plan-deprecation-hotel-app-subscriptions.md`
(retrait du consommateur « portail » vis-à-vis de `hotel_app_subscriptions`). Les 2
lignes Folkestone restent volontairement en l'état (`expired`), non corrigées
manuellement — voir ADR-011, section « Événement historique de référence ».

### Tests
14/14 scénarios SQL (`sql/tests/phase2b_p0_trial_coherence.sql`) en transaction
`BEGIN...ROLLBACK` sur la production réelle, 499/499 Jest. Déployé en production et
vérifié : ACL correcte, 0 job `pg_cron`, 0 appelant restant de l'ancienne fonction.

## v1.5.1 — Hotfix : statut MAD absent du menu Pointage RH

### Cause
Signalé en production le 2026-07-28 : Karima OULSAADA (Grand Hôtel du Havre),
mise à disposition de Folkestone opera ce jour-là (`staff_planning.status =
'MAD'` à Folkestone), n'apparaissait pas dans le menu Pointage de Folkestone
alors qu'elle y travaille réellement. `pointage_range_summary()` (sql/66)
ne filtrait que `status IN ('P','PE')` — le statut `MAD` (mise à
disposition), bien que représentant une présence physique attendue, en
était exclu.

### Correctif
`sql/67_pointage_include_mad_status.sql` : `CREATE OR REPLACE` de
`pointage_range_summary()` avec `status IN ('P','PE','MAD')`. `sql/66`
mis à jour en parallèle pour qu'une reconstruction from-scratch obtienne
directement la version corrigée.

### Tests
Nouveau cas 12 dans `sql/tests/pointage_daily_summary.sql` (salarié
planifié `MAD` à un hôtel différent de son hôtel principal, pas encore
pointé) : apparaît dans le périmètre, `planning_status='MAD'`,
`is_extra=true`, `real_in` NULL. **11/11 tests SQL** (pointage_daily_summary),
**387/387 Jest**, `check-frontend-syntax.mjs` 0 erreur.

## v1.5.0 — Refonte de la page Pointage RH (retard/rattrapage/solde du jour)

### Résumé
Refonte complète de la page Pointage RH (`index.html`) pour afficher, par
salarié et par jour, l'écart entre horaire planifié et horaire réel : retard
matin, rattrapage soir, solde du jour, cumul mensuel — calculés **côté
serveur** pour rester cohérents avec les futurs calculs de paie.

### Base de données — `sql/66_pointage_daily_summary.sql`
- Nouvelle RPC `pointage_range_summary(p_hotel, p_from, p_to)` : un seul
  appel couvre le tableau du jour, les KPI, l'export PDF et le cumul mensuel.
  Isolation multi-hôtel stricte (`pl_my_hotels()`), garde-fou de plage
  (≤ 92 jours).
- Salariés inclus par jour : planifiés (`staff_planning.status IN ('P','PE')`)
  **OU** ayant pointé à cet hôtel (couvre les extras/renforts inter-hôtel —
  corrige au passage le bug où un pointage inter-hôtel restait invisible
  dans ce menu, cf. diagnostic Folkestone/Mas Provencal du 2026-07-27).
- Heure planifiée : `staff_planning.shift_start/shift_end` du jour, sinon
  repli sur l'horaire par défaut du salarié (`department_schedules` via
  `employees.schedule_id`).
- Fonction utilitaire `pl_pointage_time_delta_minutes()` : écart en minutes
  entre heure planifiée et heure réelle, normalisé pour rester correct sur
  un service traversant minuit (ex. prévu 23:50 / réel 00:10 → +20 min, pas
  −23h40).
- Formules : `retard_matin = max(0, delta_arrivée)` ;
  `rattrapage_soir = max(0, delta_départ)` ;
  `solde_jour = delta_arrivée − delta_départ` (peut être négatif = avance).
- Documente en migration versionnée `department_schedules` (table déjà
  présente en production mais jamais créée par une migration `sql/`).
- Grants stricts : `authenticated` uniquement, `anon`/`PUBLIC` refusés.

### Frontend — `index.html`, vue Pointage
- Tableau pleine largeur (plus aucun panneau latéral).
- Filtres **Service** et **Statut** (Tous/Pointés/Non pointés), instantanés,
  sans aller-retour serveur.
- Nouvelles colonnes : Arrivée (prévue/réelle), Départ (prévue/réelle),
  Retard matin, Rattrapage soir, Solde du jour, Total retard (mois).
- Export PDF dédié (`Exporter la feuille de pointage (PDF)`, jsPDF +
  autoTable, même police/style que l'export Planning existant) — uniquement
  les salariés prévus du jour, mêmes colonnes que le tableau.
- Bouton de pointage manuel déplacé en dernière colonne (« Pointage
  manuel ») — logique interne inchangée (`openClockingForm`).
- Édition d'un pointage existant toujours possible (clic sur l'heure réelle).
- Légende « Comprendre le solde du jour » sous le tableau.
- Salariés en renfort inter-hôtel visibles avec un badge « Extra ».

### Tests
- `sql/tests/pointage_daily_summary.sql` : 10 blocs `DO $$…$$`, dont les 5
  cas canoniques du cahier des charges (retard rattrapé → solde 0, retard
  partiel → +10, départ anticipé pur → +20, cumul retard+anticipé → +25,
  avance → −12), session ouverte (pas de faux 0), absence de plan/horaire
  (NULL propre, piège `GREATEST(0,NULL)=0` évité), repli horaire par défaut,
  traversée de minuit, visibilité inter-hôtel (`is_extra`), isolation
  multi-hôtel, garde-fou de plage, grants.
- `tests/pointage-daily-view.test.js` : 33 tests — formatage, couleurs
  (vert/rouge/gris), filtres instantanés, agrégat mensuel, KPI, et contrats
  sur le fichier source réel garantissant qu'aucune fonctionnalité existante
  (QR, caméra, terminal, pointage manuel, édition, permissions) n'a régressé.
- `scripts/ci/run-pointage-tests.sh` : étape 5b ajoutée (≥ 10 tests OK requis).
- Résultats locaux : **336/336 Jest** (+33), **28/28 SQL** (18+10),
  **3/3 concurrence**, `check-frontend-syntax.mjs` 0 erreur.

## v1.4.4 — Pointage v2 : hotfix « Failed to fetch » + retry réseau

### Cause
Scan QR reproduit en recette réelle (Folkestone opera, 2026-07-27) : la
requête échoue côté client avec `TypeError: Failed to fetch`, sans jamais
atteindre les logs de la edge function `clock-portal` (seul le préflight
`OPTIONS` y apparaît, jamais le `POST` qui suit).

Cause racine : `Access-Control-Allow-Headers` de `clock-portal` ne listait
pas `idempotency-key`. Ce header personnalisé (ajouté par `portal.html` pour
rendre chaque scan rejouable sans risque de doublon) force un préflight CORS.
Quand le navigateur doit revalider ce préflight (cache expiré — l'edge
function ne renvoyait pas non plus `Access-Control-Max-Age`), la vérification
échoue silencieusement côté navigateur : la requête réelle n'est jamais
envoyée, `fetch()` rejette avec une erreur réseau générique, et la connexion
mobile instable en environnement hôtelier (wifi hall/sous-sol) amplifie le
phénomène.

### Correctifs

**Edge function `clock-portal`** :
- `Access-Control-Allow-Headers` inclut désormais `idempotency-key`.
- `Access-Control-Max-Age: 600` ajouté pour que le navigateur réutilise la
  décision de préflight 10 minutes au lieu de revalider à chaque scan/retry.

**Portail salarié (`portal.html`)** :
- `submitQrCode` retente désormais jusqu'à 2 fois (backoff 800 ms / 1600 ms)
  en cas d'échec **réseau pur** (`isNetworkFetchError` — aucune réponse
  serveur reçue), avec la **même** `Idempotency-Key` : `record_clocking()`
  étant idempotente sur cette clé, un nouvel essai ne peut jamais créer un
  second pointage, même si une tentative précédente avait en réalité atteint
  le serveur.
- Une erreur **métier** renvoyée par le serveur (JSON `{error,code}`, ex.
  `WRONG_HOTEL`, `GPS_TOO_FAR`) n'est **jamais** rejouée — sort immédiatement
  avec le message d'origine.
- Message final clarifié si les 3 tentatives échouent toutes en réseau :
  « Connexion réseau impossible après plusieurs tentatives ».

### Tests
- Nouveaux tests Jest `isNetworkFetchError` (7 cas : libellés Chrome/Firefox/
  Safari vs erreurs métier serveur — jamais confondues).
- Test de contrat sur le fichier source réel de `clock-portal` : garantit que
  `idempotency-key` reste toujours listé dans `Access-Control-Allow-Headers`
  et que `Access-Control-Max-Age` est défini.
- Test de contrat sur `portal.html` : `submitQrCode` ne génère jamais une
  seconde `Idempotency-Key` pendant ses retries.
- Résultats locaux : **303/303 Jest** (+8), `check-frontend-syntax.mjs` 0 erreur.

## v1.4.3 — Pointage v2 : hotfix scan « cannot extract elements from a scalar »

### Cause
Chaque scan de pointage sans anomalie GPS explosait avec
`ERROR 22023 cannot extract elements from a scalar`, remonté au frontend
sous forme de « Erreur enregistrement: cannot extract elements from a scalar ».

Deux bugs latents dans `record_clocking` (migration 63) :

1. **`anomaly_flags` scalar-null non géré** : la RPC utilisait
   `p_audit ? 'anomaly_flags'` pour tester la présence de la clé. Cet
   opérateur renvoie `true` même quand la valeur est `null`. L'edge function
   envoyait systématiquement `anomaly_flags: null` quand aucune anomalie
   → `jsonb_array_elements_text(null::jsonb)` → 22023.
2. **Casts colonne incorrects** : les colonnes `ip_address` (texte en prod)
   et `distance_meters` (double precision en prod) existaient déjà
   avant la migration 63 avec des types différents de ceux déclarés.
   Les `ADD COLUMN IF NOT EXISTS ip_address inet / distance_meters int`
   étaient des no-ops silencieux. Les casts `::inet` et `::int` dans
   `record_clocking` levaient `42804 COALESCE types inet and text
   cannot be matched` au clock-out.

### Correctifs

**SQL** (nouveau `sql/65_pointage_record_clocking_column_alignment.sql`,
appliqué en prod, et fichier consolidé `sql/63` mis à jour pour les
reconstructions from scratch) :
- Pattern robuste `CASE jsonb_typeof(p_audit->'anomaly_flags') WHEN 'array' THEN … ELSE … END`
  sur les deux blocs UPDATE (clock-out : conserve les anomalies existantes)
  et INSERT (clock-in : NULL par défaut).
- `distance_meters` cast vers `float8`, `ip_address` sans cast (texte direct).
- Signature / owner / security / search_path / grants **inchangés**.

**Edge function `clock-portal` v10** :
- Contrat client propre : la clé `anomaly_flags` est OMISE du payload quand
  le tableau est vide (au lieu d'envoyer `null`).
- Le fix SQL reste actif comme filet de sécurité pour tout autre appelant.

**Fixture CI** (`sql/tests/pointage_minimal_schema.sql`) :
- Types alignés sur la disposition production réelle
  (`ip_address text`, `distance_meters double precision`).

### Tests
- 6 nouveaux sous-tests SQL **18A–F** dans `sql/tests/pointage_hardening.sql` :
  A `null`, B clé absente, C tableau valide, D scalaire texte, E objet,
  F clock-out avec `null` conserve les anomalies existantes.
- Nouveaux tests Jest `buildAuditPayload — anomaly_flags omission` (3 tests)
  vérifiant que la clé n'est pas dans le payload quand `anomalies.length===0`.
- Runner CI : `NB_OK ≥ 18` obligatoire.
- Résultats locaux : **292/292 Jest** (+3), **18/18 SQL** (+1), **3/3 concurrence**.

### Vérifications production
7 cas d'`anomaly_flags` testés en prod contre `record_clocking` (INSERT),
tous OK (aucune exception 22023) : `{}`, `null`, `[]`, `["gps_accuracy_low"]`,
`"gps_accuracy_low"`, `{}`, `true`. Nettoyage complet effectué, aucune
donnée réelle modifiée.

## v1.4.2 — Pointage v2 : hotfix production (post-déploiement)

### Corrections DB alignées prod
- **`generate_terminal_token()`** : appel `gen_random_bytes(24)` non qualifié + `SET search_path = public, extensions`. Corrige l'échec de la migration 63 sur Supabase (pgcrypto vit dans le schéma `extensions`, pas `public`).
- **`pointage_terminals_prevent_delete_if_used()`** : ajout `SET search_path = public` (advisor Supabase `function_search_path_mutable`).
- **`staff_clocking_idempotency`** : `ENABLE ROW LEVEL SECURITY` explicite (oubli du 63 initial ; l'advisor security a levé `rls_disabled_in_public`).
- **RPC admin** (`create/rename/regenerate/set_active/archive/set_security_pointage_terminal`, `employee_can_clock_at`) : `REVOKE EXECUTE ... FROM PUBLIC, anon` explicite après le GRANT à `authenticated`. Supabase ajoute par défaut anon au GRANT sur toute fonction publique — le REVOKE ferme cette voie même si les checks internes `pl_my_hotels()` bloquent déjà anon.
- **`record_clocking`** : `REVOKE ... FROM PUBLIC, anon, authenticated` (au lieu du seul FROM PUBLIC), preuve directe via `has_function_privilege` : `anon=false, authenticated=false, service_role=true`.

### Table de remédiation `sql/64_pointage_remediation_log.sql`
- Nouvelle table `staff_clockings_remediation_log(id, clocking_id, hotel_id, employee_id, original_row jsonb, remediation_type, remediation_reason, remediated_at, remediated_by, remediated_by_email)`.
- RLS active, `SELECT` réservé aux hôtels via `pl_my_hotels()`.
- Utilisée par l'opération de remédiation atomique des deux pointages orphelins pré-v2 (`2026-06-07`) : `clock_out_ts = clock_in_ts + 1 µs` (contrainte `clock_out_after_in` impose `>`), `clock_status='suspicious'`, `anomaly_flags += 'orphan_open_shift_pre_pointage_v2'`.

### Tests CI
- Le fixture `sql/tests/pointage_minimal_schema.sql` conserve pgcrypto dans `public` (search_path par défaut) mais crée aussi le schéma `extensions` pour compatibilité avec les migrations qui qualifient `extensions.gen_random_bytes(...)`.
- Nouveau test **17** dans `sql/tests/pointage_hardening.sql` : RLS `staff_clocking_idempotency` + RPC admin non exécutables par `anon` (create, regenerate, archive, employee_can_clock_at).
- Le runner CI requiert désormais `NB_OK >= 17`.

### Résultats
- 289 tests Jest (inchangés) + **17 tests SQL** (+1) + 3 scénarios de concurrence — tous verts localement et en CI.
- Advisor Supabase : findings du module Pointage passés de **3** (1 ERROR + 2 WARN structurels) à **0**.

## v1.4.1 — Pointage v2 : durcissement post-audit

### Autorisation multi-hôtel — plus stricte
- Retrait total du critère "historique" : posséder un ancien pointage dans un hôtel n'autorise plus rien.
- Nouvelle fonction SQL `employee_can_clock_at(employee, hotel, day)` — 4 critères OU, chacun explicite et actuel :
  hôtel principal + employé actif · `employee_hotel_assignments` active · `employee_extra_activations` active ce mois-ci · `staff_planning` P ce jour.
- L'edge function `clock-portal` refuse l'accès des employés désactivés (`EMP_INACTIVE`).

### Terminaux — archivage
- Nouveaux champs `archived_at`, `archived_by`, `archived_by_email`.
- Trigger `pointage_terminals_prevent_delete_if_used` → toute tentative de `DELETE` sur un terminal référencé par `staff_clockings` lève `foreign_key_violation` avec un HINT.
- Contrainte `pointage_terminals_archived_not_active` : archivé ⇒ inactif.
- Index unique `(hotel_id, lower(name))` sur les terminaux actifs non archivés.
- UI : bouton **Archiver** proposé sur les terminaux utilisés ; **Supprimer** disparaît dès qu'il y a un pointage attaché.

### Régénération de token — atomique + auditée
- Nouvelle fonction crypto `generate_terminal_token()` (`gen_random_bytes(24)`, 192 bits d'entropie).
- Nouvelles RPC `SECURITY DEFINER` : `create_pointage_terminal`, `rename_pointage_terminal`, `regenerate_pointage_terminal_token`, `set_pointage_terminal_active`, `archive_pointage_terminal`, `set_pointage_terminal_security`.
- Isolation multi-tenant vérifiée dans chaque RPC (`hotel_id IN pl_my_hotels()`).
- Verrou pessimiste `SELECT ... FOR UPDATE` sur la ligne pendant la régénération.
- Journal `pointage_terminal_events(action, actor_user_id, actor_auth_id, actor_email, details)` en INSERT-only pour les clients (RLS SELECT-only par hôtel).

### Fallback `hotel_qr_tokens` — stratégie de transition
- Commentaire SQL `OBSOLÈTE` posé sur la table (visible dans Studio Supabase).
- Aucun nouveau token `hotel_qr_tokens` créé par l'app (l'UI admin est passée à `create_pointage_terminal`).
- L'edge function accepte encore la lecture legacy pendant la fenêtre 90 j documentée dans `docs/pointage-v2-deploy.md` ; le flag `terminal_legacy:true` remonte au client pour la télémétrie.
- TODO daté ancré dans `sql/63_pointage_terminals_hardening.sql` § 13 pour la migration 65 (drop).

### Protection SQL contre le double-pointage
- Index unique partiel `staff_clockings_one_open_per_employee` sur `employee_id WHERE clock_out_ts IS NULL` — au plus un pointage ouvert par employé, tous hôtels et terminaux confondus.
- Table dédiée `staff_clocking_idempotency(key PK, clocking_id, action, created_at)` — un retry réseau avec la même clé retourne la même écriture.
- Nouvelle RPC `record_clocking(...)` (SECURITY INVOKER, réservée à `service_role`) qui combine :
  1) advisory lock par `hashtextextended(employee_id, 62)` (sérialisation stricte),
  2) lecture idempotence après verrou,
  3) `UPDATE ... WHERE clock_out_ts IS NULL` pour éviter les doubles clock_out concurrents,
  4) `INSERT` avec catch `unique_violation` pour idempotence à l'insert.

### Heure serveur + fuseau hôtel
- `clock_in_ts` / `clock_out_ts` = `now()` (jamais l'heure du téléphone).
- Nouvelle fonction `pl_hotel_local_day(hotel, ts)` : date civile locale de l'hôtel (fallback `Europe/Paris`).
- `staff_clockings.day` calculé côté SQL avec ce fuseau, robuste aux DST et postes de nuit.

### Extensibilité sécurité QR
- Nouveaux champs par terminal : `geofence_radius_override_meters`, `active_from_minute`, `active_to_minute`.
- L'edge function applique le rayon terminal → hôtel (fallback), et refuse les scans hors plage (code `OUTSIDE_TIME_WINDOW`, plage traversant minuit gérée).

### Cycle de vie caméra
- Verrous `qrOpening` (empêche 2 scanners simultanés sur double-clic) et `qrDetected` (empêche 2 handlers d'aboutir sur la même image).
- `stopCameraStream()` invoqué sur `visibilitychange`, `pagehide`, `beforeunload`, et systématiquement au début d'un nouveau `startCamera()`.
- Chargeur `jsQR` : loader singleton, retry possible après échec réseau, script balise retirée sur erreur.

### Idempotency-Key côté client
- `portal.html` génère une clé `ptg-<uuid>` par tentative utilisateur, envoyée en header HTTP `Idempotency-Key` + body ; un retry porte la même clé, le serveur retourne la même écriture.

### Tests
- Suite Jest : 289 tests verts (avant : 273).
- Suite SQL : 12 tests dans `sql/tests/pointage_hardening.sql` (autorisation, archivage, régénération, idempotence, day fuseau, privilèges).
- Test de concurrence `scripts/test-pointage-concurrency.sh` : 3 scénarios parallèles verts (clés distinctes, même clé, 2 terminaux du même hôtel).

## v1.4 — Refonte du module Pointage (terminaux)

### Principe
- Le QR Code n'identifie **plus** un salarié : il identifie **un terminal de pointage**.
- Un hôtel peut posséder plusieurs terminaux (Réception, Cuisine, Entrée du personnel…), chacun avec son propre QR.
- Le salarié est identifié via sa session Flowtym au moment du scan.
- Aucun QR à réimprimer lors des arrivées/départs des collaborateurs.

### Frontend — Portail salarié (`portal.html`)
- Le bouton principal **Pointer entrée / Pointer sortie** ouvre immédiatement la caméra (getUserMedia).
- Compatibilité étendue : Safari iOS (playsinline, muted, autoplay), Chrome Android, Chrome/Edge desktop, Firefox.
- Décodeur natif `BarcodeDetector` avec fallback automatique `jsQR` chargé à la demande.
- Détection de compatibilité (contexte sécurisé, présence de `mediaDevices.getUserMedia`) avec messages explicites.
- Gestion fine des erreurs de permission caméra (NotAllowedError, NotFoundError, NotReadableError, OverconstrainedError, SecurityError).
- La **saisie manuelle du code** est reléguée à un lien secondaire, accessible uniquement depuis l'écran scanner ou son panneau d'erreur.
- Nouveau design plein écran du scanner avec cadre-guide, feedback tactile (vibrate) à la détection.

### Frontend — Admin (`index.html`, onglet Paramètres › Pointage QR)
- Nouvelle interface de gestion multi-terminaux : lister, créer, nommer, associer à un hôtel, imprimer/télécharger, désactiver, réactiver, régénérer, supprimer.
- Chaque terminal affiche son QR en direct, son code, sa date de création.
- Impression optimisée avec nom d'hôtel + nom de terminal.

### Backend — Base de données (`sql/62_pointage_terminals.sql`)
- Nouvelle table `pointage_terminals(id, hotel_id, name, location, token, is_active, timestamps)` avec RLS multi-tenant.
- Colonne `terminal_id` ajoutée à `staff_clockings` (FK, ON DELETE SET NULL).
- Backfill idempotent : chaque hôtel disposant déjà d'un `hotel_qr_tokens` actif hérite d'un terminal « Réception » reprenant l'ancien token.
- Rétrocompatibilité totale : la table `hotel_qr_tokens` reste lisible par l'edge function en fallback.
- Fonction RPC `list_pointage_terminals(uuid)`.

### Backend — Edge function `clock-portal`
- Résolution du token contre `pointage_terminals` (nouveau) puis `hotel_qr_tokens` (legacy).
- Vérification que le salarié est autorisé à pointer dans l'hôtel du terminal (compatible multi-hôtels : shift planifié ou historique).
- Enregistrement de `terminal_id` sur le pointage (ou `qr_token_id` en fallback legacy).
- Codes d'erreur enrichis : `MISSING_TOKEN`, `AUTH_INVALID`, `EMP_NOT_FOUND`, `PORTAL_DISABLED`, `INVALID_TERMINAL`, `WRONG_HOTEL`, `QR_DISABLED`, `GPS_REQUIRED`, `GPS_TOO_FAR`.
- Réponse enrichie : `terminal_id`, `terminal_name`, `hotel_name`.

### Tests
- Nouveau fichier `tests/pointage-terminals.test.js` (19 tests) : extraction du token, décision clock_in/out, détection double-pointage, autorisation multi-hôtel.

## v1.3 — Contrats & Documents (Phases 1b + 2)

### Frontend
- **Vue Contrats refondue avec sous-onglets** : Vue d'ensemble, Modèles, Générer un contrat.
- **Onglet Modèles** : CRUD de modèles HTML versionnés, archivage, création d'une nouvelle version (archive automatique de l'ancienne), 25 variables documentées en référence.
- **Assistant de génération de contrat en 4 étapes** :
  1. Choix du collaborateur (avec alertes sur données civiles manquantes)
  2. Choix du modèle (filtrage automatique par service/rôle, suggérés en tête)
  3. Saisie des champs spécifiques (dates, période d'essai, rémunération, lieu, manager, convention collective)
  4. Aperçu HTML rendu + bouton **Générer le PDF** qui :
     - substitue les variables `{{...}}` (variables manquantes surlignées en jaune dans l'aperçu)
     - génère le PDF via jsPDF
     - upload dans Supabase Storage bucket `hr-documents`
     - crée un document type « contrat » sur la fiche collaborateur
     - télécharge la copie pour l'utilisateur
     - écrit une entrée dans `hr_document_audit_logs`
- **Fiche collaborateur enrichie** :
  - Section État civil avec date/lieu de naissance, nationalité, n° sécu, titre de séjour (visible seulement aux rôles RH/direction)
  - Section Documents RH avec **upload réel de fichiers** (PDF/JPEG/PNG, 10 Mo max), date d'émission, date d'expiration, badge automatique (Valide / Expire dans X j / Expiré / Manquant), téléchargement via URL signée 60 s, suppression
  - Audit log à chaque upload/download/delete
- **Formulaire collaborateur étendu** avec bloc *État civil* conditionnel selon les permissions.
- **Tableau de bord** : nouveau bloc **Alertes documents** (top 10 alertes documents expirés / expirant / manquants), clic ouvre la fiche concernée.
- **Référentiel DOC_TYPES** aligné sur les 13 types de la base (`document_types`).

### Base de données et stockage (Phase 1a, déjà appliqué)
- Migration 07 : 6 champs civils sur `employees` (RGPD sensible)
- Migration 08 : référentiel `document_types` (13 types normalisés)
- Migration 09 : `contract_templates` versionnables
- Migration 10 : enrichissement `employee_documents` + vue `v_employee_documents_alerts`
- Migration 11 : `hr_document_audit_logs` avec accès restreint admin/comptabilité
- Migration 12 : 2 buckets Supabase Storage privés (hr-templates, hr-documents) + 8 policies RLS

### Permissions
- Champs civils, État civil, Documents RH : visibles seulement pour `direction`, `admin_hotel`, `comptabilite` (via `canFicheFull()`).
- Alertes documents dashboard : seulement pour les rôles avec accès fiche complète.

### Tests
- 92 tests jsdom (17 nouveaux : sous-onglets contrats, création modèle, substitution variables, fallback variables manquantes, upload doc, types DOC, champs civils form, masquage réception, alertes dashboard).

### À venir (Phases 3 & 4)
- **Phase 3 — Signature électronique Yousign** : table signature_requests, machine d'états, intégration API. Provider recommandé : Yousign (FR, eIDAS, 9 à 25 €/mois selon volume).
- **Phase 4 — Attestation mutuelle + compléments** : même moteur que les contrats, table `mutual_certificate_templates` dédiée, notifications email.

## v1.2 — Module Pointage

Saisie manuelle, vue par jour, sessions multiples, calcul auto des heures, modal CRUD. RLS par hôtel. 75 tests.

## v1.1 — Gestion des accès par rôle

Matrice de permissions, filtrage onglets, fiche restreinte, badge rôle, bloc Accès dans Paramètres, 3 fonctions RPC sécurisées. 68 tests.

## v1.0 — Lancement production

11 onglets, édition en masse planning, 7 tables RH avec RLS, migrations rejouables. 56 tests.

## Roadmap restante (blueprint v2 — juin 2026)

> Ordre de priorité commerciale : Absences/CP-RTT → Recrutement → Paie → Portail salarié

### Phase 3
- **3A** — Signature électronique Yousign (table `signature_requests`, machine d'états, webhooks)
- **3B** — Gestion des absences et compteurs CP/RTT (workflow approbation, soldes, calendrier équipe)
- **3C** — Recrutement complet : pipeline Kanban candidats + transformation one-click candidat → salarié

### Phase 4
- **4A** — Éléments variables de paie + exports configurables par logiciel de paie hôtel
- **4B** — Formations obligatoires et échéances (catalogue, matrice salariés × formations, alertes)
- **4C** — Visites médicales périodiques (calcul automatique prochaine visite, alertes)
- **4D** — Matériel remis aux salariés (inventaire, décharges PDF, alerte retour à la sortie)
- **4E** — Organigramme hôtel (arborescence interactive, export PNG/PDF, basé sur `manager_id`)

### Phase 5
- Portail salarié **salarie.flowtym.com** — magic-link, planning, absences, documents, formations, matériel

### Phase 6
- Self check-in QR pour les collaborateurs
- Notifications push / email événements clés

### Transversal
- Attestation mutuelle, invitation utilisateurs, conservation légale paramétrable par pays
- Durcissement RLS par rôle

Voir `docs/BLUEPRINT.md` pour le détail complet.
