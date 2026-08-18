#!/usr/bin/env bash
# Runs every ./_scripts/step-NN-*.sh in order: the same first-time setup as
# startup.sh, broken into individually re-runnable steps. If one step
# fails, fix the underlying issue and re-run just that script (e.g.
# ./_scripts/step-04-install-ingress.sh) instead of starting over - every
# step is idempotent, same guarantee as startup.sh itself.
#
# Config comes from ./.env (see .env.example).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

load_env
info "env=$ENV namespace=$K8S_NAMESPACE size=$K8S_SIZE domain=$DOMAIN"

for step in "$SCRIPTS_DIR"/step-[0-9]*.sh; do
  echo
  info "── $(basename "$step") ──"
  "$step"
done

echo
ok "Startup complete: https://$DOMAIN"
echo "Re-run this script, or any single step-*.sh, any time - every step is idempotent."
echo "Use ./_scripts/test.sh to verify it's responding, ./_scripts/restart.sh after a reboot,"
echo "and ./_scripts/clean.sh to tear down."
