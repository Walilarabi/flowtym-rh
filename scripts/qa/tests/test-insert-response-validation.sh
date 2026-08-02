#!/usr/bin/env bash
# scripts/qa/tests/test-insert-response-validation.sh
#
# Non-régression pour la cause racine réelle de "CRITIQUE : Échec création des lignes
# public.users" (`jq: Cannot index object with number`) : le script indexait aveuglément
# `.[0].id` sur une réponse PostgREST sans jamais avoir vérifié le code HTTP, la présence d'un
# objet d'erreur, ou même que le corps était du JSON valide. Corrigé par
# assert_insert_response() / insert_and_get_id() / insert_and_get_id_rest()
# (scripts/qa/phase2-staging-acceptance.sh) qui imposent, dans l'ordre, avant tout accès `.[0]` :
#   1. contrôle du code HTTP (200/201 attendu) ;
#   2. contrôle que le corps est du JSON syntaxiquement valide ;
#   3. détection d'un objet d'erreur PostgREST ({message,code,...} ou {error:...}) ;
#   4. contrôle que le corps est bien un tableau ;
#   5. contrôle qu'au moins une ligne avec un `id` est présente.
#
# Ce test extrait la définition RÉELLE de assert_insert_response() depuis le script principal
# (jamais une réimplémentation qui pourrait diverger silencieusement du code réel) et l'exécute
# contre des réponses HTTP synthétiques couvrant chacun des 5 contrôles ci-dessus, y compris des
# corps délibérément invalides — la garantie recherchée est qu'aucun cas ne fait jamais planter
# le test (`jq: Cannot index ...`), et que chaque échec produit un message explicite via
# log_fail(). 100% hors réseau, déterministe.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MAIN_SCRIPT="$ROOT/scripts/qa/phase2-staging-acceptance.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "jq est requis pour ce test"; exit 2; }

echo "=== A. Volet structurel ==="

if grep -q '^assert_insert_response() {' "$MAIN_SCRIPT"; then
  pass "A1 : assert_insert_response() est définie dans le script principal"
else
  fail "A1 : assert_insert_response() est absente — le durcissement des réponses HTTP a disparu"
fi

if grep -q '^insert_and_get_id() {' "$MAIN_SCRIPT" && grep -q '^insert_and_get_id_rest() {' "$MAIN_SCRIPT"; then
  pass "A2 : insert_and_get_id() et insert_and_get_id_rest() sont définies"
else
  fail "A2 : une des deux variantes (service_call / rest_call) d'insertion validée est absente"
fi

if grep -qE 'tail -n \+2 \| jq -r .\.\[0\]' "$MAIN_SCRIPT"; then
  fail "A3 : un motif d'extraction non validé (tail | jq -r '.[0]...') est réapparu dans le script"
else
  pass "A3 : plus aucun motif d'extraction non validé (tail -n +2 | jq -r '.[0]...') dans le script"
fi

N_CALLERS=$(grep -cE '\binsert_and_get_id(_rest)?\b "' "$MAIN_SCRIPT")
if [[ "$N_CALLERS" -ge 8 ]]; then
  pass "A4 : insert_and_get_id()/insert_and_get_id_rest() sont utilisées à ${N_CALLERS} endroits (fixtures + tickets support)"
else
  fail "A4 : seulement ${N_CALLERS} appels détectés — des sites d'insertion ne sont peut-être plus validés"
fi

echo ""
echo "=== B. Volet comportemental — assert_insert_response() isolée ==="

# Extraction de la définition RÉELLE de la fonction (jamais une réimplémentation qui pourrait
# diverger du code effectivement exécuté en CI).
FUNC_SRC=$(sed -n '/^assert_insert_response() {/,/^}/p' "$MAIN_SCRIPT")
if [[ -z "$FUNC_SRC" ]]; then
  echo "Impossible d'extraire assert_insert_response() — abandon des tests comportementaux."
  echo ""
  echo "=== Résumé : ${PASS} PASS, $((FAIL+1)) FAIL ==="
  exit 1
