#!/usr/bin/env bash
# Shared helpers for the scripts in this directory. Sourced, not executed.

set -eo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPTS_DIR/.." && pwd)

_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'
info() { echo "${_c_blue}==>${_c_reset} $*"; }
ok()   { echo "${_c_green}==>${_c_reset} $*"; }
warn() { echo "${_c_yellow}==>${_c_reset} $*"; }
die()  { echo "${_c_red}ERROR:${_c_reset} $*" >&2; exit 1; }

require_bin() {
  local b
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "'$b' is required but not found on \$PATH."
  done
}

# Loads ./.env (creating it from .env.example on first run) and fills in
# defaults for the optional vars.
load_env() {
  if [[ ! -f "$ROOT_DIR/.env" ]]; then
    if [[ -f "$ROOT_DIR/.env.example" ]]; then
      cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
      die "No .env found - created one from .env.example. Edit $ROOT_DIR/.env, then re-run this script."
    fi
    die "No .env or .env.example found in $ROOT_DIR."
  fi

  set -a
  # shellcheck disable=SC1090,SC1091
  source "$ROOT_DIR/.env"
  set +a

  : "${ENV:?ENV must be set in .env}"
  : "${K8S_NAMESPACE:?K8S_NAMESPACE must be set in .env}"
  : "${DOMAIN:?DOMAIN must be set in .env}"

  K8S_SIZE=${K8S_SIZE:-single-instance}
  MINIKUBE_PROFILE=${MINIKUBE_PROFILE:-forgeops-$ENV}
  MINIKUBE_DRIVER=${MINIKUBE_DRIVER:-docker}
  MINIKUBE_CPUS=${MINIKUBE_CPUS:-4}
  MINIKUBE_MEMORY=${MINIKUBE_MEMORY:-8000mb}
  MINIKUBE_DISK=${MINIKUBE_DISK:-40g}
  INGRESS=${INGRESS:-traefik}
  PREREQS_MANUAL=${PREREQS_MANUAL:-false}
}

# Installs cert-manager/ingress/secret-agent via either `forgeops prereqs`
# (default) or, when PREREQS_MANUAL=true in .env, prereqs-manual.sh - which
# fetches each chart with a separate `helm pull` into a local cache instead
# of one `helm upgrade --repo` call, for networks that block some of the
# chart repo hosts `forgeops prereqs` needs. See prereqs-manual.sh -h.
install_prereqs() {
  if [[ "$PREREQS_MANUAL" == true ]]; then
    "$SCRIPTS_DIR/prereqs-manual.sh"
    return
  fi

  local ingress_flag=""
  if [[ "$INGRESS" == "nginx" ]]; then
    ingress_flag="--nginx"
  elif [[ "$INGRESS" == "haproxy" ]]; then
    ingress_flag="--haproxy"
  fi
  ./bin/forgeops prereqs $ingress_flag
}

# Resolve the --small/--medium/--large/--single-instance flag forgeops env expects.
size_flag() {
  case "$K8S_SIZE" in
    single-instance) echo "--single-instance" ;;
    small|medium|large) echo "--$K8S_SIZE" ;;
    *) die "Unknown K8S_SIZE '$K8S_SIZE' (expected single-instance|small|medium|large)" ;;
  esac
}

ingress_release_and_namespace() {
  case "$INGRESS" in
    nginx)   echo "ingress-nginx ingress-nginx" ;;
    haproxy) echo "haproxy-ingress haproxy-ingress" ;;
    *)       echo "traefik traefik" ;;
  esac
}

kubectl_ctx() {
  kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null
}

# `minikube start` on an already-running profile still reconciles the
# control plane (apiserver/etcd/scheduler/kube-proxy etc.), which restarts
# them and causes several minutes of cluster instability - e.g. the
# secret-agent webhook's route briefly breaking mid-`forgeops apply`. Only
# actually start it when it's not already running.
minikube_ensure_running() {
  if minikube status -p "$MINIKUBE_PROFILE" 2>/dev/null | grep -q "^host: Running"; then
    ok "minikube profile '$MINIKUBE_PROFILE' already running, leaving it alone"
    return
  fi
  info "Starting minikube profile '$MINIKUBE_PROFILE' (creates it on first run)"
  minikube start -p "$MINIKUBE_PROFILE" \
    --driver="$MINIKUBE_DRIVER" \
    --cpus="$MINIKUBE_CPUS" \
    --memory="$MINIKUBE_MEMORY" \
    --disk-size="$MINIKUBE_DISK"
}

