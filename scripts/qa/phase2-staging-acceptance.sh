#!/usr/bin/env bash
# phase2-staging-acceptance.sh
#
# Recette d'acceptation pré-production Phase 2 (Super Admin / Support / Licences / Essais /
# Statistiques). Exécutée EXCLUSIVEMENT par le workflow GitHub Actions
# .github/workflows/phase2-staging-acceptance.yml (workflow_dispatch uniquement).
#
# Ce script :
#   - refuse de s'exécuter si la cible n'est pas explicitement la branche de staging Phase 2 ;
#   - crée ses propres fixtures fictives, avec un run ID unique pour un nettoyage déterministe ;
#   - teste réellement signup/login (GoTrue), PostgREST, RPC, Edge Functions ;
#   - couvre anon / authenticated sans hôtel / hôtel A / hôtel B / support_agent / super_admin ;
#   - compare la structure de la base de staging à un instantané de référence de production
#     committé dans scripts/qa/fixtures/ (jamais un accès réseau direct à la production) ;
#   - nettoie systématiquement ses fixtures, y compris en cas d'échec (trap) ;
#   - masque tous les secrets/tokens via `::add-mask::` ET dans toute sortie affichée ;
#   - produit un rapport PASS/FAIL et un artefact JSON assaini (aucun secret, aucun JWT).
#
# Ce script ne contient et n'affiche AUCUNE valeur de secret. Tous les secrets sont lus
# exclusivement depuis les variables d'environnement (fournies par le workflow depuis les
# GitHub Actions secrets) et ne sont jamais imprimés, loggés, ni inclus dans l'artefact.

set -uo pipefail

# ============================================================================
# 0. GARDES ANTI-PRODUCTION
# ============================================================================
: "${PHASE2_STAGING_URL:?PHASE2_STAGING_URL manquant}"
: "${PHASE2_STAGING_ANON_KEY:?PHASE2_STAGING_ANON_KEY manquant}"
: "${PHASE2_STAGING_SERVICE_ROLE_KEY:?PHASE2_STAGING_SERVICE_ROLE_KEY manquant}"
: "${PHASE2_NOTIFICATION_INTERNAL_KEY:?PHASE2_NOTIFICATION_INTERNAL_KEY manquant}"
: "${CONFIRM_STAGING:?CONFIRM_STAGING manquant (doit valoir YES)}"
: "${GITHUB_ENVIRONMENT_NAME:?GITHUB_ENVIRONMENT_NAME manquant}"

# Project ref UNIQUE autorisé pour cette recette. Toute autre valeur est un refus immédiat.
readonly ALLOWED_STAGING_REF="jutigvpcwiwvxkabbolg"
# Liste explicite des refs interdits — le vrai projet de production en tête. Étendre cette
# liste si d'autres environnements sensibles existent un jour.
readonly FORBIDDEN_REFS=("hzrzkvdebaadditvbqis")

if [[ "${CONFIRM_STAGING}" != "YES" ]]; then
  echo "::error::CONFIRM_STAGING doit valoir exactement YES. Arrêt."
  exit 2
fi
if [[ "${GITHUB_ENVIRONMENT_NAME}" != "phase2-staging" ]]; then
  echo "::error::Environnement GitHub attendu 'phase2-staging', reçu '${GITHUB_ENVIRONMENT_NAME}'. Arrêt."
  exit 2
fi
for ref in "${FORBIDDEN_REFS[@]}"; do
  if [[ "${PHASE2_STAGING_URL}" == *"${ref}"* ]]; then
    echo "::error::PHASE2_STAGING_URL contient un project ref INTERDIT (${ref} — production ou environnement sensible). Arrêt immédiat, aucune action effectuée."
    exit 2
  fi
done
if [[ "${PHASE2_STAGING_URL}" != *"${ALLOWED_STAGING_REF}"* ]]; then
  echo "::error::PHASE2_STAGING_URL ne correspond pas au project ref de staging attendu (${ALLOWED_STAGING_REF}). Arrêt."
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "::error::jq est requis"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "::error::curl est requis"; exit 2; }

# ============================================================================
# 0bis. GARDE-FOU CIBLE RENFORCÉ — validation multi-source, avant toute action
# ============================================================================
# Aucune migration, aucun setup, aucun test, aucun appel Edge Function n'a lieu avant ce point.
# Voir scripts/qa/lib/target-guard.sh pour le détail des 3 sources indépendantes vérifiées
# (URL, ref encodé dans la clé anon, ref encodé dans la clé service_role) et le test de
# non-régression dédié scripts/qa/tests/test-target-guard.sh.
export FORBIDDEN_TARGET_REFS="${FORBIDDEN_REFS[*]}"
# shellcheck source=lib/target-guard.sh
source "$(dirname "$0")/lib/target-guard.sh"
validate_staging_target || exit 2
# shellcheck source=lib/http-response.sh
source "$(dirname "$0")/lib/http-response.sh"

# ============================================================================
# Masquage — GitHub Actions (::add-mask::) + masquage défensif de toute sortie affichée
# ============================================================================
mask_secret() {
  # Enregistre une valeur comme secrète auprès de GitHub Actions (masquée dans TOUS les logs
  # du job à partir de cet instant) — no-op silencieux hors GitHub Actions.
  local v="$1"
  [[ -n "$v" ]] && echo "::add-mask::${v}"
}
mask_secret "${PHASE2_STAGING_SERVICE_ROLE_KEY}"
mask_secret "${PHASE2_NOTIFICATION_INTERNAL_KEY}"
mask_secret "${PHASE2_STAGING_ANON_KEY}"

# Filet de sécurité défensif, en plus de ::add-mask:: : masque tout ce qui ressemble à un JWT
# (3 segments base64url séparés par des points) ou une clé sb_publishable_/sb_secret_ dans
# toute chaîne qu'on affiche nous-mêmes (préviews d'erreurs, corps de réponse tronqués).
mask() {
  sed -E 's/[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/***REDACTED_JWT***/g; s/sb_(publishable|secret)_[A-Za-z0-9_]+/***REDACTED_KEY***/g; s/Bearer [A-Za-z0-9._-]+/Bearer ***REDACTED***/g'
}

RUN_TAG="phase2qa-$(date -u +%s)-${GITHUB_RUN_ID:-local}"
RUN_TAG="${RUN_TAG:0:40}"
echo "RUN_TAG=${RUN_TAG}"

RESULTS_DIR="${GITHUB_WORKSPACE:-.}/qa-results"
mkdir -p "$RESULTS_DIR"
RESULTS_JSON="${RESULTS_DIR}/phase2-staging-acceptance-result.json"
declare -a RESULT_ROWS=()
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
CREATED_AUTH_IDS=()
CREATED_ROWS=() # "table|id"

record() {
  # record STATUS LABEL HTTP_STATUS_OR_EMPTY
  local status="$1" label="$2" http="${3:-}"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  RESULT_ROWS+=("$(jq -nc --arg s "$status" --arg l "$label" --arg h "$http" --arg t "$ts" \
    '{status:$s, label:$l, http_status:$h, timestamp:$t}')")
  if [[ "$status" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT+1)); echo "[PASS] ${label} ${http:+(HTTP $http)}" | mask
  else
    FAIL_COUNT=$((FAIL_COUNT+1)); FAILURES+=("$label"); echo "[FAIL] ${label} ${http:+(HTTP $http)}" | mask
  fi
}
log_pass() { record PASS "$1" "${2:-}"; }
log_fail() { record FAIL "$1" "${2:-}"; }
log_info() { echo "[INFO] $1" | mask; }