fi

# Dépendances minimales de assert_insert_response() : log_fail() (stub qui marque sa sortie
# pour preuve qu'un message explicite a bien été émis) et mask() (no-op transparent ici,
# comportement réel du masquage déjà couvert par les tests existants).
log_fail() { echo "[FAIL-CAPTURED] $1 ${2:-}"; }
mask() { cat; }

eval "$FUNC_SRC"

run_case() {
  # run_case NAME STATUS BODY EXPECT_SUCCESS [EXPECT_ID]
  #
  # NB : assert_insert_response est invoquée via $(...) (sous-shell) — toute variable qu'elle
  # modifierait (ex. LAST_FAIL_MSG) ne serait donc PAS visible ici. On vérifie plutôt que la
  # sortie capturée (stdout+stderr fusionnés) contient bien le marqueur émis par log_fail(),
  # preuve qu'un message explicite a réellement été produit avant l'échec.
  local name="$1" status="$2" body="$3" expect_ok="$4" expect_id="${5:-}"
  local out rc
  out=$(assert_insert_response "test:${name}" "$status" "$body" 2>&1)
  rc=$?
  if [[ "$expect_ok" == "1" ]]; then
    if [[ $rc -eq 0 && "$out" == "$expect_id" ]]; then
      pass "${name} : succès attendu, id='${out}' obtenu"
    else
      fail "${name} : succès attendu (id='${expect_id}') mais rc=${rc} out='${out}'"
    fi
  else
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '\[FAIL-CAPTURED\]'; then
      pass "${name} : échec attendu, capturé proprement avec message explicite"
    else
      fail "${name} : échec attendu avec message explicite, mais rc=${rc} out='${out}'"
    fi
  fi
}

# B1 — succès nominal : HTTP 201 + tableau avec id.
run_case "insert_ok" "201" '[{"id":"11111111-1111-1111-1111-111111111111","name":"x"}]' "1" "11111111-1111-1111-1111-111111111111"

# B2 — contrôle HTTP : statut inattendu (400) même avec un corps qui ressemblerait à un succès.
run_case "http_400_with_array_body" "400" '[{"id":"should-not-be-used"}]' "0"

# B3 — contrôle JSON : corps non-JSON du tout (jamais parsé, jamais de crash jq).
run_case "invalid_json_body" "200" 'ceci ne ressemble à aucun JSON {{{' "0"

# B4 — objet d'erreur PostgREST reconnu explicitement (NOT NULL violation typique).
run_case "postgrest_error_object" "200" '{"code":"23502","message":"null value in column \"first_name\" violates not-null constraint","hint":null,"details":null}' "0"

# B5 — objet d'erreur au format {error:...} (variante GoTrue/Edge Function).
run_case "generic_error_object" "400" '{"error":"invalid_request","error_description":"quelque chose a échoué"}' "0"

# B6 — corps JSON valide mais forme inattendue (ni tableau, ni objet reconnu comme erreur).
run_case "unexpected_shape" "200" '{"unexpected":"shape","no_id_no_message":true}' "0"

# B7 — tableau vide (0 ligne insérée, ex. RLS a silencieusement filtré l'INSERT).
run_case "empty_array" "201" '[]' "0"

# B8 — tableau non vide mais sans champ id.
run_case "array_without_id" "201" '[{"name":"sans id"}]' "0"

# B9 — reproduction exacte de la régression observée en CI : le cas historique était un
# HTTP 400 avec un objet d'erreur PostgREST (NOT NULL sur first_name/last_name), jamais détecté
# avant cette correction — confirmé ici que ce cas précis est maintenant capturé proprement.
run_case "regression_users_not_null" "400" '{"code":"23502","message":"null value in column \"last_name\" of relation \"users\" violates not-null constraint"}' "0"

echo ""
echo "=== Résumé : ${PASS} PASS, ${FAIL} FAIL ==="
[[ "$FAIL" -eq 0 ]]
