# Activity Log

Append-only, most recent entry at the bottom. One entry per action/result.

---

**2026-08-28** — Reviewed `rq01.md`, inspected repo state (`.env`, tool
versions, minikube/docker status). Found `.env` fully configured for a
fresh single-instance deployment (`ENV=local`, ns `ping-local`, domain
`ping-local.test.bbl`) but never actually run: no `.venv/`, no
`forgeops configure`. Found two issues: `MINIKUBE_CPUS=9` exceeds Docker
Desktop's 8 allocated CPUs (blocking, must fix before M2), and a stale
orphaned minikube profile `forgeops-demo` (non-blocking cleanup).

**2026-08-28** — Created `plan-01-cluster-bringup.md`, `status.md`, and
this log under `_requirements/`, mapping bring-up to 11 milestones (M0-M10)
against the existing `_scripts/step-01..09-*.sh` scripts, plus a low-level
system design section (component inventory, dependency graph, ingress
routing, secrets flow). Milestones not yet started — commands to be run by
the user in their own terminal per milestone.

**2026-08-28** — User asked to execute the plan end-to-end instead
(superseding the "user runs commands" working agreement). Ran M0: set
`MINIKUBE_CPUS=6` in `.env` (was 9, exceeded Docker Desktop's 8 CPUs),
`minikube delete -p forgeops-demo` (stale orphaned profile, removed
cleanly), `./_scripts/check.sh` → 0 blocking issues (3 expected warnings:
no `.venv` yet, `forgeops configure` not run, minikube profile not
started — all addressed by upcoming milestones).

**2026-08-28** — Ran M1-M7 in sequence, all succeeded: Python venv +
`forgeops configure` (M1); minikube cluster `forgeops-local` up, node
Ready (M2); cert-manager 3/3 pods Running (M3); traefik 2/2 pods Running
in ns `traefik` (M4); secret-agent 2/2 Running in ns `secret-agent` (M5);
`step-06-verify-prereqs.sh` confirmed all healthy, webhook rolled out (M6);
`step-07-configure-environment.sh` generated `kustomize/overlay/local/`
and `helm/local/` (M7). Started M8 (`step-08-deploy-platform.sh`) in the
background — deploys DS idrepo/CTS, AM, IDM, UIs; expected to take
several minutes for image pulls and bootstrap.

**2026-08-28** — M8 (`step-08-deploy-platform.sh`) completed (exit 0):
namespace `ping-local`, all ConfigMaps/Services/Deployments/StatefulSets/
Ingresses created, `SecretAgentConfiguration` applied and all expected
secrets (`am-env-secrets`, `idm-env-secrets`, `ds-passwords`,
`ds-env-secrets`) generated successfully. amAdmin and other credentials
issued. Pods immediately after apply: all in Init/Pending/ContainerCreating
(expected — first-run image pulls + init containers). Started a background
poll (every 15s, up to ~10 min) watching `kubectl get pods -n ping-local`
until every pod is Running/Ready or a one-shot Job shows Completed.

**2026-08-28** — Root cause found for stuck `ds-cts-0`/`ds-idrepo-0`
(Pending) and AM/IDM crash-looping (startup probe failures — they depend
on DS being up): the generated `kustomize/overlay/local/ds-{cts,idrepo}/
sts.yaml` hardcode `storageClassName: fast`, but this minikube cluster only
has the default `standard` StorageClass — `fast` doesn't exist
(`ProvisioningFailed ... storageclass "fast" not found`). The fix already
ships in the repo as `etc/resources/minikube-fast-storage-class.yaml`
(a StorageClass named `fast` on the same `k8s.io/minikube-hostpath`
provisioner) but none of the `_scripts/step-*.sh` files apply it — a real
gap in the script sequence (only `selfsigned-issuer.yaml` gets applied in
step-07/startup.sh). Applied it manually via `kubectl apply -f
etc/resources/minikube-fast-storage-class.yaml`; both PVCs (`data-ds-cts-0`,
`data-ds-idrepo-0`) bound immediately, `ds-cts-0`/`ds-idrepo-0` moved from
Pending to Init. Continuing to monitor for full readiness.

**2026-08-28** — M8 confirmed fully done. Final state in ns `ping-local`:
`admin-ui`, `am`, `end-user-ui`, `idm`, `login-ui` all `1/1 Running`;
`ds-cts-0`/`ds-idrepo-0` `1/1 Running`; Jobs `ds-set-passwords` and
`amster` both `Complete` (1/1). AM and IDM each show 1 restart from the
earlier DS-not-ready crash loop, self-resolved once DS came up — no
lingering issue. Updated `status.md`'s pod table with the actual pod
names/status. Moving to M9 (ingress host access) and M10 (smoke test).

**2026-08-28** — Ran M9 (`step-09-setup-ingress-access.sh`): minikube IP
not directly routable from this WSL2 host (as anticipated), docker
alpine/socat proxy published host ports 80/443 -> cluster ingress. Checked
the Windows hosts file (`/mnt/c/Windows/System32/drivers/etc/hosts`,
read-only from WSL) — it already had `127.0.0.1 ping-local.test.bbl` from
prior setup, so no manual edit needed. M9 done.

Ran M10: `./_scripts/test.sh` — both `https://ping-local.test.bbl/am` and
`/platform` returned HTTP 200. `./_scripts/admin-password.sh` returned the
amadmin password. Automated verification is fully green; end-to-end
integration (M8-M10) confirms rq01's requirements are met: all required
pods (DS idrepo, DS CTS, AM, IDM, Platform/End-User/Login UIs) Running,
correct dependency order (DS -> ds-set-passwords -> AM -> amster -> IDM ->
UIs), and integration verified via the ingress-routed smoke test. Manual
browser login at https://ping-local.test.bbl/platform (user `amadmin`) is
the one remaining confirmation step, left for the user since it requires
an actual browser session.

**Cluster bring-up: SUCCESSFUL.** All milestones M0-M10 complete (M10's
automated half); only the optional manual browser click-through remains.
