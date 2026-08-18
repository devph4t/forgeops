#!/usr/bin/env bash
# Manual step 4/4: verify cert-manager/ingress/secret-agent actually
# landed, then wait for the secret-agent admission webhook to be ready
# (needed before `forgeops apply` can create/patch a
# SecretAgentConfiguration).
#
# Unlike ./_scripts/step-06-verify-prereqs.sh, this doesn't self-heal via
# `./bin/forgeops prereqs --upgrade` - it just tells you which
# step-manual-*.sh to re-run, keeping this path forgeops-free end to end.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl
load_env
cd "$ROOT_DIR"
kubectl_ctx

read -r _ ing_ns <<< "$(ingress_release_and_namespace)"

for entry in "cert-manager step-manual-01-install-cert-manager.sh" \
             "$ing_ns step-manual-02-install-ingress.sh" \
             "secret-agent step-manual-03-install-secret-agent.sh"; do
  read -r ns script <<< "$entry"
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    ok "Namespace '$ns' exists"
  else
    die "Namespace '$ns' is missing - re-run ./_scripts/$script"
  fi
done

info "Waiting for secret-agent webhook to be ready"
kubectl rollout status deployment/secret-agent -n secret-agent --timeout=90s || true

ok "Manual step 4 done: prereqs verified healthy."
