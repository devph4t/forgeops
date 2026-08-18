#!/usr/bin/env bash
# Step 3/9: install/upgrade cert-manager - a direct `helm upgrade --install`
# against the public chart repo, no `./bin/forgeops prereqs` involved.
#
# Idempotent via Helm itself (--reset-values means every run converges to
# the same values, whether this is the first install or the hundredth) -
# no separate "already installed" pre-check needed.
#
# CM_VERSION pins a version (e.g. v1.21.1); unset installs whatever's
# latest in the chart repo. See ./_scripts/step-manual-01-install-cert-manager.sh
# for a variant that fetches the chart via a plain curl instead of Helm's
# repo protocol (for restricted networks).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm
load_env
cd "$ROOT_DIR"
kubectl_ctx

CM_NAMESPACE=${CM_NAMESPACE:-cert-manager}
CM_OPTS="--set crds.enabled=true \
--set global.leaderElection.namespace=$CM_NAMESPACE \
--set tolerations[0].key=kubernetes\.io/arch \
--set tolerations[0].effect=NoSchedule \
--set tolerations[0].operator=Exists \
--set cainjector.tolerations[0].key=kubernetes\.io/arch \
--set cainjector.tolerations[0].effect=NoSchedule \
--set cainjector.tolerations[0].operator=Exists \
--set startupapicheck.tolerations[0].key=kubernetes\.io/arch \
--set startupapicheck.tolerations[0].effect=NoSchedule \
--set startupapicheck.tolerations[0].operator=Exists \
--set webhook.tolerations[0].key=kubernetes\.io/arch \
--set webhook.tolerations[0].effect=NoSchedule \
--set webhook.tolerations[0].operator=Exists"

info "Installing cert-manager${CM_VERSION:+ ($CM_VERSION)}"
helm upgrade cert-manager cert-manager --repo https://charts.jetstack.io \
  ${CM_VERSION:+--version="$CM_VERSION"} \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$CM_NAMESPACE" --install --reset-values --create-namespace \
  $CM_OPTS

ok "Step 3 done: cert-manager installed."
