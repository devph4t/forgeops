#!/usr/bin/env bash
# Step 4/9: install/upgrade the ingress controller - traefik by default, or
# nginx/haproxy if INGRESS is set to that in .env. Direct `helm upgrade
# --install` calls against each chart's public repo, no
# `./bin/forgeops prereqs` involved.
#
# Idempotent via Helm itself (--reset-values means every run converges to
# the same values) - no separate "already installed" pre-check needed.
#
# Every controller's Service is forced to NodePort (never LoadBalancer):
# minikube's docker driver never assigns a LoadBalancer an external IP
# (needs `minikube tunnel`/MetalLB, neither of which run here), so
# Helm's --atomic/--wait would otherwise block until $HELM_TIMEOUT and
# fail every time, no matter how long the timeout is - NodePort is what
# ./_scripts/lib.sh's ensure_ingress_reachable reads from the Service
# anyway, so nothing downstream depends on the external IP.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm
load_env
cd "$ROOT_DIR"
kubectl_ctx

NGINX_CONTROLLER=${NGINX_CONTROLLER:-traefik.io/ingress-controller}
CRD_CMD=""

case "$INGRESS" in
  nginx)
    REPO=https://kubernetes.github.io/ingress-nginx
    CHART=ingress-nginx
    NAMESPACE=${NX_NAMESPACE:-ingress-nginx}
    VERSION=${NX_VERSION:-}
    OPTS="--set controller.kind=Deployment \
--set controller.replicaCount=2 \
--set controller.allowSnippetAnnotations=true \
--set controller.service.type=NodePort \
--set controller.publishService.enabled=true \
--set controller.stats.enabled=true \
--set controller.tolerations[0].key=kubernetes\.io/arch \
--set controller.tolerations[0].effect=NoSchedule \
--set controller.tolerations[0].operator=Exists \
--set controller.admissionWebhooks.patch.tolerations[0].key=kubernetes\.io/arch \
--set controller.admissionWebhooks.patch.tolerations[0].effect=NoSchedule \
--set controller.admissionWebhooks.patch.tolerations[0].operator=Exists \
--set defaultBackend.tolerations[0].key=kubernetes\.io/arch \
--set defaultBackend.tolerations[0].effect=NoSchedule \
--set defaultBackend.tolerations[0].operator=Exists"
    ;;
  haproxy)
    REPO=https://haproxy-ingress.github.io/charts
    CHART=haproxy-ingress
    NAMESPACE=${HP_NAMESPACE:-haproxy-ingress}
    VERSION=${HP_VERSION:-}
    OPTS="--set controller.kind=Deployment \
--set controller.replicaCount=2 \
--set controller.minAvailable=2 \
--set controller.service.type=NodePort \
--set controller.publishService.enabled=true \
--set controller.stats.enabled=true \
--set controller.ingressClassResource.enabled=true \
--set controller.tolerations[0].key=kubernetes\.io/arch \
--set controller.tolerations[0].effect=NoSchedule \
--set controller.tolerations[0].operator=Exists \
--set defaultBackend.tolerations[0].key=kubernetes\.io/arch \
--set defaultBackend.tolerations[0].effect=NoSchedule \
--set defaultBackend.tolerations[0].operator=Exists"
    ;;
  *)
    REPO=https://traefik.github.io/charts
    CHART=traefik
    NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
    VERSION=${TRAEFIK_VERSION:-}
    OPTS="--set deployment.replicas=2 \
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
    CRD_CMD=1
    ;;
esac

if [[ -n "$CRD_CMD" ]]; then
  info "Applying traefik + Gateway API CRDs"
  helm show crds traefik --repo "$REPO" | kubectl apply --server-side --force-conflicts -f -
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
fi

info "Installing $INGRESS ingress${VERSION:+ ($VERSION)}"
helm upgrade "$CHART" "$CHART" --repo "$REPO" \
  ${VERSION:+--version="$VERSION"} \
  "$(helm_rollback_flag)" --timeout="${HELM_TIMEOUT:-10m}" \
  --namespace "$NAMESPACE" --install --reset-values --create-namespace \
  $OPTS

if [[ "$INGRESS" == "traefik" ]]; then
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
fi

ok "Step 4 done: $INGRESS ingress installed."
