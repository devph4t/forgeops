#!/usr/bin/env bash
# Manual step 3/3: install/upgrade secret-agent without going through
# `./bin/forgeops prereqs`.
#
# secret-agent's chart is only published via an OCI registry
# (oci://us-docker.pkg.dev/...), which doesn't have a flat, curl-able .tgz
# URL the way traditional chart repos (cert-manager, traefik) do - OCI
# registries speak the Docker Registry HTTP API (manifests + content-
# addressed blobs, usually behind a bearer-token exchange), not a static
# file server. `helm pull --untar` is the practical way to fetch one
# without reimplementing that protocol by hand; it still avoids
# `./bin/forgeops` entirely, just like the curl-based steps either side of
# this one. Once pulled, it's installed the same way: `helm upgrade
# --install` from the local unpacked chart.
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
CACHE_DIR="$CHARTS_DIR/manual"
mkdir -p "$CACHE_DIR"

if [[ -d "$CACHE_DIR/secret-agent" ]]; then
  ok "secret-agent chart already downloaded ($CACHE_DIR/secret-agent)"
else
  info "Pulling oci://us-docker.pkg.dev/forgeops-public/charts/secret-agent ($SEC_VERSION)"
  helm pull oci://us-docker.pkg.dev/forgeops-public/charts/secret-agent \
    --version "$SEC_VERSION" --untar --untardir "$CACHE_DIR"
fi

SEC_OPTS="--set tolerations[0].key=kubernetes\.io/arch \
--set tolerations[0].effect=NoSchedule \
--set tolerations[0].operator=Exists"

info "Installing secret-agent $SEC_VERSION from local chart"
helm upgrade secret-agent "$CACHE_DIR/secret-agent" \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$SEC_NAMESPACE" --install --reset-values --create-namespace \
  $SEC_OPTS

ok "Manual step 3 done: secret-agent $SEC_VERSION installed."
