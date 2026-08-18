# _scripts

Local dev workflow scripts that wrap the `forgeops` CLI to bring up the Ping
Identity Platform on a local minikube cluster, from a completely fresh
machine. Config is read from `.env` at the repo root (see `.env.example`).

## Prerequisites

Install and have on `$PATH`: `docker`, `kubectl`, `helm`, `minikube`,
`python3` (3.9.6+). On Linux, `./_scripts/install-deps.sh` installs whichever
of these are missing.

## Usage

```
./_scripts/install-deps.sh   # (Linux) install docker/kubectl/helm/minikube/python3 if missing
cp .env.example .env         # edit ENV / K8S_NAMESPACE / K8S_SIZE / DOMAIN
./_scripts/check.sh          # verify tools/dependencies are installed and healthy
./_scripts/startup.sh        # first-time setup: venv, minikube, prereqs, deploy
./_scripts/start-step.sh     # same as startup.sh, run step-by-step via _scripts/step-*.sh
./_scripts/start-manual.sh   # same as start-step.sh, prereqs fetched by curl instead of Helm/forgeops
./_scripts/test.sh           # smoke-test: curls /am and /platform, checks for a healthy response
./_scripts/down.sh           # pause: stops minikube + the host proxy, keeps all data
./_scripts/restart.sh        # resume after down.sh, or after a reboot
./_scripts/clean.sh          # tear down the namespace + prereqs (add --full to also delete the minikube profile)
./_scripts/admin-password.sh # print the amAdmin password
./_scripts/prereqs-manual.sh # alternative to `forgeops prereqs` for restricted networks (see below)
./_scripts/platform-images.sh # loads am/idm/ds/ig/amster/UI images into minikube (see below)
```

Or via the `Makefile` at the repo root (run `make help` for the list):

```bash
make install-deps     # (Linux) install docker/kubectl/helm/minikube/python3 if missing
make check
make start
make start-step       # same as 'start', run step-by-step via _scripts/step-*.sh
make start-manual     # same as 'start-step', prereqs fetched by curl instead of Helm/forgeops
make test
make down
make restart
make clean            # add ARGS=--full to also delete the minikube profile
make admin-password
make prereqs-manual   # ARGS=--pull to only cache charts for an offline install
make platform-images  # ARGS=--pull to only cache images for an offline install
```

- `install-deps.sh` (Linux only) installs whichever of `docker`/`kubectl`/`helm`/`minikube`/`python3` are missing: docker via its official convenience script (and adds you to the `docker` group), kubectl/minikube as the official binaries into `/usr/local/bin`, helm via its official install script, python3 via the system package manager (`apt-get`/`dnf`/`yum`/`pacman`). Idempotent - already-installed tools are skipped. Needs sudo; prompts for confirmation before installing (skip with `-y`).
- `check.sh` is a read-only preflight check — it verifies `docker`/`kubectl`/`helm`/`minikube`/`python3` are installed, the docker daemon is reachable, `.env` has the required values, and reports whether the machine is ready for `startup.sh`. Exits `0` when there are no blocking issues, `1` otherwise, so it's safe to use as a gate in onboarding docs or CI.
- `startup.sh` is safe to re-run any time — every step (venv creation,
  `forgeops configure`, `minikube start`, `forgeops prereqs`, `forgeops env`,
  `forgeops apply`) is idempotent. It also makes sure `https://$DOMAIN` is
  actually reachable from this host (see "Reaching the platform" below), and
  self-heals a couple of sharp edges in `forgeops prereqs`/`env` (a stale
  cert-manager CRD check, and the interactive TLS-issuer prompt).
- `start-step.sh` does exactly what `startup.sh` does, but as nine separate
  `step-NN-*.sh` scripts run in order (`step-01-python-venv.sh` ...
  `step-09-setup-ingress-access.sh`) instead of one monolithic script. Each
  step is independently re-runnable and idempotent, same as `startup.sh`
  overall - useful when one step fails: fix the underlying issue and re-run
  just that script (e.g. `./_scripts/step-04-install-ingress.sh`) instead of
  starting over. cert-manager, the ingress controller and secret-agent are
  separate steps (3/4/5) even though `forgeops prereqs` can install all
  three in one call, specifically so any one of them can be retried alone.
  Steps 3/4/5 themselves are standalone too - direct `helm upgrade
  --install` calls against each chart's repo, not `./bin/forgeops prereqs`.
