# Cluster Bring-up Status

Live status board for `plan-01-cluster-bringup.md`. Updated after each
milestone is run and reported back. See `activity-log.md` for the
timestamped history behind these statuses.

Last updated: 2026-08-28 (M0-M10 automated checks complete — cluster is up; manual browser login still to be confirmed by user)

## Milestone checklist

| # | Milestone | Status | Notes |
|---|---|---|---|
| M0 | Pre-flight fixes (`.env` CPU fix, stale profile cleanup, `check.sh`) | Done | `MINIKUBE_CPUS` 9→6, `forgeops-demo` profile deleted, `check.sh` reports 0 blocking issues |
| M1 | Python venv + `forgeops configure` | Done | `.venv` created, `forgeops configure` succeeded |
| M2 | Minikube cluster up | Done | Profile `forgeops-local` running, 6 CPU/8000mb/40g |
| M3 | cert-manager installed | Done | 3/3 pods Running in ns `cert-manager` |
| M4 | Ingress controller (traefik) installed | Done | Installed in ns `traefik` |
| M5 | Secret Agent operator installed | Done | 2/2 Running in ns `secret-agent` |
| M6 | Prereqs verified healthy | Done | secret-agent webhook rolled out successfully |
| M7 | forgeops environment configured (`ENV=local`) | Done | Generated `kustomize/overlay/local/` and `helm/local/` |
| M8 | Platform deployed (pods created) | Done | Hit and fixed a real bug: DS PVCs requested `storageClassName: fast`, which minikube doesn't ship by default — applied `etc/resources/minikube-fast-storage-class.yaml` (see activity log). All pods now 1/1 Running, both Jobs Complete |
| M9 | Host access to ingress set up | Done | Docker proxy (alpine/socat) publishing 80/443; Windows hosts file already had `127.0.0.1 ping-local.test.bbl` |
| M10 | Smoke test + manual login validation | Automated part done | `./_scripts/test.sh`: `/am` and `/platform` both HTTP 200. Manual browser login at https://ping-local.test.bbl/platform still to be confirmed by user |

## Required pods (from `rq01.md`)

| Pod / workload | Namespace | Replicas (desired/ready) | Status | Notes |
|---|---|---|---|---|
| `ds-idrepo-0` (Directory Server — user store / idrepo) | ping-local | 1/1 | Running | |
| `ds-cts-0` (Directory Server — Token Store / CTS) | ping-local | 1/1 | Running | |
| `am-6ddd7856cd-h4s9s` (PingAM) | ping-local | 1/1 | Running | 1 restart during startup (crash-looped waiting on DS before the storage fix) |
| `idm-7b8fd8dd48-5r6tx` (PingIDM) | ping-local | 1/1 | Running | 1 restart, same cause as AM |
| `admin-ui-76c77c8c9c-rhdvh` (Platform Admin UI) | ping-local | 1/1 | Running | |
| `end-user-ui-5c9bf5b564-cfzhs` (End-User UI) | ping-local | 1/1 | Running | |
| `login-ui-78d8cddd97-vkm5f` (Login UI) | ping-local | 1/1 | Running | |
| `ds-set-passwords` (Job) | ping-local | 1/1 | Completed | |
| `amster` (Job) | ping-local | 1/1 | Completed | Imports AM config |

## Cluster prereqs (outside `ping-local` namespace)

| Component | Namespace | Status |
|---|---|---|
| cert-manager | cert-manager | 3/3 Running |
| traefik (ingress) | traefik | 2/2 Running |
| secret-agent | secret-agent | 2/2 Running |
| fast StorageClass | (cluster-scoped) | Created (manual fix, see activity log) |

## How to log in (manual final confirmation)

- URL: https://ping-local.test.bbl/platform
- Username: `amadmin`
- Password: run `./_scripts/admin-password.sh` (also printed at the end of
  the M8 apply output)

## Known environment facts

- Minikube profile: `forgeops-local`, driver `docker`
- Namespace: `ping-local`
- Domain: `ping-local.test.bbl`
- Size: `single-instance` (replicas = 1 everywhere)
- Ingress: traefik, access mode `docker` (WSL2 proxy via alpine/socat containers)
- Stale/unrelated: minikube profile `forgeops-demo` (orphaned, container gone)
