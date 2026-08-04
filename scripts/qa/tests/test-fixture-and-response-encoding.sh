#!/usr/bin/env bash
# scripts/qa/tests/test-fixture-and-response-encoding.sh
#
# Non-régression pour deux corrections issues d'une exécution réelle du workflow
# phase2-staging-acceptance (run PASS:1 / FAIL:6) :
#
#   FAIL #6 — création des hôtels fictifs échouait avec `jq: Cannot index object with number`.
#     Cause racine : public.hotels.hotel_code est un varchar(5), mais le code fictif construit
#     était RUN_SUFFIX (8 caractères) + une lettre = 9 caractères -> PostgREST rejetait l'INSERT
#     (400, corps JSON = objet d'erreur, pas un tableau) -> `.[0].id` échouait sur cet objet.
#
#   FAIL #1 — section STRUCTURE : introspection de 42 tables produisant un JSON volumineux.
#     Deux pièges : `echo "$R" | head -n1` pouvait recevoir SIGPIPE ("Broken pipe") sur un $R
#     volumineux ; `jq --argjson staging "$STAGING_SNAPSHOT"` pouvait dépasser ARG_MAX du système
#     ("Argument list too long"). Corrigés respectivement par scripts/qa/lib/http-response.sh
#     (expansion de paramètre bash pure) et par un fichier temporaire lu via `--slurpfile`.
#
# 100% hors réseau, déterministe, ne touche jamais Supabase ni GitHub.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MAIN_SCRIPT="$ROOT/scripts/qa/phase2-staging-acceptance.sh"
HTTP_RESPONSE_LIB="$ROOT/scripts/qa/lib/http-response.sh"

PASS=0
FAIL=0
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }

command -v jq >/dev/null 2>&1 || { echo "jq est requis pour ce test"; exit 2; }

echo "=== A. FAIL #6 — longueur de hotel_code (varchar(5)) ==="

# A1 : structurel — le script ne doit plus utiliser RUN_SUFFIX brut (8 caractères) pour
# hotel_code, mais un HOTEL_CODE_SUFFIX dédié.
if grep -q 'HOTEL_CODE_SUFFIX="\${RUN_SUFFIX: -4}"' "$MAIN_SCRIPT"; then
  pass "A1 : HOTEL_CODE_SUFFIX dérivé sur 4 caractères est présent dans le script"
else
  fail "A1 : HOTEL_CODE_SUFFIX absent ou modifié — le bug hotel_code(5) peut être revenu"
fi

if grep -qE '\-\-arg c "\$\{HOTEL_CODE_SUFFIX\}A"' "$MAIN_SCRIPT" && grep -qE '\-\-arg c "\$\{HOTEL_CODE_SUFFIX\}B"' "$MAIN_SCRIPT"; then
  pass "A1bis : les deux hôtels fictifs (A, B) utilisent bien HOTEL_CODE_SUFFIX pour hotel_code"
else
  fail "A1bis : la construction de hotel_code pour hôtel A/B ne référence plus HOTEL_CODE_SUFFIX"
fi

if grep -qE '\-\-arg c "\$\{RUN_SUFFIX\}A"|\-\-arg c "\$\{RUN_SUFFIX\}B"' "$MAIN_SCRIPT"; then
  fail "A1ter : hotel_code utilise encore RUN_SUFFIX brut (8 caractères) — régression réintroduite"
else
  pass "A1ter : hotel_code n'utilise plus RUN_SUFFIX brut (8 caractères)"
fi