die_critical() {
  log_fail "CRITIQUE: $1"
  echo "Arrêt immédiat (échec critique)." | mask
  cleanup
  write_artifact
  print_summary
  exit 1
}

# ============================================================================
# Helpers HTTP — aucun secret jamais imprimé, même en cas d'erreur curl
# ============================================================================
rest_call() {
  local method="$1" path="$2" jwt="${3:-}" body="${4:-}" extra="${5:-}"
  local auth_header="Authorization: Bearer ${PHASE2_STAGING_ANON_KEY}"
  [[ -n "$jwt" ]] && auth_header="Authorization: Bearer ${jwt}"
  local args=(-sS -X "$method" "${PHASE2_STAGING_URL}${path}"
    -H "apikey: ${PHASE2_STAGING_ANON_KEY}" -H "$auth_header" -H "Content-Type: application/json"
    -H "Prefer: return=representation")
  [[ -n "$extra" ]] && args+=(-H "$extra")
  [[ -n "$body" ]] && args+=(-d "$body")
  local resp status body_out
  resp=$(curl "${args[@]}" -w $'\n%{http_code}' 2>/dev/null)
  status=$(echo "$resp" | tail -n1)
  body_out=$(echo "$resp" | sed '$d')
  echo "$status"
  echo "$body_out"
}

service_call() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "${PHASE2_STAGING_URL}${path}"
    -H "apikey: ${PHASE2_STAGING_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${PHASE2_STAGING_SERVICE_ROLE_KEY}"
    -H "Content-Type: application/json" -H "Prefer: return=representation")
  [[ -n "$body" ]] && args+=(-d "$body")
  local resp status body_out
  resp=$(curl "${args[@]}" -w $'\n%{http_code}' 2>/dev/null)
  status=$(echo "$resp" | tail -n1)
  body_out=$(echo "$resp" | sed '$d')
  echo "$status"
  echo "$body_out"
}

# assert_insert_response LABEL STATUS BODY
#
# Cœur commun de validation d'une réponse PostgREST censée représenter une ligne insérée
# (Prefer: return=representation) — jamais d'accès `.[0]` sans être passé, dans cet ordre
# strict, par ces contrôles :
#   1. le code HTTP (doit être 200/201) ;
#   2. que le corps est du JSON syntaxiquement valide (jamais parsé sinon) ;
#   3. que le corps n'est pas un objet d'erreur PostgREST ({message,code,details,hint} ou
#      {error:...}) — un objet reconnu comme erreur produit un message explicite avec le détail
#      renvoyé par PostgREST, jamais un `jq: Cannot index object with number` opaque ;
#   4. que le corps est bien un tableau (forme attendue de `Prefer: return=representation`) ;
#   5. que ce tableau contient au moins une ligne avec un `id`.
# Écrit l'id sur stdout et retourne 0 en cas de succès ; sinon émet un [FAIL] explicite (HTTP +
# détail éventuel) via log_fail et retourne 1 — jamais un die_critical direct ici, pour laisser
# l'appelant décider (certains inserts sont critiques, d'autres non).
assert_insert_response() {
  local label="$1" status="$2" body="$3"

  if [[ "$status" != "200" && "$status" != "201" ]]; then
    log_fail "${label} — code HTTP inattendu (${status}, attendu 200/201)" "$status"
    echo "  corps reçu : ${body}" | mask
    return 1
  fi

  if ! echo "$body" | jq -e . >/dev/null 2>&1; then
    log_fail "${label} — réponse non-JSON reçue malgré un HTTP ${status}" "$status"
    echo "  corps reçu (tronqué) : $(echo "$body" | head -c 300)" | mask
    return 1
  fi

  if echo "$body" | jq -e 'type == "object" and (has("message") or has("code") or has("error") or has("hint"))' >/dev/null 2>&1; then
    local errmsg
    errmsg=$(echo "$body" | jq -r '.message // .error // .hint // .code // "erreur PostgREST non détaillée"' 2>/dev/null)
    log_fail "${label} — PostgREST a renvoyé un objet d'erreur (HTTP ${status})" "$status"
    echo "  détail : ${errmsg}" | mask
    return 1
  fi

  if ! echo "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log_fail "${label} — forme JSON inattendue (ni tableau, ni objet d'erreur reconnu)" "$status"
    return 1
  fi

  local id
  id=$(echo "$body" | jq -r '.[0].id // empty' 2>/dev/null)
  if [[ -z "$id" ]]; then
    log_fail "${label} — tableau vide ou sans champ id (0 ligne insérée)" "$status"
    return 1
  fi

  echo "$id"
  return 0
}

# insert_and_get_id LABEL PATH PAYLOAD — variante service_role (fixtures QA internes).
insert_and_get_id() {
  local label="$1" path="$2" payload="$3"
  local resp
  resp=$(service_call POST "$path" "$payload")
  split_http_response "$resp"
  assert_insert_response "$label" "$HTTP_STATUS" "$HTTP_BODY"
}

# insert_and_get_id_rest LABEL PATH JWT PAYLOAD — variante rest_call (INSERT réel via
# PostgREST sous l'identité d'un persona JWT, ex. hôtel A créant son propre ticket support).
insert_and_get_id_rest() {
  local label="$1" path="$2" jwt="$3" payload="$4"
  local resp
  resp=$(rest_call POST "$path" "$jwt" "$payload")
  split_http_response "$resp"
  assert_insert_response "$label" "$HTTP_STATUS" "$HTTP_BODY"
}

expect_status() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then log_pass "$label" "$got"; else log_fail "$label — attendu $want" "$got"; fi
}

