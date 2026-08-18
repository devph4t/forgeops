#!/usr/bin/env bash
# Manual step 1/3: install/upgrade cert-manager without Helm's chart-repo
# protocol - curl the chart's .tgz directly, extract it, then `helm
# upgrade --install` from the local unpacked chart. Same end result as
# ./_scripts/step-03-install-cert-manager.sh, fetched differently: for
# networks where a plain HTTPS GET works but Helm's repo-index flow
# (index.yaml discovery) doesn't.
#
# Unlike step-03, CM_VERSION must be a real, resolvable chart version (the
# download URL is built from it directly) - there's no "latest" here.
# Override via .env if the pinned default below is stale.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm curl tar
load_env
cd "$ROOT_DIR"
kubectl_ctx

CM_NAMESPACE=${CM_NAMESPACE:-cert-manager}
CM_VERSION=${CM_VERSION:-v1.21.1}
CHART_URL="https://charts.jetstack.io/charts/cert-manager-${CM_VERSION}.tgz"
CACHE_DIR="$CHARTS_DIR/manual"
mkdir -p "$CACHE_DIR"
CHART_TGZ="$CACHE_DIR/cert-manager-${CM_VERSION}.tgz"

if [[ -f "$CHART_TGZ" ]]; then
  ok "cert-manager chart already downloaded ($CHART_TGZ)"
else
  info "Downloading $CHART_URL"
  curl -fSL "$CHART_URL" -o "$CHART_TGZ"
fi

info "Extracting chart"
rm -rf "$CACHE_DIR/cert-manager"
tar -xzf "$CHART_TGZ" -C "$CACHE_DIR"

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

info "Installing cert-manager $CM_VERSION from local chart"
helm upgrade cert-manager "$CACHE_DIR/cert-manager" \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$CM_NAMESPACE" --install --reset-values --create-namespace \
  $CM_OPTS

ok "Manual step 1 done: cert-manager $CM_VERSION installed."