# A2 : comportemental — pour un éventail réaliste de RUN_TAG, le code fictif final
# (HOTEL_CODE_SUFFIX + une lettre) doit toujours tenir dans varchar(5), quelle que soit la forme
# de RUN_TAG (exécution GitHub Actions réelle avec GITHUB_RUN_ID numérique long, ou exécution
# locale avec le suffixe littéral "local").
check_hotel_code_length() {
  local run_tag="$1"
  local run_suffix="${run_tag: -8}"
  local hotel_code_suffix="${run_suffix: -4}"
  local code_a="${hotel_code_suffix}A"
  local code_b="${hotel_code_suffix}B"
  [[ ${#code_a} -le 5 && ${#code_b} -le 5 ]]
}

SAMPLE_RUN_TAGS=(
  "phase2qa-1735821000-123456789012345"   # GitHub Actions : run_id long
  "phase2qa-1735821000-42"                # run_id court
  "phase2qa-1735821000-local"             # exécution locale (pas de GITHUB_RUN_ID)
  "phase2qa-1-a"                          # cas dégénéré, RUN_TAG très court
)
ALL_OK=1
for tag in "${SAMPLE_RUN_TAGS[@]}"; do
  if ! check_hotel_code_length "$tag"; then
    fail "A2 : RUN_TAG='${tag}' produit un hotel_code > 5 caractères"
    ALL_OK=0
  fi
done
[[ "$ALL_OK" == "1" ]] && pass "A2 : hotel_code reste <= 5 caractères pour tous les RUN_TAG testés (dont les cas limites)"

echo ""
echo "=== B. FAIL #1 — section STRUCTURE (introspection volumineuse) ==="

# B1 : structurel — plus aucun `--argjson staging` (payload volumineux passé en argv), doit
# être `--slurpfile staging` (fichier temporaire).
if grep -q -- '--argjson staging' "$MAIN_SCRIPT"; then
  fail "B1 : le script utilise encore --argjson pour STAGING_SNAPSHOT — risque ARG_MAX réintroduit"
else
  pass "B1 : plus aucun --argjson sur le payload d'introspection volumineux"
fi
if grep -q -- '--slurpfile staging "\$STAGING_SNAPSHOT_FILE"' "$MAIN_SCRIPT"; then
  pass "B1bis : --slurpfile staging (fichier temporaire) est bien utilisé"
else
  fail "B1bis : --slurpfile staging absent — la comparaison structurelle risque de ne plus fonctionner"
fi

# B2 : structurel — le script source bien lib/http-response.sh et utilise split_http_response
# (pas de retour à `echo "$R" | head -n1` sur le payload d'introspection).
if grep -q 'source "\$(dirname "\$0")/lib/http-response.sh"' "$MAIN_SCRIPT"; then
  pass "B2 : phase2-staging-acceptance.sh source bien lib/http-response.sh"
else
  fail "B2 : lib/http-response.sh n'est plus sourcé — le correctif Broken pipe peut être revenu"
fi
N_SPLIT_CALLS=$(grep -c 'split_http_response "\$R"' "$MAIN_SCRIPT")
if [[ "$N_SPLIT_CALLS" -ge 2 ]]; then
  pass "B2bis : split_http_response() est utilisé pour les deux introspections (STRUCTURE + tables nouvelles)"
else
  fail "B2bis : split_http_response() n'est appelé que ${N_SPLIT_CALLS} fois (attendu >= 2) — régression possible"
fi

# B3 : comportemental — split_http_response() découpe correctement un payload volumineux
# (~3 Mo, taille représentative d'une introspection réelle de 42 tables), sans erreur ni
# troncature, en isolant strictement la première ligne (statut) du reste (corps).
# shellcheck source=../lib/http-response.sh
source "$HTTP_RESPONSE_LIB"

BIG_BODY=$(jq -nc --argjson n 50000 '[range($n)] | map({id:., name:("table_"+(.|tostring)), columns:[{name:"col_a",type:"text",nullable:true},{name:"col_b",type:"uuid",nullable:false}]})')
COMBINED=$'200\n'"${BIG_BODY}"

split_http_response "$COMBINED"

if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "B3 : statut extrait correctement (200) sur un payload volumineux (~$(( ${#BIG_BODY} / 1024 )) Ko)"
else
  fail "B3 : statut extrait incorrect ('${HTTP_STATUS}') sur payload volumineux"
fi

if [[ "$HTTP_BODY" == "$BIG_BODY" ]]; then
  pass "B3bis : corps extrait identique au corps d'origine (aucune troncature/altération)"
else
  fail "B3bis : corps extrait diverge de l'original — perte ou altération de données sur payload volumineux"
fi

# B4 : comportemental — le corps extrait, écrit dans un fichier temporaire, reste exploitable
# par jq --slurpfile (chemin réellement emprunté par la section STRUCTURE), y compris pour un
# payload dépassant largement la taille typique d'un argument de ligne de commande.
TMP_FILE=$(mktemp)
printf '%s' "$HTTP_BODY" > "$TMP_FILE"
COUNT=$(jq -n --slurpfile staging "$TMP_FILE" '$staging[0] | length')
rm -f "$TMP_FILE"
if [[ "$COUNT" == "50000" ]]; then
  pass "B4 : le corps extrait est relu correctement via jq --slurpfile (50000 éléments, chemin réel de la section STRUCTURE)"
else
  fail "B4 : jq --slurpfile sur le corps extrait a retourné un compte inattendu (${COUNT}, attendu 50000)"
fi

echo ""
echo "=== Résumé : ${PASS} PASS, ${FAIL} FAIL ==="
[[ "$FAIL" -eq 0 ]]
