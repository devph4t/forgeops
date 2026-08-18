#!/usr/bin/env bash
# Step 9/9: make sure https://$DOMAIN is actually reachable from this host
# - publishes host ports 80/443 to the cluster ingress when the minikube IP
# isn't directly routable (typical on WSL2/Docker Desktop). Idempotent.
#
# Part of the step-by-step alternative to startup.sh - see
# ./_scripts/start-step.sh to run every step in order, or run this one
# alone to redo just this part (e.g. after switching
# INGRESS_ACCESS_MODE in .env).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker kubectl minikube
load_env
cd "$ROOT_DIR"
kubectl_ctx

info "Setting up access to https://$DOMAIN"
ensure_ingress_reachable

ok "Step 9 done: https://$DOMAIN"
