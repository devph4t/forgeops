#!/usr/bin/env bash
# Installs the forgeops cluster prereqs (cert-manager, ingress, secret-agent)
# one component at a time, fetching each chart with a separate `helm pull`
# into a local cache and installing from that local copy - instead of
# `forgeops prereqs`'s single call that adds a Helm repo and installs
# straight from it.
#
# Use this when `./bin/forgeops prereqs` fails on a network with a policy
# that blocks some of the hosts it needs:
#   charts.jetstack.io          (cert-manager)
#   traefik.github.io           (traefik ingress, the default)
#   kubernetes.github.io        (nginx ingress, only if INGRESS=nginx)
#   haproxy-ingress.github.io   (haproxy ingress, only if INGRESS=haproxy)
#   us-docker.pkg.dev           (secret-agent, an OCI registry)
#   github.com                  (traefik only: Gateway API CRDs)
# Each step below prints exactly which host it needs before touching it, so
# a failure tells you precisely what to get allowlisted (or route through a
# proxy - helm/curl both honor HTTP_PROXY/HTTPS_PROXY/NO_PROXY from .env).
#
# For a fully offline install: run `--pull` once on a machine that *does*
# have access to those hosts, to download every chart into $CHARTS_DIR
# (default: _scripts/.chart-cache). Copy that directory to the restricted
# machine (it's self-contained) and re-run without --pull - every step then
# installs from the local cache and needs no network for the chart fetch
# (the cluster still needs to be able to pull the resulting container
# images from wherever your registry mirror is).
#
# Safely resumable: components already installed in the cluster are skipped,
# and cached charts are reused - so if one step fails, fix that one thing
# and re-run; nothing already done gets redone.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin helm kubectl curl
load_env
kubectl_ctx

PULL_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --pull) PULL_ONLY=true ;;
    -h|--help)
      echo "usage: $0 [--pull]"
      echo
      echo "  (no args)  install cert-manager, ingress ($INGRESS) and secret-agent,"
      echo "             fetching+caching each chart locally first"
      echo "  --pull     only download chart files into \$CHARTS_DIR - don't install"
      echo "             anything. Run this on a machine with network access, then"
      echo "             copy \$CHARTS_DIR to the restricted machine and re-run"
      echo "             without --pull."
      echo
      echo "Config (in .env): CHARTS_DIR (default: _scripts/.chart-cache)"
      exit 0
      ;;
    *) die "Unknown argument: $arg (use -h for usage)" ;;
  esac
done

CHARTS_DIR=${CHARTS_DIR:-$SCRIPTS_DIR/.chart-cache}
mkdir -p "$CHARTS_DIR"
info "Chart cache: $CHARTS_DIR"

# Warns (doesn't fail) if $1 isn't reachable, so a blocked host is diagnosed
# up front with an actionable message instead of as an opaque helm timeout.
check_host() {
  local url=$1 host
  host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#/.*$##')
  if ! curl -sI --max-time 5 "https://$host" >/dev/null 2>&1; then
    warn "Can't reach '$host' (needed to fetch from $url)."
    echo "    -> ask your network/security team to allowlist it, set HTTPS_PROXY in .env,"
    echo "       or pre-fetch it on another machine with: $0 --pull"
  fi
}

