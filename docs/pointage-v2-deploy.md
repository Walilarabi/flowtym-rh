# Pointage v2 — Ordre de déploiement et checklist manuelle

## Résumé du changement

Refonte du module de pointage : le QR Code n'identifie plus un salarié mais un **terminal de pointage**. Un hôtel peut en avoir plusieurs (Réception, Cuisine…). Le salarié est authentifié via sa session Flowtym au moment du scan.

Cette PR remplace l'implémentation naïve du premier commit `c5485e3` par une version durcie après audit critique :

- autorisation multi-hôtel STRICTE (plus d'auto-autorisation par historique),
- archivage logique des terminaux (le DELETE physique est bloqué en base si le terminal a servi),
- régénération de token cryptographique atomique + journal d'audit,
- protection SQL contre le double-pointage (index unique partiel + advisory lock + table d'idempotence),
- heure serveur + fuseau hôtel systématiques (poste de nuit / DST OK),
- extensibilité sécurité QR (rayon par terminal, plage horaire par terminal),
- cycle de vie caméra robuste (pagehide / visibilitychange / beforeunload).

## Ordre exact de déploiement

À jouer dans cet ordre, avec ON_ERROR_STOP. Chaque migration est idempotente et rejouable.

### 1. Base de données (Supabase SQL editor)

```bash
psql "$SUPABASE_URL" -v ON_ERROR_STOP=1 -f sql/62_pointage_terminals.sql
psql "$SUPABASE_URL" -v ON_ERROR_STOP=1 -f sql/63_pointage_terminals_hardening.sql
```

- `62` crée `pointage_terminals`, backfill un terminal « Réception » par hôtel disposant déjà d'un `hotel_qr_tokens` actif, ajoute `terminal_id` sur `staff_clockings`.
- `63` durcit tout : autorisation stricte, archivage, RPC atomiques, protection double-pointage, colonnes de sécurité par terminal, journal d'événements, TODO daté pour retirer `hotel_qr_tokens` (fenêtre 90 j).

**Vérifier immédiatement** :

```sql
-- Doit renvoyer une ligne par hôtel qui avait un ancien QR.
SELECT hotel_id, count(*) FROM public.pointage_terminals GROUP BY hotel_id;

-- Doit exister et être vide au départ.
SELECT count(*) FROM public.pointage_terminal_events;

-- Un salarié actif de l'hôtel principal doit être autorisé.
SELECT public.employee_can_clock_at(
  '<uuid_employé>', '<uuid_hotel>', current_date);
```

### 2. Edge function `clock-portal`

Déploiement Supabase :

```bash
supabase functions deploy clock-portal
```

### 3. Frontend

Push automatique via Vercel dès merge de la branche.

## Rollback

Toutes les migrations sont additives. Pour désactiver la v2 sans casser
l'existant :

```sql
-- Désactive la nouvelle protection (les anciens INSERT redeviennent possibles)
DROP INDEX IF EXISTS public.staff_clockings_one_open_per_employee;
DROP INDEX IF EXISTS public.staff_clockings_idempotency_key_uidx;
-- Le trigger et le fallback legacy restent en place ; les anciens QR
-- hotel_qr_tokens continuent de fonctionner via clock-portal.
```

Aucune donnée n'est perdue ; on peut revenir à la version précédente du
`clock-portal` sans rejouer de migration.

## Fenêtre de retrait du fallback `hotel_qr_tokens`

- **J+0** (déploiement) : commentaire OBSOLÈTE posé sur `hotel_qr_tokens` (migration 63). L'edge function lit encore, mais le frontend ne peut plus créer de tokens hotel-level.
- **J+30** : ajouter `is_deprecated=true` sur `hotel_qr_tokens` (migration 64 à écrire) et logguer un warning côté edge à chaque usage.
- **J+60** : `UPDATE hotel_qr_tokens SET is_active=false` (mail aux hôtels concernés une semaine avant).
- **J+90** : `DROP TABLE hotel_qr_tokens` + retrait du chemin `resolveTerminal → legacy` dans l'edge function (migration 65).

## Checklist de test manuel

### Safari iOS (iPhone, iOS 17+)

- [ ] Connexion salarié via `/salarie`, session ouverte
- [ ] Onglet **Pointage** → bouton « Pointer entrée » ouvre la caméra plein écran
- [ ] Premier scan : demande de permission caméra → « Autoriser »
- [ ] Le flux vidéo apparaît, le cadre est net, le scan est instantané
- [ ] Un flash « Entrée enregistrée ✓ — Réception » s'affiche
- [ ] Basculer sur un autre onglet Safari → la caméra doit se couper (LED éteinte)
- [ ] Revenir → la vue Pointage doit afficher « Pointer sortie »
- [ ] Re-scanner : « Sortie enregistrée ✓ »
- [ ] Double-tap sur le bouton « Pointer » : un seul scanner s'ouvre, un seul pointage créé
- [ ] Refuser explicitement la caméra → panneau d'erreur clair, lien « Saisir le code manuellement »
- [ ] Saisie manuelle du code (`ftt_…`) → pointage OK, retour caméra fonctionnel
- [ ] En mode avion : erreur claire « Session expirée » ou timeout GPS ; aucun pointage fantôme n'apparaît

### Chrome Android (12+)

- [ ] Idem Safari iOS
- [ ] `BarcodeDetector` natif utilisé (vérifiable en console : pas de chargement `jsqr`)
- [ ] Faire une rotation d'écran pendant le scan → la vidéo reste correctement affichée

### Chrome / Edge desktop

- [ ] Sur `localhost` (contexte sécurisé), le bouton « Pointer » ouvre bien la webcam
- [ ] Sur un poste sans webcam : erreur « Aucune caméra détectée », lien manuel visible
- [ ] Ouvrir deux onglets, scanner dans les deux : la base ne crée qu'un seul pointage ouvert

### Admin — Paramètres › Pointage QR

- [ ] Créer un terminal « Cuisine » → apparaît, QR affiché
- [ ] Imprimer / Télécharger → PNG net contenant l'URL `?action=clock&token=…`
- [ ] Régénérer → nouveau token, ancien immédiatement invalide (test avec l'ancien QR côté salarié → erreur `INVALID_TERMINAL`)
- [ ] Désactiver / Réactiver un terminal → statut visible immédiatement
- [ ] Sur un terminal déjà utilisé : le bouton **Supprimer** est masqué (seul **Archiver** est proposé) ; tentative directe en base → `foreign_key_violation`
- [ ] Archiver un terminal : status ARCHIVÉ, plus scannable ; le pointage existant reste visible dans l'historique
- [ ] Consulter `SELECT * FROM pointage_terminal_events ORDER BY created_at DESC LIMIT 20` : toutes les actions journalisées (create, rename, regenerate, disable, enable, archive) avec `actor_email`

### Multi-hôtel (règle stricte)

- [ ] Employé principal Paris scanne le QR de Paris → OK
- [ ] Le même employé scanne le QR de Nice sans droit → erreur `WRONG_HOTEL`
- [ ] Ajouter une affectation permanente vers Nice → le scan Nice passe
- [ ] Retirer l'affectation → le scan Nice est de nouveau refusé
- [ ] Employé désactivé (`employees.active=false`) → erreur `EMP_INACTIVE`
- [ ] Ancien employé qui a des pointages historiques dans Nice mais aucun droit actuel → REFUSÉ (`WRONG_HOTEL`)

### Concurrence

- [ ] Sur poste de test, ouvrir 2 onglets, cliquer « Pointer entrée » simultanément → 1 seul pointage
- [ ] Retry réseau (Chrome DevTools → Throttling → offline puis online) sur le même clic → 1 seul pointage (grâce à `Idempotency-Key`)
- [ ] Scan sur terminal Paris pendant qu'un autre poste scanne sur Cuisine (même employé) → 1 seul pointage ouvert (voir index `staff_clockings_one_open_per_employee`)

### Fuseau / poste de nuit

- [ ] Poste de nuit : clock-in à 23:55, clock-out à 01:10 le lendemain → 1 seul pointage, `day` correspond au 23 (fuseau hôtel), `clock_out_ts` > `clock_in_ts`
- [ ] Oubli de sortie la veille : clock-in aujourd'hui reçoit un `clock_out` sur l'ancien pointage (via `openShift`), pas un nouveau clock-in
