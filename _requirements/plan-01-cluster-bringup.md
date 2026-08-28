# Plan 01: Bring up the ForgeOps cluster successfully

Tracks against `rq01.md`. Companion docs: `status.md` (live checklist +
pod table), `activity-log.md` (timestamped run history).

## Context

`rq01.md` states the goal: a working minikube-based Kubernetes cluster
running PingAM, PingIDM, the Platform UI, and two DS instances
(idrepo/user store + CTS/token store), with visibility into pod status,
replica counts, dependency order, deployment progress, and health
validation.

Repo investigation found the environment **not yet configured for first
run**, with two real blockers:

- `.env` is otherwise fully configured (`ENV=local`,
  `K8S_NAMESPACE=ping-local`, `DOMAIN=ping-local.test.bbl`,
  `MINIKUBE_PROFILE=forgeops-local`, `INGRESS=traefik`,
  `INGRESS_ACCESS_MODE=docker`), but **`MINIKUBE_CPUS=9`** while Docker
  Desktop is only configured with **8 CPUs total** — `minikube start`
  would request more CPU than the Docker Desktop VM has. Needs lowering
  (e.g. to 6, leaving headroom for Docker Desktop + the WSL2 host) before
  Milestone 2.
- No `.venv/` and no `lib/dependencies/.configured_version` yet →
  `forgeops configure` has never run.

Non-blocking heads-up: a stale minikube profile `forgeops-demo` is
registered (container already gone) from an earlier, differently-named
attempt. Doesn't interfere with `forgeops-local`, but worth
`minikube delete -p forgeops-demo` to clean up. Its leftover kubectl
context is harmless — `kubectl_ctx` (`_scripts/lib.sh:185`) switches to the
right context automatically at every step.

Toolchain check: docker, kubectl, helm, minikube, python3 all installed
and working (Docker Desktop reachable, 931GB free disk). This is WSL2, so
the minikube IP almost certainly won't be directly routable from the host
— expect the docker/alpine-socat proxy path (`ensure_ingress_reachable` in
`_scripts/lib.sh:336`, matches `INGRESS_ACCESS_MODE=docker` already set),
which means `ping-local.test.bbl` needs to be pointed at `127.0.0.1` in the
**Windows** hosts file, not the WSL one.

The existing `_scripts/step-01..09-*.sh` scripts are the right granularity
for "run one command, check the result, move to the next" — each is
idempotent and individually re-runnable, and together they're exactly what
`startup.sh` runs in sequence. The milestones below map 1:1 to these
scripts.

`forgeops apply` (used in Milestone 8) already owns dependency ordering
between DS/AM/IDM/UI internally — rq01's "Make it have order to have
deployment order" and "Make all integrate" requirements are satisfied by
the tooling's default topology, not something new to build. Our job is
bring-up + verification.

## Working agreement for execution

