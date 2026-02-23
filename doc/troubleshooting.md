# Troubleshooting Guide

Common issues and solutions for operators deploying and running Baudrate.

---

## Table of Contents

- [Setup & First Run](#setup--first-run)
- [Environment Variables](#environment-variables)
- [Database](#database)
- [Assets & Static Files](#assets--static-files)
- [Reverse Proxy](#reverse-proxy)
- [Federation](#federation)
- [Authentication & Sessions](#authentication--sessions)
- [Rate Limiting](#rate-limiting)
- [Clustering](#clustering)

---

## Setup & First Run

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

### First-run wizard

On first launch, Baudrate redirects all requests to `/setup`. The wizard
creates the initial admin account and seeds roles/permissions. The setup is
considered complete when the `setup_completed` setting is set to `"true"`.

If the setup wizard is interrupted partway through (e.g., roles seeded but no
admin account created), you can reset and re-run:

```bash
mix ecto.reset  # Drops, recreates, and re-migrates the database
```

### PostgreSQL requirements

Baudrate requires the `pg_trgm` extension for full-text search (CJK support).
The migration creates it automatically, but your PostgreSQL user needs the
`CREATE EXTENSION` privilege, or the extension must be pre-installed by a
superuser:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

---

## Environment Variables

### Required (production)

| Variable | Description | How to generate |
|----------|-------------|-----------------|
| `DATABASE_URL` | PostgreSQL connection string | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Session/cookie signing + encryption key derivation | `mix phx.gen.secret` |
| `PHX_HOST` | Public hostname for URL generation | Your domain (e.g., `forum.example.com`) |
| `PHX_SERVER` | Enable the HTTP server in releases | Set to `"true"` |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listening port |
| `POOL_SIZE` | `10` | Database connection pool size |
| `ECTO_IPV6` | unset | Set to `"true"` to enable IPv6 for database connections |
| `DATABASE_SSL` | `"true"` | Set to `"false"` to disable SSL for database connections |
| `DNS_CLUSTER_QUERY` | unset | DNS SRV record for Erlang clustering (e.g., `"baudrate.example.com"`) |

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

## Assets & Static Files

### Production asset build

Before deploying to production, compile and digest assets:

```bash
mix assets.deploy
```

This runs Tailwind (minified) + esbuild (minified) + `phx.digest` to
generate fingerprinted files and `priv/static/cache_manifest.json`.

**Symptom of missing asset build:** Pages load without CSS styling, or
JavaScript doesn't execute.

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

User-uploaded files (avatars, article images, attachments) are stored in
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

HTTP Signatures include a `Date` header validated within **+/-30 seconds**.
If your server's clock is off, all incoming federation requests will be
rejected with signature verification failures.

**Fix:** Ensure NTP is configured and running:

```bash
timedatectl status        # Check current time sync
sudo systemctl enable ntp # Enable NTP
```

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

The `DeliveryWorker` polls the `delivery_jobs` table every 60 seconds,
processing up to 50 jobs per cycle.

**Backoff schedule for failed deliveries:**

| Attempt | Retry after |
|---------|-------------|
| 1 | 60 seconds |
| 2 | 5 minutes |
| 3 | 30 minutes |
| 4 | 2 hours |
| 5 | 12 hours |
| 6 | 24 hours |
| 7+ | Abandoned |

After 6 failed attempts, jobs are marked as abandoned. You can retry
abandoned jobs from the admin federation dashboard (`/admin/federation`).

**Symptom of stuck delivery:** Check the federation dashboard for jobs in
`failed` or `pending` state. Common causes:

- Remote instance is down (will retry automatically)
- Clock skew causing signature rejection (fix NTP)
- Domain is blocked by the remote instance
- DNS resolution failure

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

Domains in `ap_domain_blocklist` are:

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

1. **Clock skew** — TOTP is time-based. Ensure both server and user's device
   have accurate time (NTP on server, auto time on device)
2. **SECRET_KEY_BASE changed** — TOTP secrets are encrypted with a key
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

### Not distributed

The Hammer ETS backend is **node-local**. In a multi-node cluster, each node
has its own rate-limit counters. This means:

- Effective rate limits are multiplied by the number of nodes
- An attacker could distribute requests across nodes to bypass limits

For production clusters, consider switching to a distributed rate-limit
backend (e.g., Redis).

### RealIp plug required in production

Without the `RealIp` plug correctly configured, all requests appear to come
from the reverse proxy's IP address. This means:

- A single IP-based rate-limit bucket for all users
- Rate limits trigger for everyone after a few requests

See [Reverse Proxy](#reverse-proxy) for configuration.

---

## Clustering

### PubSub

Phoenix PubSub (`Baudrate.PubSub`) is used for real-time LiveView updates.
In a single-node deployment, the default `Phoenix.PubSub.PG2` adapter works
out of the box.

For multi-node deployments, ensure nodes can discover each other via
`DNS_CLUSTER_QUERY`:

```bash
export DNS_CLUSTER_QUERY="baudrate.example.com"
```

### Background workers

The following GenServers run on **every node** in the cluster:

| Worker | Interval | Purpose |
|--------|----------|---------|
| `SessionCleaner` | 1 hour | Purge expired sessions, old login attempts, orphan images |
| `DeliveryWorker` | 60 seconds | Poll and deliver pending federation jobs |
| `StaleActorCleaner` | 24 hours | Refresh or delete stale remote actors |

In a multi-node cluster, these workers run independently on each node. This
is generally safe (database operations are idempotent), but may result in
slightly redundant work.

### Hammer not distributed

As noted in [Rate Limiting](#rate-limiting), Hammer uses a node-local ETS
backend. Rate-limit state is not shared across nodes.
