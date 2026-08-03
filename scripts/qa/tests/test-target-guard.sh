#!/usr/bin/env bash
# scripts/qa/tests/test-target-guard.sh
#
# Test de non-régression du garde-fou cible (scripts/qa/lib/target-guard.sh) : garantit qu'il
# ne peut plus être supprimé ou affaibli accidentellement.
#
# 100% hors réseau, ne touche jamais Supabase ni GitHub — les JWT utilisés sont fabriqués
# localement (claims arbitraires, signature bidon jamais vérifiée par le garde-fou, qui ne fait
# qu'un recoupement de cohérence de cible, pas une authentification).
#
# Deux volets :
#   A. Structurel — le script principal source bien lib/target-guard.sh et appelle bien
#      validate_staging_target avant toute autre action (avant STRUCTURE/SETUP/AUTH/...).
#   B. Comportemental — le garde-fou bloque (exit 2) sur chaque désaccord entre URL / clé anon /
#      clé service_role / ref interdit, et laisse passer (exit 0) quand tout concorde.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MAIN_SCRIPT="$ROOT/scripts/qa/phase2-staging-acceptance.sh"
GUARD_LIB="$ROOT/scripts/qa/lib/target-guard.sh"
WORKFLOW_FILE="$ROOT/.github/workflows/phase2-staging-acceptance.yml"

PASS=0
FAIL=0
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }

command -v jq >/dev/null 2>&1 || { echo "jq est requis pour ce test"; exit 2; }

mk_fake_jwt() {
  local ref="$1"
  local header payload
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | base64 | tr -d '=\n' | tr '+/' '-_')
  payload=$(printf '{"iss":"supabase","ref":"%s","role":"anon","iat":0,"exp":9999999999}' "$ref" | base64 | tr -d '=\n' | tr '+/' '-_')
  echo "${header}.${payload}.fakesignature"
}

REAL_REF="rhftbfgvenxdpqudokcw"
OTHER_REF="zzzz00000000000000zz"
PROD_REF="hzrzkvdebaadditvbqis"

REAL_URL="https://${REAL_REF}.supabase.co"
OTHER_URL="https://${OTHER_REF}.supabase.co"

ANON_OK=$(mk_fake_jwt "$REAL_REF")
SVC_OK=$(mk_fake_jwt "$REAL_REF")
ANON_WRONG=$(mk_fake_jwt "$OTHER_REF")
SVC_WRONG=$(mk_fake_jwt "$OTHER_REF")
ANON_PROD=$(mk_fake_jwt "$PROD_REF")
SVC_PROD=$(mk_fake_jwt "$PROD_REF")

run_guard() {
  ALLOWED_STAGING_REF="$REAL_REF" \
  FORBIDDEN_TARGET_REFS="$PROD_REF" \
  PHASE2_STAGING_URL="$1" \
  PHASE2_STAGING_ANON_KEY="$2" \
  PHASE2_STAGING_SERVICE_ROLE_KEY="$3" \
  bash "$GUARD_LIB" 2>&1
}

echo "=== A. Volet structurel ==="

if grep -q 'source "\$(dirname "\$0")/lib/target-guard.sh"' "$MAIN_SCRIPT"; then
  pass "phase2-staging-acceptance.sh source bien lib/target-guard.sh"
else
  fail "phase2-staging-acceptance.sh ne source plus lib/target-guard.sh — garde-fou supprimé"
fi

if grep -q 'validate_staging_target || exit 2' "$MAIN_SCRIPT"; then
  pass "phase2-staging-acceptance.sh appelle bien validate_staging_target || exit 2"
else
  fail "phase2-staging-acceptance.sh n'appelle plus validate_staging_target — garde-fou désactivé"
fi

# Le garde-fou doit apparaître AVANT la section STRUCTURE (première action réelle du script :
# introspection via service_call/_qa_introspect_tables).
GUARD_LINE=$(grep -n 'validate_staging_target || exit 2' "$MAIN_SCRIPT" | head -1 | cut -d: -f1)
STRUCTURE_LINE=$(grep -n '=== STRUCTURE' "$MAIN_SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$GUARD_LINE" && -n "$STRUCTURE_LINE" && "$GUARD_LINE" -lt "$STRUCTURE_LINE" ]]; then
  pass "Le garde-fou cible s'exécute avant la section STRUCTURE (avant toute action)"
