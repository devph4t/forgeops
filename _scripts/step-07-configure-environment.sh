#!/usr/bin/env bash
# Step 7/9: create/update the forgeops environment - the Kustomize overlay
# and Helm values under kustomize/overlay/$ENV and helm/$ENV - and apply
# the self-signed ClusterIssuer cert-manager needs for it.
#
# Part of the step-by-step alternative to startup.sh - see
# ./_scripts/start-step.sh to run every step in order, or run this one
# alone to redo just this part (e.g. after changing DOMAIN/K8S_SIZE).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm python3
load_env
cd "$ROOT_DIR"
kubectl_ctx
activate_venv

info "Configuring forgeops environment '$ENV'"
kubectl apply -f etc/resources/selfsigned-issuer.yaml >/dev/null
./bin/forgeops env --env-name "$ENV" --fqdn "$DOMAIN" --namespace "$K8S_NAMESPACE" \
  --cluster-issuer default-issuer "$(size_flag)"

ok "Step 7 done: environment '$ENV' configured."
