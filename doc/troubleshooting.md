# Troubleshooting Guide

Common issues and solutions for operators deploying and running Baudrate.
See the [SysOp Guide](sysop.md) for the comprehensive operational reference.

---

## Table of Contents

- [Setup & First Run](#setup--first-run)
- [Environment Variables](#environment-variables)
- [Database](#database)
- [Assets, Static Files & Build Dependencies](#assets-static-files--build-dependencies)
- [Reverse Proxy](#reverse-proxy)
- [Federation](#federation)
- [Authentication & Sessions](#authentication--sessions)
- [Rate Limiting](#rate-limiting)
- [A second node](#a-second-node)
- [Detailed health report](#detailed-health-report)

---

## Setup & First Run

> **See the [SysOp Guide](sysop.md#installation) for the full installation
> and first-run setup guide.**

### Development setup

```bash
mix setup       # Install deps, create DB, run migrations, build assets
mix phx.server  # Start dev server at https://localhost:4001
```

The dev server uses HTTPS with a self-signed certificate. Generate one with:

```bash
mix phx.gen.cert
```

This creates `priv/cert/selfsigned_key.pem` and `priv/cert/selfsigned.pem`.
Your browser will show a security warning — this is expected for development.

### First-run wizard interrupted

If the setup wizard is interrupted partway through (e.g., roles seeded but no
admin account created), you can reset and re-run:

```bash
mix ecto.reset  # Drops, recreates, and re-migrates the database
```

### PostgreSQL `pg_trgm` extension missing

See [Database](#database) section below for resolution.

---

## Environment Variables

> **See the [SysOp Guide](sysop.md#environment-variables) for the complete
> reference of all environment variables and their defaults.**

### SECRET_KEY_BASE — critical warning

`SECRET_KEY_BASE` is used to derive encryption keys for:

- **Session cookies** (signing + encryption)
- **TOTP secrets** (AES-256-GCM via TotpVault, salt: `"totp_encryption_key"`)
- **Federation private keys** (AES-256-GCM via KeyVault, salt: `"federation_key_encryption"`)

**Never change `SECRET_KEY_BASE` after deployment.** Changing it will:

1. Invalidate all existing sessions (users must re-login)
2. Make all TOTP secrets undecryptable (users locked out of 2FA)
3. Make all federation private keys undecryptable (federation breaks until keys are rotated)

If you must change it, you will need to:
- Have all users with TOTP re-enroll their authenticator apps
- Rotate all federation keys via the admin panel

---

## Database

### Development credentials

The default dev database config (`config/dev.exs`):

| Setting | Value |
|---------|-------|
| Username | `baudrate_db_user` |
| Password | `baudrate_database` |
| Database | `baudrate_dev` |
| Hostname | `localhost` |

### DATABASE_SSL defaults to true

In production (`config/runtime.exs`), `DATABASE_SSL` defaults to `"true"`.
If your database doesn't support SSL (common with local PostgreSQL), set:

```bash
export DATABASE_SSL=false
```

### Connection pool exhaustion

If you see `DBConnection.ConnectionError` or timeout errors under load,
increase the pool size:

```bash
export POOL_SIZE=20
```

The test configuration automatically scales the pool to
`System.schedulers_online() * 2`.

### pg_trgm extension missing

If migrations fail with:

```
ERROR: type "gtrgm" does not exist
```

Install the `pg_trgm` extension (requires superuser or the
`postgresql-contrib` package):

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

### Resetting the database

For development, reset the entire database:

```bash
mix ecto.reset  # drop + create + migrate
```

---

## Assets, Static Files & Build Dependencies

### Production asset build

Before deploying to production, compile and digest assets:

```bash
mix assets.deploy
```

This runs Tailwind (minified) + esbuild (minified) + `phx.digest` to
generate fingerprinted files and `priv/static/cache_manifest.json`.

**Symptom of missing asset build:** Pages load without CSS styling, or
JavaScript doesn't execute.

### Rust toolchain requirement

HTML sanitization uses a Rust NIF (Ammonia via Rustler). A stable Rust
toolchain must be installed before `mix compile` can succeed:

```bash
# Install via rustup (https://rustup.rs)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Verify
rustc --version
cargo --version
```

The NIF is compiled automatically by `mix compile`. First compilation
downloads Rust crate dependencies (~30s); subsequent builds are incremental.

**Symptom of missing Rust:** Compilation fails with
`Compiling crate baudrate_sanitizer ... error: no such command: 'rustc'`
or similar cargo/rustc not found errors.

### libvips requirement

Avatar and article image processing requires `libvips`. Install it:

```bash
# Debian/Ubuntu
sudo apt install libvips-dev

# macOS
brew install vips

# Alpine
apk add vips-dev
```

**Symptom of missing libvips:** Avatar uploads or article image uploads fail
with NIF-related errors.

### Uploads directory

User-uploaded files (avatars, article images) are stored in
`priv/static/uploads/`. This directory must be:

1. **Writable** by the application process
2. **Persistent** across deployments (not wiped on redeploy)

For containerized deployments, mount a persistent volume at
`priv/static/uploads/`.

---

## Reverse Proxy

### X-Forwarded-For header

Baudrate's `RealIp` plug extracts the client IP from the `X-Forwarded-For`
header (configurable in `config/prod.exs`). Your reverse proxy **must set**
(not append to) this header:

```nginx
# Nginx — correct
proxy_set_header X-Forwarded-For $remote_addr;

# Nginx — WRONG (appends, allowing IP spoofing)
# proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

**Symptom of incorrect configuration:** Rate limiting doesn't work (all
requests appear from the proxy IP), or attackers can bypass rate limits by
spoofing the header.

**Symptom: all users still share one rate-limit bucket after setting the
header.** The plug is fail closed — it believes `X-Forwarded-For` only from a
peer in the `trusted_proxies` allow-list, which defaults to loopback. If the
proxy runs on a different host, name it:

```bash
BAUDRATE_TRUSTED_PROXIES="10.0.0.0/8"
```

An invalid entry raises at boot with the offending value in the message.

### X-Forwarded-Proto header

Required for HTTPS detection behind a reverse proxy. Baudrate's `force_ssl`
config rewrites based on this header:

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

**Symptom of missing header:** Infinite redirect loops between HTTP and HTTPS.

### WebSocket passthrough

Phoenix LiveView requires WebSocket connections. Configure your proxy to pass
through WebSocket upgrades:

```nginx
location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Symptom of blocked WebSockets:** Pages load initially but don't update
in real-time; forms may not submit properly; "connection lost" banners appear.

### HSTS

Production config enables HSTS with a 2-year expiry, subdomain inclusion, and
preload compatibility:

```elixir
force_ssl: [hsts: true, subdomains: true, preload: true, expires: 63_072_000]
```

Once HSTS is active, browsers will refuse to connect over HTTP for the
configured duration. Make sure HTTPS is fully working before enabling HSTS
preloading.

---

## Federation

### Clock synchronization (NTP)

HTTP Signatures include a `Date` header validated within **+/-300 seconds** (5 minutes).
If your server's clock is off, all incoming federation requests will be
rejected with signature verification failures.

**Fix:** Ensure NTP is configured and running:

```bash
timedatectl status        # Check current time sync
sudo systemctl enable ntp # Enable NTP
```

### Remote instance rejected with `public_key_too_weak`

Baudrate requires inbound actor public keys to be RSA of at least **2048 bits**
— the size Mastodon and Baudrate itself generate. A remote instance still using
a 1024-bit (or smaller) key cannot federate: a short modulus makes its
signatures forgeable by a third party, who could then impersonate that actor to
this instance.

The check runs both when caching an actor and when verifying a signature, so
actors cached before this rule existed are rejected too.

**Fix:** the remote operator must rotate to a 2048-bit key. There is no
configuration to lower the threshold.

### HTTPS-only enforcement

All federation actor URIs must be HTTPS. Baudrate will not:

- Fetch remote actors over HTTP
- Accept HTTP actor URIs in incoming activities
- Deliver to HTTP inbox URLs

**Exception:** Localhost (`127.0.0.1`, `::1`) is allowed in dev/test.

### PHX_HOST must match your public hostname

`PHX_HOST` is used to generate all actor URIs, WebFinger responses, and
outgoing activity URLs. If it doesn't match your actual public hostname:

- WebFinger lookups will fail
- Remote instances can't resolve your actors
- HTTP Signature verification may fail (host header mismatch)

### Delivery queue

Delivery jobs are written in the same transaction as the post, like or follow
that causes them, and the `DeliveryWorker` is woken when it commits (see
[ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)
and the sysop guide's Delivery Queue section). The 60-second poll only picks up
retries and anything missed.

**Retry schedule for failed deliveries:**

| Failed attempt | Next try |
|----------------|----------|
| 1 | after 60 seconds |
| 2 | after 5 minutes |
| 3 | after 30 minutes |
| 4 | after 2 hours |
| 5 | after 12 hours |
| 6 | abandoned |

A final `4xx` response other than `401`, `408` and `429` abandons a job at
once. You can retry abandoned jobs from the admin federation dashboard
(`/admin/federation`).

**Symptom of stuck delivery:** Check the federation dashboard for jobs in
`failed` or `pending` state. Common causes:

- Remote instance is down (will retry automatically). After 5 unreachable
  results in a row its circuit opens and its jobs wait together, with one probe
  per interval; look for `federation.delivery_circuit_open` in the log and
  `SELECT * FROM delivery_circuits WHERE trips > 0;`. Jobs held for 7 days are
  abandoned.
- Deliveries only go out once a minute — the worker is not receiving
  notifications. Baudrate must connect to PostgreSQL directly, not through a
  pooler in transaction mode, which cannot carry `LISTEN`.
- Jobs with `last_error: ":timeout"` — the remote server did not answer within
  the request deadline; the attempt counts like any other failure.
- Clock skew causing signature rejection (fix NTP)
- Domain is blocked by the remote instance
- DNS resolution failure
- Board follow 422 errors — check delivery job `last_error` for the response body (includes remote server's rejection reason since v1.1.17)
- Jobs with `last_error: ":unknown_actor"` — the local user or board referenced by `actor_uri` was deleted after the job was queued. Since v1.5.9 these jobs are marked `failed` (and eventually `abandoned` via the normal retry schedule) rather than causing Task crashes that left the job stuck in `pending` forever.
- Jobs that previously crash-looped with a `CaseClauseError` from `Delivery.do_deliver/1` — caused by a local actor that existed but had no RSA keypair (e.g. a new user whose user-signed Like was delivered to a *board's* remote followers before their own actor was ever fetched). `Delivery.get_private_key/1` now self-heals: it lazily generates the keypair at signing time and normalizes the missing-key case to `{:error, :no_private_key}`, so such jobs deliver on the next worker pass instead of crashing.

### Inbound activities not taking effect

The inbox answers `202` once an activity is stored; the work happens afterwards
in `InboundWorker`. A remote follow, reply or like that does not show up has
left a row behind:

```sql
SELECT id, activity_type, status, attempts, last_error, inserted_at
FROM inbound_activities
ORDER BY id DESC LIMIT 20;
```

- `pending` for long — the worker is busy or stopped. Processing is 4 at a time
  and one per remote account, so one account's backlog does not delay others.
  With federation switched off, nothing is processed.
- `rejected` — the handler refused it; `last_error` gives the reason, such as
  `:not_found` (the local account or board does not exist) or `:domain_blocked`
  (the domain was blocked after the activity arrived).
- `failed` — processing crashed or ran past 5 minutes three times; the log has
  `federation.inbound_crashed` or `federation.inbound_timeout` with the id.

An activity refused at the door is answered `422` and never stored: the log
line is `federation.inbox_error` with the reason (for example `:actor_mismatch`).

### Federation kill switch

Setting `ap_federation_enabled` to `false` (via `/admin/settings` or
`/admin/federation`) disables all federation:

- All `/ap/*` endpoints return 404
- Delivery worker skips all pending jobs
- WebFinger and NodeInfo remain available for discovery

### Allowlist mode

When `ap_federation_mode` is set to `"allowlist"`:

- **Only** domains in `ap_domain_allowlist` are accepted
- An **empty allowlist blocks all domains** (safe default)
- Both inbound (inbox) and outbound (delivery) are filtered

### Domain blocklist

Domains with a row in `domain_blocks` (managed at `/admin/federation`) are:

- Rejected at inbox (incoming activities return 202 but are silently dropped)
- Skipped during delivery (jobs marked as abandoned with reason `"domain_blocked"`)
- Domain comparison is case-insensitive

---

## Authentication & Sessions

### Session configuration

| Setting | Value |
|---------|-------|
| Cookie name | `_baudrate_key` |
| Cookie lifetime | 14 days |
| Same-site policy | `Lax` |
| Encryption | Signed + encrypted (separate salts) |
| Token rotation | Every 24 hours (via `RefreshSession` plug) |
| Max concurrent sessions | 3 per user (oldest evicted) |

### Session cleanup

The `SessionCleaner` GenServer runs every hour and:

1. Purges expired user sessions (older than 14 days)
2. Purges old login attempts (older than 7 days)
3. Deletes orphan article images (older than 24 hours)

### TOTP issues

If users report "invalid TOTP code" errors with correct codes:

1. **Code already used** — each code works once per account (ADR 0024). A
   user who signs in on a second device, or confirms two actions, within the
   same 30 seconds must wait for the next code
2. **Clock skew** — TOTP is time-based. A code is accepted for its own
   30-second period and the one after it, but never before its period starts,
   so a device clock running ahead fails first. Ensure both server and user's
   device have accurate time (NTP on server, auto time on device)
3. **SECRET_KEY_BASE changed** — TOTP secrets are encrypted with a key
   derived from `SECRET_KEY_BASE`. If it changed, all TOTP secrets are
   unrecoverable. Users must use recovery codes to log in and re-enroll TOTP.

### Login throttling

Failed logins trigger progressive delays per account:

| Failures (1-hour window) | Delay |
|--------------------------|-------|
| 0-4 | None |
| 5-9 | 5 seconds |
| 10-14 | 30 seconds |
| 15+ | 120 seconds |

Failed TOTP codes at login and failed re-authentication from a signed-in
session count as failures too; `/admin/login-attempts` shows which check each
attempt was for.

This is **not** a hard lockout — it's a delay. The account is never fully
locked out to prevent DoS via deliberate failed logins.

Admins can view login attempts at `/admin/login-attempts`.

---

## Rate Limiting

### Configuration

Rate limiting uses [Hammer](https://hexdocs.pm/hammer/) with an ETS backend:

| Endpoint | Limit | Window |
|----------|-------|--------|
| Login | 10 attempts | 5 minutes per IP |
| TOTP verification | 15 attempts | 5 minutes per IP |
| Registration | 5 attempts | 1 hour per IP |
| Password reset | 5 attempts | 1 hour per IP |
| Avatar upload | 5 changes | 1 hour per user |
| AP endpoints | 120 requests | 1 minute per IP |
| AP inbox | 60 requests | 1 minute per remote domain |
| Direct messages | 20 messages | 1 minute per user |

### Fails open

If the ETS rate-limit backend encounters an error (e.g., table doesn't exist),
requests are **allowed through** rather than blocked. This prevents an
infrastructure failure from causing a denial of service.

### Counters reset on restart

The Hammer ETS backend keeps its counters in the node's memory, so a restart
starts every limit from zero. That is expected. The counters are complete
because Baudrate runs on one node; see [A second node](#a-second-node).

### RealIp plug required in production

Without the `RealIp` plug correctly configured, all requests appear to come
from the reverse proxy's IP address. This means:

- A single IP-based rate-limit bucket for all users
- Rate limits trigger for everyone after a few requests

See [Reverse Proxy](#reverse-proxy) for configuration.

---

## A second node

Baudrate supports exactly one node per database
([ADR 0033](adr/0033-baudrate-runs-on-one-node.md)). Its caches, security-key
challenges, download tokens and rate limits are kept in memory, and its
background workers assume nothing else is doing their job.

### Symptoms

A second node running against the same database (a forgotten
`bin/baudrate start`, or a copy of the release started on another host)
shows up as:

- remote instances receiving the same activity twice;
- a domain block, or a change on `/admin/settings`, that works on some
  requests and not others;
- security-key sign-in or admin re-verification failing intermittently;
- a data export download answering "not found" although it was just offered.

### Checking

`bin/baudrate eval` and the backup service are not second nodes: they load the
application without starting it. On the host, look for more than one running
node:

```bash
pgrep -af 'beam.smp.*baudrate'
```

A backup or another `eval` task shows up here too while it runs; it exits on
its own.

On the database, the connections should come from one place and number about
`POOL_SIZE`, plus your own session:

```sql
SELECT client_addr, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY client_addr;
```

### Fix

1. Stop the extra node.
2. **Restart the remaining service** (`sudo systemctl restart baudrate`), even
   though it looks healthy. A domain block or settings change made through the
   node you stopped never reached this node's caches; a restart reloads them
   from the database, which holds the change.

Deliveries already sent twice cannot be recalled.

---

## Detailed health report

The report is on the server only: `curl -s http://127.0.0.1:4001/health | jq`
(see the sysop guide's Detailed Health Report section and
[ADR 0035](adr/0035-operational-visibility-stays-on-the-host.md)).

### Nothing answers on port 4001

- `HEALTH_DETAIL_PORT` is not in the environment. It is set by the Ansible env
  template; a hand-made install has to add it. Check with
  `grep HEALTH_DETAIL_PORT /opt/baudrate/env/baudrate.env`.
- The listener binds `127.0.0.1` only. From another machine it is unreachable
  by design; run the request on the server.

### A check fails

- `delivery_queue` — deliveries are due but not being sent. Look for
  `federation.delivery_crashed` or `federation.delivery_timeout` in
  `journalctl -u baudrate`, and check that the `workers` check shows
  `delivery_worker` running. A backlog towards one instance that is down does
  not fail this check: its circuit holds those jobs on purpose.
- `inbound_queue` — see [Inbound activities not taking effect](#inbound-activities-not-taking-effect).
- `workers` — a worker has not completed a run for three intervals. A crash
  loop looks the same as a stopped worker; search the log for the module name.
  Right after a restart, a worker that has not run yet counts as healthy until
  three intervals have passed.
- `disk` — below 1 GiB or 10% free under the uploads directory. Backups stop
  at the same floor. The media cache is safe to shrink (it is re-fetched on
  demand); backups in `/var/backups/baudrate` are not.
- `backup` — the newest backup is over 26 hours old, or there is none:
  `systemctl list-timers baudrate-backup` and `journalctl -u baudrate-backup`.
  A backup refused for lack of disk space shows both this and `disk` failing.
- A check reports `raised an error` — the check itself failed (for example a
  table missing because migrations did not run). The reason is deliberately
  generic; the log has the error.
