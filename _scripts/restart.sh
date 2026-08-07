#!/usr/bin/env bash
# Restart an already-initialized deployment (e.g. after a reboot or
# `minikube stop`). Does not reinstall prereqs or reconfigure the
# environment - use startup.sh for that.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker kubectl minikube
load_env

cd "$ROOT_DIR"
activate_venv

minikube_ensure_running
kubectl_ctx

info "Waiting for secret-agent webhook to be ready"
kubectl rollout status deployment/secret-agent -n secret-agent --timeout=90s || true

info "Re-applying platform to namespace '$K8S_NAMESPACE' (idempotent)"
retry 10 6 ./bin/forgeops apply --env-name "$ENV" --namespace "$K8S_NAMESPACE"

info "Waiting for components to be ready"
./bin/forgeops wait --namespace "$K8S_NAMESPACE" \
  || warn "Some components weren't ready before the timeout; check with: kubectl get pods -n $K8S_NAMESPACE"

info "Setting up access to https://$DOMAIN"
ensure_ingress_reachable

ok "Restart complete: https://$DOMAIN"
