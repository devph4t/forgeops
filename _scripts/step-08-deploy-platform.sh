#!/usr/bin/env bash
# Step 8/9: deploy the Ping Identity Platform into the cluster.
#
# On restricted networks (PREREQS_MANUAL=true), also pre-loads the
# platform's own images (am, idm, ds, ig, amster, the UIs...) into
# minikube first - the prereqs steps only cover
# cert-manager/ingress/secret-agent, not the platform itself.
#
# Part of the step-by-step alternative to startup.sh - see
# ./_scripts/start-step.sh to run every step in order, or run this one
# alone to redo just this part.
#
# Needs the venv active even though `apply` itself is a bash script: the
# top-level `forgeops` dispatcher runs a python pre-flight check (via
# whatever `python3` is on $PATH) before every subcommand except
# `configure`.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm python3
load_env
cd "$ROOT_DIR"
kubectl_ctx
activate_venv

if [[ "$PREREQS_MANUAL" == true ]]; then
  "$SCRIPTS_DIR/platform-images.sh" || true
fi

info "Applying platform to namespace '$K8S_NAMESPACE'"
retry 10 6 ./bin/forgeops apply --env-name "$ENV" --namespace "$K8S_NAMESPACE" --create-namespace

ok "Step 8 done: platform applied to namespace '$K8S_NAMESPACE'."
