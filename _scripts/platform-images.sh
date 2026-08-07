#!/usr/bin/env bash
# Makes sure every container image the Ping Identity Platform itself needs
# (am, amster, ds, idm, ig, the UIs, kubectl, busybox:musl - see
# kustomize/overlay/$ENV/image-defaulter/kustomization.yaml) is available in
# minikube, using the same offline cache as prereqs-manual.sh. That script
# only covers cert-manager/ingress/secret-agent and their images - this one
# covers the platform `forgeops apply` actually deploys, which on this repo
# all come from us-docker.pkg.dev/forgeops-public/images/*.
#
# Use this when pods in $K8S_NAMESPACE are stuck at ImagePullBackOff /
# Init:ImagePullBackOff after `forgeops apply` on a network that blocks
# that registry - once the images are loaded, kubelet's existing backoff
# retry picks them up on its own (imagePullPolicy is IfNotPresent), or
# force it immediately with: kubectl delete pod -n $K8S_NAMESPACE <pod>
#
# For a fully offline install: run `--pull` once on a machine that *does*
# have access to us-docker.pkg.dev (it needs to have run
# `forgeops env --env-name $ENV ...` at least once itself, so
# kustomize/overlay/$ENV/image-defaulter/kustomization.yaml exists) to cache
# every image into $CHARTS_DIR/images. Copy that directory to the
# restricted machine and re-run without --pull.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl docker minikube
load_env
kubectl_ctx
cd "$ROOT_DIR"

PULL_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --pull) PULL_ONLY=true ;;
    -h|--help)
      echo "usage: $0 [--pull]"
      echo
      echo "  (no args)  load every platform image into minikube (from cache, a direct"
      echo "             pull, or an already-loaded copy)"
      echo "  --pull     only download images into \$CHARTS_DIR - don't load anything."
      echo "             Run this on a machine with network access, then copy"
      echo "             \$CHARTS_DIR to the restricted machine and re-run without --pull."
      echo
      echo "Config (in .env): CHARTS_DIR (default: _scripts/.chart-cache)"
      exit 0
      ;;
    *) die "Unknown argument: $arg (use -h for usage)" ;;
  esac
done

OVERLAY_FILE="kustomize/overlay/$ENV/image-defaulter/kustomization.yaml"

# Every image the platform could need: the authoritative name->tag mapping
# from the generated overlay (needs `forgeops env` to have run at least
# once), plus whatever's actually on pods right now in $K8S_NAMESPACE (in
# case that overlay file isn't present on this machine, or a pod is using
# something the static mapping doesn't cover).
discover_images() {
  if [[ -f "$OVERLAY_FILE" ]]; then
    awk '/newName:/ { name=$2 } /newTag:/ { print name ":" $2 }' "$OVERLAY_FILE"
  fi
  kubectl get pods -n "$K8S_NAMESPACE" -o json 2>/dev/null \
    | grep -o '"image": *"[^"]*"' \
    | sed -E 's/"image": *"//; s/"$//' || true
}

IMAGES=$(discover_images | sort -u)
if [[ -z "$IMAGES" ]]; then
  die "No platform images found - has 'forgeops env'/'forgeops apply' run yet? (need $OVERLAY_FILE or existing pods in $K8S_NAMESPACE)"
fi

if [[ "$PULL_ONLY" == true ]]; then
  failed=0
  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    cache_image "$image" || failed=$((failed + 1))
  done <<< "$IMAGES"

  if [[ $failed -gt 0 ]]; then
    warn "$failed image(s) couldn't be pulled - see warnings above."
  fi
  ok "Pull complete. Copy '$CHARTS_DIR' to the restricted machine, then run" \
     "this script there without --pull."
  exit 0
fi

failed=0
while IFS= read -r image; do
  [[ -z "$image" ]] && continue
  ensure_minikube_image "$image" || failed=$((failed + 1))
done <<< "$IMAGES"

if [[ $failed -gt 0 ]]; then
  warn "$failed image(s) couldn't be loaded - see warnings above."
  exit 1
fi
ok "All platform images present in minikube."
echo "Already-scheduled pods pick this up on their next pull retry automatically" \
  "(imagePullPolicy: IfNotPresent), or force it now with:" \
  "kubectl delete pod -n $K8S_NAMESPACE <pod-name>"
