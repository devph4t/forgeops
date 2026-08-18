# Running the Ping Identity Platform on Docker only

**Question:** can this repo run without k8s/minikube, on plain `docker compose`?

**Answer: yes — and most of it is already built.** The gap is smaller than it
looks, but there is one honest catch about what "docker only" means. Read
"The catch" below before starting.

Start here, then work through [MILESTONES.md](MILESTONES.md) in order. Keep
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) open while bringing things up.

---

## What already exists

A previous pass built a full export→generate pipeline (see
[_scripts/README.md](../_scripts/README.md), section "docker-compose"):

| Piece | State |
| --- | --- |
| `_scripts/compose-export.sh` | written; **already run** — `_scripts/compose/` is populated with real secrets/config |
| `_scripts/compose-generate.sh` + `compose_generate.py` | written; **already run** — produced `docker-compose.yaml` (455 lines, 18 services) |
| `docker-compose.yaml` | exists, passes `docker compose config` |
| Platform images | **all present locally** (`am`, `idm`, `ds`, `amster`, `admin-ui`, `login-ui`, `end-user-ui`, `busybox:musl`) |
| `traefik:v3.7.10` | present locally (cached by the minikube ingress prereqs) — reused as the compose ingress |

So bring-up has never been run end-to-end, but nothing is missing at the
image or secret level. This plan is about closing the last functional gaps,
not about building the pipeline.

## The catch: "docker only" has two meanings

1. **Run the platform on docker only** — no k8s at runtime. ✅ Achievable,
   that's milestones 1–4.
2. **Never need k8s at all, ever, on a clean machine** — ❌ not true today.
   `compose-export.sh` reads its inputs *out of a live minikube deployment*,
   because entrypoint/init scripts are injected via ConfigMaps and all
   passwords/keystores are generated at deploy time by Secret Agent. The
   export is a one-time bootstrap.

Practically this is fine: the export **has already been done** and lives in
`_scripts/compose/`. You can run on docker forever from here and never start
minikube again. It only bites when you need to regenerate from scratch on a
machine that has never run minikube. Milestone 5 addresses that, and it is
optional — do it only if you need clean-machine reproducibility.

> `_scripts/compose/` contains **real passwords, keys and keystores**. It is
> gitignored on purpose. Never commit it, never put it in an image layer.

---

## Architecture: what changes vs. Kubernetes

```text
Kubernetes                                Docker Compose
──────────                                ──────────────
Ingress (traefik)  ── https://$DOMAIN ──▶  ingress svc (traefik)  ── https://$DOMAIN
  ├── /am          ──▶ am Service            ├── /am          ──▶ am:8080
  ├── /am/XUI      ──▶ login-ui              ├── /am/XUI      ──▶ login-ui:8080
  ├── /openidm …   ──▶ idm                   ├── /openidm …   ──▶ idm:8080
  ├── /platform    ──▶ admin-ui              ├── /platform    ──▶ admin-ui:8080
  └── /enduser     ──▶ end-user-ui           └── /enduser     ──▶ end-user-ui:8080

StatefulSet pod DNS                       network alias
  ds-idrepo-0.ds-idrepo:1636                ds-idrepo-0.ds-idrepo:1636  (same name)
initContainers                            one-shot services +
                                            service_completed_successfully
PVC / emptyDir                            named docker volumes
Secret / ConfigMap volumes                bind mounts of exported files
Secret Agent                              (pre-exported, not re-run)
cert-manager                              self-signed cert for $DOMAIN
```

### The two gaps that actually matter

Everything above is mechanical except these two, which are why a naive
`docker compose up` would come up but not *work*:

**1. Single origin.** The generated compose gives every service its own host
port (`AM_HTTP_PORT=18081`, `ADMIN_UI_HTTP_PORT=18080`, …). But the platform
is path-routed under **one** hostname — the exported config proves it:

```text
AM_URL=/am            IDM_REST_URL=/openidm      PLATFORM_ADMIN_URL=/platform
IDM_ADMIN_URL=/admin  ENDUSER_UI_URL=/enduser    FQDN=ping-local.test.bbl
```

The admin UI at `:18080` calls `/openidm` and `/am` **on its own origin** and
gets 404. Same-origin cookies and OAuth redirects break too. Fix: one
reverse proxy on `https://$DOMAIN`, reproducing the ingress routing table.
The per-service ports stay — they're useful for debugging a single component
directly, they just aren't how the browser should reach the platform.

**2. DS hostnames.** AM is configured to reach DS at StatefulSet pod DNS:

```text
AM_STORES_USER_SERVERS=ds-idrepo-0.ds-idrepo:1636
AM_STORES_CTS_SERVERS=ds-cts-0.ds-cts:1636
```

