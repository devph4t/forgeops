#!/usr/bin/env bash
# Imports the tar.gz images images-build-export.sh produced (docker load)
# and brings up the docker-compose stack.
#
# Expects, copied over from the machine that ran images-build-export.sh /
# compose-export.sh / compose-generate.sh:
#   - _scripts/.compose-images/*.tar.gz  (or wherever IMAGE_EXPORT_DIR points)
#   - the .env entries images-build-export.sh added (<COMPONENT>_IMAGE/_TAG)
#   - docker-compose.yaml + _scripts/compose/ (from compose-export.sh /
#     compose-generate.sh - see _scripts/README.md)
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker
load_env
cd "$ROOT_DIR"

EXPORT_DIR=${IMAGE_EXPORT_DIR:-$SCRIPTS_DIR/.compose-images}

[[ -d "$EXPORT_DIR" ]] || die "No $EXPORT_DIR - copy the tar.gz files from images-build-export.sh here first."
[[ -f docker-compose.yaml ]] || die "No docker-compose.yaml at the repo root - copy it here, or generate it with" \
  "./_scripts/compose-export.sh + ./_scripts/compose-generate.sh (needs a working minikube deployment)."

shopt -s nullglob
tarballs=("$EXPORT_DIR"/*.tar.gz)
shopt -u nullglob
[[ ${#tarballs[@]} -eq 0 ]] && die "No *.tar.gz files in $EXPORT_DIR."

for f in "${tarballs[@]}"; do
  info "Importing $(basename "$f")"
  gunzip -c "$f" | docker load
done
ok "All images imported."

info "Starting the stack: docker compose up -d"
docker compose -f docker-compose.yaml up -d

ok "Stack started."
echo "Check status with: docker compose ps"
echo "Follow logs with:   docker compose logs -f <service>"
