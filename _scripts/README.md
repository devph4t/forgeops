# _scripts

Local dev workflow scripts that wrap the `forgeops` CLI to bring up the Ping
Identity Platform on a local minikube cluster, from a completely fresh
machine. Config is read from `.env` at the repo root (see `.env.example`).

## Prerequisites

Install and have on `$PATH`: `docker`, `kubectl`, `helm`, `minikube`,
`python3` (3.9.6+).

## Usage

```
cp .env.example .env   # edit ENV / K8S_NAMESPACE / K8S_SIZE / DOMAIN
./_scripts/check.sh    # verify tools/dependencies are installed and healthy
./_scripts/startup.sh  # first-time setup: venv, minikube, prereqs, deploy
./_scripts/test.sh     # smoke-test: curls /am and /platform, checks for a healthy response
./_scripts/down.sh     # pause: stops minikube + the host proxy, keeps all data
./_scripts/restart.sh  # resume after down.sh, or after a reboot
./_scripts/clean.sh    # tear down the namespace + prereqs (add --full to also delete the minikube profile)
## show admin password
kubectl get secret am-env-secrets -n ping-local -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d
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
