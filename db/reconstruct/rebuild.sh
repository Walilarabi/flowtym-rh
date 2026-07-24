#!/usr/bin/env bash
# ============================================================================
# Reconstruit la base du PÉRIMÈTRE PILOTE (déplacement + heures + paie) sur une
# instance PostgreSQL VIERGE, uniquement à partir du dépôt. Aucune dépendance
# à la base de production.
#   Usage : DB=... PSQL="psql -h ... -U ..." db/reconstruct/rebuild.sh
# Ordre : bootstrap -> foundation -> planning/move -> fonctions -> migration P0.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PSQL="${PSQL:?définir PSQL (ex: psql -h /sock -p 5432 -U postgres -d rebuild)} -v ON_ERROR_STOP=1 -q"
$PSQL -f "$HERE/00_bootstrap.sql"
$PSQL -f "$HERE/10_foundation.sql"
$PSQL -f "$HERE/20_planning_move.sql"
$PSQL -f "$HERE/30_functions.sql"
$PSQL -f "$ROOT/sql/54_p0_hours_canonical.sql"
$PSQL -f "$ROOT/sql/55_security_hardening.sql"
echo "OK — base pilote reconstruite depuis le dépôt."
