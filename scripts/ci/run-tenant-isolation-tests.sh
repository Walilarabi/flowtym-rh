#!/usr/bin/env bash
# ============================================================================
# CI — garde-fou permanent d'isolation inter-groupes (Planning Groupe).
#
# Reconstruit la base pilote depuis le dépôt (db/reconstruct/rebuild.sh, qui inclut
# sql/97_security_group_planning_isolation.sql à l'état "déjà corrigé") puis exécute
# sql/tests/tenant_isolation_group_planning.sql : crée deux groupes hôteliers
# synthétiques totalement indépendants (BOUDAA HOTELS / REDOUANE HOTELS), teste la
# matrice complète d'accès (manager/collaborateur/extra/admin plateforme × même
# groupe/autre groupe) sous le rôle Postgres `authenticated`, et échoue (RAISE
# EXCEPTION, capturé ici via le code de sortie psql) si une seule requête renvoie
# une donnée d'un groupe à un principal d'un autre groupe.
#
# Incident de référence : 2026-08-03, cf. sql/97_security_group_planning_isolation.sql.
# Requiert psql + un PG accessible via PGHOST/PGPORT/PGUSER/PGPASSWORD.
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

: "${PGHOST:=localhost}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD

DB="ti_test"

echo "== 1. Reconstruction depuis le dépôt (base pilote) =="
psql -c "DROP DATABASE IF EXISTS $DB" postgres
psql -c "CREATE DATABASE $DB" postgres
export PSQL="psql -d $DB"
bash "$ROOT/db/reconstruct/rebuild.sh"

echo "== 2. Isolation inter-groupes — Planning Groupe (Boudaa Hotels / Redouane Hotels) =="
set +e
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/sql/tests/tenant_isolation_group_planning.sql" > /tmp/ti_tests.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "ECHEC — fuite d'isolation inter-groupes detectee ou erreur SQL. Sortie complete :"
  cat /tmp/ti_tests.log
  exit 1
fi
grep -E "Isolation inter-groupes Planning Groupe : [0-9]+ / [0-9]+ PASS" /tmp/ti_tests.log || {
  echo "AUCUN resume de test detecte — sortie :"; cat /tmp/ti_tests.log; exit 1;
}
grep -E "Isolation inter-groupes Planning Groupe : ([0-9]+) / \1 PASS" /tmp/ti_tests.log || {
  echo "ECHEC : tous les tests n'ont pas passe (resume non 17/17-style) — sortie :"; cat /tmp/ti_tests.log; exit 1;
}
echo "$(grep -E 'Isolation inter-groupes Planning Groupe' /tmp/ti_tests.log)"

echo "== TOUS LES CONTROLES D'ISOLATION INTER-GROUPES PASSENT =="