- `start-manual.sh` is `start-step.sh` with a different prereqs path: steps
  3/4/5 are replaced by `step-manual-01/02/03-*.sh`, which fetch
  cert-manager/traefik by `curl`ing the chart's `.tgz` directly (bypassing
  Helm's chart-repo/index.yaml discovery, not just the `forgeops` CLI) and
  `helm install` from the local unpacked chart - useful on networks where a
  plain HTTPS GET works but repo-index discovery doesn't. secret-agent is
  the one exception: its chart is OCI-only (no flat, curl-able `.tgz` URL),
  so `step-manual-03-install-secret-agent.sh` uses `helm pull --untar`
  instead - still no `forgeops` CLI, just a different unavoidable fetch
  mechanism. `step-manual-04-verify-prereqs.sh` mirrors `step-06` minus its
  `forgeops`-based self-heal, so the whole manual path stays forgeops-free.
  Downloaded charts are cached under `$CHARTS_DIR/manual/` (same cache dir
  `prereqs-manual.sh` uses). `CM_VERSION`/`TRAEFIK_VERSION` must be a real,
  pinned chart version here (the download URL is built from it) - there's
  no "latest" like the Helm-repo path has; override in `.env` if the
  defaults baked into the scripts go stale. Steps 1/2 (venv, minikube) and
  7/8/9 (env/apply/ingress-access) are unchanged from `start-step.sh` -
  those still use the forgeops CLI (`forgeops env`/`forgeops apply` are
  python-based templating/deploy orchestration, not a Helm chart install,
  so there's no curl-and-unpack equivalent for them).
- `test.sh` is a read-only smoke test — curls `https://$DOMAIN/am` and
  `/platform` and checks for a healthy (HTTP 200) response. Exits `0`/`1`
  accordingly, so it's usable as a post-deploy check in CI too.
- `down.sh` pauses everything without deleting anything: stops minikube and
  the host proxy containers (if any). All data is preserved on disk.
- `restart.sh` assumes `startup.sh` has already run once; it brings things
  back up after `down.sh` or a reboot - starts minikube back up (only if it
  isn't already running - see below) and re-applies/waits.
- `clean.sh` prompts for confirmation before deleting anything; pass `-y` to
  skip that (e.g. in CI).
- `admin-password.sh` is a read-only lookup — prints the `amAdmin` password
  from the `am-env-secrets` Secret in `$K8S_NAMESPACE`.
- `prereqs-manual.sh` is an alternative to `forgeops prereqs` for networks
  with a policy that blocks some of the hosts it needs in one shot — it
  fetches and installs cert-manager, ingress and secret-agent one at a time
  via separate `helm pull`s into a local cache, printing exactly which host
  each step needs. It also pre-loads every container image each chart needs
  straight into minikube (`minikube image load`) — the chart fetch and the
  cluster pulling the chart's images are two separate network hops, and a
  pod stuck at "0 of 1 replicas available" / ImagePullBackOff after prereqs
  "succeeded" is usually the second one. Supports a fully offline install
  too: run `./_scripts/prereqs-manual.sh --pull` on a machine with network
  access to download every chart *and* image into `$CHARTS_DIR`, copy that
  directory to the restricted machine, then re-run without `--pull` - no
  network needed at all at that point. Set `PREREQS_MANUAL=true` in `.env`
  to make `startup.sh` use it automatically instead of `forgeops prereqs`.
  See `./_scripts/prereqs-manual.sh -h`.
- `platform-images.sh` does for the platform itself what `prereqs-manual.sh`
  does for cert-manager/ingress/secret-agent: makes sure every image
  `forgeops apply` needs (am, amster, ds, idm, ig, the UIs, kubectl,
  busybox:musl — all `us-docker.pkg.dev/forgeops-public/images/*` on this
  repo) is loaded into minikube. Use it if pods in `$K8S_NAMESPACE` are
  stuck at `ImagePullBackOff`/`Init:ImagePullBackOff`. Same offline story as
  `prereqs-manual.sh`: `--pull` on a machine with network access (it needs
  to have run `forgeops env` at least once itself) caches every image into
  `$CHARTS_DIR`; copy that over and re-run without `--pull` on the
  restricted machine. When `PREREQS_MANUAL=true`, `startup.sh` runs this
  automatically right after `forgeops env`, before `forgeops apply`. See
  `./_scripts/platform-images.sh -h`.

`lib.sh` holds the shared helpers (`.env` loading, minikube/kubectl context,
confirmation prompts) and isn't meant to be run directly.

## docker-compose (alternative to minikube)

Four more scripts let you run the platform via `docker compose` instead of
minikube/k8s, with images built from source and exported as `.tar.gz` for
moving to another machine:

```bash
./_scripts/compose-export.sh       # 1. export secrets/config from a working minikube deployment
./_scripts/compose-generate.sh     # 2. turn that export into ./docker-compose.yaml
./_scripts/images-build-export.sh  # 3. build images from source, export as .tar.gz
./_scripts/images-import-start.sh  # 4. import the .tar.gz images + docker compose up
```

or `make compose-export`, `make compose-generate`, `make images-build-export`
(`ARGS="am idm"` to build only specific components), `make images-import-start`.

**Why steps 1-2 exist at all**: AM/IDM/etc.'s actual entrypoint/init scripts
are injected via Kubernetes ConfigMaps (not baked into the images), and
their passwords/keystores are generated at deploy time by Secret Agent -
there's no way to regenerate any of that from scratch outside Kubernetes.
So instead of reimplementing Secret Agent and the platform's config
bootstrap, `compose-export.sh` reads the real, already-generated versions
out of a working `make start` deployment (`kubectl get deployment/statefulset
-o json` + every Secret/ConfigMap they reference, decoded to local files
under `_scripts/compose/` - **contains real secrets, gitignored, never
commit it**), and `compose-generate.sh` mechanically translates that into
`docker-compose.yaml` (initContainers become one-shot services chained with
`depends_on: condition: service_completed_successfully`, emptyDir/PVC
volumes become named docker volumes, secret/configMap volumes become bind
mounts of the exported files). **DS runs single-instance** (no k8s-DNS-based
replication) - this repo's own `.env` default (`K8S_SIZE=single-instance`).

**Image tags come from `.env`** (docker-compose auto-loads a `.env` file in
its own directory): each service is `${<COMPONENT>_IMAGE:-<published
default>}:${<COMPONENT>_TAG:-latest}`, e.g. `AM_IMAGE`/`AM_TAG`. Building
with `images-build-export.sh` writes these automatically, so once you've
built a component, compose picks it up with no extra config.

**Ports**: each service gets its own host port (`<COMPONENT>_<PORTNAME>_PORT`
in `.env`, e.g. `AM_HTTP_PORT`) since several components share the same
*container* port (8080) - letting `docker-compose.yaml` map them all to the
same host port would make `docker compose up` fail outright.

> **Honest caveat**: this was built and validated piece-by-piece - every jq
> extraction query and the generator's output were tested against real,
> fully-rendered manifests from this repo (including `docker compose config`
> schema validation), and the PVC/subPath/items-remap edge cases were
> checked individually. What *hasn't* been exercised is a full live run
> against a real deployment's actual secrets, or `docker compose up`
> end-to-end - there was no working minikube deployment available to export
> from while building this. Treat the first run as something to debug
> together rather than a guaranteed one-shot success.

## Notes

- **`minikube start` on an already-running profile is avoided on purpose.**
  It still reconciles the control plane (apiserver/etcd/kube-proxy/...),
  which restarts them and causes a couple of minutes of cluster instability
  — enough to break `forgeops apply`'s call into the secret-agent admission
  webhook mid-flight. `startup.sh`/`restart.sh` check `minikube status`
  first and only call `minikube start` when the profile is actually stopped.
- **Even a genuine cold boot races the same webhook.** Right after minikube
  actually starts from stopped, `kubectl rollout status` on the secret-agent
  Deployment only confirms the pod is Ready - kube-proxy can still be mid-sync
  on iptables rules for its Service for several more seconds. `apply` is
  wrapped in a retry (`retry 10 6 ...` in `lib.sh`) since `kubectl apply -k`
  is idempotent and safe to retry; this was reproduced live (3 failed
  attempts, succeeded on the 4th, ~18s later) while testing `down.sh` +
  `restart.sh`.
- **Reaching the platform**: minikube's docker network isn't always directly
  routable from the host (this is the normal case on WSL2 / Docker Desktop,
  less so on native Linux). `startup.sh`/`restart.sh` detect which case
  you're in: if the minikube IP is reachable, they just print it for you to
  add to your hosts file; otherwise they publish host ports 80/443 via two
  small `alpine/socat` docker containers that forward into the cluster's
  ingress. Either way, point `$DOMAIN` at the printed IP (or `127.0.0.1` in
  the proxy case — the Windows hosts file if you're accessing from a browser
  on Windows over WSL2) and `clean.sh`/`--full` removes those containers.
  If docker fails to publish the port with something like `Error response
  from daemon: ... /forwards/expose returned unexpected status 500` (a
  Docker Desktop port-forwarder bug on WSL2/Windows, not a forgeops issue),
  set `INGRESS_ACCESS_MODE=kubectl-port-forward` in `.env` instead — it
  forwards the same ports via a backgrounded `kubectl port-forward` (no
  extra image needed), and `down.sh`/`clean.sh`/`restart.sh` all know how to
  stop/restart it.
