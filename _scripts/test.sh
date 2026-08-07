#!/usr/bin/env bash
# Smoke-test the deployed platform: curls https://$DOMAIN/am and
# https://$DOMAIN/platform and checks for a healthy response.
#
# Read-only, safe to run any time. Exits 0 if all checks pass, 1 otherwise.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin curl
load_env

FAIL=0

# Curls $1 and checks for HTTP 200 with $3 present in the body (if given).
# If the domain doesn't resolve from this shell (e.g. on WSL2, where the
# hosts entry lives on the Windows side but startup.sh's proxy is bound to
# this shell's 127.0.0.1), retries pinned to 127.0.0.1.
curl_check() {
  local path=$1 desc=$2 expect=$3
  local url="https://${DOMAIN}${path}"
  local out code body

  out=$(curl -sk -L --max-time 10 -w '\n%{http_code}' "$url" 2>/dev/null) || out=""
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')

  if [[ -z "$code" || "$code" == "000" ]]; then
    out=$(curl -sk -L --max-time 10 \
      --resolve "${DOMAIN}:443:127.0.0.1" --resolve "${DOMAIN}:80:127.0.0.1" \
      -w '\n%{http_code}' "$url" 2>/dev/null) || out=""
    code=$(printf '%s' "$out" | tail -n1)
    body=$(printf '%s' "$out" | sed '$d')
  fi

  if [[ "$code" == "200" ]] && { [[ -z "$expect" ]] || [[ "$body" == *"$expect"* ]]; }; then
    ok "$desc -> HTTP $code"
  else
    warn "$desc -> HTTP ${code:-no response}"
    FAIL=$((FAIL + 1))
  fi
}

info "Testing https://$DOMAIN ..."
curl_check "/am/json/serverinfo/*" "AM       (/am)"       '"_id"'
curl_check "/platform/"            "Platform (/platform)" ''

echo
if [[ $FAIL -eq 0 ]]; then
  ok "All checks passed - the platform is up at https://$DOMAIN"
  exit 0
else
  echo "${_c_red}$FAIL check(s) failed.${_c_reset} Inspect with: kubectl get pods -n $K8S_NAMESPACE"
  exit 1
fi
