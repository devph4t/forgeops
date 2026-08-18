#!/usr/bin/env bash
# Same first-time setup as start-step.sh, but installs cert-manager,
# traefik and secret-agent "manually": curl each chart's .tgz directly (or
# `helm pull --untar` for secret-agent, an OCI-only chart - see
# step-manual-03-install-secret-agent.sh) and `helm install` from the
# local unpacked chart, instead of Helm's chart-repo protocol. Useful on
# networks where a plain HTTPS GET works but chart-repo discovery
# (index.yaml) doesn't.
#
# Runs: step-01 (venv), step-02 (minikube), step-manual-01..04
# (cert-manager/traefik/secret-agent + verify), then step-07..09
# (env/apply/ingress-access) - those three still use the forgeops CLI
# (`forgeops env`/`forgeops apply`), which is python-based environment
# templating and multi-resource deploy orchestration, not a Helm chart
# install; there's no curl-and-unpack equivalent for them.
#
# Config comes from ./.env (see .env.example).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

load_env
info "env=$ENV namespace=$K8S_NAMESPACE size=$K8S_SIZE domain=$DOMAIN"

for step in step-01-python-venv.sh step-02-create-minikube-profile.sh \
            step-manual-01-install-cert-manager.sh step-manual-02-install-ingress.sh \
            step-manual-03-install-secret-agent.sh step-manual-04-verify-prereqs.sh \
            step-07-configure-environment.sh step-08-deploy-platform.sh \
            step-09-setup-ingress-access.sh; do
  echo
  info "── $step ──"
  "$SCRIPTS_DIR/$step"
done

echo
ok "Startup complete: https://$DOMAIN"
echo "Re-run this script, or any single step-manual-*.sh, any time - every step is idempotent."
echo "Use ./_scripts/test.sh to verify it's responding, ./_scripts/restart.sh after a reboot,"
echo "and ./_scripts/clean.sh to tear down."
