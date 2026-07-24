#!/usr/bin/env bash
# ============================================================================
# CI — reconstruit la base pilote depuis le dépôt et rejoue les suites de tests.
# Gate : échoue si la reconstruction, les tests heures/paie (24/24) ou les
# invariants de concurrence A-G ne passent pas. Requiert psql + un PG accessible.
#   Variables : PGHOST PGPORT PGUSER PGPASSWORD (défauts localhost/5432/postgres).
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGPASSWORD="${PGPASSWORD:-postgres}"
Q(){ psql -v ON_ERROR_STOP=1 -q "$@"; }

echo "== 1. Reconstruction depuis le dépôt (base pilote) =="
psql -c "DROP DATABASE IF EXISTS pilot" postgres
psql -c "CREATE DATABASE pilot" postgres
export PSQL="psql -d pilot"
bash "$ROOT/db/reconstruct/rebuild.sh"

echo "== 2. Tests heures + paie (attendu 24/24) =="
Q -d pilot -f "$ROOT/scripts/p0/10_hours_tests.sql" >/dev/null
Q -d pilot -f "$ROOT/scripts/p0/20_payroll_lock_tests.sql" >/dev/null
P0=$(psql -d pilot -tA -c "SELECT count(*) FILTER (WHERE pass)||'/'||count(*) FROM p0_results")
echo "   P0 = $P0"
FAILN=$(psql -d pilot -tA -c "SELECT count(*) FROM p0_results WHERE NOT pass")
[ "$FAILN" = "0" ] || { echo "ECHEC P0 ($FAILN test(s) en échec)"; psql -d pilot -c "SELECT test,attendu,obtenu FROM p0_results WHERE NOT pass"; exit 1; }

echo "== 3. Concurrence A-G (invariants déterministes) =="
psql -c "DROP DATABASE IF EXISTS pilot_cc" postgres
psql -c "CREATE DATABASE pilot_cc" postgres
export PSQL="psql -d pilot_cc"; bash "$ROOT/db/reconstruct/rebuild.sh" >/dev/null
Q -d pilot_cc -f "$ROOT/scripts/concurrency/local/04_instrument.sql" >/dev/null
Q -d pilot_cc -f "$ROOT/scripts/concurrency/local/03_seed.sql" >/dev/null
SC="$ROOT/scripts/concurrency/local/scenarios"
for s in A B C D E F; do
  psql -d pilot_cc -f "$SC/${s}_A.sql" >/dev/null 2>&1 &
  psql -d pilot_cc -f "$SC/${s}_B.sql" >/dev/null 2>&1 &
  wait
done
psql -d pilot_cc -f "$SC/G.sql" >/dev/null 2>&1
CC=$(psql -d pilot_cc -tA -c "
WITH agg AS (SELECT scenario, count(DISTINCT operation_id) FILTER (WHERE operation_id IS NOT NULL) eff, bool_or(deadlock) dl FROM cc_results GROUP BY scenario),
e(scenario,x) AS (VALUES('A',1),('B',1),('C',1),('D',2),('E',1),('F',1),('G',1))
SELECT count(*) FILTER (WHERE a.dl OR a.eff<>e.x OR a.eff IS NULL) FROM e LEFT JOIN agg a USING(scenario)")
OV=$(psql -d pilot_cc -tA -c "SELECT count(*) FROM staff_planning_segments s WHERE EXISTS(SELECT 1 FROM staff_planning_segments t WHERE t.employee_id=s.employee_id AND t.day=s.day AND t.id<>s.id AND int4range(t.seg_start_min,t.seg_end_min) && int4range(s.seg_start_min,s.seg_end_min))")
ORPH=$(psql -d pilot_cc -tA -c "SELECT count(*) FROM group_move_applications WHERE status='processing'")
echo "   scénarios KO=$CC  chevauchements=$OV  orphelins=$ORPH"
[ "$CC" = "0" ] && [ "$OV" = "0" ] && [ "$ORPH" = "0" ] || { echo "ECHEC concurrence"; exit 1; }

echo "TOUS LES CONTROLES DB PASSENT (P0 $P0 ; A-G 7/7 ; 0 chevauchement ; 0 orphelin)."