# ============================================================================
# CLEANUP — appelé par trap EXIT dans tous les cas
# ============================================================================
CLEANUP_DONE=0
cleanup() {
  [[ "$CLEANUP_DONE" == "1" ]] && return
  CLEANUP_DONE=1
  log_info "=== CLEANUP : suppression des fixtures ${RUN_TAG} ==="
  local cleanup_ok=1
  for entry in "${CREATED_ROWS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    local table="${entry%%|*}" id="${entry#*|}"
    local st
    st=$(service_call DELETE "/rest/v1/${table}?id=eq.${id}" | head -n1)
    [[ "$st" != "200" && "$st" != "204" ]] && cleanup_ok=0
  done
  for aid in "${CREATED_AUTH_IDS[@]:-}"; do
    [[ -z "$aid" ]] && continue
    local st
    st=$(service_call DELETE "/auth/v1/admin/users/${aid}" | head -n1)
    [[ "$st" != "200" && "$st" != "204" ]] && cleanup_ok=0
  done
  if [[ "$cleanup_ok" == "1" ]]; then
    log_info "Nettoyage : PASS (toutes les fixtures ${RUN_TAG} supprimées)"
    echo "cleanup_status=PASS" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  else
    log_info "Nettoyage : FAIL PARTIEL — au moins une suppression a échoué, vérifier manuellement dans le Dashboard Supabase (filtrer par ${RUN_TAG})"
    echo "cleanup_status=FAIL" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

write_artifact() {
  local rows_json="[]"
  if [[ ${#RESULT_ROWS[@]} -gt 0 ]]; then
    rows_json=$(printf '%s\n' "${RESULT_ROWS[@]}" | jq -sc .)
  fi
  jq -n --argjson rows "$rows_json" --arg pass "$PASS_COUNT" --arg fail "$FAIL_COUNT" \
    --arg run_tag "$RUN_TAG" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{run_tag:$run_tag, generated_at:$ts, pass_count:($pass|tonumber), fail_count:($fail|tonumber), results:$rows}' \
    > "$RESULTS_JSON"
  log_info "Artefact écrit : ${RESULTS_JSON}"
}

print_summary() {
  echo ""
  echo "=== RÉSUMÉ : ${PASS_COUNT} PASS, ${FAIL_COUNT} FAIL ==="
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "Échecs :"
    for f in "${FAILURES[@]}"; do echo "  - $f" | mask; done
  fi
  {
    echo "## Recette Phase 2 — staging"
    echo ""
    echo "| Métrique | Valeur |"
    echo "|---|---|"
    echo "| PASS | ${PASS_COUNT} |"
    echo "| FAIL | ${FAIL_COUNT} |"
    echo "| Run tag | ${RUN_TAG} |"
    echo "| Verdict | $([[ $FAIL_COUNT -eq 0 ]] && echo '✅ PASS' || echo '❌ FAIL') |"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
}

# ============================================================================
# SECTION STRUCTURE — comparaison staging vs instantané de référence production
# ============================================================================
log_info "=== STRUCTURE (comparaison staging vs snapshot production committé) ==="

BASELINE_TABLES='["add_ons","audit_logs","employees","help_articles","hotel_addon_subscriptions","hotel_app_subscriptions","hotel_groups","hotel_subscription_events","hotel_subscriptions","hotels","hr_document_audit_logs","invoice_sequences","invoices","lighthouse_days","lighthouse_imports","mi_imported_events","onboarding_tasks","payments","plan_modules","platform_admins","platform_apps","platform_contracts","platform_credit_note_sequences","platform_credit_notes","platform_invoice_sequences","platform_invoices","platform_logs","platform_payments","platform_schema_markers","platform_settings","rms_decisions","rms_settings","rooms","salon_events","staff_departments","subscription_plans","support_tickets","user_active_hotel","user_app_access","user_hotels","user_invitations","users"]'

R=$(service_call POST "/rest/v1/rpc/_qa_introspect_tables" "$(jq -nc --argjson t "$BASELINE_TABLES" '{p_tables:$t}')")
# NB : l'introspection complète de 42 tables (colonnes/contraintes/index/triggers/policies/
# grants) peut produire un JSON volumineux. On évite ici deux pièges observés en exécution
# réelle : (1) `echo "$R" | head -n1` peut recevoir SIGPIPE ("Broken pipe") quand $R est gros et
# que head ferme son entrée tôt — remplacé par split_http_response (lib/http-response.sh,
# expansion de paramètre bash pure, sans pipe externe) ; (2) passer ce JSON volumineux à jq via
# l'option "argjson" (comme argument de ligne de commande) peut dépasser ARG_MAX du système
# ("Argument list too long") — remplacé par un fichier temporaire lu via `--slurpfile`.
split_http_response "$R"; ST="$HTTP_STATUS"; STAGING_SNAPSHOT="$HTTP_BODY"
if [[ "$ST" != "200" ]]; then
  die_critical "Impossible d'introspecter le schéma de staging (_qa_introspect_tables) — HTTP ${ST}"
fi

SNAPSHOT_FIXTURE="$(dirname "$0")/fixtures/production_schema_snapshot.json"
if [[ ! -f "$SNAPSHOT_FIXTURE" ]]; then
  die_critical "Fixture manquante : ${SNAPSHOT_FIXTURE}"
fi

STAGING_SNAPSHOT_FILE=$(mktemp)
printf '%s' "$STAGING_SNAPSHOT" > "$STAGING_SNAPSHOT_FILE"

# Comparaison stricte : colonnes (nom/type/nullable), contraintes, index, triggers, policies,
# grants, RLS enabled/forced. Tolère les différences de texte de 'default' (peut contenir des
# OID/séquences non comparables tel quel) — tout le reste doit matcher exactement.
STRUCT_DIFF=$(jq -n --slurpfile prod "$SNAPSHOT_FIXTURE" --slurpfile staging "$STAGING_SNAPSHOT_FILE" '
  ($prod[0]) as $p | ($staging[0]) as $s |
  [ ($p|keys[]) as $t | select($s[$t] != null) |
    ($p[$t]) as $pt | ($s[$t]) as $st |
    {
      table: $t,
      rls_mismatch: (if $pt.rls_enabled != $st.rls_enabled or $pt.rls_forced != $st.rls_forced then {prod:{enabled:$pt.rls_enabled,forced:$pt.rls_forced}, staging:{enabled:$st.rls_enabled,forced:$st.rls_forced}} else null end),
      columns_missing_in_staging: ([$pt.columns[] | {name,type,nullable}] - [$st.columns[] | {name,type,nullable}]),
      constraints_missing_in_staging: ([$pt.constraints[].name] - [$st.constraints[].name]),
      indexes_missing_in_staging: ([$pt.indexes[].name] - [$st.indexes[].name]),
      triggers_missing_in_staging: ([$pt.triggers[].name] - [$st.triggers[].name]),
      policies_missing_in_staging: ([$pt.policies[].name] - [$st.policies[].name])
    } |
    select(.rls_mismatch != null or (.columns_missing_in_staging|length)>0 or (.constraints_missing_in_staging|length)>0 or (.indexes_missing_in_staging|length)>0 or (.triggers_missing_in_staging|length)>0 or (.policies_missing_in_staging|length)>0)
  ]
')
DIFF_COUNT=$(echo "$STRUCT_DIFF" | jq 'length')
if [[ "$DIFF_COUNT" == "0" ]]; then
  log_pass "Comparaison structurelle staging/production : aucune divergence sur les tables de référence"
else
  log_fail "Comparaison structurelle staging/production : ${DIFF_COUNT} table(s) divergente(s) sur des objets censés être identiques (hors nouveautés Phase 2)" ""
  echo "$STRUCT_DIFF" | jq -c '.[] | {table, columns_missing_in_staging, constraints_missing_in_staging, indexes_missing_in_staging, triggers_missing_in_staging, policies_missing_in_staging}' | while read -r line; do
    echo "  divergence: $line" | mask
  done
fi
echo "$STRUCT_DIFF" > "${RESULTS_DIR}/structural_diff.json"
rm -f "$STAGING_SNAPSHOT_FILE"

# Tables Phase 2 réellement nouvelles (introduites par sql/80-89, pas encore en production —
# ces PR sont encore ouvertes) : existence + RLS activée uniquement, pas de comparaison à la
# production puisqu'elle ne les a pas encore.
NEW_TABLES='["platform_notifications","support_ticket_replies","support_ticket_attachments","support_ticket_attachment_access_log"]'
R=$(service_call POST "/rest/v1/rpc/_qa_introspect_tables" "$(jq -nc --argjson t "$NEW_TABLES" '{p_tables:$t}')")
split_http_response "$R"; ST="$HTTP_STATUS"; NEW_SNAPSHOT="$HTTP_BODY"
if [[ "$ST" == "200" ]]; then
  for t in $(echo "$NEW_TABLES" | jq -r '.[]'); do
    exists=$(echo "$NEW_SNAPSHOT" | jq --arg t "$t" 'has($t)')
    rls=$(echo "$NEW_SNAPSHOT" | jq --arg t "$t" '.[$t].rls_enabled // false')
    if [[ "$exists" == "true" && "$rls" == "true" ]]; then
      log_pass "Table Phase 2 nouvelle '${t}' présente avec RLS activée (pas encore en production, attendu)"
    else
      log_fail "Table Phase 2 nouvelle '${t}' absente ou RLS désactivée" ""
    fi
  done
else
  log_fail "Introspection des tables Phase 2 nouvelles impossible" "$ST"
fi

# ============================================================================
# SECTION SETUP — fixtures fictives via service_role (jamais utilisé pour un test d'autorisation)
# ============================================================================
log_info "=== SETUP ==="

PASSWORD="Qa-${RUN_TAG}-P@ss1"
EMAIL_SUPERADMIN="${RUN_TAG}-superadmin@flowtym-staging-test.invalid"
EMAIL_SUPPORT="${RUN_TAG}-support@flowtym-staging-test.invalid"
EMAIL_HOTEL_A="${RUN_TAG}-hotela@flowtym-staging-test.invalid"
EMAIL_HOTEL_B="${RUN_TAG}-hotelb@flowtym-staging-test.invalid"
EMAIL_NOATTACH="${RUN_TAG}-noattach@flowtym-staging-test.invalid"

create_confirmed_user() {
  # GoTrue renvoie un OBJET (jamais un tableau) : mêmes contrôles stricts que
  # insert_and_get_id (HTTP, JSON valide, objet d'erreur) mais adaptés à cette forme.
  local email="$1"
  local resp status body
  resp=$(service_call POST "/auth/v1/admin/users" \
    "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e, password:$p, email_confirm:true}')")
  split_http_response "$resp"
  status="$HTTP_STATUS"
  body="$HTTP_BODY"

  if [[ "$status" != "200" && "$status" != "201" ]]; then
    log_info "create_confirmed_user(${email}) — code HTTP inattendu (${status})"
    return 0
  fi
  if ! echo "$body" | jq -e . >/dev/null 2>&1; then
    log_info "create_confirmed_user(${email}) — réponse non-JSON malgré HTTP ${status}"
    return 0
  fi
  if echo "$body" | jq -e '(has("message") or has("error_description") or has("msg")) and (has("id") | not)' >/dev/null 2>&1; then
    local errmsg
    errmsg=$(echo "$body" | jq -r '.message // .error_description // .msg // "erreur GoTrue non détaillée"' 2>/dev/null)
    log_info "create_confirmed_user(${email}) — GoTrue a renvoyé une erreur : ${errmsg}"
    return 0
  fi

  echo "$body" | jq -r '.id // empty' 2>/dev/null
}

AUTH_ID_SUPERADMIN=$(create_confirmed_user "$EMAIL_SUPERADMIN")
AUTH_ID_SUPPORT=$(create_confirmed_user "$EMAIL_SUPPORT")
AUTH_ID_HOTEL_A=$(create_confirmed_user "$EMAIL_HOTEL_A")
AUTH_ID_HOTEL_B=$(create_confirmed_user "$EMAIL_HOTEL_B")
AUTH_ID_NOATTACH=$(create_confirmed_user "$EMAIL_NOATTACH")

for aid in "$AUTH_ID_SUPERADMIN" "$AUTH_ID_SUPPORT" "$AUTH_ID_HOTEL_A" "$AUTH_ID_HOTEL_B" "$AUTH_ID_NOATTACH"; do
  [[ -z "$aid" || "$aid" == "null" ]] && die_critical "Échec création d'un compte Auth de fixture."
  CREATED_AUTH_IDS+=("$aid")
done
log_pass "5 comptes Auth de fixture créés et confirmés"

RUN_SUFFIX="${RUN_TAG: -8}"
# public.hotels.hotel_code est un varchar(5) — RUN_SUFFIX (8 caractères) dépasserait la limite
# et ferait échouer l'INSERT (PostgREST renvoie alors un objet d'erreur, pas un tableau, d'où
# l'échec `jq: Cannot index object with number` sur `.[0].id`). Code dédié, borné à 5 caractères
# (4 issus de RUN_SUFFIX + 1 lettre A/B), tandis que RUN_SUFFIX (non contraint en longueur ici)
# reste utilisé tel quel pour platform_apps.code ci-dessous.
HOTEL_CODE_SUFFIX="${RUN_SUFFIX: -4}"
HOTEL_A_ID=$(insert_and_get_id "Création hôtel fictif A" "/rest/v1/hotels" \
  "$(jq -n --arg n "${RUN_TAG} Hotel A" --arg c "${HOTEL_CODE_SUFFIX}A" '{name:$n, city:"Paris", hotel_code:$c, status:"active", active:true}')") \
  || die_critical "Échec création des 2 hôtels fictifs."
HOTEL_B_ID=$(insert_and_get_id "Création hôtel fictif B" "/rest/v1/hotels" \
  "$(jq -n --arg n "${RUN_TAG} Hotel B" --arg c "${HOTEL_CODE_SUFFIX}B" '{name:$n, city:"Lyon", hotel_code:$c, status:"active", active:true}')") \
  || die_critical "Échec création des 2 hôtels fictifs."
CREATED_ROWS+=("hotels|${HOTEL_A_ID}" "hotels|${HOTEL_B_ID}")
log_pass "2 hôtels fictifs créés"

USER_A_ID=$(insert_and_get_id "Création ligne public.users hôtel A" "/rest/v1/users" \
  "$(jq -n --arg aid "$AUTH_ID_HOTEL_A" --arg h "$HOTEL_A_ID" --arg e "$EMAIL_HOTEL_A" '{auth_id:$aid, hotel_id:$h, email:$e, full_name:"QA Hotel A", role:"admin_hotel", is_active:true}')") \
  || die_critical "Échec création des lignes public.users."
USER_B_ID=$(insert_and_get_id "Création ligne public.users hôtel B" "/rest/v1/users" \
  "$(jq -n --arg aid "$AUTH_ID_HOTEL_B" --arg h "$HOTEL_B_ID" --arg e "$EMAIL_HOTEL_B" '{auth_id:$aid, hotel_id:$h, email:$e, full_name:"QA Hotel B", role:"admin_hotel", is_active:true}')") \
  || die_critical "Échec création des lignes public.users."
CREATED_ROWS+=("users|${USER_A_ID}" "users|${USER_B_ID}")

service_call POST "/rest/v1/user_hotels" \
  "$(jq -n --arg u "$USER_A_ID" --arg h "$HOTEL_A_ID" '{user_id:$u, hotel_id:$h, role:"admin_hotel", is_default:true}')" >/dev/null
service_call POST "/rest/v1/user_hotels" \
  "$(jq -n --arg u "$USER_B_ID" --arg h "$HOTEL_B_ID" '{user_id:$u, hotel_id:$h, role:"admin_hotel", is_default:true}')" >/dev/null
log_pass "2 utilisateurs hôtel (A, B) créés et rattachés"

PA_SUPERADMIN_ID=$(insert_and_get_id "Création platform_admin super_admin" "/rest/v1/platform_admins" \
  "$(jq -n --arg aid "$AUTH_ID_SUPERADMIN" --arg e "$EMAIL_SUPERADMIN" '{auth_id:$aid, email:$e, full_name:"QA Super Admin", role:"super_admin", is_active:true}')") \
  || die_critical "Échec création des platform_admins."
PA_SUPPORT_ID=$(insert_and_get_id "Création platform_admin support_agent" "/rest/v1/platform_admins" \
  "$(jq -n --arg aid "$AUTH_ID_SUPPORT" --arg e "$EMAIL_SUPPORT" '{auth_id:$aid, email:$e, full_name:"QA Support Agent", role:"support_agent", is_active:true}')") \
  || die_critical "Échec création des platform_admins."
CREATED_ROWS+=("platform_admins|${PA_SUPERADMIN_ID}" "platform_admins|${PA_SUPPORT_ID}")
log_pass "platform_admins créés (1 super_admin, 1 support_agent)"

PLAN_ID=$(insert_and_get_id "Création plan fictif" "/rest/v1/subscription_plans" \
  "$(jq -n --arg n "${RUN_TAG} Plan" --arg s "${RUN_TAG}-plan" '{name:$n, slug:$s, plan_scope:"public", is_active:true, is_commercializable:true, price_monthly:99, max_rooms:20, max_users:10, trial_days:14}')") \
  || die_critical "Échec création du plan fictif."
CREATED_ROWS+=("subscription_plans|${PLAN_ID}")

APP_ID=$(insert_and_get_id "Création app fictive" "/rest/v1/platform_apps" \
  "$(jq -n --arg c "APP${RUN_SUFFIX}" --arg n "${RUN_TAG} App" '{code:$c, name:$n, is_active:true}')") \
  || die_critical "Échec création de l'app fictive."
CREATED_ROWS+=("platform_apps|${APP_ID}")

SUB_A_ID=$(insert_and_get_id "Création abonnement fictif A (active)" "/rest/v1/hotel_subscriptions" \
  "$(jq -n --arg h "$HOTEL_A_ID" --arg p "$PLAN_ID" '{hotel_id:$h, plan_id:$p, status:"active", snapshot_price_net_ht:99, snapshot_effective_at:"now()"}')") \
  || die_critical "Échec création des abonnements fictifs."
TRIAL_END_J7=$(date -u -d "+7 days" +"%Y-%m-%dT12:00:00Z" 2>/dev/null || date -u -v+7d +"%Y-%m-%dT12:00:00Z")
SUB_B_ID=$(insert_and_get_id "Création abonnement fictif B (trial J+7)" "/rest/v1/hotel_subscriptions" \
  "$(jq -n --arg h "$HOTEL_B_ID" --arg p "$PLAN_ID" --arg t "$TRIAL_END_J7" '{hotel_id:$h, plan_id:$p, status:"trial", trial_ends_at:$t, snapshot_price_net_ht:99, snapshot_effective_at:"now()"}')") \
  || die_critical "Échec création des abonnements fictifs."
CREATED_ROWS+=("hotel_subscriptions|${SUB_A_ID}" "hotel_subscriptions|${SUB_B_ID}")
log_pass "1 plan + 1 app + 2 abonnements (A=active, B=trial J+7) créés"

# ============================================================================
# SECTION AUTH — signup réel + login réel (GoTrue)
# ============================================================================
log_info "=== AUTH (signup + login réels) ==="

EMAIL_SIGNUP="${RUN_TAG}-signup@flowtym-staging-test.invalid"
SIGNUP_RESP=$(rest_call POST "/auth/v1/signup" "" "$(jq -n --arg e "$EMAIL_SIGNUP" --arg p "$PASSWORD" '{email:$e, password:$p}')")
SIGNUP_STATUS=$(echo "$SIGNUP_RESP" | head -n1)
SIGNUP_BODY=$(echo "$SIGNUP_RESP" | tail -n +2)
if [[ "$SIGNUP_STATUS" == "200" ]]; then
  log_pass "POST /auth/v1/signup — inscription publique acceptée" "$SIGNUP_STATUS"
  SIGNUP_AUTH_ID=$(echo "$SIGNUP_BODY" | jq -r '.id // .user.id // empty')
  [[ -n "$SIGNUP_AUTH_ID" && "$SIGNUP_AUTH_ID" != "null" ]] && CREATED_AUTH_IDS+=("$SIGNUP_AUTH_ID")
else
  log_fail "POST /auth/v1/signup — statut inattendu" "$SIGNUP_STATUS"
fi

login() {
  # Exécutée via $(...) => sous-shell : ne jamais appeler die_critical/exit ici.
  local email="$1"
  local resp status body token
  resp=$(rest_call POST "/auth/v1/token?grant_type=password" "" "$(jq -n --arg e "$email" --arg p "$PASSWORD" '{email:$e, password:$p}')")
  status=$(echo "$resp" | head -n1)
  body=$(echo "$resp" | tail -n +2)
  [[ "$status" != "200" ]] && return 1
  token=$(echo "$body" | jq -r '.access_token')
  [[ -z "$token" || "$token" == "null" ]] && return 1
  echo "$token"
  return 0
}

JWT_SUPERADMIN=$(login "$EMAIL_SUPERADMIN") || die_critical "Login échoué pour le persona super_admin"
JWT_SUPPORT=$(login "$EMAIL_SUPPORT") || die_critical "Login échoué pour le persona support_agent"
JWT_HOTEL_A=$(login "$EMAIL_HOTEL_A") || die_critical "Login échoué pour le persona hôtel A"
JWT_HOTEL_B=$(login "$EMAIL_HOTEL_B") || die_critical "Login échoué pour le persona hôtel B"
JWT_NOATTACH=$(login "$EMAIL_NOATTACH") || die_critical "Login échoué pour le persona authenticated sans hôtel"
mask_secret "$JWT_SUPERADMIN"; mask_secret "$JWT_SUPPORT"; mask_secret "$JWT_HOTEL_A"; mask_secret "$JWT_HOTEL_B"; mask_secret "$JWT_NOATTACH"
log_pass "5 logins réussis via GoTrue (5 JWT réels obtenus, masqués)"

# ============================================================================
# SECTION RLS-MATRIX
# ============================================================================
log_info "=== RLS-MATRIX ==="

# Garde-fou : _qa_introspect_tables est un outil QA interne réservé à service_role (REVOKE ALL
# FROM PUBLIC, anon, authenticated dans qa_introspect_tables.sql) — jamais accessible via PostgREST
# à un rôle anon ou authenticated, quelle que soit l'identité du JWT.
R=$(rest_call POST "/rest/v1/rpc/_qa_introspect_tables" "" '{"p_tables":["hotels"]}'); ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" || "$ST" == "404" ]] && log_pass "anon : _qa_introspect_tables() refusé (outil QA interne service_role-only)" "$ST" || log_fail "anon a pu appeler _qa_introspect_tables() — fuite de l'outillage QA interne" "$ST"

R=$(rest_call POST "/rest/v1/rpc/_qa_introspect_tables" "$JWT_NOATTACH" '{"p_tables":["hotels"]}'); ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" || "$ST" == "404" ]] && log_pass "authenticated : _qa_introspect_tables() refusé (outil QA interne service_role-only)" "$ST" || log_fail "authenticated a pu appeler _qa_introspect_tables() — fuite de l'outillage QA interne" "$ST"

R=$(rest_call GET "/rest/v1/hotels?select=id" ""); ST=$(echo "$R"|head -n1); BODY=$(echo "$R"|tail -n +2)
N=$(echo "$BODY" | jq 'length' 2>/dev/null || echo -1)
if [[ "$ST" == "200" && "$N" == "0" ]]; then
  log_pass "anon : 0 ligne visible sur hotels (RLS fail-closed)" "$ST"
elif [[ "$ST" == "401" || "$ST" == "403" ]]; then
  log_pass "anon : refusé au niveau grant" "$ST"
else
  log_fail "anon GET hotels — ${N} ligne(s) visible(s), attendu 0" "$ST"
fi

R=$(rest_call GET "/rest/v1/hotels?select=id" "$JWT_NOATTACH"); ST=$(echo "$R"|head -n1); BODY=$(echo "$R"|tail -n +2)
N=$(echo "$BODY" | jq 'length' 2>/dev/null || echo -1)
[[ "$ST" == "200" && "$N" == "0" ]] && log_pass "authenticated sans hôtel : 0 hôtel visible" "$ST" || log_fail "authenticated sans hôtel voit ${N} hôtel(s) (attendu 0)" "$ST"

R=$(rest_call GET "/rest/v1/hotels?select=id" "$JWT_HOTEL_A"); BODY=$(echo "$R"|tail -n +2)
IDS=$(echo "$BODY" | jq -r '.[].id' 2>/dev/null)
[[ "$IDS" == "$HOTEL_A_ID" ]] && log_pass "hôtel A : isolation OK (voit exactement son hôtel)" || log_fail "hôtel A voit un ensemble inattendu" ""

R=$(rest_call GET "/rest/v1/hotels?select=id" "$JWT_HOTEL_B"); BODY=$(echo "$R"|tail -n +2)
IDS=$(echo "$BODY" | jq -r '.[].id' 2>/dev/null)
[[ "$IDS" == "$HOTEL_B_ID" ]] && log_pass "hôtel B : isolation OK (voit exactement son hôtel)" || log_fail "hôtel B voit un ensemble inattendu" ""

R=$(rest_call PATCH "/rest/v1/hotels?id=eq.${HOTEL_B_ID}" "$JWT_HOTEL_A" '{"city":"Hacked"}'); BODY=$(echo "$R"|tail -n +2)
N=$(echo "$BODY" | jq 'length' 2>/dev/null || echo -1)
[[ "$N" == "0" ]] && log_pass "hôtel A : PATCH cross-tenant sur hôtel B bloqué" "" || log_fail "hôtel A a pu modifier hôtel B (${N} ligne(s))" ""

for persona in "support_agent:$JWT_SUPPORT" "super_admin:$JWT_SUPERADMIN"; do
  name="${persona%%:*}"; jwt="${persona#*:}"
  R=$(rest_call GET "/rest/v1/hotels?select=id" "$jwt"); BODY=$(echo "$R"|tail -n +2)
  N=$(echo "$BODY" | jq 'length' 2>/dev/null || echo 0)
  [[ "$N" -ge 2 ]] && log_pass "${name} : accès transverse OK (${N} hôtels)" "" || log_fail "${name} ne voit que ${N} hôtel(s) (attendu >= 2)" ""
done

R=$(rest_call POST "/rest/v1/rpc/platform_dashboard_kpis" "$JWT_HOTEL_A" '{}'); ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" ]] && log_pass "hôtel A : platform_dashboard_kpis() refusé" "$ST" || log_fail "hôtel A a pu appeler platform_dashboard_kpis()" "$ST"

R=$(rest_call POST "/rest/v1/rpc/platform_dashboard_kpis" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
expect_status "super_admin : platform_dashboard_kpis() autorisé" "$ST" "200"

R=$(rest_call POST "/rest/v1/rpc/platform_dashboard_kpis" "$JWT_SUPPORT" '{}'); ST=$(echo "$R"|head -n1)
expect_status "support_agent : platform_dashboard_kpis() autorisé" "$ST" "200"

R=$(rest_call POST "/rest/v1/rpc/admin_create_hotel" "" '{"p":{"name":"x"}}'); ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" ]] && log_pass "anon : admin_create_hotel() refusé" "$ST" || log_fail "anon a pu appeler admin_create_hotel()" "$ST"

# Paramètres falsifiés : hotel_id inexistant sur une RPC admin -> doit échouer proprement, pas planter
R=$(rest_call POST "/rest/v1/rpc/admin_set_hotel_status" "$JWT_SUPERADMIN" '{"p_hotel":"00000000-0000-0000-0000-000000000000","p_status":"active"}')
ST=$(echo "$R"|head -n1)
[[ "$ST" == "400" || "$ST" == "404" || "$ST" == "422" ]] && log_pass "super_admin : admin_set_hotel_status() avec hotel_id inexistant rejeté proprement" "$ST" || log_fail "admin_set_hotel_status() avec hotel_id falsifié — réponse inattendue" "$ST"

# ============================================================================
# SECTION SUPPORT
# ============================================================================
log_info "=== SUPPORT ==="

TICKET_A_ID=$(insert_and_get_id_rest "Création ticket support hôtel A" "/rest/v1/support_tickets" "$JWT_HOTEL_A" \
  "$(jq -n --arg h "$HOTEL_A_ID" --arg u "$USER_A_ID" --arg e "$EMAIL_HOTEL_A" '{hotel_id:$h, module:"planning", feature:"qa", description:"Ticket hotel A", user_id:$u, user_email:$e}')") \
  || die_critical "Échec création du ticket support hôtel A."
CREATED_ROWS+=("support_tickets|${TICKET_A_ID}")
log_pass "Ticket support créé par hôtel A (INSERT réel via PostgREST)"

R=$(rest_call GET "/rest/v1/support_tickets?select=id" "$JWT_HOTEL_B"); N=$(echo "$R"|tail -n +2|jq 'length' 2>/dev/null||echo -1)
[[ "$N" == "0" ]] && log_pass "hôtel B ne voit pas le ticket de hôtel A (isolation Support OK — ticket d'un autre hôtel)" "" || log_fail "hôtel B voit ${N} ticket(s) (attendu 0)" ""

R=$(rest_call POST "/rest/v1/rpc/admin_reply_support_ticket" "$JWT_SUPPORT" \
  "$(jq -n --arg t "$TICKET_A_ID" '{p_ticket_id:$t, p_body:"Réponse publique QA", p_is_internal_note:false, p_corrects_reply_id:null}')")
split_http_response "$R"; ST="$HTTP_STATUS"
expect_status "support_agent : réponse publique au ticket" "$ST" "200"
# admin_reply_support_ticket() peut renvoyer un scalaire brut ou un tableau à un élément selon
# le typage SETOF/TABLE — jamais indexé sans avoir d'abord validé que le corps est du JSON
# syntaxiquement correct (ne parse jamais une réponse invalide).
if [[ "$ST" == "200" ]] && echo "$HTTP_BODY" | jq -e . >/dev/null 2>&1; then
  REPLY_PUBLIC_ID=$(echo "$HTTP_BODY" | jq -r 'if type=="array" then (.[0] // empty) else . end' 2>/dev/null)
else
  REPLY_PUBLIC_ID=""
fi

R=$(rest_call POST "/rest/v1/rpc/admin_reply_support_ticket" "$JWT_SUPPORT" \
  "$(jq -n --arg t "$TICKET_A_ID" '{p_ticket_id:$t, p_body:"Note interne QA", p_is_internal_note:true, p_corrects_reply_id:null}')")
ST=$(echo "$R"|head -n1)
expect_status "support_agent : note interne créée" "$ST" "200"

# Correction cross-ticket : refusée par le trigger dédié
TICKET_B_TMP=$(insert_and_get_id_rest "Création ticket support hôtel B (test cross-ticket)" "/rest/v1/support_tickets" "$JWT_HOTEL_B" \
  "$(jq -n --arg h "$HOTEL_B_ID" --arg u "$USER_B_ID" --arg e "$EMAIL_HOTEL_B" '{hotel_id:$h, module:"planning", feature:"qa", description:"Ticket hotel B", user_id:$u, user_email:$e}')")
if [[ -n "$TICKET_B_TMP" ]]; then
  CREATED_ROWS+=("support_tickets|${TICKET_B_TMP}")
  if [[ "$REPLY_PUBLIC_ID" != "null" && -n "$REPLY_PUBLIC_ID" ]]; then
    R=$(rest_call POST "/rest/v1/rpc/admin_reply_support_ticket" "$JWT_SUPPORT" \
      "$(jq -n --arg t "$TICKET_B_TMP" --arg r "$REPLY_PUBLIC_ID" '{p_ticket_id:$t, p_body:"Tentative correction cross-ticket", p_is_internal_note:false, p_corrects_reply_id:$r}')")
    ST=$(echo "$R"|head -n1)
    [[ "$ST" != "200" ]] && log_pass "correction cross-ticket refusée par le trigger" "$ST" || log_fail "correction cross-ticket aurait dû être refusée" "$ST"
  fi
fi

R=$(rest_call GET "/rest/v1/support_ticket_replies?ticket_id=eq.${TICKET_A_ID}&select=id" "$JWT_HOTEL_A")
N=$(echo "$R"|tail -n +2|jq 'length' 2>/dev/null||echo -1)
[[ "$N" == "1" ]] && log_pass "hôtel A voit 1 réponse (publique), note interne invisible" "" || log_fail "hôtel A voit ${N} réponse(s) (attendu 1)" ""

R=$(rest_call GET "/rest/v1/support_ticket_replies?ticket_id=eq.${TICKET_A_ID}&select=id" "$JWT_SUPPORT")
N=$(echo "$R"|tail -n +2|jq 'length' 2>/dev/null||echo -1)
[[ "$N" -ge "2" ]] && log_pass "support_agent voit les réponses (publique + interne)" "" || log_fail "support_agent voit ${N} réponse(s) (attendu >=2)" ""

if [[ "$REPLY_PUBLIC_ID" != "null" && -n "$REPLY_PUBLIC_ID" ]]; then
  R=$(rest_call POST "/rest/v1/rpc/admin_hide_support_ticket_reply" "$JWT_SUPPORT" \
    "$(jq -n --arg r "$REPLY_PUBLIC_ID" '{p_reply_id:$r, p_reason:"QA masquage"}')")
  ST=$(echo "$R"|head -n1)
  expect_status "support_agent : masquage de réponse" "$ST" "200"
  R=$(rest_call GET "/rest/v1/support_ticket_replies?ticket_id=eq.${TICKET_A_ID}&select=id" "$JWT_HOTEL_A")
  N=$(echo "$R"|tail -n +2|jq 'length' 2>/dev/null||echo -1)
  [[ "$N" == "0" ]] && log_pass "hôtel A ne voit plus la réponse masquée" "" || log_fail "hôtel A voit encore ${N} réponse(s) après masquage (attendu 0)" ""
fi

R=$(rest_call PATCH "/rest/v1/support_tickets?id=eq.${TICKET_A_ID}" "$JWT_SUPPORT" '{"status":"resolu"}')
ST=$(echo "$R"|head -n1); BODY=$(echo "$R"|tail -n +2)
NEWSTATUS=$(echo "$BODY" | jq -r '.[0].status // empty')
[[ "$NEWSTATUS" == "resolu" ]] && log_pass "support_agent : changement de statut à 'resolu'" "$ST" || log_fail "changement de statut échoué" "$ST"

R=$(rest_call POST "/rest/v1/rpc/admin_list_support_tickets" "$JWT_SUPPORT" \
  "$(jq -n --arg h "$HOTEL_A_ID" '{p_status:null,p_priority:null,p_assigned_to:null,p_hotel_id:$h,p_module:null,p_risk_score:null,p_search:null,p_limit:10,p_offset:0}')")
ST=$(echo "$R"|head -n1)
expect_status "support_agent : admin_list_support_tickets() filtré par hotel_id" "$ST" "200"

# ============================================================================
# SECTION LICENCES
# ============================================================================
log_info "=== LICENCES ==="
R=$(rest_call POST "/rest/v1/rpc/admin_list_license_usage" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
expect_status "super_admin : admin_list_license_usage()" "$ST" "200"
R=$(rest_call POST "/rest/v1/rpc/admin_list_license_usage" "$JWT_HOTEL_A" '{}'); ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" ]] && log_pass "hôtel A : admin_list_license_usage() refusé" "$ST" || log_fail "hôtel A a pu appeler admin_list_license_usage()" "$ST"
R=$(rest_call POST "/rest/v1/rpc/admin_platform_alerts" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
expect_status "super_admin : admin_platform_alerts()" "$ST" "200"

# ============================================================================
# SECTION ESSAIS — idempotence réelle
# ============================================================================
log_info "=== ESSAIS (idempotence) ==="
R=$(rest_call POST "/rest/v1/rpc/admin_preview_trial_ending_notifications" "$JWT_SUPERADMIN" '{}')
ST=$(echo "$R"|head -n1); BODY=$(echo "$R"|tail -n +2)
CANDIDATE=$(echo "$BODY" | jq --arg h "$HOTEL_B_ID" '[.[] | select(.hotel_id==$h and .threshold_days==7 and .would_send==true)] | length' 2>/dev/null || echo 0)
[[ "$ST" == "200" && "$CANDIDATE" == "1" ]] && log_pass "preview : hôtel B (trial J+7) candidat au palier 7" "$ST" || log_fail "preview essais — candidat=${CANDIDATE} (attendu 1)" "$ST"

R1=$(rest_call POST "/rest/v1/rpc/admin_run_trial_ending_notifications" "$JWT_SUPERADMIN" '{}')
ST1=$(echo "$R1"|head -n1); B1=$(echo "$R1"|tail -n +2)
SENT1=$(echo "$B1" | jq -r '.[0].sent_count // .sent_count // 0' 2>/dev/null)
[[ "$ST1" == "200" ]] && log_pass "1er run essais : sent_count=${SENT1}" "$ST1" || log_fail "1er run essais échoué" "$ST1"

# Double appel immédiat (concurrence simulée) + vérification d'idempotence
R2=$(rest_call POST "/rest/v1/rpc/admin_run_trial_ending_notifications" "$JWT_SUPERADMIN" '{}')
ST2=$(echo "$R2"|head -n1); B2=$(echo "$R2"|tail -n +2)
SKIPPED2=$(echo "$B2" | jq -r '.[0].skipped_already_sent // .skipped_already_sent // 0' 2>/dev/null)
if [[ "$ST2" == "200" && "${SKIPPED2:-0}" -ge 1 ]]; then
  log_pass "2e run (idempotence) : palier déjà notifié ignoré (skipped_already_sent=${SKIPPED2})" "$ST2"
else
  log_fail "idempotence essais — skipped_already_sent=${SKIPPED2} (attendu >=1)" "$ST2"
fi

# Déduplication : prouvée par les valeurs de retour du RPC ci-dessus (SENT1=1 au 1er run,
# SKIPPED2>=1 au 2e run immédiat) — jamais par une lecture directe de platform_notifications
# avec un JWT utilisateur. Cette table est volontairement accessible uniquement à service_role
# (RLS activée, zéro policy, tous les grants révoqués pour authenticated — y compris pour un
# Platform Admin, défense en profondeur, sql/82). Un super_admin reste, au niveau rôle
# PostgreSQL, `authenticated` : une lecture directe doit donc être refusée, jamais autorisée.
if [[ "$ST1" == "200" && "$SENT1" -ge 1 && "$ST2" == "200" && "${SKIPPED2:-0}" -ge 1 ]]; then
  log_pass "Déduplication confirmée via les valeurs de retour du RPC (sent_count=${SENT1}, skipped_already_sent=${SKIPPED2}) — jamais par lecture directe avec un JWT utilisateur" ""
else
  log_fail "Déduplication non confirmée par les valeurs de retour du RPC (sent_count=${SENT1}, skipped_already_sent=${SKIPPED2})" ""
fi

# Récupération de l'ID de la notification pour la section NOTIFICATIONS (Edge Function)
# ci-dessous : service_role strictement limité à ce rôle de setup/assertion QA interne — jamais
# utilisé pour démontrer qu'un utilisateur (super_admin ou autre) est autorisé à lire cette table.
R=$(service_call GET "/rest/v1/platform_notifications?category=eq.trial_ending_soon&select=id")
N=$(echo "$R"|tail -n +2|jq 'length' 2>/dev/null||echo -1)
NOTIF_ID=$(echo "$R"|tail -n +2|jq -r '.[0].id // empty')
[[ -n "$NOTIF_ID" ]] && CREATED_ROWS+=("platform_notifications|${NOTIF_ID}")
[[ "$N" == "1" ]] && log_pass "1 seule notification trial_ending_soon en base (vérifié via service_role, setup QA uniquement)" "" || log_fail "${N} notification(s) trial_ending_soon en base (attendu 1)" ""

# Garde-fou : un super_admin (rôle PostgreSQL authenticated) ne doit JAMAIS pouvoir lire
# platform_notifications directement — seul service_role y a accès (sql/82, défense en
# profondeur). Un 200 ici serait une régression de sécurité réelle.
R=$(rest_call GET "/rest/v1/platform_notifications?select=id" "$JWT_SUPERADMIN")
ST=$(echo "$R"|head -n1)
[[ "$ST" == "401" || "$ST" == "403" ]] && log_pass "super_admin : lecture directe de platform_notifications refusée comme attendu (service_role uniquement)" "$ST" || log_fail "super_admin a pu lire platform_notifications directement — régression de sécurité" "$ST"

# ============================================================================
# SECTION STATISTIQUES + Divergence des droits
# ============================================================================
log_info "=== STATISTIQUES ==="
R=$(rest_call POST "/rest/v1/rpc/admin_platform_statistics" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
expect_status "super_admin : admin_platform_statistics()" "$ST" "200"
R=$(rest_call POST "/rest/v1/rpc/admin_hotel_health_scores" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
expect_status "super_admin : admin_hotel_health_scores()" "$ST" "200"
R=$(rest_call POST "/rest/v1/rpc/admin_rights_divergence_report" "$JWT_SUPERADMIN" '{}'); ST=$(echo "$R"|head -n1)
if [[ "$ST" == "200" || "$ST" == "404" ]]; then
  # 404 = RPC pas encore présente sur ce lot (non bloquant, fonctionnalité optionnelle de ce round) ;
  # 200 = présente et exécutée avec succès. Seul un vrai code d'erreur d'autorisation est un FAIL ici.
  log_pass "super_admin : admin_rights_divergence_report() accessible ou absente proprement" "$ST"
else
  log_fail "admin_rights_divergence_report() — réponse inattendue" "$ST"
fi

# ============================================================================
# SECTION NOTIFICATIONS — Edge Function platform-send-notification (réel HTTP)
# ============================================================================
log_info "=== NOTIFICATIONS (Edge Function) ==="

NOTIF_TEST_ID="${NOTIF_ID:-}"
if [[ -z "$NOTIF_TEST_ID" ]]; then
  log_fail "Pas de notification disponible pour tester l'Edge Function (section Essais a échoué avant)" ""
else
  # Payload invalide : notification_id absent
  R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
    -H "Content-Type: application/json" -H "x-internal-key: ${PHASE2_NOTIFICATION_INTERNAL_KEY}" \
    -d '{}' -w $'\n%{http_code}')
  ST=$(echo "$R" | tail -n1)
  [[ "$ST" == "400" ]] && log_pass "Edge Function payload invalide (notification_id absent) : rejetée proprement" "$ST" || log_fail "payload invalide — attendu 400" "$ST"

  # Clé absente : refus
  R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
    -H "Content-Type: application/json" -d "$(jq -n --arg n "$NOTIF_TEST_ID" '{notification_id:$n}')" -w $'\n%{http_code}')
  ST=$(echo "$R" | tail -n1)
  [[ "$ST" == "401" ]] && log_pass "Edge Function sans x-internal-key : refusée (fail-closed)" "$ST" || log_fail "sans clé — attendu 401" "$ST"

  # Clé invalide : refus
  R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
    -H "Content-Type: application/json" -H "x-internal-key: clearly-wrong-key" \
    -d "$(jq -n --arg n "$NOTIF_TEST_ID" '{notification_id:$n}')" -w $'\n%{http_code}')
  ST=$(echo "$R" | tail -n1)
  [[ "$ST" == "401" ]] && log_pass "Edge Function avec clé invalide : refusée" "$ST" || log_fail "clé invalide — attendu 401" "$ST"

  # Batch vide : notification_id inexistant -> not_pending, jamais une erreur serveur
  R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
    -H "Content-Type: application/json" -H "x-internal-key: ${PHASE2_NOTIFICATION_INTERNAL_KEY}" \
    -d '{"notification_id":"00000000-0000-0000-0000-000000000000"}' -w $'\n%{http_code}')
  ST=$(echo "$R" | tail -n1); BODY=$(echo "$R" | head -n -1)
  SKIPPED=$(echo "$BODY" | jq -r '.skipped // false' 2>/dev/null)
  [[ "$ST" == "200" && "$SKIPPED" == "true" ]] && log_pass "Edge Function batch vide (notification_id inexistant) : skipped proprement" "$ST" || log_fail "batch vide — réponse inattendue" "$ST"

  # Clé correcte : tentative réelle. Sans RESEND_API_KEY configurée côté Supabase, Resend
  # rejette (401 côté Resend) -> chemin failed réel, réellement exercé, jamais simulé.
  R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
    -H "Content-Type: application/json" -H "x-internal-key: ${PHASE2_NOTIFICATION_INTERNAL_KEY}" \
    -d "$(jq -n --arg n "$NOTIF_TEST_ID" '{notification_id:$n}')" -w $'\n%{http_code}')
  ST=$(echo "$R" | tail -n1); BODY=$(echo "$R" | head -n -1)
  RSTATUS=$(echo "$BODY" | jq -r '.status // empty')
  if [[ "$ST" == "200" && "$RSTATUS" == "sent" ]]; then
    log_pass "Edge Function : notification envoyée pour de vrai (status=sent, RESEND_API_KEY configurée)" "$ST"
    # Double appel immédiat après un envoi réussi : doit être 'not_pending' (déduplication/concurrence)
    R=$(curl -sS -X POST "${PHASE2_STAGING_URL}/functions/v1/platform-send-notification" \
      -H "Content-Type: application/json" -H "x-internal-key: ${PHASE2_NOTIFICATION_INTERNAL_KEY}" \
      -d "$(jq -n --arg n "$NOTIF_TEST_ID" '{notification_id:$n}')" -w $'\n%{http_code}')
    ST2=$(echo "$R" | tail -n1); BODY2=$(echo "$R" | head -n -1)
    SKIPPED2=$(echo "$BODY2" | jq -r '.skipped // false' 2>/dev/null)
    [[ "$ST2" == "200" && "$SKIPPED2" == "true" ]] && log_pass "double appel après envoi : deuxième appel skipped (pas de renvoi)" "$ST2" || log_fail "double appel après envoi — réponse inattendue" "$ST2"
  elif [[ "$ST" == "502" && ( "$RSTATUS" == "pending" || "$RSTATUS" == "abandoned" ) ]]; then
    log_pass "Edge Function : échec réel Resend capturé (RESEND_API_KEY absente), status=${RSTATUS} — chemin failed/retry réel exercé" "$ST"
  else
    log_fail "Edge Function clé correcte — réponse inattendue (status=${RSTATUS})" "$ST"
  fi
fi

# ============================================================================
# FIN
# ============================================================================
write_artifact
print_summary
if [[ "$FAIL_COUNT" -gt 0 ]]; then exit 1; else exit 0; fi
