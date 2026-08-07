# _scripts

Local dev workflow scripts that wrap the `forgeops` CLI to bring up the Ping
Identity Platform on a local minikube cluster, from a completely fresh
machine. Config is read from `.env` at the repo root (see `.env.example`).

## Prerequisites

Install and have on `$PATH`: `docker`, `kubectl`, `helm`, `minikube`,
`python3` (3.9.6+).

## Usage

```
cp .env.example .env         # edit ENV / K8S_NAMESPACE / K8S_SIZE / DOMAIN
./_scripts/check.sh          # verify tools/dependencies are installed and healthy
./_scripts/startup.sh        # first-time setup: venv, minikube, prereqs, deploy
./_scripts/test.sh           # smoke-test: curls /am and /platform, checks for a healthy response
./_scripts/down.sh           # pause: stops minikube + the host proxy, keeps all data
./_scripts/restart.sh        # resume after down.sh, or after a reboot
./_scripts/clean.sh          # tear down the namespace + prereqs (add --full to also delete the minikube profile)
./_scripts/admin-password.sh # print the amAdmin password
./_scripts/prereqs-manual.sh # alternative to `forgeops prereqs` for restricted networks (see below)
```

Or via the `Makefile` at the repo root (run `make help` for the list):

```bash
make check
make start
make test
make down
make restart
make clean            # add ARGS=--full to also delete the minikube profile
make admin-password
make prereqs-manual   # ARGS=--pull to only cache charts for an offline install
```

- `check.sh` is a read-only preflight check — it verifies `docker`/`kubectl`/`helm`/`minikube`/`python3` are installed, the docker daemon is reachable, `.env` has the required values, and reports whether the machine is ready for `startup.sh`. Exits `0` when there are no blocking issues, `1` otherwise, so it's safe to use as a gate in onboarding docs or CI.
- `startup.sh` is safe to re-run any time — every step (venv creation,
  `forgeops configure`, `minikube start`, `forgeops prereqs`, `forgeops env`,
  `forgeops apply`) is idempotent. It also makes sure `https://$DOMAIN` is
  actually reachable from this host (see "Reaching the platform" below), and
  self-heals a couple of sharp edges in `forgeops prereqs`/`env` (a stale
  cert-manager CRD check, and the interactive TLS-issuer prompt).
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

`lib.sh` holds the shared helpers (`.env` loading, minikube/kubectl context,
confirmation prompts) and isn't meant to be run directly.

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
