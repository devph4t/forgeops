#!/usr/bin/env python3
"""Turns the pod specs compose-export.sh dumped under _scripts/compose/specs/
into a docker-compose.yaml at the repo root.

Not meant to be run directly - invoked by compose-generate.sh, which
activates the venv (for PyYAML) and passes the paths as argv.

Translation rules (see compose-export.sh's header for why this reads
already-deployed k8s state instead of reinventing it):
  - initContainers -> one-shot services (`restart: "no"`), chained via
    depends_on: condition: service_completed_successfully, in their
    original k8s order.
  - the main container -> the component's primary service, depending on
    all of its own init services.
  - emptyDir / PVC-backed volumes -> named docker volumes, one per
    (component, volume name, subPath) triple. A single k8s emptyDir shared
    across multiple *different* subPaths in the same pod (e.g. AM's
    "writeable" volume at both /home/forgerock and /tmp) becomes multiple
    separate named volumes instead of one - the "shared scratch space
    across subpaths" behavior doesn't survive the translation, but each
    individual mount still works. Compose's subpath support varies by
    version, so this sidesteps relying on it.
  - secret/configMap/projected volumes -> bind mounts of whatever
    compose-export.sh wrote under _scripts/compose/files/<component>/<vol>/
    (or a single file within it, when the k8s mount used subPath).
  - image refs become `${<NAME>_IMAGE:-<resolved default>}:${<NAME>_TAG:-<resolved default tag>}`,
    <NAME> derived from the image's repo path (e.g. .../images/am -> AM) -
    override AM_IMAGE/AM_TAG etc. in .env to point at a locally built image.
  - envFrom/individual secretKeyRef -> env_file entries pointing at the
    .env files compose-export.sh wrote under _scripts/compose/env/<component>/.
  - readinessProbe.httpGet -> a compose healthcheck, when the probe's port
    can be resolved from the container's own ports[].
"""
import json
import re
import sys
from pathlib import Path

import yaml

# component -> other components its main service should wait on
# (service_started only - we don't have reliable healthchecks for DS).
DEPENDS_ON = {
    "am": ["ds-idrepo", "ds-cts"],
    "idm": ["ds-idrepo", "ds-cts"],
    "ig": ["am"],
    "admin-ui": ["am", "idm"],
    "end-user-ui": ["am", "idm"],
    "login-ui": ["am", "idm"],
}


def image_env_names(image: str) -> tuple[str, str, str, str]:
    """us-docker.pkg.dev/forgeops-public/images/am:latest ->
    ("AM_IMAGE", "us-docker.pkg.dev/forgeops-public/images/am", "AM_TAG", "latest")
    """
    repo, _, tag = image.rpartition(":")
    if not repo:  # no tag in the ref at all
        repo, tag = image, "latest"
    name = re.sub(r"[^A-Za-z0-9]+", "_", repo.rsplit("/", 1)[-1]).strip("_").upper()
    return f"{name}_IMAGE", repo, f"{name}_TAG", (tag or "latest")


def image_ref(image: str) -> str:
    img_var, img_default, tag_var, tag_default = image_env_names(image)
    return "${%s:-%s}:${%s:-%s}" % (img_var, img_default, tag_var, tag_default)


def volume_kind_map(spec: dict) -> dict:
    """volume name -> 'named' | ('bind', kind) for kind in secret/configmap/projected."""
    kinds = {}
    for v in spec.get("volumes", []) or []:
        name = v["name"]
        if "emptyDir" in v:
            kinds[name] = "named"
        elif "secret" in v or "configMap" in v or "projected" in v:
            kinds[name] = "bind"
        else:
            kinds[name] = "named"  # unrecognized (e.g. downwardAPI) - best-effort as scratch space
    # volumeMounts referencing a name absent from volumes[] are PVC-backed
    # (StatefulSet volumeClaimTemplates aren't listed in .spec.template.spec).
    for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
        for vm in c.get("volumeMounts", []) or []:
            kinds.setdefault(vm["name"], "named")
    return kinds


def port_lookup(container: dict) -> dict:
    return {p.get("name"): p["containerPort"] for p in container.get("ports", []) or [] if p.get("name")}


def healthcheck(container: dict):
    probe = container.get("readinessProbe", {}).get("httpGet")
    if not probe:
        return None
    port = probe.get("port")
    if isinstance(port, str):
        port = port_lookup(container).get(port)
    if not port:
        return None
    return {
        "test": ["CMD-SHELL", f"curl -sf http://localhost:{port}{probe.get('path', '/')} || exit 1"],
        "interval": "10s",
        "timeout": "5s",
        "retries": 10,
        "start_period": "60s",
    }


def host_port_env(component: str, port: dict) -> str:
    label = port.get("name") or str(port["containerPort"])
    label = re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_").upper()
    return f"{component.upper().replace('-', '_')}_{label}_PORT"


