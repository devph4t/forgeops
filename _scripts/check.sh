#!/usr/bin/env bash
# Read-only preflight check: verifies the tools/dependencies startup.sh needs
# are installed and healthy, and reports whether the machine is ready.
#
# Never modifies anything. Exits 0 if there are no blocking issues, 1 otherwise.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

FAIL=0
WARN=0

pass() {
  printf "  %-46s %s\n" "$1" "${_c_green}OK${_c_reset}"
}

fail() {
  printf "  %-46s %s\n" "$1" "${_c_red}MISSING${_c_reset}"
  if [[ -n "${2:-}" ]]; then
    echo "      -> $2"
  fi
  FAIL=$((FAIL + 1))
}

warnc() {
  printf "  %-46s %s\n" "$1" "${_c_yellow}WARN${_c_reset}"
  if [[ -n "${2:-}" ]]; then
    echo "      -> $2"
  fi
  WARN=$((WARN + 1))
}

# Never let a --version probe (which can legitimately fail, e.g. kubectl
# doesn't support --version) trip `set -e` and abort the whole check.
tool_version() {
  local bin=$1 out=""
  case "$bin" in
    kubectl)  out=$("$bin" version --client 2>/dev/null | head -n1) || true ;;
    helm)     out=$("$bin" version --short 2>/dev/null) || true ;;
    minikube) out=$("$bin" version --short 2>/dev/null) || true ;;
    *)        out=$("$bin" --version 2>/dev/null | head -n1) || true ;;
  esac
  printf '%s' "$out"
}

check_bin() {
  local bin=$1 hint=$2
  if command -v "$bin" >/dev/null 2>&1; then
    pass "$bin ($(tool_version "$bin"))"
  else
    fail "$bin" "$hint"
  fi
}

echo "Tools"
check_bin docker   "install: https://docs.docker.com/get-docker/"
check_bin kubectl  "install: https://kubernetes.io/docs/tasks/tools/#kubectl"
check_bin helm     "install: https://helm.sh/docs/intro/install/"
check_bin minikube "install: https://minikube.sigs.k8s.io/docs/start/"
check_bin python3  "install python 3.9.6+"

echo
echo "Runtime status"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass "docker daemon reachable"
  else
    fail "docker daemon reachable" "start Docker Desktop / the docker service"
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9,6) else 1)'; then
    pass "python3 version ($PY_VER, need >= 3.9.6)"
  else
    fail "python3 version ($PY_VER)" "need 3.9.6+"
  fi
fi

if command -v pip3 >/dev/null 2>&1; then
  pass "pip3"
else
  fail "pip3" "usually ships alongside python3"
fi

echo
echo "Project setup"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  pass ".env exists"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a

  for var in ENV K8S_NAMESPACE DOMAIN; do
    if [[ -n "${!var:-}" ]]; then
      pass "  \$$var set (${!var})"
    else
      fail "  \$$var set" "add $var=... to .env"
    fi
  done

  case "${K8S_SIZE:-single-instance}" in
    single-instance|small|medium|large)
      pass "  \$K8S_SIZE valid (${K8S_SIZE:-single-instance})" ;;
    *)
      fail "  \$K8S_SIZE valid" "must be single-instance|small|medium|large, got '$K8S_SIZE'" ;;
  esac
else
  fail ".env exists" "copy .env.example to .env and edit it"
fi

if [[ -d .venv ]]; then
  pass ".venv exists"
else
  warnc ".venv exists" "not created yet - startup.sh will create it"
fi

if [[ -f lib/dependencies/.configured_version ]]; then
  pass "forgeops configure has run"
else
  warnc "forgeops configure has run" "not run yet - startup.sh will run it"
fi

echo
echo "Cluster (informational, not required to start)"
MINIKUBE_PROFILE=${MINIKUBE_PROFILE:-forgeops-${ENV:-local}}
if command -v minikube >/dev/null 2>&1; then
  if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
    pass "minikube profile '$MINIKUBE_PROFILE' running"
  else
    warnc "minikube profile '$MINIKUBE_PROFILE' running" "not started yet - startup.sh will create/start it"
  fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
  ok "Ready for startup ($WARN warning(s), 0 blocking issues)."
  exit 0
else
  echo "${_c_red}Not ready:${_c_reset} $FAIL blocking issue(s) above must be fixed first."
  exit 1
fi
