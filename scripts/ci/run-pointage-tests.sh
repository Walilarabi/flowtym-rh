#!/usr/bin/env bash
# ============================================================================
# CI — module Pointage v2.
# Charge un schéma minimal auto-suffisant, applique les migrations 62 puis 63,
# rejoue chaque migration pour prouver l'idempotence, puis exécute :
#   • sql/tests/pointage_hardening.sql (12+ tests)
#   • scripts/test-pointage-concurrency.sh (3 scénarios parallèles)
# Requiert psql + un PG accessible via PGHOST/PGPORT/PGUSER/PGPASSWORD.
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

: "${PGHOST:=localhost}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD

DB="ptg_test"
Q(){ psql -v ON_ERROR_STOP=1 -q "$@"; }

echo "== 0. Base neuve =="
psql -c "DROP DATABASE IF EXISTS $DB" postgres
psql -c "CREATE DATABASE $DB" postgres

echo "== 1. Chargement du schéma minimal (dépendances 62/63) =="
Q -d $DB -f "$ROOT/sql/tests/pointage_minimal_schema.sql"

echo "== 2. Migration 62 — pointage_terminals =="
Q -d $DB -f "$ROOT/sql/62_pointage_terminals.sql"

echo "== 3. Migration 63 — pointage_terminals_hardening =="
Q -d $DB -f "$ROOT/sql/63_pointage_terminals_hardening.sql"

echo "== 4. Idempotence — réappliquer 62 puis 63 (doit passer sans erreur) =="
Q -d $DB -f "$ROOT/sql/62_pointage_terminals.sql"
Q -d $DB -f "$ROOT/sql/63_pointage_terminals_hardening.sql"

echo "== 5. Suite de tests SQL (assertions + signatures + RLS + grants) =="
# On désactive temporairement `set -e` pour capturer le code de sortie ET la sortie.
set +e
psql -v ON_ERROR_STOP=1 -d $DB -f "$ROOT/sql/tests/pointage_hardening.sql" > /tmp/ptg_tests.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "ECHEC (psql RC=$RC) — sortie complète :"
  cat /tmp/ptg_tests.log
  exit 1
fi
grep -E "NOTICE:  OK [0-9]+" /tmp/ptg_tests.log || { echo "AUCUN test SQL n'a émis d'OK — sortie :"; cat /tmp/ptg_tests.log; exit 1; }
NB_OK=$(grep -c "NOTICE:  OK " /tmp/ptg_tests.log)
echo "   → $NB_OK tests SQL OK"
[ "$NB_OK" -ge "16" ] || { echo "ECHEC : $NB_OK tests OK détectés, attendu >= 16"; cat /tmp/ptg_tests.log; exit 1; }

echo "== 6. Fixtures pour la suite de concurrence =="
Q -d $DB -f "$ROOT/sql/tests/pointage_concurrency.sql"

echo "== 7. Scénarios de concurrence (3 scénarios psql parallèles) =="
PGCONN="-h $PGHOST -p $PGPORT -U $PGUSER -d $DB" bash "$ROOT/scripts/test-pointage-concurrency.sh"

echo "== TOUS LES CONTROLES POINTAGE PASSENT =="
