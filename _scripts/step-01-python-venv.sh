#!/usr/bin/env bash
# Step 1/9: create the Python virtualenv and run `forgeops configure`.
# Needed before any other step - `forgeops configure`/`forgeops env` are
# python3 scripts that import packages installed into .venv.
#
# Safe to re-run - skips anything already done. Part of the step-by-step
# alternative to startup.sh - see ./_scripts/start-step.sh to run every
# step in order, or run this one alone to redo just this part.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin python3
load_env
cd "$ROOT_DIR"

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

ok "Step 1 done: Python venv ready, forgeops configured."