def container_service(component: str, container: dict, spec: dict, kinds: dict,
                       root: Path, env_dir: Path, files_dir: Path,
                       is_init: bool, next_host_port: list) -> dict:
    svc: dict = {"image": image_ref(container["image"])}

    cmd = list(container.get("command") or []) + list(container.get("args") or [])
    if cmd:
        svc["command"] = cmd

    sec = spec.get("securityContext") or {}
    if sec.get("runAsUser") is not None:
        svc["user"] = f'{sec["runAsUser"]}:{sec.get("fsGroup", 0)}'

    literal_env = {e["name"]: e["value"] for e in container.get("env", []) or [] if "value" in e}
    if literal_env:
        svc["environment"] = literal_env

    comp_env_dir = env_dir / component
    if comp_env_dir.is_dir():
        env_files = sorted(str(p.relative_to(root))
                            for p in comp_env_dir.glob("*.env") if p.stat().st_size > 0)
        if env_files:
            svc["env_file"] = env_files

    volumes = []
    for vm in container.get("volumeMounts", []) or []:
        name, mount_path = vm["name"], vm["mountPath"]
        sub_path = vm.get("subPath")
        ro = ":ro" if vm.get("readOnly") else ""
        kind = kinds.get(name, "named")
        if kind == "named":
            vol_name = f"{component}_{name}" + (f"_{re.sub(r'[^A-Za-z0-9]+', '_', sub_path)}" if sub_path else "")
            volumes.append(f"{vol_name}:{mount_path}{ro}")
        else:
            src = files_dir / component / name
            if sub_path:
                src = src / sub_path
            volumes.append(f"./{src.relative_to(root)}:{mount_path}{ro}")
    if volumes:
        svc["volumes"] = volumes

    if not is_init:
        # containerPort:containerPort would collide on the host whenever two
        # components share a port number (e.g. every Java service uses 8080
        # internally) - so each gets its own host port instead, sequentially
        # allocated (deterministic across regenerations) and .env-overridable.
        ports = []
        for p in container.get("ports", []) or []:
            env_name = host_port_env(component, p)
            host_port = next_host_port[0]
            next_host_port[0] += 1
            ports.append("${%s:-%d}:%d" % (env_name, host_port, p["containerPort"]))
        if ports:
            svc["ports"] = ports
        hc = healthcheck(container)
        if hc:
            svc["healthcheck"] = hc
    else:
        svc["restart"] = "no"

    return svc


def named_volumes_for(component: str, spec: dict, kinds: dict) -> set[str]:
    names = set()
    for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
        for vm in c.get("volumeMounts", []) or []:
            if kinds.get(vm["name"]) == "named":
                sub = vm.get("subPath")
                suffix = f"_{re.sub(r'[^A-Za-z0-9]+', '_', sub)}" if sub else ""
                names.add(f"{component}_{vm['name']}{suffix}")
    return names


def main():
    root = Path(sys.argv[1])
    compose_dir = root / "_scripts" / "compose"
    specs_dir = compose_dir / "specs"
    env_dir = compose_dir / "env"
    files_dir = compose_dir / "files"

    services = {}
    all_named_volumes = set()
    next_host_port = [18080]  # shared mutable counter, allocated in sorted-component order

    for spec_path in sorted(specs_dir.glob("*.json")):
        component = spec_path.stem
        spec = json.loads(spec_path.read_text())
        kinds = volume_kind_map(spec)
        all_named_volumes |= named_volumes_for(component, spec, kinds)

        init_names = []
        for idx, c in enumerate(spec.get("initContainers") or []):
            svc_name = f"{component}-init-{idx}-{c['name']}"
            svc = container_service(component, c, spec, kinds, root, env_dir, files_dir,
                                     is_init=True, next_host_port=next_host_port)
            if init_names:
                svc["depends_on"] = {init_names[-1]: {"condition": "service_completed_successfully"}}
            services[svc_name] = svc
            init_names.append(svc_name)

        main_containers = spec.get("containers") or []
        if not main_containers:
            continue
        svc = container_service(component, main_containers[0], spec, kinds, root, env_dir, files_dir,
                                 is_init=False, next_host_port=next_host_port)
        depends = {n: {"condition": "service_completed_successfully"} for n in init_names}
        for dep in DEPENDS_ON.get(component, []):
            if (specs_dir / f"{dep}.json").exists():
                depends[dep] = {"condition": "service_started"}
        if depends:
            svc["depends_on"] = depends
        services[component] = svc

    compose = {
        "services": services,
        "volumes": {v: {} for v in sorted(all_named_volumes)},
        "networks": {"default": {"name": "forgeops-compose"}},
    }

    out_path = root / "docker-compose.yaml"
    header = (
        "# Generated by _scripts/compose-generate.sh from _scripts/compose/specs/*.json\n"
        "# (which compose-export.sh dumped from a live minikube deployment). Do not\n"
        "# hand-edit - re-run compose-export.sh + compose-generate.sh instead.\n"
        "#\n"
        "# Image tags come from .env (docker-compose auto-loads .env in this\n"
        "# directory) - e.g. set AM_IMAGE/AM_TAG to point at a locally built image.\n"
        "# See _scripts/README.md for the full docker-compose workflow.\n\n"
    )
    with out_path.open("w") as f:
        f.write(header)
        yaml.safe_dump(compose, f, default_flow_style=False, sort_keys=False, width=100)

    print(f"Wrote {out_path} ({len(services)} services, {len(all_named_volumes)} named volumes)")


if __name__ == "__main__":
    main()
