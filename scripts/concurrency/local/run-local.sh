#!/usr/bin/env bash
# ============================================================================
# Exécute les tests de concurrence RÉELS à deux connexions sur un cluster
# PostgreSQL local jetable (aucune donnée de production).
#
# Prérequis : binaires PostgreSQL 16 (initdb/postgres/psql) + extensions
#   btree_gist, pgcrypto. Doit tourner sous un utilisateur non-root (le binaire
#   postgres refuse root) — adaptez PGUSER/su selon votre environnement.
#
# Étapes : initdb -> start -> 01..04 (schéma/fonctions/seed/instrumentation)
#   -> scénarios A-G (deux backends psql concurrents, PID distincts)
#   -> 05_verify (5 livrables) -> stop.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PGDATA="${PGDATA:-/var/tmp/pgcc/data}"
SOCK="${SOCK:-/var/tmp/pgcc/sock}"
PORT="${PORT:-55432}"
DB="${DB:-flowtym_cc}"
BIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PSQL="$BIN/psql -h $SOCK -p $PORT -U postgres -d $DB -v ON_ERROR_STOP=1"
MGR='55555555-5555-5555-5555-555555555555'

$PSQL -f "$HERE/01_schema.sql"
$PSQL -f "$HERE/02_functions.sql"
$PSQL -f "$HERE/04_instrument.sql"
$PSQL -f "$HERE/03_seed.sql"

run_pair() {
  $PSQL -c 'SELECT pg_backend_pid()' -f "$HERE/scenarios/${1}_A.sql" &
  local a=$!
  $PSQL -c 'SELECT pg_backend_pid()' -f "$HERE/scenarios/${1}_B.sql" &
  local b=$!
  wait $a; wait $b
}
for s in A B C D E F; do run_pair "$s"; done
$PSQL -f "$HERE/scenarios/G.sql"
$PSQL -f "$HERE/05_verify.sql"