In compose the container is just `ds-idrepo`, so that name doesn't resolve.
Do **not** fix this by rewriting the env to `ds-idrepo:1636` — the DS server
cert is issued for `DNS:*.ds, DNS:*.ds-idrepo, DNS:*.ds-cts`, and a wildcard
does not match the bare label `ds-idrepo`. LDAPS hostname verification would
fail. Fix: give the container a **docker network alias** of
`ds-idrepo-0.ds-idrepo`, which resolves *and* matches the wildcard SAN.

Verified empirically — docker's embedded DNS resolves dotted aliases:

```text
$ nslookup ds-idrepo-0.ds-idrepo
Name: ds-idrepo-0.ds-idrepo    Address: 172.22.0.2
```

---

## Design decisions (and why)

| Decision | Rationale |
| --- | --- |
| Fixes live in **`docker-compose.override.yaml`**, not in `docker-compose.yaml` | The generated file is gitignored and gets overwritten by `compose-generate.sh`. Compose auto-loads the override, so fixes survive regeneration and *are* committable. |
| **Traefik**, not nginx, as the proxy | `traefik:v3.7.10` is already cached locally, and it's the same ingress controller the k8s path uses — routing semantics match. No new image pull (matters on the restricted networks this repo already caters to). |
| **Terminate TLS** at the proxy with a self-signed cert | AM's config was bootstrapped against `https://$DOMAIN`. Serving plain HTTP invites secure-cookie and redirect-mismatch bugs. TLS-terminating proxy in front of HTTP backends mirrors the k8s ingress exactly. |
| Keep per-service host ports | Free debugging surface (`curl localhost:18081/am/isAlive.jsp` isolates AM from the proxy). Harmless as long as the browser uses the proxy. |
| **Do not** re-run Secret Agent / cert-manager logic | Reimplementing them is the expensive path and buys nothing — the generated material already exists in `_scripts/compose/`. |
| DS stays **single-instance** | Matches `.env` (`K8S_SIZE=single-instance`). DS replication is k8s-DNS-dependent; out of scope. |

## Deliverables already written by this plan

| File | Purpose |
| --- | --- |
| `docker-compose.override.yaml` | DS network aliases + the `ingress` proxy service |
| `_scripts/proxy/traefik.yml` | Traefik static config (entrypoints, http→https) |
| `_scripts/proxy/dynamic.yml` | The routing table — the k8s Ingress rules, translated |
| `_scripts/proxy/gen-cert.sh` | Generates the self-signed cert for `$DOMAIN` |

### What has actually been verified

Be precise about this, because the rest of the repo's compose work carries a
"never run end-to-end" caveat and it would be easy to over-trust these files.

**Verified by running it:**

- Docker's embedded DNS resolves the dotted alias `ds-idrepo-0.ds-idrepo`.
- `docker compose config` validates the merged base + override, and the
  aliases and `ingress` service land on the right services.
- Traefik v3.7.10 loads both config files with **zero errors**, and
  `traefik healthcheck --ping` returns OK.
- **All 9 ingress routes were tested end-to-end through Traefik against stub
  backends** — including the `/am/XUI` → login-ui vs `/am` → am precedence,
  which is the one that silently breaks login if it resolves the wrong way:

  | path | → | path | → |
  |---|---|---|---|
  | `/am/isAlive.jsp` | am ✅ | `/upload/f` | idm ✅ |
  | `/am/XUI/` | login-ui ✅ | `/export/f` | idm ✅ |
  | `/login/x` | login-ui ✅ | `/admin/x` | idm ✅ |
  | `/openidm/info` | idm ✅ | `/platform/` | admin-ui ✅ |
  | `/enduser/` | end-user-ui ✅ | unknown path | 404 (not 502) ✅ |

- `/` redirects 302 → `/platform/`; TLS serves the generated cert with the
  right SANs; `gen-cert.sh` is idempotent on re-run.

**Not verified — this is where the risk lives:**

- No real platform container has been started. Everything above used stub
  backends, so routing is proven but **AM/IDM/DS bring-up is not**.
- Volume ownership under `user: '11111:0'` (no `fsGroup` in compose) is a
  predicted problem, not an observed one — see TROUBLESHOOTING §2.
- DS init idempotency and the AM→DS LDAPS handshake are untested.

Which is exactly why milestones 2 and 3 exist and are ordered the way they
are: DS alone first, then AM alone, then the rest.

## Definition of done

`./_scripts/test.sh` passes (HTTP 200 from `https://$DOMAIN/am` and
`/platform`) against a stack started with `docker compose up -d`, with
minikube **stopped**, and you can log in to `/platform` as `amadmin`.
