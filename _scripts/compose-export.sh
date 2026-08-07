#!/usr/bin/env bash
# Exports the resolved Kubernetes config for the platform running in
# $K8S_NAMESPACE - each component's Deployment/StatefulSet pod spec, plus
# every Secret/ConfigMap it references - into local files under
# _scripts/compose/, so compose-generate.sh can turn them into a
# docker-compose.yaml.
#
# Why this exists: AM/IDM/etc.'s actual entrypoint/init scripts are injected
# via ConfigMaps (not baked into the images), and their passwords/keystores
# are generated at deploy time by Secret Agent - there is no way to
# regenerate any of that from scratch outside Kubernetes. So instead of
# trying to reimplement Secret Agent + the platform's config bootstrap,
# this reads the REAL, already-generated versions out of a working
# `make start` deployment.
#
# Requires the platform to have been applied at least once (the workloads
# need to exist - pods don't need to be Running/healthy, since this reads
# .spec.template, not live pod status).
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

require_bin kubectl jq
load_env
kubectl_ctx

COMPOSE_DIR="$SCRIPTS_DIR/compose"
SPECS_DIR="$COMPOSE_DIR/specs"
ENV_DIR="$COMPOSE_DIR/env"
FILES_DIR="$COMPOSE_DIR/files"

# component:kind pairs - the k8s workloads that get translated. Remove a
# line (e.g. ig, or a UI you don't need) to skip it.
WORKLOADS=(
  "am:deployment"
  "idm:deployment"
  "ig:deployment"
  "admin-ui:deployment"
  "end-user-ui:deployment"
  "login-ui:deployment"
  "ds-idrepo:statefulset"
  "ds-cts:statefulset"
)

rm -rf "$SPECS_DIR" "$ENV_DIR" "$FILES_DIR"
mkdir -p "$SPECS_DIR" "$ENV_DIR" "$FILES_DIR"

# Dumps every key of secret/configmap $2 (kind $1) into directory $3, named
# per optional items-mapping json array $4 ([{"key":...,"path":...}], as
# found on a volume's .secret.items/.configMap.items) - falls back to every
# key under its own name when $4 is empty/null, matching how Kubernetes
# itself resolves an items-less secret/configMap volume.
dump_files() {
  local kind=$1 name=$2 destdir=$3 items=$4 json key path raw
  json=$(kubectl get "$kind" "$name" -n "$K8S_NAMESPACE" -o json 2>/dev/null) || {
    warn "$kind/$name not found - skipping"
    return 1
  }
  mkdir -p "$destdir"

  if [[ -n "$items" && "$items" != "null" ]]; then
    while IFS=$'\t' read -r key path; do
      [[ -z "$key" ]] && continue
      raw=$(jq -r --arg k "$key" '(.data[$k] // .binaryData[$k]) // empty' <<< "$json")
      [[ -z "$raw" ]] && continue
      if [[ "$kind" == "secret" ]]; then
        printf '%s' "$raw" | base64 -d > "$destdir/$path"
      else
        printf '%s' "$raw" > "$destdir/$path"
      fi
    done < <(jq -r '.[] | [.key, .path] | @tsv' <<< "$items")
  else
    for key in $(jq -r '(.data // {}) | keys[]' <<< "$json"); do
      jq -r --arg k "$key" '.data[$k]' <<< "$json" \
        | { [[ "$kind" == secret ]] && base64 -d || cat; } > "$destdir/$key"
    done
    for key in $(jq -r '(.binaryData // {}) | keys[]' <<< "$json"); do
      jq -r --arg k "$key" '.binaryData[$k]' <<< "$json" | base64 -d > "$destdir/$key"
    done
  fi
  ok "  $kind/$name -> $destdir"
}

# Dumps secret/configmap $2 (kind $1) as a KEY=VALUE env file at $3.
dump_env() {
  local kind=$1 name=$2 out=$3 json filter
  json=$(kubectl get "$kind" "$name" -n "$K8S_NAMESPACE" -o json 2>/dev/null) || {
    warn "$kind/$name not found - skipping"
    return 1
  }
  if [[ "$kind" == "secret" ]]; then
    filter='(.data // {}) | to_entries[] | .key + "=" + (.value | @base64d)'
  else
    filter='(.data // {}) | to_entries[] | .key + "=" + .value'
  fi
  jq -r "$filter" <<< "$json" >> "$out"
  ok "  $kind/$name -> $out"
}