**The bring-up commands themselves are run by the user**, one milestone at
a time, in their own terminal. After each one they report the result back
(paste output, or "done"/"failed: ..."), and `status.md` +
`activity-log.md` get updated accordingly before handing over the next
command. Read-only verification commands (`kubectl get pods`, `minikube
status`, `./_scripts/test.sh`) can be run on request to help confirm a
milestone's outcome — mutating commands (`minikube start`, `forgeops
apply`, etc.) only run when explicitly asked for.

## Milestones

**M0 — Pre-flight fixes (blocking)**
- Edit `.env`: change `MINIKUBE_CPUS=9` → `MINIKUBE_CPUS=6`.
- Optional cleanup: `minikube delete -p forgeops-demo` (stale orphaned profile).
- Run: `./_scripts/check.sh` — must report 0 blocking issues.

**M1 — Python venv + forgeops configure**
- `./_scripts/step-01-python-venv.sh`
- Done when: `.venv/` exists and `lib/dependencies/.configured_version` exists.

**M2 — Local Kubernetes cluster (minikube)**
- `./_scripts/step-02-create-minikube-profile.sh`
- Done when: `minikube status -p forgeops-local` shows `host: Running`,
  `kubectl get nodes` shows the node Ready.

**M3 — cert-manager**
- `./_scripts/step-03-install-cert-manager.sh`
- Done when: `kubectl get pods -n cert-manager` all Running/Ready.

**M4 — Ingress controller (traefik)**
- `./_scripts/step-04-install-ingress.sh`
- Done when: traefik pod(s) Running, `kubectl get svc -A | grep traefik` shows a Service.

**M5 — Secret Agent operator**
- `./_scripts/step-05-install-secret-agent.sh`
- Done when: `kubectl get pods -n secret-agent` Running.

**M6 — Verify prereqs healthy (self-heals any partial installs)**
- `./_scripts/step-06-verify-prereqs.sh`
- Done when: script exits 0, secret-agent webhook rollout reports ready.

**M7 — Configure the forgeops environment**
- `./_scripts/step-07-configure-environment.sh`
- Generates the Kustomize overlay + Helm values for `ENV=local` (fqdn
  `ping-local.test.bbl`, namespace `ping-local`, single-instance size).
- Done when: script exits 0 (`kustomize/overlay/local/` and/or
  `helm/local/` got written).

**M8 — Deploy the platform (the core requirement from rq01)**
- `./_scripts/step-08-deploy-platform.sh`
- This is where the required pods actually get created: DS idrepo (user
  store), DS CTS (token store), PingAM, PingIDM, Platform UI(s).
- **Known gap (discovered on this run):** the generated
  `kustomize/overlay/<ENV>/ds-{cts,idrepo}/sts.yaml` hardcode
  `storageClassName: fast`, but a fresh minikube cluster only has the
  default `standard` StorageClass — DS pods stick on `Pending` with
  `storageclass "fast" not found`, which then cascades into AM/IDM
  crash-looping on their startup probes (they need DS up). The repo
  already ships the fix as `etc/resources/minikube-fast-storage-class.yaml`
  but none of the `_scripts/step-*.sh` apply it. Run this once, right
  after M8 (or before, doesn't matter — it just needs to exist before the
  DS PVCs try to bind):
  ```bash
  kubectl apply -f etc/resources/minikube-fast-storage-class.yaml
  ```
- Done when: `kubectl get pods -n ping-local` shows all pods Running with
  full readiness (e.g. `1/1`) — this becomes the pod table in `status.md`.
- Most likely to need patience/retries (image pulls, DS bootstrap, AM/IDM
  startup) — expect to check back with `kubectl get pods -n ping-local -w`
  a few times.

**M9 — Host access to the ingress**
- `./_scripts/step-09-setup-ingress-access.sh`
- Then manually: add `127.0.0.1  ping-local.test.bbl` to the **Windows**
  hosts file (WSL2 — the browser resolves via Windows, not the WSL
  `/etc/hosts`).
- Done when: the script confirms the docker proxy (or port-forward) is up.

**M10 — Smoke test / health validation**
- `./_scripts/test.sh` — curls `https://ping-local.test.bbl/am` and
  `/platform`, expects HTTP 200.
- `./_scripts/admin-password.sh` to get the amAdmin password, then confirm
  manual login in a browser at `https://ping-local.test.bbl/platform` as
  final end-to-end integration confirmation.
- Done when: `test.sh` exits 0 and login succeeds — cluster considered
  successful.

## Low-level system design

Derived by reading the actual manifests this deployment applies
(`kustomize/base/*/secret-agent/*.yaml`, the `kustomize/overlay/default/`
reference overlay `forgeops env` regenerates as `overlay/local/`, and
`bin/commands/apply`) — not inferred from docs. `K8S_SIZE=single-instance`
in `.env` means every workload below runs at `replicas: 1` (no HA, no DS
replication topology) — matches what `rq01.md` asks for.

### Component inventory

| Component | Kind | Image | Replicas | Ports (container) | Storage |
|---|---|---|---|---|---|
| `ds-idrepo` | StatefulSet | `ds` | 1 | 8080 http, 8443 https, 1389 ldap, 1636 ldaps, 4444 admin, 8989 replication | PVC 10Gi |
| `ds-cts` | StatefulSet | `ds` | 1 | same as idrepo | PVC 10Gi |
| `am` | Deployment | `am` | 1 | 8080 http, 8081 https | writable emptyDir only |
| `idm` | Deployment | `idm` | 1 | 8080 http, 8443 https | writable emptyDir only |
| `admin-ui` | Deployment | `admin-ui` | 1 | 8080 (nginx static) | none |
| `end-user-ui` | Deployment | `end-user-ui` | 1 | 8080 | none |
| `login-ui` | Deployment | `login-ui` | 1 | 8080 | none |
| `ds-set-passwords` | Job (run once) | `ds` | — | — | — |
| `amster` | Job (run once) | `amster` | — | — | — |

Plus cluster-level operators installed in Milestones 3-5, outside the
`ping-local` namespace: `cert-manager` (ns `cert-manager`), `traefik`
ingress controller, `secret-agent` (ns `secret-agent`).

### Boot / dependency order (handled internally by `forgeops apply`)

