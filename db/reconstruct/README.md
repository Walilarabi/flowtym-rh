# Reconstruction de la base (périmètre pilote) — sans dépendance à la production

Ce dossier permet de reconstruire **intégralement, depuis le dépôt Git seul**, la
base nécessaire au **pilote** (déplacement inter-hôtels + moteur d'heures segments +
garde-fou paie), sur une instance PostgreSQL **vierge**. Aucune dépendance implicite
à la base de production ; aucun `db pull`.

## Contexte (dette identifiée et corrigée)

L'ancienne chaîne `sql/01`→`53` **ne pouvait pas** reconstruire la base : les tables
fondationnelles (`hotels`, `employees`, `hotel_groups`, `users`, `user_hotels`,
`staff_departments`) étaient créées par un amorçage **antérieur à `sql/01`, jamais
versionné**, et `sql/46`→`53` étaient des **stubs documentaires** (0 ligne exécutable).
Ce dossier ferme cette dette pour le périmètre pilote.

## Contenu (ordre de chargement)

1. `00_bootstrap.sql` — rôles/schemas/extensions/shim `auth.uid()` (fournis nativement
   par Supabase, absents d'un cluster nu). Idempotent.
2. `10_foundation.sql` — tables fondationnelles (DDL fidèle au schéma live).
3. `20_planning_move.sql` — planning, segments (contrainte d'exclusion), moteur
   déplacement (tables).
4. `30_functions.sql` — RPC + triggers (audit, garde d'intégrité, idempotence…).
5. `../../sql/54_p0_hours_canonical.sql` — migration P0 (fonction canonique, garde-fou
   paie, flag, service_id).

## Procédure

```bash
# 1) instance vierge (exemple : cluster local jetable)
initdb -D /tmp/pg && pg_ctl -D /tmp/pg -o "-p 5432 -k /tmp/pg" start
createdb -h /tmp/pg -p 5432 flowtym

# 2) reconstruction depuis le dépôt SEUL
PSQL="psql -h /tmp/pg -p 5432 -U postgres -d flowtym" db/reconstruct/rebuild.sh

# 3) preuve (rejeu des suites de tests) — attendu 24/24 et A-G 7/7
psql ... -f scripts/p0/10_hours_tests.sql
psql ... -f scripts/p0/20_payroll_lock_tests.sql
# concurrence : scripts/concurrency/local (voir docs/move-concurrency-local-run.md)
```

## Preuve reproductible (vérifiée)

Sur cluster PostgreSQL 16 vierge, `rebuild.sh` charge les 5 couches sans erreur, puis :
- **P0 heures + paie : 24/24 PASS** ;
- **Concurrence A–G : 7/7 PASS** (0 deadlock, 0 chevauchement, 0 orphelin).

## Périmètre & limite (honnête)

Ce jeu couvre le **périmètre pilote**. Les autres modules produit (recrutement,
médical, RMS/réservations, housekeeping, yousign…) ne sont **pas** inclus : leurs
tables restent définies dans le schéma live et via les `sql/01`→`45` historiques (qui
supposent la fondation). Rendre **tout** le produit reproductible (baseline complète
255 tables) est un chantier distinct, non requis pour le pilote.
