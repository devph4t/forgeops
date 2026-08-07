#!/usr/bin/env bash
# Pause the deployment without deleting anything: stops minikube and the
# host-access proxy containers (if any). All data is preserved - bring it
# back up with ./_scripts/restart.sh. For a real teardown use ./_scripts/clean.sh.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker minikube
load_env

info "Stopping host access proxy (if any)"
stop_ingress_proxy

if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  info "Stopping minikube profile '$MINIKUBE_PROFILE'"
  minikube stop -p "$MINIKUBE_PROFILE"
else
  info "minikube profile '$MINIKUBE_PROFILE' is already stopped"
fi

ok "Down. Nothing was deleted - run ./_scripts/restart.sh to bring it back up."