```
cert-manager ──┐
               ├─► secret-agent (webhook must be Ready before apply can
traefik ───────┘    create/patch a SecretAgentConfiguration — this is why
                     Milestone 6 explicitly waits on its rollout)
                          │
                          ▼
          SecretAgentConfiguration (kustomize/base/secrets/secret-agent)
                          │  generates K8s Secrets
                          ▼
        ┌─────────────────┴──────────────────┐
        ▼                                     ▼
   ds-idrepo StatefulSet                 ds-cts StatefulSet
   (identities, policies,                (OAuth2/SSO session &
    dynamic config)                       token store)
        │                                     │
        └──────────────┬──────────────────────┘
                        ▼
              ds-set-passwords Job
        (sets uid=admin/monitor bind passwords
         on both DS instances — apply auto-adds
         this if the ds-cts/ds-idrepo STS don't
         exist yet, see bin/commands/apply:100-104)
                        │
                        ▼
                 am Deployment  ◄──── mounts am-secrets, truststore
              (needs ds-idrepo config store +
               ds-cts token store reachable)
                        │
                        ▼
                amster Job (run once)
        (imports AM configuration/policies via
         AM's REST API — needs am-secrets + AM up)
                        │
                        ▼
                 idm Deployment  ◄──── mounts idm-secrets, truststore
              (needs ds-idrepo as its repo backend;
               OPENIDM_REPO_PASSWORD/USERSTORE_PASSWORD
               come from Secret Agent secrets)
                        │
                        ▼
        admin-ui / end-user-ui / login-ui Deployments
         (static UI bundles; call am/idm only from the
          browser through the ingress, no pod-to-pod dep)
```

### Ingress routing (single host `ping-local.test.bbl`, TLS via cert-manager `default-issuer`)

| Path prefix | Backend Service | Purpose |
|---|---|---|
| `/am` | `am` :80→8081(https) | AM REST + console |
| `/am/XUI` | `login-ui` | AM's login screens (served by login-ui, not AM itself) |
| `/openidm`, `/upload`, `/export`, `/admin`, `/openicf` | `idm` :80→8080 | IDM REST APIs |
| `/platform` | `admin-ui` | Platform admin UI |
| `/enduser` | `end-user-ui` | End-user self-service UI |

On WSL2 with `INGRESS_ACCESS_MODE=docker` (this machine's config), the path
from a browser is: `Windows browser → hosts file (ping-local.test.bbl →
127.0.0.1) → docker alpine/socat containers (host ports 80/443) →
minikube node's ingress NodePort → traefik → one of the Services above →
pod`.

### Secrets flow

`SecretAgentConfiguration` (`kustomize/base/secrets/secret-agent/secret-agent-config.yaml`)
is applied once; the `secret-agent` operator (installed in Milestone 5)
watches it and generates the actual `Secret` objects — nothing is
hand-authored. Notable ones consumed downstream: `am-secrets` (mounted
into `am`'s `openam` container, includes the AM keystore/keys),
`idm-secrets` (env vars `OPENIDM_REPO_PASSWORD`, `USERSTORE_PASSWORD`,
`OPENIDM_KEYSTORE_PASSWORD`, `OPENIDM_ADMIN_PASSWORD`, `RS_CLIENT_SECRET`
in the `idm` Deployment), `ds-*` admin/monitor bind-password secrets
consumed by the `ds-set-passwords` Job and both DS StatefulSets, and the
TLS truststore/keypair secrets mounted by `truststore-init` initContainers
on am/idm/ds pods. `./_scripts/admin-password.sh` (Milestone 10) reads the
amAdmin password back out of these generated secrets.

### End-to-end request flow (what Milestone 10's login check exercises)

```
Browser → https://ping-local.test.bbl/platform
        → admin-ui pod (serves the Platform Admin SPA)
        → SPA calls https://ping-local.test.bbl/am/json/... for auth
        → am pod authenticates against ds-idrepo (identities),
          writes session/token state to ds-cts
        → SPA then calls https://ping-local.test.bbl/openidm/... for
          managed-object data
        → idm pod reads/writes managed users in ds-idrepo
```

A pass here (Milestone 10) confirms rq01's "Make all integrate"
requirement end-to-end, not just that each pod individually reports Ready.

## Verification

- Each milestone's "Done when" line above is the check for that step.
- Overall success = M10 passes: `./_scripts/test.sh` exits 0 and the
  Platform UI login works, with `status.md`'s pod table showing every
  required pod from `rq01.md` Running/Ready.
