#!/usr/bin/env bash
# scripts/qa/lib/http-response.sh
#
# Découpage sûr d'une réponse HTTP combinée (STATUS\nBODY, format produit par rest_call()/
# service_call() dans phase2-staging-acceptance.sh) en ses deux composantes.
#
# Écrit volontairement en expansion de paramètre bash pure, SANS aucun pipe vers un processus
# externe (head/tail/echo) : pour un corps de réponse volumineux (ex. introspection complète de
# 42 tables via _qa_introspect_tables), le motif `echo "$R" | head -n1` peut recevoir SIGPIPE
# ("Broken pipe") si `head` ferme son entrée avant que l'écriture ne soit terminée — observé en
# exécution réelle (workflow phase2-staging-acceptance, FAIL section STRUCTURE).
#
# Usage :
#   split_http_response "$R"
#   # puis lire $HTTP_STATUS et $HTTP_BODY (variables globales, volontairement pas de sous-shell)
split_http_response() {
  local combined="$1"
  HTTP_STATUS="${combined%%$'\n'*}"
  HTTP_BODY="${combined#*$'\n'}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "scripts/qa/lib/http-response.sh est une bibliothèque à sourcer, pas à exécuter directement." >&2
  exit 2
fi
