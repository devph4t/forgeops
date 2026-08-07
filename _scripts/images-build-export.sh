#!/usr/bin/env bash
# Builds the Ping Identity Platform images from source (am, idm, ds, ig,
# amster via `forgeops build`; admin-ui, end-user-ui, login-ui via
# `docker buildx bake`) and exports each as a compressed tar.gz, for
# transferring a custom build to another machine (e.g. one that can't reach
# the image registry - see prereqs-manual.sh/platform-images.sh for pulling
# already-published images instead of building from source).
#
# Every image is re-tagged to forgeops/<component>:$BUILD_TAG before export,
# and this script updates .env with the matching <COMPONENT>_IMAGE/_TAG
# overrides docker-compose.yaml reads (see compose-generate.sh) - so once
# you've built here, `docker compose up` on any machine that has imported
# the tar.gz files (via images-import-start.sh) uses your build instead of
# the published image, with no further config needed.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin docker
load_env
cd "$ROOT_DIR"
activate_venv

BUILD_TAG=${BUILD_TAG:-local}
EXPORT_DIR=${IMAGE_EXPORT_DIR:-$SCRIPTS_DIR/.compose-images}
mkdir -p "$EXPORT_DIR"

# component -> how to build it: "forgeops" (bin/forgeops build) or "bake"
# (docker buildx bake). Remove a line to skip building that component.
COMPONENTS=(
  "am:forgeops"
  "idm:forgeops"
  "ds:forgeops"
  "ig:forgeops"
  "amster:forgeops"
  "admin-ui:bake"
  "end-user-ui:bake"
  "login-ui:bake"
)

ONLY=()
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "usage: $0 [component ...]"
      echo "  (no args)  build + export every component listed in this script"
      echo "  component  build + export only these (e.g. $0 am idm)"
      echo
      echo "Config (in .env): BUILD_TAG (default: local), IMAGE_EXPORT_DIR (default: _scripts/.compose-images)"
      exit 0
      ;;
    *) ONLY+=("$arg") ;;
  esac
done

want() {
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local c
  for c in "${ONLY[@]}"; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}

local_tag() { printf 'forgeops/%s:%s' "$1" "$BUILD_TAG"; }

# <component>_IMAGE / <component>_TAG - matches compose_generate.py's
# image_env_names() derivation (last path segment of the image ref).
env_var_prefix() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

set_env_var() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$ROOT_DIR/.env" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ROOT_DIR/.env" && rm -f "$ROOT_DIR/.env.bak"
  else
    echo "${key}=${value}" >> "$ROOT_DIR/.env"
  fi
}

export_image() {
  local component=$1 tag; tag=$(local_tag "$component")
  local out="$EXPORT_DIR/$component.tar.gz"
  info "$component: exporting $tag -> $out"
  docker save "$tag" | gzip > "$out"
  ok "$component: exported ($(du -h "$out" | cut -f1))"

  local prefix; prefix=$(env_var_prefix "$component")
  set_env_var "${prefix}_IMAGE" "forgeops/$component"
  set_env_var "${prefix}_TAG" "$BUILD_TAG"
}

for entry in "${COMPONENTS[@]}"; do
  IFS=: read -r component method <<< "$entry"
  want "$component" || continue
  tag=$(local_tag "$component")

  if [[ "$method" == "forgeops" ]]; then
    info "$component: building via forgeops build"
    ./bin/forgeops build --env-name "$ENV" --tag "$BUILD_TAG" "$component"
    docker tag "$component:$BUILD_TAG" "$tag"
  else
    info "$component: building via docker buildx bake"
    docker buildx bake -f docker/docker-bake.hcl \
      --set '*.platform=linux/amd64' \
      --set '*.output=type=docker' \
      --set '*.cache-to=' \
      --set '*.cache-from=' \
      "$component"
    # bake's default tags include ...images/<component>:latest - re-tag
    # whichever of its tags actually landed locally to our own convention.
    src=$(docker images --format '{{.Repository}}:{{.Tag}}' \
      | grep -E "/${component}:(latest|${BUILD_TAG})$" | head -1) || true
    [[ -z "$src" ]] && die "$component: bake didn't produce a local image matching *${component}:latest - check the build output above."
    docker tag "$src" "$tag"
  fi

  export_image "$component"
done

ok "Build + export complete: $EXPORT_DIR"
echo "Copy that directory to the target machine, then run:"
echo "  ./_scripts/images-import-start.sh"