for entry in "${WORKLOADS[@]}"; do
  IFS=: read -r component kind <<< "$entry"
  info "Exporting $component ($kind)"

  spec_json=$(kubectl get "$kind" "$component" -n "$K8S_NAMESPACE" -o json 2>/dev/null) || {
    warn "$kind/$component not found in namespace '$K8S_NAMESPACE' - skipping (has 'forgeops apply' run?)"
    continue
  }
  pod_spec=$(jq '.spec.template.spec' <<< "$spec_json")
  echo "$pod_spec" > "$SPECS_DIR/$component.json"

  comp_env_dir="$ENV_DIR/$component"
  comp_files_dir="$FILES_DIR/$component"
  mkdir -p "$comp_env_dir"

  # envFrom: secretRef/configMapRef -> one env file per ref, named after it.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dump_env secret "$name" "$comp_env_dir/envfrom.$name.env" || true
  done < <(jq -r '[.initContainers[]?, .containers[]?][] | .envFrom[]? | select(.secretRef) | .secretRef.name' <<< "$pod_spec" | sort -u)

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dump_env configmap "$name" "$comp_env_dir/envfrom.$name.env" || true
  done < <(jq -r '[.initContainers[]?, .containers[]?][] | .envFrom[]? | select(.configMapRef) | .configMapRef.name' <<< "$pod_spec" | sort -u)

  # Individual env[].valueFrom.secretKeyRef/configMapKeyRef -> one merged
  # file per component, keyed by the container's env var NAME (not the
  # secret's internal key, which can differ).
  keyref_env="$comp_env_dir/keyref.env"
  : > "$keyref_env"
  while IFS=$'\t' read -r envname kind name key; do
    [[ -z "$envname" ]] && continue
    val_json=$(kubectl get "$kind" "$name" -n "$K8S_NAMESPACE" -o json 2>/dev/null) || {
      warn "$kind/$name not found - skipping $envname"
      continue
    }
    if [[ "$kind" == "secret" ]]; then
      val=$(jq -r --arg k "$key" '.data[$k] // empty' <<< "$val_json" | base64 -d)
    else
      val=$(jq -r --arg k "$key" '.data[$k] // empty' <<< "$val_json")
    fi
    echo "$envname=$val" >> "$keyref_env"
  done < <(jq -r '
    [.initContainers[]?, .containers[]?][] | .env[]? |
    if .valueFrom.secretKeyRef then
      [.name, "secret", .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | @tsv
    elif .valueFrom.configMapKeyRef then
      [.name, "configmap", .valueFrom.configMapKeyRef.name, .valueFrom.configMapKeyRef.key] | @tsv
    else empty end' <<< "$pod_spec")
  [[ -s "$keyref_env" ]] && ok "  individual key refs -> $keyref_env"

  # volumes: secret / configMap / projected sources -> one directory per
  # volume name, respecting any items[] key->path remap.
  while IFS=$'\t' read -r volname kind name items; do
    [[ -z "$volname" ]] && continue
    dump_files "$kind" "$name" "$comp_files_dir/$volname" "$items" || true
  done < <(jq -r '
    .volumes[]? | . as $v |
    ( if .secret then [{kind:"secret", name:.secret.secretName, items:(.secret.items // null)}]
      elif .configMap then [{kind:"configmap", name:.configMap.name, items:(.configMap.items // null)}]
      elif .projected then [.projected.sources[]? |
        if .secret then {kind:"secret", name:.secret.name, items:(.secret.items // null)}
        elif .configMap then {kind:"configmap", name:.configMap.name, items:(.configMap.items // null)}
        else empty end]
      else [] end
    )[] | [$v.name, .kind, .name, (.items | tojson)] | @tsv' <<< "$pod_spec")
done

ok "Export complete: $COMPOSE_DIR"
echo "Next: ./_scripts/compose-generate.sh to turn this into a docker-compose.yaml."
