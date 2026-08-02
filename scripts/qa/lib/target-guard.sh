#!/usr/bin/env bash
# scripts/qa/lib/target-guard.sh
#
# Garde-fou cible — validation multi-source, exécutée AVANT toute action (migration, setup,
# test, appel Edge Function) que l'environnement ciblé est bien et uniquement la branche
# Supabase phase2-staging — jamais la production, jamais un autre environnement.
#
# Sourcé par scripts/qa/phase2-staging-acceptance.sh en tout premier, avant toute autre logique
# (avant même la section STRUCTURE). Peut aussi être exécuté directement en sous-processus
# (bash scripts/qa/lib/target-guard.sh) pour le test de non-régression dédié —
# voir scripts/qa/tests/test-target-guard.sh — sans toucher au réseau ni à Supabase.
#
# Trois sources INDÉPENDANTES doivent toutes converger vers le même project ref attendu :
#   1. PHASE2_STAGING_URL (chaîne fournie par le secret GitHub) ;
#   2. le claim "ref" encodé dans le JWT de PHASE2_STAGING_ANON_KEY — une clé Supabase classique
#      (anon/service_role) est un JWT dont le payload contient {"ref": "<project_ref>", ...},
#      émis par Supabase lui-même, indépendamment de l'URL fournie ;
#   3. le claim "ref" encodé dans le JWT de PHASE2_STAGING_SERVICE_ROLE_KEY, idem.
# Si un secret a été mal recopié (bonne URL mais mauvaise clé, ou l'inverse), au moins une de
# ces trois sources divergera et le garde-fou bloque avant toute action. Aucune des trois ne
# doit non plus jamais correspondre à un ref interdit (production en tête).
#
# La branche Supabase phase2-staging est un projet à part entière au sens de l'API Supabase
# (Branching 2.0 : chaque branche a son propre project ref, jamais partagé avec une autre
# branche ni avec le projet parent) — un project ref qui matche exactement ${ALLOWED_STAGING_REF}
# identifie donc de façon unique et suffisante la branche phase2-staging elle-même.

: "${ALLOWED_STAGING_REF:?ALLOWED_STAGING_REF doit être défini avant de sourcer target-guard.sh}"
: "${FORBIDDEN_TARGET_REFS:=}"

_target_guard_b64url_decode() {
  local input="$1" rem
  input="${input//-/+}"; input="${input//_//}"
  rem=$(( ${#input} % 4 ))
  if [[ $rem -eq 2 ]]; then input="${input}=="; elif [[ $rem -eq 3 ]]; then input="${input}="; fi
  echo "$input" | base64 -d 2>/dev/null
}

# Décode le claim "ref" d'un JWT Supabase (anon/service_role). Ne vérifie PAS la signature —
# ce n'est pas une authentification, seulement un recoupement défensif de cohérence de cible.
decode_jwt_ref() {
  local jwt="${1:-}" payload
  [[ -z "$jwt" ]] && return 1
  payload=$(echo "$jwt" | cut -d '.' -f2)
  _target_guard_b64url_decode "$payload" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null
}

validate_staging_target() {
  local url="${PHASE2_STAGING_URL:-}"
  local anon="${PHASE2_STAGING_ANON_KEY:-}"
  local svc="${PHASE2_STAGING_SERVICE_ROLE_KEY:-}"
  local expected="${ALLOWED_STAGING_REF}"
  local -a forbidden=()
  # shellcheck disable=SC2206
  [[ -n "${FORBIDDEN_TARGET_REFS}" ]] && forbidden=(${FORBIDDEN_TARGET_REFS})

  # Anti-production explicite EN PREMIER : vérifié avant toute comparaison au ref attendu, pour
  # que toute tentative visant la production (URL ou clé) produise TOUJOURS le message "INTERDIT"
  # distinct et sans ambiguïté, plutôt qu'un message générique de non-concordance.
  local f
  for f in "${forbidden[@]:-}"; do
    [[ -z "$f" ]] && continue
    if [[ "$url" == *"$f"* ]]; then
      echo "::error::GARDE-FOU CIBLE : PHASE2_STAGING_URL contient le project ref INTERDIT (${f} — production ou environnement sensible). Arrêt immédiat, aucune action effectuée."
      return 2
    fi
  done

  if [[ "$url" != "https://${expected}.supabase.co" ]]; then
    echo "::error::GARDE-FOU CIBLE : PHASE2_STAGING_URL ('${url}') ne correspond pas exactement à https://${expected}.supabase.co. Arrêt immédiat, aucune action effectuée."
    return 2
  fi

  local anon_ref
  anon_ref=$(decode_jwt_ref "$anon")
  for f in "${forbidden[@]:-}"; do
    [[ -z "$f" ]] && continue
    if [[ "$anon_ref" == "$f" ]]; then
      echo "::error::GARDE-FOU CIBLE : PHASE2_STAGING_ANON_KEY encode le project ref INTERDIT (${f} — production ou environnement sensible). Arrêt immédiat, aucune action effectuée."
      return 2
    fi
  done
  if [[ -z "$anon_ref" || "$anon_ref" != "$expected" ]]; then
    echo "::error::GARDE-FOU CIBLE : le project ref encodé dans PHASE2_STAGING_ANON_KEY ('${anon_ref:-illisible}') ne correspond pas à ${expected}. Arrêt immédiat, aucune action effectuée."
    return 2
  fi

  local svc_ref
  svc_ref=$(decode_jwt_ref "$svc")
  for f in "${forbidden[@]:-}"; do
    [[ -z "$f" ]] && continue
    if [[ "$svc_ref" == "$f" ]]; then
      echo "::error::GARDE-FOU CIBLE : PHASE2_STAGING_SERVICE_ROLE_KEY encode le project ref INTERDIT (${f} — production ou environnement sensible). Arrêt immédiat, aucune action effectuée."
      return 2
    fi
  done
  if [[ -z "$svc_ref" || "$svc_ref" != "$expected" ]]; then
    echo "::error::GARDE-FOU CIBLE : le project ref encodé dans PHASE2_STAGING_SERVICE_ROLE_KEY ('${svc_ref:-illisible}') ne correspond pas à ${expected}. Arrêt immédiat, aucune action effectuée."
    return 2
  fi

  echo "[PASS] Garde-fou cible : PHASE2_STAGING_URL, la clé anon et la clé service_role pointent tous les trois vers le project ref exact de la branche phase2-staging (${expected}), aucun ref interdit détecté."
  return 0
}

# Exécuté directement (pas sourcé) : lance la validation et propage le code de sortie — c'est
# ce chemin qu'utilise le test de non-régression, en sous-processus, sans jamais toucher au
# script principal ni au réseau.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  validate_staging_target
  exit $?
fi
