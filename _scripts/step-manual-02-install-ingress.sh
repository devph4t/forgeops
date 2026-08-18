#!/usr/bin/env bash
# Manual step 2/3: install/upgrade traefik without Helm's chart-repo
# protocol - curl the chart's .tgz directly, extract it, then `helm
# upgrade --install` from the local unpacked chart. Same end result as
# ./_scripts/step-04-install-ingress.sh, fetched differently.
#
# nginx/haproxy aren't supported here - only their default (traefik) ships
# a chart tarball at a predictable, curl-able URL; the others would need
# their own pinned-version URL added the same way if you need this path
# for them too.
#
# Applies the chart's bundled CRDs (traefik/crds/*.yaml, from the same
# local download - no extra network round-trip) plus the upstream Gateway
# API CRDs (a plain manifest URL, not a chart - already about as "manual"
# as it gets). TRAEFIK_VERSION must be a real, resolvable chart version -
# there's no "latest" here. Override via .env if the pinned default below
# is stale.
#
# Forces the Service to NodePort, never LoadBalancer - see
# ./_scripts/step-04-install-ingress.sh for why.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm curl tar
load_env
cd "$ROOT_DIR"
kubectl_ctx

[[ "$INGRESS" == "traefik" ]] || die "INGRESS=$INGRESS - this manual step only supports traefik (see the script header)."

TRAEFIK_NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
TRAEFIK_VERSION=${TRAEFIK_VERSION:-41.2.0}
CHART_URL="https://traefik.github.io/charts/traefik/traefik-${TRAEFIK_VERSION}.tgz"
CACHE_DIR="$CHARTS_DIR/manual"
mkdir -p "$CACHE_DIR"
CHART_TGZ="$CACHE_DIR/traefik-${TRAEFIK_VERSION}.tgz"

if [[ -f "$CHART_TGZ" ]]; then
  ok "traefik chart already downloaded ($CHART_TGZ)"
else
  info "Downloading $CHART_URL"
  curl -fSL "$CHART_URL" -o "$CHART_TGZ"
fi

info "Extracting chart"
rm -rf "$CACHE_DIR/traefik"
tar -xzf "$CHART_TGZ" -C "$CACHE_DIR"

info "Applying traefik CRDs (from the downloaded chart)"
kubectl apply --server-side --force-conflicts -f "$CACHE_DIR/traefik/crds/"

info "Applying Gateway API CRDs"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

TRAEFIK_OPTS="--set deployment.replicas=2 \
--set ingressClass.enabled=true \
--set ingressRoute.dashboard.enabled=false \
--set service.spec.type=NodePort \
--set providers.kubernetesIngressNGINX.enabled=true \
--set providers.kubernetesIngressNGINX.ingressClassByName=true \
--set providers.kubernetesIngressNGINX.publishService.enabled=true \
--set providers.kubernetesIngress.publishedService.enabled=true \
--set providers.kubernetesGateway.enabled=true \
--set gateway.enabled=false \
--set tolerations[0].key=kubernetes\.io/arch \
--set tolerations[0].effect=NoSchedule \
--set tolerations[0].operator=Exists"

info "Installing traefik $TRAEFIK_VERSION from local chart"
helm upgrade traefik "$CACHE_DIR/traefik" \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$TRAEFIK_NAMESPACE" --install --reset-values --create-namespace \
  $TRAEFIK_OPTS

NGINX_CONTROLLER=${NGINX_CONTROLLER:-traefik.io/ingress-controller}
CURRENT_CONTROLLER=$(kubectl get ingressclass nginx -o="jsonpath={.spec.controller}" 2>/dev/null || true)
if [[ -z "$CURRENT_CONTROLLER" || "$CURRENT_CONTROLLER" != "$NGINX_CONTROLLER" ]]; then
  [[ -n "$CURRENT_CONTROLLER" ]] && kubectl delete ingressclass nginx >/dev/null 2>&1
  kubectl apply -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/managed-by: forgeops-prereqs
    app.kubernetes.io/name: traefik
    app.kubernetes.io/part-of: traefik
spec:
  controller: $NGINX_CONTROLLER
EOF
fi

ok "Manual step 2 done: traefik $TRAEFIK_VERSION installed."
