# Troubleshooting the compose bring-up

Failure modes predicted from how the k8s→compose translation works, ordered
by how likely you are to hit them. Each has a symptom, the real cause, and
the fix.

## First: which layer is broken?

Always isolate before debugging. The per-service host ports exist for this:

```bash
docker compose ps -a                      # who is up / who exited non-zero
curl -sf http://localhost:18081/am/isAlive.jsp   # AM directly (no proxy)
curl -skf https://ping-local.test.bbl/am/isAlive.jsp  # AM through the proxy
```

- direct fails → the **component** is broken (§1–§4)
- direct works, proxied fails → the **routing** is broken (§5)

---

## 1. An init service exits non-zero and everything stalls

**Symptom:** `docker compose up` hangs; `docker compose ps -a` shows e.g.
`am-init-1-filesystem-init  Exited (1)`, dependents never start.

**Cause:** the init chain uses
`depends_on: condition: service_completed_successfully`. One non-zero exit
stops the chain — the compose equivalent of a stuck initContainer.

```bash
docker compose logs am-init-0-custom-vol-init
docker compose logs am-init-1-filesystem-init
```

Re-run a single init service after a fix:

```bash
docker compose up --force-recreate am-init-1-filesystem-init
```

## 2. Permission denied writing to a volume

**Symptom:** init logs show `Permission denied` under `/opt/opendj/data`,
`/writeable`, `/fbc`, or `/custom`.

**Cause:** services run as `user: '11111:0'` (the forgerock UID), but docker
creates named volumes root-owned `0:0`. Kubernetes handled this with
`fsGroup` in the pod security context, which **has no compose equivalent**.

**Fix**, in preference order:

1. Let the image's own init do it — most of these init scripts chown their
   target; make sure the *first* service touching a volume runs as root by
   dropping `user:` from that one-shot service only.
2. Pre-create with correct ownership:
   ```bash
   docker run --rm -v forgeops_ds-idrepo_data:/d busybox:musl chown -R 11111:0 /d
   ```

Note the volume is namespaced by compose project (directory) name — check
`docker volume ls` for the real prefix.

## 3. AM starts but can't reach DS

**Symptom:** AM log shows LDAP connection or SSL handshake errors against
`ds-idrepo-0.ds-idrepo:1636`; `/am/isAlive.jsp` never turns healthy.

Three distinct causes — check in this order:

**3a. Name doesn't resolve.**
```bash
docker compose exec am getent hosts ds-idrepo-0.ds-idrepo
```
Empty → the network alias in `docker-compose.override.yaml` isn't applied.
Confirm with `docker compose config | grep -A3 aliases`.

**3b. Certificate hostname mismatch.** The DS cert is issued for
`DNS:*.ds, DNS:*.ds-idrepo, DNS:*.ds-cts`. A wildcard matches exactly one
label, so `ds-idrepo-0.ds-idrepo` ✅ but bare `ds-idrepo` ❌.

> **Do not "fix" this by editing `AM_STORES_USER_SERVERS` to `ds-idrepo:1636`.**
> It resolves and then fails hostname verification — a more confusing error
> than the one you started with. Keep the pod-style name; fix the alias.

**3c. Truststore missing the DS CA.** `am-init-2-truststore-init` builds
`/truststore/amtruststore` from `_scripts/compose/files/am/truststore/`.
Confirm it exited 0 and the CA is in there:
```bash
docker compose logs am-init-2-truststore-init
docker compose exec am keytool -list -keystore /home/forgerock/amtruststore \
  -storepass changeit | head
```

## 4. DS init won't re-run cleanly

**Symptom:** worked the first time; after a restart the init service fails
with "already initialized" / setup errors.

**Cause:** `init-and-restore.sh` expects either an empty data dir or a fully
set-up one. A half-populated volume (init killed midway) is neither.

**Fix:** at this stage the data is disposable —
`docker compose down -v` and start clean. Once you have data you care
about, snapshot the volume first.

## 5. 404 / 502 through the proxy

**502** — Traefik is up, the backend isn't. `docker compose ps`, check that
service's logs. Note Traefik resolves backend names at request time, so a
backend that started late recovers on its own.

**404** — the path has no route. Compare against the routing table in
`_scripts/proxy/dynamic.yml`; the source of truth is the charts:

```bash
grep -rn "path:" charts/identity-platform/templates/*-ingress.yaml
```

The one that bites: `/am/XUI` must win over `/am` (login-ui, not AM). In
`dynamic.yml` that's the explicit `priority:` — higher wins. If login
renders as raw AM XUI or 404s, priorities are wrong.

## 6. Admin UI loads but shows only spinners

**Cause:** the page loaded, its XHRs to `/openidm` or `/am` did not. This is
the **single-origin** failure — you're browsing a per-service port
(`localhost:18080`) instead of `https://$DOMAIN/platform`.

**Fix:** always use the proxy origin in the browser. Confirm in devtools →
Network: the failing request's origin should be `$DOMAIN`, not `localhost`.
If it genuinely is on `$DOMAIN`, check for a CORS or cookie error in the
console instead — that points back at TLS/proto (§7).

## 7. Redirect loops, or login bounces back to login

**Cause:** AM builds absolute URLs from the forwarded headers. TLS is
terminated at Traefik and AM speaks plain HTTP, so if `X-Forwarded-Proto`
is missing or wrong, AM emits `http://` URLs into an `https://` page and
the browser drops the cookies.

Traefik sets `X-Forwarded-*` automatically. Check what AM actually receives:

```bash
docker compose logs am | grep -i "forwarded\|redirect"
```

Also confirm `AM_SERVER_FQDN` matches the host you're browsing —
`ping-local.test.bbl`, not `localhost`:

```bash
grep FQDN _scripts/compose/env/am/envfrom.platform-config.env
```

## 8. Port 80/443 already bound

**Cause:** the minikube path publishes the same ports via `alpine/socat`
containers or `kubectl port-forward`.

```bash
./_scripts/down.sh                  # stops minikube + host proxies
docker ps | grep socat
ss -tlnp | grep -E ':(80|443)\s'
```

Or sidestep it: set `PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` in `.env` and
browse `https://$DOMAIN:<port>`.

## 9. Browser rejects the self-signed certificate

Expected — `gen-cert.sh` issues a self-signed cert. Click through, or trust
`_scripts/proxy/certs/tls.crt` in your OS/browser store. For `curl`, use
`-k`. On WSL2 browsing from Windows, trust it in the **Windows** store.

## 10. Everything is up but `test.sh` still fails

`test.sh` was written for the minikube path. It may fail on the self-signed
cert rather than on the platform. Check whether it passes `-k` to `curl`;
if not, that's a one-line fix in `_scripts/test.sh`, not a platform problem.

---

## Useful commands

```bash
docker compose ps -a                    # include exited init services
docker compose logs -f --tail=100 am
docker compose config                   # fully merged base + override
docker compose exec am bash             # shell into a running service
docker compose up -d --force-recreate am
docker compose down                     # stop, keep volumes
docker compose down -v                  # DESTROYS all data
docker volume ls | grep -E "am_|ds-|idm_"
```
