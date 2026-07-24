# Backlog RC2 — Flowtym RH

> **RC1 est figée.** Ce document est le **registre des demandes différées**. Rien ici
> n'est implémenté pendant le pilote. Le pilote mesure le produit **tel qu'il existe
> aujourd'hui**. Seuls entrent en RC1 : bug critique, anomalie reproduite, faille de
> sécurité, perte de données (voir `incident-runbook.md`).

## Comment utiliser ce registre
- Toute demande d'évolution reçue pendant le pilote est **ajoutée ici** (non traitée).
- Format : `[ID] Titre — origine — priorité (P1/P2/P3) — note`.
- Rien n'est planifié tant que la phase RC2 n'est pas ouverte par le Release Manager.

## Éléments déjà différés (issus des revues v1/v2 et des lots)

### Sécurité / conformité (pré-requis PRODUCTION, non bloquants pilote)
- `[RC2-SEC-1]` Revue de la **surface `anon`** des fonctions SECURITY DEFINER (183 avis) — P2.
- `[RC2-SEC-2]` `search_path` mutable sur fonctions **hors moteur déplacement**
  (`analytics_*`, `trg_hotel_code_immutable`, 5 avis) — P3.
- `[RC2-SEC-3]` Déplacer les extensions hors du schéma `public` (`extension_in_public`, 4) — P3.

### Performance (à l'échelle, non bloquant au volume pilote)
- `[RC2-PERF-1]` `auth_rls_initplan` : envelopper `auth.uid()` en `(select auth.uid())`
  sur les politiques RLS (64 avis) — P2.
- `[RC2-PERF-2]` Indexer les **clés étrangères** non couvertes (`unindexed_foreign_keys`,
  280 avis) — P2.
- `[RC2-PERF-3]` Rationaliser les **politiques permissives multiples**
  (`multiple_permissive_policies`, 330 avis) — P3.

### Reproductibilité / socle
- `[RC2-DB-1]` **Baseline produit COMPLÈTE** reproductible depuis le dépôt (au-delà du
  périmètre pilote : recrutement, médical, RMS, housekeeping, yousign…). RC1 ne couvre
  que le périmètre pilote via `db/reconstruct/` — P1 pour la production.
- `[RC2-DB-2]` Convertir `db/reconstruct/` + `sql/*` en migrations Supabase natives
  (`supabase/migrations/`) pour `supabase db reset` — P2.

### Frontend (migration heures — chantier de fond)
- `[RC2-FE-1]` Compteurs légaux de la **grille de planning** (C3) : source d'affichage
  vs source de vérité — décider si/comment exposer les heures canoniques hors édition — P2.
- `[RC2-FE-2]` `v_staff_month_summary` (C4) : vue heures dérivée des segments — P3.
- `[RC2-FE-3]` `check_replacement_constraints` (C5) : heures hebdo via `staff_day_hours` — P3.
- `[RC2-FE-4]` Affichage exact des **jours fractionnés** (portail salarié, exports PDF/Excel
  informatifs — « C6 / C7 reporting ») — P3.
- `[RC2-FE-5]` Découpe du monolithe `index.html` (16k+ lignes) — dette de maintenabilité — P3.

### service_id / couverture (P1 fonctionnel, hors pilote)
- `[RC2-COV-1]` Saisie native de `service_id` sur les segments + moteur de couverture
  par tranche (design : `docs/coverage-engine-design.md`) — P2.

### Exploitation / observabilité
- `[RC2-OPS-1]` Observabilité runtime : logs structurés + alerting (au-delà de l'audit
  métier `planning_audit`) — P2.
- `[RC2-OPS-2]` Activer la **protection de branche** `main` (checks CI requis) —
  action d'exploitation, à faire au démarrage — P1.

### Paie (validation métier)
- `[RC2-PAIE-1]` Ventilation HS 25 %/50 % : remplacer la règle simplifiée par la règle
  conventionnelle validée par le cabinet paie — P2.

## Demandes reçues pendant le pilote (à compléter)

| ID | Titre | Origine | Date | Priorité | Note |
|---|---|---|---|---|---|
| | | | | | |
