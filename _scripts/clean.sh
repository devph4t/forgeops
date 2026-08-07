#!/usr/bin/env bash
# Tear down everything this project created, back to a fresh-machine state:
# the app namespace, plus the cluster-wide prereqs forgeops installed
# (cert-manager, ingress controller, secret-agent).
#
# --full also deletes the minikube profile itself.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

FULL=false
SKIP_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --full) FULL=true ;;
    -y|--yes) SKIP_CONFIRM=true ;;
    -h|--help)
      echo "usage: $0 [--full] [-y|--yes]"
      echo "  --full   also delete the minikube profile/cluster (fully fresh machine)"
      echo "  -y       skip the confirmation prompt"
      exit 0
      ;;
    *) die "Unknown argument: $arg (use -h for usage)" ;;
  esac
done

require_bin docker kubectl minikube helm
load_env

warn "This will delete namespace '$K8S_NAMESPACE' and the forgeops prereqs" \
     "(cert-manager, $INGRESS, secret-agent) from minikube profile '$MINIKUBE_PROFILE'."
if [[ "$FULL" == true ]]; then
  warn "--full given: minikube profile '$MINIKUBE_PROFILE' will also be destroyed entirely."
fi
confirm "Continue?" || die "Aborted."

info "Removing host access proxy (if any)"
remove_ingress_proxy

if ! minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  warn "Minikube profile '$MINIKUBE_PROFILE' isn't running - nothing to clean inside it."
  if [[ "$FULL" == true ]]; then
    info "Deleting minikube profile '$MINIKUBE_PROFILE'"
    minikube delete -p "$MINIKUBE_PROFILE" || true
  fi
  exit 0
fi

kubectl_ctx
cd "$ROOT_DIR"

if [[ "$FULL" == true ]]; then
  info "Deleting minikube profile '$MINIKUBE_PROFILE'"
  minikube delete -p "$MINIKUBE_PROFILE"
  ok "Clean complete (minikube profile removed)."
  exit 0
fi

if [[ -f .venv/bin/activate ]]; then
  info "Deleting forgeops platform from namespace '$K8S_NAMESPACE'"
  ./bin/forgeops delete --env-name "$ENV" --namespace "$K8S_NAMESPACE" --force --yes || true
fi

info "Deleting namespace '$K8S_NAMESPACE'"
kubectl delete namespace "$K8S_NAMESPACE" --ignore-not-found

info "Uninstalling cluster prereqs"
read -r ING_RELEASE ING_NAMESPACE <<< "$(ingress_release_and_namespace)"

helm uninstall cert-manager -n cert-manager >/dev/null 2>&1 || true
kubectl delete namespace cert-manager --ignore-not-found

helm uninstall "$ING_RELEASE" -n "$ING_NAMESPACE" >/dev/null 2>&1 || true
kubectl delete namespace "$ING_NAMESPACE" --ignore-not-found

helm uninstall secret-agent -n secret-agent >/dev/null 2>&1 || true
kubectl delete namespace secret-agent --ignore-not-found

ok "Clean complete. Minikube profile '$MINIKUBE_PROFILE' is still running (now empty)."
echo "Use --full to remove the minikube profile entirely."
