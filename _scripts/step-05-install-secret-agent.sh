#!/usr/bin/env bash
# Step 5/9: install/upgrade secret-agent - a direct `helm upgrade --install`
# against its OCI chart, no `./bin/forgeops prereqs` involved.
#
# Idempotent via Helm itself (--reset-values means every run converges to
# the same values) - no separate "already installed" pre-check needed.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm
load_env
cd "$ROOT_DIR"
kubectl_ctx

SEC_NAMESPACE=${SA_NAMESPACE:-secret-agent}
SEC_VERSION=${SA_VERSION:-v1.2.12}
SEC_OPTS="--set tolerations[0].key=kubernetes\.io/arch \
--set tolerations[0].effect=NoSchedule \
--set tolerations[0].operator=Exists"

info "Installing secret-agent ($SEC_VERSION)"
helm upgrade secret-agent oci://us-docker.pkg.dev/forgeops-public/charts/secret-agent \
  --version="$SEC_VERSION" \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$SEC_NAMESPACE" --install --reset-values --create-namespace \
  $SEC_OPTS

ok "Step 5 done: secret-agent installed."
