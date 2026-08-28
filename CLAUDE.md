# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

ForgeOps provides the Docker, Kustomize and Helm artifacts (plus a custom
`forgeops` CLI) used to deploy the **Ping Advanced Identity Software**
(PingAM, PingIDM, PingDS, PingGateway, and the Login/Admin/End-User UIs) on
Kubernetes. There is no application source code to compile here — the
"build" outputs are container images, Kustomize overlays, and Helm charts.

## Commands

### Local dev bring-up (minikube)

Config lives in `.env` at the repo root (copy from `.env.example`), read by
everything under `./_scripts/`.

```bash
./_scripts/check.sh           # or: make check   - preflight: verifies docker/kubectl/helm/minikube/python3
./_scripts/startup.sh         # or: make start    - idempotent: venv, forgeops configure, minikube, prereqs, env, apply
./_scripts/test.sh            # or: make test     - smoke test: curls https://$DOMAIN/am and /platform
./_scripts/admin-password.sh  # or: make admin-password - prints the amAdmin password (Secret Agent-generated)
./_scripts/down.sh            # or: make down     - pause: stop minikube + host proxy, keep all data
./_scripts/restart.sh         # or: make restart  - resume after down.sh / a reboot
./_scripts/clean.sh           # or: make clean    - delete namespace + prereqs (--full also deletes the minikube profile)
```

`startup.sh` is also available step-by-step (`./_scripts/start-step.sh`,
running `step-01-python-venv.sh` ... `step-09-setup-ingress-access.sh`), and
in a `forgeops`-CLI-free variant for restricted networks
(`./_scripts/start-manual.sh`, using `step-manual-0N-*.sh`). See
[`_scripts/README.md`](_scripts/README.md) for the full script list
(`install-deps.sh`, `prereqs-manual.sh`, `platform-images.sh`) and their
offline/restricted-network `--pull` modes.

### The `forgeops` CLI directly (no scripts)

```bash
python3 -m venv .venv && source .venv/bin/activate
./bin/forgeops configure                     # must be run once before any other command
./bin/forgeops prereqs                        # cert-manager, ingress, secret-agent
./bin/forgeops env --env-name demo --fqdn <domain> --namespace <ns> --cluster-issuer default-issuer --single-instance
./bin/forgeops apply --env-name demo --namespace <ns> --create-namespace
```

Other subcommands (`bin/forgeops <command> -h` for usage): `amster`, `build`,
`config`, `delete`, `dsconfig`, `image`, `info`, `migrate`, `rotate`,
`upgrade-am-config`, `version`, `wait`. `clean`/`install` are deprecated
aliases.

### Helm chart validation (what CI runs on `charts/**` changes)

```bash
bash bin/check-helm.sh
```

Runs `helm lint` and `helm template` (including with `am.pdb.enabled=true`
and `am.autoscaling.enabled=true`) against `charts/identity-platform` and
`charts/ping-gateway`. This is the closest thing this repo has to a test
suite for chart changes — run it after editing anything under `charts/`.

### docker-compose alternative (no minikube/k8s)

Exports a working minikube deployment's secrets/config and runs the
platform via `docker compose` instead — see "docker-compose (alternative to
minikube)" in [`_scripts/README.md`](_scripts/README.md) for the 4-step
pipeline (`compose-export.sh` → `compose-generate.sh` →
`images-build-export.sh` → `images-import-start.sh`) and its caveats
(single-instance DS only, `_scripts/compose/` holds real secrets and is
gitignored — never commit it).

## Architecture

```
Browser → Ingress (traefik/nginx/haproxy) → Login UI / Admin UI / End-User UI, PingAM, PingIDM, (optional) PingGateway
PingAM, PingIDM → DS idrepo (shared AM/IDM repo, dynamic policy/agent data)
PingAM → DS CTS (Core Token Service)
Secret Agent Operator → generates K8s Secrets consumed by AM/IDM
cert-manager → issues the TLS certificate used by Ingress
```

### `bin/forgeops` — the central CLI

