#!/usr/bin/env bash
# Step 2/9: start (or create, on first run) the local minikube cluster and
# point kubectl at it.
#
# Safe to re-run - leaves an already-running profile alone (see
# minikube_ensure_running in lib.sh: restarting an already-running profile
# still reconciles the control plane and causes several minutes of cluster
# instability). Part of the step-by-step alternative to startup.sh - see
# ./_scripts/start-step.sh to run every step in order, or run this one
# alone to redo just this part.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker minikube kubectl
load_env
cd "$ROOT_DIR"

minikube_ensure_running
kubectl_ctx

ok "Step 2 done: minikube profile '$MINIKUBE_PROFILE' is running, kubectl context set."
