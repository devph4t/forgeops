# Milestones

Work these in order. Each has a **goal**, **tasks**, and a hard
**acceptance check** — a command with a pass/fail answer. Don't move on
until the acceptance check passes; the later milestones assume the earlier
ones actually work.

Effort estimates assume you already have the repo state described in
[README.md](README.md) (export done, images present).

| # | Milestone | Est. | Blocking? |
| --- | --- | --- | --- |
| 0 | Baseline verification | 15 min | yes |
| 1 | Single origin + DS DNS | 1–2 h | yes |
| 2 | Data tier up (DS) | 1–2 h | yes |
| 3 | App tier up (AM, IDM, UIs) | 2–4 h | yes |
| 4 | Lifecycle scripts + `make` targets | 1–2 h | no |
| 5 | Cut the minikube dependency | 1–2 d | optional |

---

## Milestone 0 — Baseline verification

**Goal:** confirm the starting point is what this plan assumes, before
changing anything.

### Tasks

1. Confirm the export is populated and non-empty:
   ```bash
   ls _scripts/compose/specs/     # expect 7 json files
   find _scripts/compose/files -type f | wc -l   # expect > 0
   ```
2. Confirm all images are present:
   ```bash
   docker images | grep -E "forgeops-public|busybox.*musl|traefik"
   ```
   Missing any? Run `make images-build-export` (build from source) or pull
   them, then `make images-import-start`.
3. Confirm the generated compose parses: `docker compose config -q`
4. Note the domain: `grep DOMAIN .env` → `ping-local.test.bbl`

### Acceptance

```bash
docker compose config -q && echo BASELINE_OK
```

> If `_scripts/compose/` is empty or missing, you cannot proceed — you need
> a one-time export from a working minikube deployment
> (`make start && make compose-export && make compose-generate`). See "The
> catch" in [README.md](README.md).

---

## Milestone 1 — Single origin + DS DNS

**Goal:** the two structural gaps from the README are closed in config.
Nothing is running yet — this milestone is about the files being right.

### Tasks

1. Review the four delivered files (already written):
   - `docker-compose.override.yaml`
   - `_scripts/proxy/traefik.yml`
   - `_scripts/proxy/dynamic.yml`
   - `_scripts/proxy/gen-cert.sh`
2. Generate the TLS cert:
   ```bash
   ./_scripts/proxy/gen-cert.sh
   ```
3. Add the hosts entry pointing `$DOMAIN` at the proxy. On WSL2 you need it
   in **both** places if you browse from Windows:
   - Linux: `/etc/hosts` → `127.0.0.1 ping-local.test.bbl`
   - Windows: `C:\Windows\System32\drivers\etc\hosts` → same line
4. Make sure host ports 80/443 are free — **stop minikube and the socat
   proxies from the k8s path first**, they bind the same ports:
   ```bash
   ./_scripts/down.sh
   ```
   If 80/443 are still taken, set `PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` in
   `.env` and use `https://$DOMAIN:<port>` throughout.

### Acceptance

```bash
docker compose config -q && \
docker compose config | grep -A2 "ds-idrepo-0.ds-idrepo" && \
test -f _scripts/proxy/certs/tls.crt && echo M1_OK
```

---

## Milestone 2 — Data tier up (DS)

**Goal:** `ds-idrepo` and `ds-cts` start, finish their init, and accept
LDAPS with a cert that validates.

DS first, alone. It's the dependency root, and its failures are the ones
most likely to be misread as AM failures later.

### Tasks

1. Start only the data tier:
   ```bash
   docker compose up -d ds-idrepo ds-cts
   docker compose logs -f ds-idrepo
   ```
2. Watch the one-shot init services complete. `ds-idrepo-init-0-init` runs
   `init-and-restore.sh` and must exit **0**:
   ```bash
   docker compose ps -a | grep init
   ```
3. Confirm data landed in the named volume (not an empty dir):
   ```bash
   docker compose exec ds-idrepo ls -la /opt/opendj/data/db
   ```
4. Verify LDAPS answers **and** the cert chain validates under the alias
   name — this is the check that proves the alias/SAN reasoning:
   ```bash
   docker compose exec ds-cts sh -c \
     'ldapsearch -H ldaps://ds-idrepo-0.ds-idrepo:1636 \
        -o mech=EXTERNAL -b "" -s base "(&)" 1.1' || true
   ```
   A TLS/hostname error here means the alias is wrong. A *bind/auth* error
   is fine — TLS succeeded, which is what's being tested.

### Acceptance

Both DS containers `running`, both init services `exited (0)`, and
`ldaps://ds-idrepo-0.ds-idrepo:1636` completes its TLS handshake.

### Likely failures

- **Permission denied on /opt/opendj/data** — the services run as
  `user: '11111:0'`. Named volumes are created root-owned; the first write
  can fail. Fix: let the init service chown, or pre-create the volume with
  the right ownership. See TROUBLESHOOTING.
- **Init exits non-zero on a re-run** — `init-and-restore.sh` is not always
  idempotent against a half-populated volume. `docker compose down -v` and
  start clean (destroys DS data — fine at this stage).

---

## Milestone 3 — App tier up (AM, IDM, UIs)

**Goal:** the full stack is reachable at `https://$DOMAIN` and the smoke
test passes.

### Tasks

