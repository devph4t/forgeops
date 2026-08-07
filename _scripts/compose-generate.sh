#!/usr/bin/env bash
# Turns the pod specs compose-export.sh dumped under _scripts/compose/specs/
# into a docker-compose.yaml at the repo root. Run compose-export.sh first.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

load_env
activate_venv   # for PyYAML - already a forgeops dependency (lib/python/requirements.txt)

[[ -d "$SCRIPTS_DIR/compose/specs" ]] || die "No $SCRIPTS_DIR/compose/specs - run ./_scripts/compose-export.sh first."

python3 "$SCRIPTS_DIR/compose_generate.py" "$ROOT_DIR"
ok "Generated $ROOT_DIR/docker-compose.yaml"
echo "Set image tags in .env (e.g. AM_IMAGE/AM_TAG) if you built custom images with"
echo "./_scripts/images-build-export.sh, then bring it up with:"
echo "  ./_scripts/images-import-start.sh   (or: docker compose up -d)"