`bin/forgeops` (bash) is a thin dispatcher: it validates the subcommand
against a fixed list, sources `forgeops.conf` (repo root, then
`$FORGEOPS_DATA/forgeops.conf`, then `~/.forgeops.conf` — later sources
win), requires `forgeops configure` to have run (checked via
`lib/python/ensure_configuration_is_valid_or_exit.py`), then execs
`bin/commands/<command>`. Each file in `bin/commands/` is a standalone
script — either bash (sourcing `lib/shell/stdlib.sh` and
`bin/commands/common.sh` for shared helpers/`usageStd`) or Python
(inserting `lib/python` onto `sys.path` by walking up to find the repo
root, i.e. the directory containing `README.md`). `env` is the largest and
most involved command — it's Python/argparse-based and generates both the
Kustomize overlay and the Helm values files for an environment from
`lib/python/defaults.py`/`constants.py`.

### Kustomize and Helm are two views of the same deployment

`kustomize/base/<component>/` holds the raw per-component manifests (am,
amster, idm, ds/{cts,idrepo,set-passwords,snapshot}, the three UIs, ig,
platform, secrets, security netpolicies, keystore-create).
`kustomize/overlay/<env>/` (default env ships as `default`) patches those
bases per environment. `charts/identity-platform` is the Helm equivalent,
with size-specific values files (`values-small/-medium/-large.yaml`) and
secrets-backend-specific ones (`values-secret-agent.yaml` vs
`values-secret-generator.yaml`, `values-helm-generate-secrets.yaml`).
`helm/<env>/` (generated, not templates) holds the per-environment Helm
values that `forgeops env` produces — `values.yaml` plus the split-out
`values-images.yaml`/`values-ingress.yaml`/`values-size.yaml`; see
[`helm/README.md`](helm/README.md). **`forgeops env` is the source of
truth for generating both** — hand-editing files under `kustomize/overlay/`
or `helm/<env>/` is supported (the command won't clobber settings it
doesn't manage) but the base/chart templates under `kustomize/base/` and
`charts/` are what actually change behavior across all environments.

### `docker/` — component images

One directory per component (`am`, `amster`, `am-config-upgrader`, `ds`,
`ds-proxy`, `idm`, `ig`, `admin-ui`, `login-ui`, `end-user-ui`, `rcs`,
`gatling`), each with its own `Dockerfile` (and often a
`Dockerfile-custom` for the config-profile-injected build used by
`forgeops build`). `docker/docker-bake.hcl` drives multi-arch
(`amd64,arm64`) buildx builds and is what `forgeops build`/`forgeops
image` ultimately invoke; images publish to
`us-docker.pkg.dev/forgeops-public/images/*` by default (override via
`PUSH_TO`/`BASE_REPO`/`DEPLOY_REPO` in `forgeops.conf`).

### Secrets

Generated by the [Secret Agent Operator](https://github.com/ForgeRock/secret-agent)
(default) or, per the Helm chart's `values-secret-generator.yaml`, an
alternative secret-generator backend. Never hand-author secret values in
manifests — they're templated as Secret Agent CRDs
(`kustomize/base/*/secret-agent/`) or secret-generator CRDs
(`kustomize/base/*/secret-generator/`).

### Config layering

`forgeops.conf` (repo root, tracked as `forgeops.conf.example`) → per-user
`~/.forgeops.conf` → `.env` (repo root, read only by `_scripts/`, not by
`bin/forgeops` directly) are three separate layers. `.env` controls the
`_scripts/` workflow (`ENV`, `K8S_NAMESPACE`, `K8S_SIZE`, `DOMAIN`,
minikube sizing, `PREREQS_MANUAL`, docker-compose image tags/ports).
`forgeops.conf`/`~/.forgeops.conf` control the `forgeops` CLI itself
(`BUILD_PATH`/`KUSTOMIZE_PATH`/`HELM_PATH`, `PUSH_TO`, ingress/secrets
backend choice for `prereqs`, registry URLs). Both have `.example` files
checked into git; the real files are gitignored/local-only.

### CI

- `.github/workflows/check-helm.yml` runs `bin/check-helm.sh` on any PR
  touching `charts/**`.
- `.github/workflows/main.yml` is a manual (`workflow_dispatch`) release/tag
  build that bakes and pushes platform images.
- `jenkins-scripts/` holds the internal Jenkins pipelines/stages
  (`pr-tests`, `postcommit-tests`, `functional-tests-eks/gke`) used for
  fuller functional test runs against real clusters — not runnable
  locally.