1. Bring up AM and watch its init chain (`custom-vol-init` →
   `filesystem-init` → `truststore-init` → `am`):
   ```bash
   docker compose up -d am
   docker compose logs -f am
   ```
   AM is the long pole — expect 2–5 minutes to boot. It is healthy when the
   log reaches the AM/Tomcat startup-complete line.
2. Verify AM directly, bypassing the proxy, so a failure is unambiguously
   AM's and not routing's:
   ```bash
   curl -sf http://localhost:${AM_HTTP_PORT:-18081}/am/isAlive.jsp && echo AM_OK
   ```
   Failure here is almost always AM↔DS: check `AM_STORES_*` resolution and
   the truststore. See TROUBLESHOOTING.
3. Bring up the rest:
   ```bash
   docker compose up -d
   docker compose ps
   ```
4. Verify routing through the proxy — each ingress path in turn:
   ```bash
   for p in /am/isAlive.jsp /openidm /platform /enduser /am/XUI; do
     printf '%s -> ' "$p"
     curl -sk -o /dev/null -w '%{http_code}\n' "https://$DOMAIN$p"
   done
   ```
   Expect 2xx/3xx/401 — **not** 404 (bad route) and not 502 (backend down).
5. Run the repo's own smoke test. It curls `https://$DOMAIN/am` and
   `/platform`; add `-k` handling if it rejects the self-signed cert:
   ```bash
   ./_scripts/test.sh
   ```
6. Log in to `https://$DOMAIN/platform` as `amadmin`:
   ```bash
   grep AM_PASSWORDS_AMADMIN_CLEAR _scripts/compose/env/am/envfrom.am-env-secrets.env
   ```

### Acceptance

`./_scripts/test.sh` exits 0 **with minikube stopped**, and you can log in
to `/platform` in a browser and see the admin UI load data (not a spinner —
a spinner means `/openidm` calls are failing).

### Open item to verify here

The exported config sets `LOGIN_UI_URL=/login/#/service/Login`, but the k8s
Ingress only routes `/am/XUI` to login-ui — there is no `/login` rule in the
charts. `dynamic.yml` routes **both** to login-ui to cover it. If login
redirects land somewhere unexpected, this is the first thing to look at.

---

## Milestone 4 — Lifecycle scripts + `make` targets

**Goal:** the docker path is as easy to drive as `make start`.

### Tasks

1. Add scripts under `_scripts/` mirroring the existing style (source
   `lib.sh`, read `.env`, idempotent, `-h` help):
   - `compose-up.sh` — `gen-cert.sh`, then `docker compose up -d`, wait for
     health, print the URL and the amadmin password
   - `compose-down.sh` — `docker compose stop` (keeps volumes/data)
   - `compose-clean.sh` — `docker compose down -v` behind a confirmation
     prompt (`-y` to skip), matching `clean.sh`'s convention
2. Add `make compose-up` / `compose-down` / `compose-clean` and list them in
   the `help` target alongside the existing compose targets.
3. Update `_scripts/README.md`: document the override file, the proxy, the
   hosts entry, and drop the "never run end-to-end" caveat once M3 passes.
4. Update the root `README.md` so a newcomer can pick docker *or* minikube.

### Acceptance

From a stopped stack: `make compose-up && ./_scripts/test.sh` passes, then
`make compose-down && make compose-up` passes again **with data preserved**
(your admin login still works, no re-init).

---

## Milestone 5 — Cut the minikube dependency (optional)

**Goal:** a clean machine can produce a working stack without ever
installing minikube. Only worth doing if you need reproducibility for other
people or CI. Milestones 1–4 give you a working docker platform without it.

Pick one of three approaches, in increasing order of cost and payoff:

### 5a. Freeze the export (cheapest, ~2 h)

Encrypt `_scripts/compose/` (`sops`, `age`, or `git-crypt`) and commit the
ciphertext. `compose-up.sh` decrypts on start.

- ✅ Trivial; clean machine works immediately.
- ❌ Real secrets in git history, even encrypted. Everyone shares one
  identical set of keys. **Local dev only — never for anything shared or
  internet-facing.**

### 5b. Generate the secrets natively (moderate, ~1–2 d)

Replace the Secret-Agent-generated material with a `compose-bootstrap.sh`
that generates it locally: random passwords, then `keytool`/`openssl` for
the keystores, DS master/SSL keypairs off a local CA (keep the SANs
`*.ds`, `*.ds-idrepo`, `*.ds-cts` — see README).

- ✅ No secrets in git; fresh keys per machine.
- ❌ You must match exactly what each component expects. Work component by
  component and diff against the existing export — you have a known-good
  reference in `_scripts/compose/`, use it as the spec.

### 5c. Template the config out of the charts (most correct, ~2–3 d)

The init scripts and config come from chart files
(`charts/identity-platform/files/**`) — render them with `helm template`
instead of `kubectl get` from a live cluster, and combine with 5b for
secrets. Then `compose-generate.sh` needs no cluster at all.

- ✅ Genuinely k8s-free; tracks upstream chart changes.
- ❌ Largest change to `compose_generate.py`.

**Recommendation:** 5a now if you just need a teammate running today; 5c if
this becomes the supported path. Skip entirely if it's just you on this box.

### Acceptance

On a machine with docker and no minikube/kubectl: clone, run the documented
bootstrap, `make compose-up`, `./_scripts/test.sh` passes.
