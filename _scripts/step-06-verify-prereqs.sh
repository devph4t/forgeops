#!/usr/bin/env bash
# Step 6/9: verify cert-manager/ingress/secret-agent actually landed - not
# just "CRDs exist", which `forgeops prereqs` treats as already-installed
# even after a previous run was interrupted post-CRDs but pre-release (see
# verify_prereqs_healthy in lib.sh, which forces a real reinstall of any
# prereq whose namespace is missing) - then waits for the secret-agent
# admission webhook to be ready. That webhook must be up before `forgeops
# apply` can create/patch a SecretAgentConfiguration.
#
# Part of the step-by-step alternative to startup.sh - see
# ./_scripts/start-step.sh to run every step in order, or run this one
# alone to redo just this part.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl helm
load_env
cd "$ROOT_DIR"
kubectl_ctx

verify_prereqs_healthy

info "Waiting for secret-agent webhook to be ready"
kubectl rollout status deployment/secret-agent -n secret-agent --timeout=90s || true

ok "Step 6 done: prereqs verified healthy."