# Fetches chart $2 (version $4) from repo $3 into $CHARTS_DIR/$2-$4, or
# reuses it if already cached there. $3 may be an oci:// reference.
fetch_chart() {
  local pretty=$1 chart=$2 repo=$3 version=$4
  local dir="$CHARTS_DIR/$chart-${version:-latest}"

  if [[ -d "$dir/$chart" ]]; then
    ok "$pretty: using cached chart ($dir/$chart)"
    return
  fi

  info "$pretty: fetching chart from $repo"
  if [[ "$repo" =~ ^oci:// ]]; then
    # $repo for OCI charts is already the full path to the chart itself
    # (e.g. oci://.../charts/secret-agent) - not a repo root to append
    # $chart to, unlike the https:// index-based repos below.
    check_host "$repo"
    helm pull "$repo" ${version:+--version="$version"} --untar --untardir "$dir"
  else
    check_host "$repo"
    helm pull "$chart" --repo "$repo" ${version:+--version="$version"} --untar --untardir "$dir"
  fi
  ok "$pretty: chart cached at $dir/$chart"
}

# Installs a previously-fetched chart from $CHARTS_DIR. Skips if $6 (an
# "already installed" probe, e.g. `kubectl get crd ...`) is non-empty.
install_chart() {
  local pretty=$1 chart=$2 namespace=$3 version=$4 opts=$5 installed=$6
  local dir="$CHARTS_DIR/$chart-${version:-latest}/$chart"

  if [[ -n "$installed" ]]; then
    ok "$pretty already installed, skipping."
    return
  fi

  info "$pretty: installing from local chart ($dir)"
  # shellcheck disable=SC2086
  helm upgrade "$chart" "$dir" --namespace "$namespace" \
    --install --create-namespace --reset-values $opts
  ok "$pretty installed."
}

# --- cert-manager -----------------------------------------------------
CM_PRETTY="Cert Manager"
CM_REPO=https://charts.jetstack.io
CM_CHART=cert-manager
CM_NAMESPACE=${CM_NAMESPACE:-cert-manager}
CM_VERSION=${CM_VERSION:-}
CM_OPTS="--set crds.enabled=true --set global.leaderElection.namespace=$CM_NAMESPACE"
CM_INSTALLED=$(kubectl get crd -l app=cert-manager 2>/dev/null)

# --- ingress (traefik/nginx/haproxy, matching $INGRESS from .env) -----
NGINX_CONTROLLER=${NGINX_CONTROLLER:-traefik.io/ingress-controller}
GATEWAY_API_VERSION=v1.5.1
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
GATEWAY_API_CACHE="$CHARTS_DIR/gateway-api-${GATEWAY_API_VERSION}.yaml"

if [[ "$INGRESS" == "traefik" ]]; then
  ING_PRETTY="Traefik Proxy (Ingress/Gateway API)"
  ING_REPO=https://traefik.github.io/charts
  ING_CHART=traefik
  ING_NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
  ING_VERSION=${TRAEFIK_VERSION:-}
  ING_OPTS="--set deployment.replicas=1 --set ingressClass.enabled=true \
--set ingressRoute.dashboard.enabled=false \
--set providers.kubernetesIngressNGINX.enabled=true \
--set providers.kubernetesIngressNGINX.ingressClassByName=true \
--set providers.kubernetesIngressNGINX.publishService.enabled=true \
--set providers.kubernetesIngress.publishedService.enabled=true \
--set providers.kubernetesGateway.enabled=true --set gateway.enabled=false"
  ING_INSTALLED=$(kubectl get clusterroles -l app.kubernetes.io/name=traefik 2>/dev/null)
elif [[ "$INGRESS" == "nginx" ]]; then
  ING_PRETTY="NGINX Ingress"
  ING_REPO=https://kubernetes.github.io/ingress-nginx
  ING_CHART=ingress-nginx
  ING_NAMESPACE=${NX_NAMESPACE:-ingress-nginx}
  ING_VERSION=${NX_VERSION:-}
  ING_OPTS="--set controller.replicaCount=1 --set controller.service.type=LoadBalancer \
--set controller.publishService.enabled=true"
  ING_INSTALLED=$(kubectl get clusterroles -l app.kubernetes.io/name=ingress-nginx 2>/dev/null)
else
  ING_PRETTY="HAProxy Ingress"
  ING_REPO=https://haproxy-ingress.github.io/charts
  ING_CHART=haproxy-ingress
  ING_NAMESPACE=${HP_NAMESPACE:-haproxy-ingress}
  ING_VERSION=${HP_VERSION:-}
  ING_OPTS="--set controller.replicaCount=1 --set controller.service.type=LoadBalancer \
--set controller.publishService.enabled=true --set controller.ingressClassResource.enabled=true"
  ING_INSTALLED=$(kubectl get clusterroles -l app.kubernetes.io/name=haproxy-ingress 2>/dev/null)
fi

# --- secret-agent -------------------------------------------------------
SEC_PRETTY="Secret Agent"
SEC_REPO=oci://us-docker.pkg.dev/forgeops-public/charts/secret-agent
SEC_CHART=secret-agent
SEC_NAMESPACE=${SA_NAMESPACE:-secret-agent}
SEC_VERSION=${SA_VERSION:-v1.2.12}
SEC_OPTS=""
SEC_INSTALLED=$(kubectl get crd secretagentconfigurations.${SEC_NAMESPACE}.secrets.forgerock.io 2>/dev/null || true)

if [[ "$PULL_ONLY" == true ]]; then
  fetch_chart "$CM_PRETTY" "$CM_CHART" "$CM_REPO" "$CM_VERSION"
  fetch_chart "$ING_PRETTY" "$ING_CHART" "$ING_REPO" "$ING_VERSION"
  fetch_chart "$SEC_PRETTY" "$SEC_CHART" "$SEC_REPO" "$SEC_VERSION"

  if [[ "$INGRESS" == "traefik" ]]; then
    if [[ ! -f "$GATEWAY_API_CACHE" ]]; then
      info "Gateway API: fetching manifest from github.com"
      check_host "$GATEWAY_API_URL"
      curl -sL "$GATEWAY_API_URL" -o "$GATEWAY_API_CACHE"
    fi
    ok "Gateway API: cached at $GATEWAY_API_CACHE"
  fi

  ok "Pull complete. Copy '$CHARTS_DIR' to the restricted machine, then run" \
     "this script there without --pull."
  exit 0
fi

# 1. cert-manager
fetch_chart "$CM_PRETTY" "$CM_CHART" "$CM_REPO" "$CM_VERSION"
install_chart "$CM_PRETTY" "$CM_CHART" "$CM_NAMESPACE" "$CM_VERSION" "$CM_OPTS" "$CM_INSTALLED"

# 2. ingress + (traefik only) its CRDs and the Gateway API CRDs
fetch_chart "$ING_PRETTY" "$ING_CHART" "$ING_REPO" "$ING_VERSION"
if [[ "$INGRESS" == "traefik" && -z "$ING_INSTALLED" ]]; then
  info "$ING_PRETTY: applying Traefik CRDs"
  helm show crds "$CHARTS_DIR/$ING_CHART-${ING_VERSION:-latest}/$ING_CHART" \
    | kubectl apply --server-side --force-conflicts -f -

  if [[ -f "$GATEWAY_API_CACHE" ]]; then
    info "$ING_PRETTY: applying cached Gateway API CRDs"
  else
    info "$ING_PRETTY: fetching + applying Gateway API CRDs from github.com"
    check_host "$GATEWAY_API_URL"
    curl -sL "$GATEWAY_API_URL" -o "$GATEWAY_API_CACHE"
  fi
  kubectl apply -f "$GATEWAY_API_CACHE"
fi
install_chart "$ING_PRETTY" "$ING_CHART" "$ING_NAMESPACE" "$ING_VERSION" "$ING_OPTS" "$ING_INSTALLED"

if [[ "$INGRESS" == "traefik" ]]; then
  NGINX_CURRENT_CONTROLLER=$(kubectl get ingressclass nginx -o="jsonpath={.spec.controller}" 2>/dev/null || true)
  if [[ -z "$NGINX_CURRENT_CONTROLLER" || "$NGINX_CURRENT_CONTROLLER" != "$NGINX_CONTROLLER" ]]; then
    kubectl delete ingressclass nginx >/dev/null 2>&1 || true
    kubectl create -f - <<EOF
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

# 3. secret-agent
fetch_chart "$SEC_PRETTY" "$SEC_CHART" "$SEC_REPO" "$SEC_VERSION"
install_chart "$SEC_PRETTY" "$SEC_CHART" "$SEC_NAMESPACE" "$SEC_VERSION" "$SEC_OPTS" "$SEC_INSTALLED"

ok "All prereqs installed."
