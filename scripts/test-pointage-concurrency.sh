#!/usr/bin/env bash
# Test de concurrence : deux INSERT parallèles doivent produire exactement
# 1 pointage ouvert grâce à l'index unique partiel + advisory lock.
#
# Prérequis : PGCONN (variables PG*) pointe sur une base ayant les migrations
# 62 et 63 appliquées et les fixtures de sql/tests/pointage_hardening.sql
# jouées (ou au moins un employé actif et un terminal créés).
#
# Usage :
#   PGCONN="-h /tmp -p 5433 -U postgres -d flowtym_test" ./scripts/test-pointage-concurrency.sh
set -euo pipefail

PGCONN=${PGCONN:-"-h /tmp -p 5433 -U postgres -d flowtym_test"}
psql $PGCONN -q -c "SELECT public._concurrency_setup();"

TID=$(psql $PGCONN -Atq -c "SELECT id FROM public.pointage_terminals ORDER BY created_at DESC LIMIT 1")
EMP='e0000001-0000-0000-0000-000000000001'
HOT='11111111-1111-1111-1111-111111111111'

# Deux transactions parallèles avec 100 ms de délai chacun côté client
run_side () {
  local key=$1
  psql $PGCONN -Atq -c "SELECT public.record_clocking('$EMP','$HOT','$TID','qr','$key');"
}

# ── Scénario 1 : deux requêtes SANS clé d'idempotence (2 actions distinctes)
#    Comportement attendu : le SQL sérialise (advisory lock + unique partiel).
#    L'une aboutit à clock_in, l'autre à clock_out. Jamais 2 clock_in ouverts.
run_side "conc-A" > /tmp/side-a.out &
run_side "conc-B" > /tmp/side-b.out &
wait
echo "Scénario 1 — clés distinctes :"
echo "  A: $(cat /tmp/side-a.out)"
echo "  B: $(cat /tmp/side-b.out)"

TOTAL=$(psql $PGCONN -Atq -c "SELECT count(*) FROM public.staff_clockings WHERE employee_id='$EMP';")
OPEN=$(psql $PGCONN -Atq -c "SELECT count(*) FROM public.staff_clockings WHERE employee_id='$EMP' AND clock_out_ts IS NULL;")
if [ "$TOTAL" != "1" ] || [ "$OPEN" -gt "1" ]; then
  echo "FAIL scénario 1 : total=$TOTAL open=$OPEN (attendu total=1 open<=1)"; exit 1
fi
echo "OK scénario 1 · 1 pointage total, jamais 2 ouverts"

# ── Scénario 2 : deux requêtes AVEC LA MÊME clé d'idempotence (double-clic
#    ou retry réseau). Une seule ligne doit exister, les deux retours pointent
#    dessus, la seconde est marquée idempotent=true.
psql $PGCONN -q -c "SELECT public._concurrency_setup();"
TID=$(psql $PGCONN -Atq -c "SELECT id FROM public.pointage_terminals ORDER BY created_at DESC LIMIT 1")
run_side "same-key" > /tmp/side-a.out &
run_side "same-key" > /tmp/side-b.out &
wait
echo "Scénario 2 — même clé d'idempotence :"
echo "  A: $(cat /tmp/side-a.out)"
echo "  B: $(cat /tmp/side-b.out)"

TOTAL=$(psql $PGCONN -Atq -c "SELECT count(*) FROM public.staff_clockings WHERE employee_id='$EMP';")
IDEMP_ROWS=$(psql $PGCONN -Atq -c "SELECT count(*) FROM public.staff_clocking_idempotency WHERE key='same-key';")
if [ "$TOTAL" != "1" ] || [ "$IDEMP_ROWS" != "1" ]; then
  echo "FAIL scénario 2 : total=$TOTAL idempotency_rows=$IDEMP_ROWS (attendu 1/1)"; exit 1
fi
echo "OK scénario 2 · même clé → même ligne, aucun doublon"

# ── Scénario 3 : deux terminaux DIFFÉRENTS du même hôtel, sans clé.
#    Un seul pointage ouvert autorisé par l'index unique partiel.
psql $PGCONN -q -c "SELECT public._concurrency_setup();"
T1=$(psql $PGCONN -Atq -c "SELECT id FROM public.pointage_terminals ORDER BY created_at DESC LIMIT 1")
# Deuxième terminal : INSERT direct pour éviter d'avoir à re-jouer set_config
# dans une nouvelle session psql. Le RPC create_pointage_terminal est déjà
# testé côté sql/tests/pointage_hardening.sql.
T2=$(psql $PGCONN -Atq -c "INSERT INTO public.pointage_terminals(hotel_id,name,is_active) VALUES('$HOT','SecondTerminal',true) RETURNING id;")
psql $PGCONN -Atq -c "SELECT public.record_clocking('$EMP','$HOT','$T1','qr',NULL);" > /tmp/s3a.out &
psql $PGCONN -Atq -c "SELECT public.record_clocking('$EMP','$HOT','$T2','qr',NULL);" > /tmp/s3b.out &
wait
echo "Scénario 3 — 2 terminaux différents :"
echo "  T1: $(cat /tmp/s3a.out)"
echo "  T2: $(cat /tmp/s3b.out)"
OPEN=$(psql $PGCONN -Atq -c "SELECT count(*) FROM public.staff_clockings WHERE employee_id='$EMP' AND clock_out_ts IS NULL;")
if [ "$OPEN" -gt "1" ]; then
  echo "FAIL scénario 3 : $OPEN pointages ouverts simultanés"; exit 1
fi
echo "OK scénario 3 · au plus 1 pointage ouvert sur 2 terminaux distincts"

echo
echo "==== TOUS LES SCÉNARIOS DE CONCURRENCE PASSENT ===="
