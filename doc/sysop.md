# SysOp Guide

Operational guide for installing, configuring, and maintaining a Baudrate
instance.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [First-Run Setup](#first-run-setup)
- [Environment Variables](#environment-variables)
- [Site Settings](#site-settings)
- [User Management](#user-management)
- [Board Management](#board-management)
- [Moderation](#moderation)
- [Federation](#federation)
- [Security](#security)
- [Deployment](#deployment)
- [Maintenance](#maintenance)
- [Clustering](#clustering)
- [Admin Routes](#admin-routes)

---

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| Elixir | 1.15+ | Application runtime |
| Erlang/OTP | 26+ | VM |
| PostgreSQL | 15+ | Database (requires `pg_trgm` extension) |
| libvips | any | Avatar and image processing |
| Rust toolchain | stable | HTML sanitizer NIF (Ammonia via Rustler) |

### Installing build dependencies

```bash
# Debian/Ubuntu
sudo apt install libvips-dev

# macOS
brew install vips

# Alpine
apk add vips-dev

# Rust (all platforms — https://rustup.rs)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### PostgreSQL extension

The `pg_trgm` extension is required for full-text search (CJK support).
Migrations create it automatically, but the database user needs the
`CREATE EXTENSION` privilege, or a superuser must pre-install it:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

---

## Installation

```bash
git clone <repository-url>
cd baudrate
mix setup          # Install deps, create DB, run migrations, build assets
mix phx.gen.cert   # Generate self-signed cert for HTTPS (dev only)
mix phx.server     # Start server (https://localhost:4001 in dev)
```

For production, build and digest assets before starting:

```bash
mix assets.deploy  # Minify CSS/JS + fingerprint for cache busting
```

---

## First-Run Setup

On first launch, all requests redirect to `/setup`. The setup wizard:

1. Creates the initial **admin account** (with password and optional TOTP)
2. Seeds **roles and permissions** (guest, user, moderator, admin)
3. Creates the **SysOp board** (protected system announcements board)
4. Sets the `setup_completed` flag

If setup is interrupted partway through, reset the database:

```bash
mix ecto.reset  # Drop, recreate, re-migrate
```

---

## Environment Variables

### Required (production)

| Variable | Description | How to generate |
|----------|-------------|-----------------|
| `DATABASE_URL` | PostgreSQL connection string | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Signing + encryption key derivation | `mix phx.gen.secret` |
| `PHX_HOST` | Public hostname for URL generation | Your domain (e.g., `forum.example.com`) |
| `PHX_SERVER` | Enable HTTP server in releases | Set to `"true"` |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listening port |
| `POOL_SIZE` | `10` | Database connection pool size |
| `ECTO_IPV6` | unset | Set to `"true"` for IPv6 database connections |
| `DATABASE_SSL` | `"true"` | Set to `"false"` for non-SSL local databases |
| `DNS_CLUSTER_QUERY` | unset | DNS SRV record for Erlang clustering |

### SECRET_KEY_BASE — critical warning

`SECRET_KEY_BASE` derives encryption keys for:

- **Session cookies** (signing + encryption)
- **TOTP secrets** (AES-256-GCM via TotpVault, salt: `"totp_encryption_key"`)
- **Federation private keys** (AES-256-GCM via KeyVault, salt: `"federation_key_encryption"`)

**Never change `SECRET_KEY_BASE` after deployment.** Changing it will:

1. Invalidate all existing sessions (users must re-login)
2. Make all TOTP secrets undecryptable (users locked out of 2FA)
3. Make all federation private keys undecryptable (federation breaks)

If you must change it: have all TOTP users re-enroll their authenticator apps,
and rotate all federation keys via the admin panel.

### PHX_HOST must match your public hostname

`PHX_HOST` generates all actor URIs, WebFinger responses, and outgoing activity
URLs. A mismatch causes WebFinger lookup failures, unresolvable actors, and
HTTP Signature verification errors.

---

## Site Settings

Configure at `/admin/settings`:

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `site_name` | string | (set at setup) | Display name in headers and NodeInfo |
| `registration_mode` | enum | `"approval_required"` | Registration policy (see [Registration Modes](#registration-modes)) |
| `eua` | markdown | (empty) | End User Agreement shown at registration |
| `ap_federation_enabled` | boolean | `"true"` | Federation kill switch |
| `ap_federation_mode` | enum | `"blocklist"` | `blocklist` or `allowlist` |
| `ap_domain_blocklist` | text | `""` | Comma-separated blocked domains |
| `ap_domain_allowlist` | text | `""` | Comma-separated allowed domains |
| `ap_authorized_fetch` | boolean | `"false"` | Require HTTP Signatures on AP GET requests |
| `ap_blocklist_audit_url` | string | `""` | External known-bad-actor list URL |

---

## User Management

### Roles & Permissions (RBAC)

| Role | Level | TOTP Required | Key Permissions |
|------|-------|---------------|-----------------|
| **admin** | 3 | Required | All permissions including user management, settings, federation |
| **moderator** | 2 | Required | Content moderation, report handling, user muting |
| **user** | 1 | Optional | Create content, edit own posts, manage profile |
| **guest** | 0 | Disabled | View public content only |

Higher roles inherit all lower role permissions. Permissions follow a
`scope.action` naming convention (e.g., `admin.manage_users`,
`user.create_content`).

### Managing Users (`/admin/users`)

- **Search & filter** by username and status (active/pending/banned)
- **Change roles** — assign any role to any user
- **Ban/Unban** — banning invalidates all existing sessions immediately
- **Self-protection** — admins cannot ban themselves or change their own role

### Registration Modes

Configure `registration_mode` at `/admin/settings`:

| Mode | Behavior |
|------|----------|
| `approval_required` (default) | New users get `pending` status — can browse but cannot post until approved |
| `open` | New users are `active` immediately |
| `invite_only` | Requires a valid invite code; invited users are `active` immediately |

Approve pending users at `/admin/pending-users`.

Registration requires accepting terms: a system activity-logging notice (always
shown) and an optional site-specific End User Agreement (configurable at
`/admin/settings`, stored as markdown).

### Invite Codes (`/admin/invites`)

- Generate single-use or multi-use invite codes
- Set optional expiration time
- Track who created and who used each code
- Revoke active codes at any time

### Login Monitoring (`/admin/login-attempts`)

All login attempts (success and failure) are recorded and viewable at
`/admin/login-attempts` (paginated, filterable by username). Records older
than 7 days are purged hourly by `SessionCleaner`.

Failed logins trigger **progressive per-account delays** (not hard lockout):

| Failures (1-hour window) | Delay |
|--------------------------|-------|
| 0-4 | None |
| 5-9 | 5 seconds |
| 10-14 | 30 seconds |
| 15+ | 120 seconds |

Progressive delay avoids the DoS vector of an attacker deliberately locking
out accounts by submitting wrong passwords.

### Password Reset

Users reset passwords at `/password-reset` using **recovery codes** (10 issued
at registration). There is no email-based recovery — users must save their
recovery codes when displayed. Each code can only be used once.

### TOTP Two-Factor Authentication

- **Required** for admin and moderator roles (must enroll before first login
  completes)
- **Optional** for user role (enable at `/profile`)
- **Disabled** for guest role
- Secrets encrypted at rest with AES-256-GCM (key derived from
  `SECRET_KEY_BASE`)
- Recovery codes: 10 per user, HMAC-SHA256 hashed, one-time use
- Clock skew tolerance: ±30 seconds (NTP synchronization is critical)
- Users can reset their own TOTP at `/profile/totp-reset`
- If `SECRET_KEY_BASE` changes, all TOTP secrets become unrecoverable — users
  must use recovery codes and re-enroll

---

## Board Management

### Creating & Configuring Boards (`/admin/boards`)

- **Name & description** — display text and optional markdown description
- **Slug** — URL-safe identifier (immutable after creation)
- **Parent board** — hierarchical nesting up to 10 levels deep
- **Permissions** — minimum role to view and to post (see below)
- **Federation toggle** — `ap_enabled` enables/disables AP endpoints per board

### Board Permissions

| Field | Values | Default | Purpose |
|-------|--------|---------|---------|
| `min_role_to_view` | guest, user, moderator, admin | guest | Minimum role to see the board |
| `min_role_to_post` | user, moderator, admin | user | Minimum role to create articles |

Only boards with `min_role_to_view == "guest"` and `ap_enabled == true` are
federated. Private boards (non-guest view) are hidden from all AP endpoints
(actor, outbox, inbox, WebFinger).

### Board Moderators

Assign per-board moderators at `/admin/boards` -> "Moderators" button:

- **Pin/Unpin** articles
- **Lock/Unlock** threads (disable new comments)
- **Delete** articles and comments (soft-delete)
- **Cannot** edit others' articles (only the author and admin can edit)

Users with admin or moderator role are automatically treated as moderators of
all boards. All moderator actions are logged in the moderation log.

### SysOp Board

The `sysop` board is a protected system board:

- **Created automatically** during first-run setup (position 0, always listed
  first)
- **Cannot be deleted** — deletion returns an error
- **Mute exemption** — admin articles in the SysOp board are always visible,
  even if the viewing user has muted the admin
- **Purpose** — system announcements that must be seen by all users

---

## Moderation

### Report Queue (`/admin/moderation`)

- View open reports targeting articles, comments, or remote actors
- **Resolve** — mark resolved with optional notes (logged)
- **Dismiss** — mark dismissed, no action taken (logged)
- **Delete** reported content directly from the queue (soft-delete, logged)
- **Flag** — send AP `Flag` activity to remote instances for remote content

### Moderation Log (`/admin/moderation-log`)

Immutable audit trail of all administrative actions:

- User bans/unbans, role changes, approvals
- Report resolution/dismissal
- Content deletions (articles, comments)
- Board CRUD operations
- Domain blocking/unblocking
- Federation key rotations
- Board moderator assignments

Filterable by action type, paginated (25 per page).

### User Blocks & Mutes

**Blocks** prevent all interaction and are communicated to remote instances via
`Block` / `Undo(Block)` activities. Blocked users' content is hidden from
article listings, comments, and search results.

**Mutes** are a lighter, purely local action — hidden from the muter's view
without preventing interaction or sending any federation activity. DM
conversations with muted users are visually de-emphasized rather than hidden.

Both blocks and mutes support local users and remote actors.

---

## Federation

### Enabling / Disabling

**Instance-level kill switch** (`ap_federation_enabled` at `/admin/settings`):

- When disabled: all `/ap/*` endpoints return 404, delivery worker skips jobs
- WebFinger and NodeInfo remain available for discovery
- Also togglable from `/admin/federation`

**Per-board toggle** (`ap_enabled` on each board at `/admin/boards`):

- When disabled: board AP endpoints return 404, delivery skips board followers
- WebFinger excludes the board

### Federation Modes

| Mode | Behavior |
|------|----------|
| `blocklist` (default) | Accept all domains except those in `ap_domain_blocklist` |
| `allowlist` | Accept **only** domains in `ap_domain_allowlist`; empty list blocks all |

Domain filtering applies to both inbound (inbox) and outbound (delivery).
Comparison is case-insensitive. Configure at `/admin/settings`.

### Domain Blocklist / Allowlist

Configure at `/admin/settings` (comma-separated domains) or one-click block
from the federation dashboard (`/admin/federation`).

Blocked domains:
- **Inbound**: activities are accepted (202) but silently dropped
- **Outbound**: delivery jobs are abandoned with reason `"domain_blocked"`

### Authorized Fetch

Optional "secure mode" requiring HTTP Signatures on GET requests to `/ap/*`
endpoints. Toggle at `/admin/settings` -> `ap_authorized_fetch`.

- When enabled: unsigned GET requests return 401 Unauthorized
- WebFinger and NodeInfo remain publicly accessible (spec requirement)
- Outbound actor resolution automatically falls back to signed GET when remote
  instances require it

### Delivery Queue (`/admin/federation`)

The federation dashboard shows:

- **Known instances** — domains with delivery statistics and last contact time
- **Delivery queue** — pending, failed, delivered, and abandoned jobs
- **One-click domain blocking** from the instance list

**Retry schedule for failed deliveries:**

| Attempt | Retry after |
|---------|-------------|
| 1 | 60 seconds |
| 2 | 5 minutes |
| 3 | 30 minutes |
| 4 | 2 hours |
| 5 | 12 hours |
| 6 | 24 hours |
| 7+ | Abandoned |

Admin actions:
- **Retry** abandoned jobs
- **Abandon** pending/failed jobs
- **Abandon all for domain** (useful for unresponsive instances)

Job deduplication: a partial unique index on `(inbox_url, actor_uri)` for
pending/failed jobs prevents duplicate deliveries on retry or race conditions.

### Key Rotation

Actor RSA keypairs (users, boards, site) can be rotated from the federation
dashboard (`/admin/federation`):

- **Site keys**: "Rotate Site Keys" button
- **Board keys**: "Rotate Keys" per board
- New public keys are distributed to followers via `Update` activities
- All rotations are recorded in the moderation log

### Blocklist Audit

Compare your local blocklist against external known-bad-actor lists:

1. Set `ap_blocklist_audit_url` in `/admin/settings` to the external list URL
2. Use the "Audit" feature on `/admin/federation`
3. View: external/local counts, overlap, missing domains
4. "Add" individual domains or "Add All" missing domains

Supported formats: JSON array, newline-separated, CSV (Mastodon export format).

### Stale Actor Cleanup

The `StaleActorCleaner` GenServer runs daily (configurable via
`stale_actor_cleanup_interval`, default 24h) and handles remote actors whose
`fetched_at` exceeds the max age (`stale_actor_max_age`, default 30 days):

- **Referenced actors** (with followers, articles, comments) -> refreshed
- **Unreferenced actors** -> deleted from the database
- Batched: 50 actors per cycle
- Skipped when federation is disabled

---

## Security

### SSL / HSTS

Production enforces HTTPS with HSTS:

```elixir
force_ssl: [hsts: true, subdomains: true, preload: true, expires: 63_072_000]
```

HSTS has a 2-year expiry. Once active, browsers refuse HTTP connections for
that duration. Ensure HTTPS is fully working before enabling HSTS preloading.

### Rate Limiting

| Endpoint | Limit | Scope |
|----------|-------|-------|
| Login | 10 / 5 min | per IP |
| Login | progressive delay (5s/30s/120s) | per account |
| TOTP verification | 15 / 5 min | per IP |
| Registration | 5 / hour | per IP |
| Password reset | 5 / hour | per IP |
| Avatar upload | 5 / hour | per user |
| AP endpoints | 120 / min | per IP |
| AP inbox | 60 / min | per remote domain |
| Feeds (RSS/Atom) | 30 / min | per IP |
| Direct messages | 20 / min | per user |

Rate limiting uses [Hammer](https://hexdocs.pm/hammer/) with an ETS backend
(node-local). In multi-node clusters, effective limits are multiplied by node
count. Consider a distributed backend (e.g., Redis) for production clusters.

Rate limiting **fails open** — backend errors allow requests through rather
than causing denial of service.

### Reverse Proxy (Nginx)

Baudrate runs plain HTTP behind a reverse proxy. TLS termination happens at
Nginx — **you do not need to configure HTTPS in Phoenix itself**. The
production endpoint already sets `url: [scheme: "https", port: 443]` and
`force_ssl: [rewrite_on: [:x_forwarded_proto]]`, so Phoenix generates correct
`https://` URLs and redirects HTTP→HTTPS based on the `X-Forwarded-Proto`
header from Nginx.

#### Full Nginx Configuration

```nginx
# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name forum.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name forum.example.com;

    # --- TLS ---
    ssl_certificate     /etc/letsencrypt/live/forum.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/forum.example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/forum.example.com/chain.pem;

    # --- Request limits ---
    client_max_body_size 16M;      # Match your upload size limit

    # --- Proxy to Phoenix ---
    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;

        # WebSocket support (required for LiveView)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Host and scheme forwarding
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;       # SET, not append
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts for long-lived WebSocket connections
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        # Disable buffering for LiveView streaming
        proxy_buffering off;
    }
}
```

Replace `forum.example.com` with your domain and adjust certificate paths to
match your TLS provider (Let's Encrypt, etc.).

#### Why This Matters

| Header / Setting | What breaks without it |
|------------------|------------------------|
| `X-Forwarded-For $remote_addr` | Rate limiting sees only the proxy's IP — all users share one limit |
| `X-Forwarded-Proto $scheme` | `force_ssl` can't detect HTTPS → infinite redirect loop |
| `Upgrade` + `Connection` | LiveView falls back to long-polling; real-time updates and form submissions break |
| `proxy_read_timeout 600s` | Nginx closes idle WebSocket connections after 60s default, causing LiveView disconnects |
| `proxy_buffering off` | LiveView streaming responses are delayed until the buffer fills |

#### Critical Security Notes

- **`X-Forwarded-For` must be SET, not appended.** Using `$proxy_add_x_forwarded_for`
  allows clients to spoof their IP by sending a fake `X-Forwarded-For` header,
  breaking rate limiting and IP-based security logging.
- **Bind Phoenix to localhost only** if Nginx and Phoenix run on the same
  machine. In `runtime.exs`, change `ip: {0, 0, 0, 0, 0, 0, 0, 0}` to
  `ip: {127, 0, 0, 1}` (IPv4) or `ip: {0, 0, 0, 0, 0, 0, 0, 1}` (IPv6
  loopback) to prevent direct access bypassing Nginx.

#### Obtaining TLS Certificates

Using [Let's Encrypt](https://letsencrypt.org/) with Certbot:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d forum.example.com
```

Certbot automatically configures Nginx and sets up auto-renewal via a systemd
timer. Verify renewal works: `sudo certbot renew --dry-run`.

### Session Security

| Aspect | Detail |
|--------|--------|
| Cookie | Signed + encrypted (separate salts), `SameSite=Lax`, `Secure` in production |
| TTL | 14 days from creation or last rotation |
| Rotation | Tokens rotated every 24 hours |
| Concurrency | Max 3 sessions per user; oldest evicted on 4th login |
| Banning | Invalidates all existing sessions immediately |

### Content Security

- **HTML sanitization** — all federated content sanitized via Ammonia (Rust NIF,
  allowlist-based) before database storage
- **SSRF protection** — DNS-pinned connections, reject private/loopback IPs,
  HTTPS-only for remote fetches
- **Content size limits** — 256 KB AP payload, 64 KB content body
- **File uploads** — magic byte validation, re-encoding as WebP (strips EXIF,
  destroys polyglots)
- **Non-image attachments** — forced download via `Content-Disposition: attachment`
- **CSP** — restrictive Content-Security-Policy, no eval
- **X-Frame-Options** — DENY

### Clock Synchronization

HTTP Signatures validate the `Date` header within ±30 seconds. If the server
clock drifts, all incoming federation requests will fail signature verification.

```bash
timedatectl status          # Check time sync status
sudo systemctl enable ntp   # Enable NTP
```

---

## Deployment

### Build Dependencies

Before deploying, ensure:

1. **Rust toolchain** installed (for HTML sanitizer NIF compilation)
2. **libvips** installed (for image processing)
3. **Node.js** not required (esbuild is fetched by Mix)

> **Important:** The build machine must match the target OS and CPU architecture,
> because the Ammonia HTML sanitizer NIF is compiled to native code via Rustler.
> Cross-compilation is not supported out of the box.

### Asset Build

```bash
MIX_ENV=prod mix assets.deploy   # Tailwind (minified) + esbuild (minified) + phx.digest
```

Generates fingerprinted files and `priv/static/cache_manifest.json`. Without
this step, pages load without CSS styling and JavaScript doesn't execute.

### Building a Release

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The release is written to `_build/prod/rel/baudrate/`. It includes the compiled
BEAM code, the Ammonia NIF `.so`, ERTS, and the overlay convenience scripts
(`bin/server`, `bin/migrate`).

### Uploads Directory

`priv/static/uploads/` stores avatars, article images, and attachments:

- Must be **writable** by the application process
- Must be **persistent** across deployments
- For containers: mount a persistent volume at this path
- In OTP releases, `priv/static/` is **read-only** — configure an external
  upload path outside the release directory for production

### Production Start

```bash
# With mix (development / staging)
PHX_SERVER=true mix phx.server

# With releases — convenience script
bin/server

# With releases — manual
PHX_SERVER=true bin/baudrate start
```

The endpoint binds to `{0, 0, 0, 0, 0, 0, 0, 0}` (all IPv6/IPv4 interfaces)
on the configured `PORT` (default 4000).

### Running Migrations in Production

```bash
# Convenience script (recommended)
bin/migrate

# Or via eval
bin/baudrate eval "Baudrate.Release.migrate"
```

To rollback a specific migration:

```bash
bin/baudrate eval "Baudrate.Release.rollback(Baudrate.Repo, 20260101000000)"
```

Replace `20260101000000` with the migration version to roll back to.

---

## Maintenance

### Background Workers

| Worker | Interval | Purpose |
|--------|----------|---------|
| `SessionCleaner` | 1 hour | Purge expired sessions, old login attempts (>7 days), orphan images (>24h) |
| `DeliveryWorker` | 60 seconds | Poll and deliver pending federation jobs (50 per cycle) |
| `StaleActorCleaner` | 24 hours | Refresh or delete stale remote actors (>30 days) |

In multi-node clusters, these run independently on each node. Operations are
idempotent (safe but slightly redundant).

### Delivery Job Purge

Completed delivery jobs are automatically purged:
- `delivered` jobs older than 7 days
- `abandoned` jobs older than 30 days

### Database Maintenance

```bash
mix ecto.migrate    # Run pending migrations
mix ecto.reset      # Drop + create + migrate (development only!)
```

Ensure the PostgreSQL `pg_trgm` extension is installed before migrations.
Increase `POOL_SIZE` if you see `DBConnection.ConnectionError` under load.

---

## Clustering

### Multi-Node Discovery

Configure DNS-based cluster discovery:

```bash
export DNS_CLUSTER_QUERY="baudrate.example.com"
```

PubSub (for LiveView real-time updates) works automatically once nodes
discover each other via `Phoenix.PubSub.PG2`.

### Limitations

- **Rate limiting** (Hammer ETS) is node-local — effective limits multiply by
  node count
- **Background workers** run on every node independently (idempotent, slightly
  redundant)
- Consider a distributed rate-limit backend (e.g., Redis) for production
  clusters

---

## Admin Routes

| Route | Purpose |
|-------|---------|
| `/admin/settings` | Site name, registration mode, federation settings |
| `/admin/users` | User management (search, ban/unban, role changes) |
| `/admin/pending-users` | Approve pending registrations |
| `/admin/boards` | Board CRUD, permissions, moderator assignment |
| `/admin/federation` | Delivery queue, known instances, domain blocking, key rotation |
| `/admin/moderation` | Report queue (resolve, dismiss, delete content) |
| `/admin/moderation-log` | Audit trail of all admin actions |
| `/admin/invites` | Invite code generation and revocation |
| `/admin/login-attempts` | Login attempt history (filterable, paginated) |

---

## Further Reading

- [Troubleshooting Guide](troubleshooting.md) — common issues and solutions
- [AP Endpoint API Reference](api.md) — ActivityPub and public API documentation
- [Development Guide](development.md) — architecture, project structure, implementation details
