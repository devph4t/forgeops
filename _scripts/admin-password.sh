#!/usr/bin/env bash
# Prints the amAdmin password for the deployed platform.
#
# Read-only, safe to run any time.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl
load_env
kubectl_ctx

kubectl get secret am-env-secrets -n "$K8S_NAMESPACE" \
  -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d
echo
