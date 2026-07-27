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

echo "== 3b. Migration 64 — remediation log =="
Q -d $DB -f "$ROOT/sql/64_pointage_remediation_log.sql"

echo "== 3c. Migration 65 — record_clocking column alignment + anomaly_flags safe =="
Q -d $DB -f "$ROOT/sql/65_pointage_record_clocking_column_alignment.sql"

echo "== 3d. Migration 66 — résumé quotidien (retard/rattrapage/solde) =="
Q -d $DB -f "$ROOT/sql/66_pointage_daily_summary.sql"

echo "== 4. Idempotence — réappliquer 62 → 66 (doit passer sans erreur) =="
Q -d $DB -f "$ROOT/sql/62_pointage_terminals.sql"
Q -d $DB -f "$ROOT/sql/63_pointage_terminals_hardening.sql"
Q -d $DB -f "$ROOT/sql/64_pointage_remediation_log.sql"
Q -d $DB -f "$ROOT/sql/65_pointage_record_clocking_column_alignment.sql"
Q -d $DB -f "$ROOT/sql/66_pointage_daily_summary.sql"

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
echo "   → $NB_OK tests SQL OK (pointage_hardening.sql)"
[ "$NB_OK" -ge "18" ] || { echo "ECHEC : $NB_OK tests OK détectés, attendu >= 18"; cat /tmp/ptg_tests.log; exit 1; }

echo "== 5b. Suite de tests SQL — résumé quotidien (retard/rattrapage/solde) =="
set +e
psql -v ON_ERROR_STOP=1 -d $DB -f "$ROOT/sql/tests/pointage_daily_summary.sql" > /tmp/ptg_daily_tests.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "ECHEC (psql RC=$RC) — sortie complète :"
  cat /tmp/ptg_daily_tests.log
  exit 1
fi
grep -E "NOTICE:  OK [0-9]+" /tmp/ptg_daily_tests.log || { echo "AUCUN test SQL n'a émis d'OK — sortie :"; cat /tmp/ptg_daily_tests.log; exit 1; }
NB_OK_DAILY=$(grep -c "NOTICE:  OK " /tmp/ptg_daily_tests.log)
echo "   → $NB_OK_DAILY tests SQL OK (pointage_daily_summary.sql)"
[ "$NB_OK_DAILY" -ge "10" ] || { echo "ECHEC : $NB_OK_DAILY tests OK détectés, attendu >= 10"; cat /tmp/ptg_daily_tests.log; exit 1; }

echo "== 6. Fixtures pour la suite de concurrence =="
Q -d $DB -f "$ROOT/sql/tests/pointage_concurrency.sql"

echo "== 7. Scénarios de concurrence (3 scénarios psql parallèles) =="
PGCONN="-h $PGHOST -p $PGPORT -U $PGUSER -d $DB" bash "$ROOT/scripts/test-pointage-concurrency.sh"

echo "== TOUS LES CONTROLES POINTAGE PASSENT =="
