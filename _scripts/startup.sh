#!/usr/bin/env bash
# First-time setup on a fresh machine: installs the Python venv, starts a
# local minikube cluster, installs cluster prereqs, then configures and
# deploys the Ping Identity Platform via the forgeops CLI.
#
# Config comes from ./.env (see .env.example). Safe to re-run - every step
# is idempotent.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker kubectl helm minikube python3
load_env

info "env=$ENV namespace=$K8S_NAMESPACE size=$K8S_SIZE domain=$DOMAIN"
cd "$ROOT_DIR"

# 1. Python virtualenv + forgeops configure
if [[ ! -d .venv ]]; then
  info "Creating Python virtualenv (.venv)"
  python3 -m venv .venv
fi
activate_venv

if [[ ! -f lib/dependencies/.configured_version ]]; then
  info "Running forgeops configure"
  ./bin/forgeops configure
else
  info "forgeops already configured, skipping"
fi

# 2. Local Kubernetes cluster
minikube_ensure_running
kubectl_ctx

# 3. Cluster prereqs (cert-manager, ingress, secret-agent)
info "Installing cluster prereqs (cert-manager, $INGRESS ingress, secret-agent)"
install_prereqs
verify_prereqs_healthy

# secret-agent's admission webhook must be up before `apply` can create/patch
# a SecretAgentConfiguration - `minikube start` on an existing profile can
# transiently restart pods, so give it a moment here rather than racing it.
info "Waiting for secret-agent webhook to be ready"
kubectl rollout status deployment/secret-agent -n secret-agent --timeout=90s || true

# 4. Create/update the forgeops environment (Kustomize overlay + Helm values)
info "Configuring forgeops environment '$ENV'"
kubectl apply -f etc/resources/selfsigned-issuer.yaml >/dev/null
./bin/forgeops env --env-name "$ENV" --fqdn "$DOMAIN" --namespace "$K8S_NAMESPACE" \
  --cluster-issuer default-issuer "$(size_flag)"

# On restricted networks, also pre-load the platform's own images (am, idm,
# ds, ig, amster, the UIs...) into minikube before apply schedules any pods -
# install_prereqs above only covers cert-manager/ingress/secret-agent.
if [[ "$PREREQS_MANUAL" == true ]]; then
  "$SCRIPTS_DIR/platform-images.sh" || true
fi

# 5. Deploy
info "Applying platform to namespace '$K8S_NAMESPACE'"
retry 10 6 ./bin/forgeops apply --env-name "$ENV" --namespace "$K8S_NAMESPACE" --create-namespace

# 6. Make sure the ingress is actually reachable from this host
info "Setting up access to https://$DOMAIN"
ensure_ingress_reachable

ok "Startup complete: https://$DOMAIN"
echo
echo "Re-run this script any time; every step is idempotent."
echo "Use ./_scripts/test.sh to verify it's responding, ./_scripts/restart.sh after a reboot,"
echo "and ./_scripts/clean.sh to tear down."