else
  fail "Le garde-fou cible n'est plus avant la section STRUCTURE (ligne garde=${GUARD_LINE:-?}, ligne STRUCTURE=${STRUCTURE_LINE:-?})"
fi

# Le workflow GitHub Actions doit lui aussi exécuter le garde-fou comme étape dédiée, AVANT
# l'étape "Exécuter la recette d'acceptation" (deux points d'application indépendants : script
# ET workflow, comme demandé explicitement).
GUARD_STEP_LINE=$(grep -n 'bash scripts/qa/lib/target-guard.sh' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
ACCEPT_STEP_LINE=$(grep -n 'bash scripts/qa/phase2-staging-acceptance.sh' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
if [[ -n "$GUARD_STEP_LINE" && -n "$ACCEPT_STEP_LINE" && "$GUARD_STEP_LINE" -lt "$ACCEPT_STEP_LINE" ]]; then
  pass "Le workflow exécute le garde-fou comme étape dédiée avant la recette d'acceptation"
else
  fail "Le workflow n'exécute plus le garde-fou avant la recette (ligne garde=${GUARD_STEP_LINE:-?}, ligne recette=${ACCEPT_STEP_LINE:-?})"
fi

echo ""
echo "=== B. Volet comportemental ==="

# T1 : tout concorde -> doit passer (exit 0)
OUT=$(run_guard "$REAL_URL" "$ANON_OK" "$SVC_OK"); RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q '\[PASS\] Garde-fou cible'; then
  pass "T1 : cible cohérente (URL + 2 clés alignées sur phase2-staging) -> accepté"
else
  fail "T1 : cible cohérente aurait dû être acceptée (rc=$RC) : $OUT"
fi

# T2 : URL ne correspond pas au ref attendu -> doit bloquer
OUT=$(run_guard "$OTHER_URL" "$ANON_OK" "$SVC_OK"); RC=$?
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q 'PHASE2_STAGING_URL'; then
  pass "T2 : URL divergente -> bloqué avec message explicite"
else
  fail "T2 : URL divergente aurait dû être bloquée (rc=$RC) : $OUT"
fi

# T3 : clé anon encode un autre ref que l'URL -> doit bloquer
OUT=$(run_guard "$REAL_URL" "$ANON_WRONG" "$SVC_OK"); RC=$?
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q 'PHASE2_STAGING_ANON_KEY'; then
  pass "T3 : clé anon divergente -> bloqué avec message explicite"
else
  fail "T3 : clé anon divergente aurait dû être bloquée (rc=$RC) : $OUT"
fi

# T4 : clé service_role encode un autre ref -> doit bloquer
OUT=$(run_guard "$REAL_URL" "$ANON_OK" "$SVC_WRONG"); RC=$?
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q 'PHASE2_STAGING_SERVICE_ROLE_KEY'; then
  pass "T4 : clé service_role divergente -> bloqué avec message explicite"
else
  fail "T4 : clé service_role divergente aurait dû être bloquée (rc=$RC) : $OUT"
fi

# T5 : les clés encodent le ref de PRODUCTION -> doit bloquer avec message "INTERDIT"
OUT=$(run_guard "$REAL_URL" "$ANON_PROD" "$SVC_PROD"); RC=$?
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q 'INTERDIT'; then
  pass "T5 : clés pointant vers le ref de production -> bloqué explicitement (INTERDIT)"
else
  fail "T5 : clés de production auraient dû être bloquées explicitement (rc=$RC) : $OUT"
fi

# T6 : JWT illisible (pas un JWT du tout) -> doit bloquer, jamais accepté par défaut
OUT=$(run_guard "$REAL_URL" "not-a-jwt" "$SVC_OK"); RC=$?
if [[ $RC -eq 2 ]]; then
  pass "T6 : clé anon illisible (pas un JWT) -> bloqué (fail-closed)"
else
  fail "T6 : clé anon illisible aurait dû être bloquée (rc=$RC) : $OUT"
fi

echo ""
echo "=== Résumé : ${PASS} PASS, ${FAIL} FAIL ==="
[[ "$FAIL" -eq 0 ]]