confirm() {
  local prompt=$1
  if [[ "${SKIP_CONFIRM:-false}" == true ]]; then
    return 0
  fi
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

activate_venv() {
  [[ -f "$ROOT_DIR/.venv/bin/activate" ]] || die "No .venv found - run ./_scripts/startup.sh first."
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.venv/bin/activate"
}

# forgeops prereqs treats "CRDs already exist" as "already installed" and
# skips reinstalling - which leaves things broken if a previous run was
# interrupted after CRDs landed but before the actual release finished (no
# namespace, no pods, no helm release). Force a real (re)install of any
# prereq whose namespace doesn't actually exist.
verify_prereqs_healthy() {
  local ing_ns entry ns comp
  read -r _ ing_ns <<< "$(ingress_release_and_namespace)"

  for entry in "cert-manager cert-manager" "$ing_ns ingress" "secret-agent secrets"; do
    read -r ns comp <<< "$entry"
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      warn "Namespace '$ns' is missing even though prereqs reported it installed - forcing a real (re)install."
      if [[ "$PREREQS_MANUAL" == true ]]; then
        "$SCRIPTS_DIR/prereqs-manual.sh"
      else
        ./bin/forgeops prereqs --upgrade "$comp"
      fi
    fi
  done
}

# Docker's minikube driver puts the cluster in its own docker network. On
# native Linux that network is usually directly routable from the host, but
# on WSL2 / Docker Desktop it typically isn't. Detect which case we're in:
# if direct routing works, just tell the caller the minikube IP to put in
# /etc/hosts; otherwise publish 80/443 on the host via two small docker
# containers that forward into the cluster's ingress NodePorts. Idempotent.
ensure_ingress_reachable() {
  local ing_release ing_ns https_np http_np mip name_https name_80

  # Service name == release name holds for the traefik chart (the default
  # and only combination this has been exercised against); nginx/haproxy
  # charts name their Service differently and would need adjusting here.
  read -r ing_release ing_ns <<< "$(ingress_release_and_namespace)"
  https_np=$(kubectl get svc "$ing_release" -n "$ing_ns" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null) || true
  http_np=$(kubectl get svc "$ing_release" -n "$ing_ns" \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null) || true
  mip=$(minikube ip -p "$MINIKUBE_PROFILE" 2>/dev/null) || true

  if [[ -z "$https_np" || -z "$http_np" || -z "$mip" ]]; then
    warn "Ingress NodePorts not available yet; skipping host access setup (re-run later if needed)."
    return
  fi

  name_https="fgo-proxy-${MINIKUBE_PROFILE}-443"
  name_80="fgo-proxy-${MINIKUBE_PROFILE}-80"

  if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${mip}/${https_np}" 2>/dev/null; then
    docker rm -f "$name_https" "$name_80" >/dev/null 2>&1 || true
    ok "minikube IP $mip is directly reachable from this host."
    echo "Add this to your hosts file:  $mip  $DOMAIN"
    return
  fi

  info "minikube IP isn't directly routable from this host (common on WSL2/Docker Desktop)."
  info "Publishing host ports 80/443 -> cluster ingress via docker instead."
  docker rm -f "$name_https" "$name_80" >/dev/null 2>&1 || true
  docker run -d --name "$name_https" --network "$MINIKUBE_PROFILE" -p 443:443 --restart unless-stopped \
    alpine/socat "TCP-LISTEN:443,fork,reuseaddr" "TCP:${mip}:${https_np}" >/dev/null
  docker run -d --name "$name_80" --network "$MINIKUBE_PROFILE" -p 80:80 --restart unless-stopped \
    alpine/socat "TCP-LISTEN:80,fork,reuseaddr" "TCP:${mip}:${http_np}" >/dev/null
  ok "Host ports 80/443 now proxy to the cluster ingress."
  echo "Point $DOMAIN at 127.0.0.1 in your hosts file (the Windows hosts file if you're on WSL2)."
}

# Removes the docker proxy containers ensure_ingress_reachable may have created.
remove_ingress_proxy() {
  docker rm -f "fgo-proxy-${MINIKUBE_PROFILE}-443" "fgo-proxy-${MINIKUBE_PROFILE}-80" >/dev/null 2>&1 || true
}

# Stops (without removing) the docker proxy containers, for a pause/resume
# cycle via down.sh + restart.sh instead of a full teardown.
stop_ingress_proxy() {
  docker stop "fgo-proxy-${MINIKUBE_PROFILE}-443" "fgo-proxy-${MINIKUBE_PROFILE}-80" >/dev/null 2>&1 || true
}

# Retries a command a few times with a delay between attempts. Useful right
# after a cluster (re)start: `kubectl rollout status` only confirms a pod is
# Ready, not that kube-proxy has finished syncing iptables rules for its
# Service - so a call into e.g. the secret-agent admission webhook can still
# transiently connection-refuse for a few more seconds after that. Safe to
# use with `forgeops apply` since `kubectl apply -k` is idempotent.
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    warn "Attempt $n/$attempts failed, retrying in ${delay}s..."
    sleep "$delay"
    n=$((n + 1))
  done
}
