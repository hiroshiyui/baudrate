# SysOp Guide

Operational guide for installing, configuring, and maintaining a Baudrate
(ActivityPub-enabled Bulletin Board System) instance.

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
- [PWA (Progressive Web App)](#pwa-progressive-web-app)
- [Deployment](#deployment)
- [Backup & Restore](#backup--restore)
- [Maintenance](#maintenance)
- [Scaling](#scaling)
- [Admin Routes](#admin-routes)

---

## Prerequisites

The deploy builds on the server, so a server needs all of these. A host that
installs a [release built in CI](#release-artifacts) by hand needs only
PostgreSQL, its client and the Debian 12 base system: the release carries its
own Erlang runtime and NIFs.

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

1. **Verifies the installation key** — required in production until setup completes
2. Creates the initial **admin account** (with password and optional TOTP)
3. Seeds **roles and permissions** (guest, user, moderator, admin)
4. Creates the **SysOp board** (protected system announcements board)
5. Sets the `setup_completed` flag

### Installation Key

The `INSTALLATION_KEY` environment variable gates access to the setup wizard.
Without it, anyone who discovers the `/setup` URL can complete setup and become
admin. **It is required in production until setup completes.**

- While setup is incomplete and no key is configured, the app answers **503 on
  every browser route** rather than serving an unguarded wizard. Set the key and
  restart to unlock it. (ActivityPub and health endpoints are unaffected.)
- The check is not a boot-time `raise`: `config/runtime.exs` runs before the
  database is available, so refusing to start there would let a transient
  database outage brick the instance on restart. Enforcement lives in
  `Baudrate.Setup.InstallationKey` and the `EnsureSetup` plug instead.
- When set, the wizard starts with a verification step before the database check
- The key is validated with constant-time comparison to prevent timing attacks
- After 3 failed attempts, the form locks for 30 seconds (brute-force protection)
- The gate is enforced in the `complete_setup` event handler, not just in the
  rendered step — a client speaking the LiveView protocol directly cannot skip
  ahead to admin creation
- `Setup.complete_setup/2` additionally refuses to run once setup is complete,
  so a wizard session left open during installation cannot mint a second admin
- Once setup is complete the lock lifts, so the key is no longer needed and can
  be removed. Removing it **before** the wizard finishes locks the instance

Set the key in your environment file or generate one during deployment:

```bash
# Generate a random key
openssl rand -base64 24

# Set in environment
export INSTALLATION_KEY="your-random-key-here"
```

The Ansible deploy playbook auto-generates this key if not configured in your
SOPS secrets file.

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
| `RELEASE_COOKIE` | This server's Erlang distribution cookie. A release refuses to start, and `remote`/`rpc` refuse to run, without one, or with the public cookie shipped in `releases/COOKIE` ([Erlang distribution](#erlang-distribution-and-the-remote-console)) | `head -c 48 /dev/urandom \| base64 \| tr -d '/+=\n'`; Ansible generates one per server |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listening port |
| `POOL_SIZE` | `10` | Database connection pool size |
| `ECTO_IPV6` | unset | Set to `"true"` for IPv6 database connections |
| `DATABASE_SSL` | `"true"` | Set to `"false"` for non-SSL local databases |
| `INSTALLATION_KEY` | unset | **Required until setup completes** — the app answers 503 without it. Safe to remove afterwards (see [Installation Key](#installation-key)) |
| `BAUDRATE_TRUSTED_PROXIES` | `127.0.0.1,::1` | Comma-separated IPs/CIDRs whose `x-forwarded-for` is believed. Set this when the reverse proxy is not on the same host — the client IP is otherwise taken from the peer address |
| `BAUDRATE_REAL_IP_HEADER` | `x-forwarded-for` | Header carrying the real client IP |
| `HEALTH_DETAIL_PORT` | unset (Ansible: `4001`) | Serves the [detailed health report](#detailed-health-report) on `127.0.0.1` at this port. Unset: no listener. Only the port is configurable, never the address |
| `BAUDRATE_BACKUP_DIR` | unset (Ansible: `/var/backups/baudrate/daily`) | Where nightly backups are written, for the report's backup check. Unset: that check is skipped |
| `LOG_FORMAT` | unset | `json` writes one JSON object per log line ([Logs](#logs)); anything else keeps the text format |

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
| `eua` | markdown | (empty) | Terms of service — shown at registration, published at `/terms` |
| `privacy_policy` | markdown | (empty) | Privacy policy, published at `/privacy` |
| `ap_federation_enabled` | boolean | `"true"` | Federation kill switch |
| `ap_federation_mode` | enum | `"blocklist"` | `blocklist` or `allowlist` |
| `ap_domain_allowlist` | text | `""` | Comma-separated allowed domains |
| `ap_authorized_fetch` | boolean | `"false"` | Require HTTP Signatures on AP GET requests |
| `ap_blocklist_audit_url` | string | `""` | External known-bad-actor list URL |
| `theme_light` | enum | `"aquaosx"` | DaisyUI theme for light mode (22 options; default "Mac OS X (Aqua)") |
| `theme_dark` | enum | `"aquaosxdark"` | DaisyUI theme for dark mode (15 options; default "Mac OS X (Aqua) Dark") |

The **Mac OS X (Aqua)** light theme (`aquaosx`) reproduces the Aqua look: glossy
gel buttons, the iconic blue "default" button with a soft focus glow, hairline
white "windows" (cards/modals/dropdowns) with soft drop shadows, rounded
segmented controls, and rounded blue-gel WebKit scrollbars. It uses the native
Apple UI font stack (no bundled webfont). It is the default light theme; any
other can be chosen under *Admin → Settings → Theme (light)*. Both its palette (the `aquaosx` DaisyUI theme block — named that
way because DaisyUI already ships a dark theme called `aqua`) and its glossy
chrome (the `[data-theme="aquaosx"]` layer) live in the standalone
`assets/css/themes/aquaosx.css`, which `assets/css/app.css` pulls in via
`@import` near the end of the file (Tailwind v4 inlines local imports in place,
keeping the chrome overrides late in the cascade).

Its dark-scheme sibling, **Mac OS X (Aqua) Dark** (`aquaosxdark`), keeps the same
gel chrome and Aqua-blue default button on graphite windows and dark input
wells. It is the default dark theme, so a fresh instance shows the matching Aqua
look whichever scheme the visitor's browser or the header toggle picks; any
other can be chosen under *Admin → Settings → Theme (dark)*. Instances that
already saved a theme choice keep it. It lives in `assets/css/themes/aquaosx-dark.css`;
the two files mirror each other rule for rule, so a chrome change in one should
be made in both.

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

### Policy Pages

Three admin-authored markdown documents, each edited in its own card at
`/admin/settings` and published on a public page any guest can read:

| Page | Setting | What belongs in it |
|------|---------|--------------------|
| `/terms` | `eua` | The agreement a member accepts when registering |
| `/rules` | *(`rules` table)* | What members may and may not do here — a numbered list, edited at `/admin/rules` |
| `/privacy` | `privacy_policy` | What the site records about visitors, and what happens to it |

The footer links the documents you have actually written, and nothing while
all three are empty — a link to a page saying "not published yet" is worse
than no link. The registration form keeps showing the terms inline and now
also links `/terms`, so a member can re-read afterwards what they agreed to.

#### Site Rules (`/admin/rules`)

The rules are a numbered list rather than one document, so a member reporting
something can point at the rule they say was broken — the `rule_violation`
report category could previously only say *that* a rule was broken, never
which. Each rule has a short title, an optional Markdown detail, and a stable
anchor (`/rules#rule-3`) you can link to.

Rules are **retired, not deleted**. A retired rule leaves `/rules` and the
report form, but every report that already cited it still names it; deleting
would quietly empty the citation on every past report. Retired rules are listed
at the bottom of the page and can be restored, which puts them back at the end.

Citing a rule is always optional, even for "Breaks a rule": a reporter who
cannot find the right number must still be able to report.

If you upgraded from a version where the rules were one document, that document
is now the first rule, titled "Site rules" — split it up when convenient.

Markdown is rendered through the same sanitizer and media proxy as any post,
so an image in a policy page is re-served locally rather than fetched by the
reader's browser from a third party. Editing a document takes effect at once;
each save is recorded in the moderation log (`update_eua`, `update_privacy`,
and `create_rule` / `update_rule` / `retire_rule` / `restore_rule` /
`reorder_rules` for the rules).

#### Publishing new terms

Saving the terms is a quiet edit. To require members to accept them again,
tick **"Require every member to accept again"** before saving. That increments
`eua_version` and is logged as `publish_terms_version`.

Every member then sees a banner until they accept on `/terms`, and **posting
and interacting are paused** — creating articles and comments, liking,
boosting, forwarding, voting, following, direct messages and invites all
return "The terms have changed."

What a pause deliberately does *not* stop (ADR 0031):

- **reading** anything, including the terms themselves;
- undoing an earlier like or boost, and deleting their own content;
- **reporting abuse** — a member who cannot report cannot ask for help;
- anything about account security: password, second factors, sessions, export.
- **bot accounts.** A bot cannot sign in to accept, and its posts go through
  the same gate, so bots are exempt and RSS feeds keep running.

Staff are paused like everyone else, though administration itself is not
affected. Leave the box unticked for a typo or a reworded sentence: if every
save prompts the whole instance, the prompt stops meaning anything.

Upgrading to this version stamps existing accounts as having accepted version
0, so nobody is prompted by the upgrade itself — only by your first deliberate
publication.

### Invite Codes (`/admin/invites`)

- Generate single-use or multi-use invite codes
- Set optional expiration time
- Track who created and who used each code
- Revoke active codes at any time
- **Generate on behalf of a user** — admins can issue invite codes attributed
  to any user, bypassing the 7-day account age restriction. The user's rolling
  30-day quota (max 5 codes) is still enforced. The generated code's "Created
  By" shows the target user, so the user can share it immediately.

### Login Monitoring (`/admin/login-attempts`)

All login attempts (success and failure) are recorded and viewable at
`/admin/login-attempts` (paginated, filterable by username). Records older
than 7 days are purged hourly by `SessionCleaner`.

The **Check** column shows what each attempt was for:

| Check | Meaning |
|-------|---------|
| Password | The password step of login, or a password reset |
| Two-factor code | The TOTP step of login. It is only reached with the **correct password**, so a run of failures here means someone else knows that password. The user is notified after 3 in an hour |
| Re-authentication | Password plus code entered from a signed-in session (password change, security keys, data export) |

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
- Codes are accepted for the current 30-second period and for 30 seconds after
  they roll over. A code from a device clock running ahead is not accepted, so
  keep the server on NTP
- Each code works **once** per account: a code that signed in or confirmed an
  action is refused if entered again, even within its 30 seconds (ADR 0024).
  Users who need two checks in a row wait for the next code
- Failed codes at login count toward the account's login throttle, and after 3
  in an hour the user gets a security notice to change their password
- Users can reset their own TOTP at `/profile/totp-reset`
- `users.totp_enabled_at` records when TOTP was enabled; accounts that already
  had TOTP when that column was added are stamped with the upgrade time. Features that refuse
  a freshly enrolled factor (data export needs 7 days) count from there.
- Signed-in users can change their password at `/profile/password` and sign out
  every other session from `/profile` → Sessions. Both require the password (plus
  TOTP when enabled), close the other sessions' open pages immediately, and send
  a security notice that cannot be turned off.
- If `SECRET_KEY_BASE` changes, all TOTP secrets become unrecoverable — users
  must use recovery codes and re-enroll

### WebAuthn / FIDO2 Hardware Security Keys

Users can register FIDO2-compatible hardware security keys (e.g. YubiKey,
Passkey, Touch ID) as an additional second factor at `/profile`.

- **Registration** — at `/profile` → "Security Keys" section. The user first
  confirms their identity (password, plus the current TOTP code if TOTP is
  enabled), which unlocks "Register New Key" and "Remove" for 5 minutes.
  Without this, a stolen session cookie could enrol a key and use it to pass
  admin sudo mode. Failed confirmations count as failed logins toward the
  account throttle and appear in the login-attempt log.
- **Admin sudo mode** — at `/admin/verify` admins can choose TOTP or a registered
  security key; both grant the same 10-minute sudo window
- **Multiple keys** — users may register as many keys as they like; each has a
  user-defined label, last-used timestamp, and sign count (clone detection)
- **Credential storage** — credential ID and public key are stored in the
  `webauthn_credentials` table; credentials are deleted with the user (cascade)
- **Challenges** — single-use, 60-second ETS-backed challenge store
  (`WebAuthnChallenges` GenServer); challenges are consumed atomically and are
  bound to their purpose (a challenge issued for sudo verification cannot
  register a key)
- **Sign count** — incremented on each successful authentication to detect
  cloned authenticators (a lower count than expected triggers an error)
- **No user-verification enforcement** — `user_verification: :preferred`; the
  relying party does not mandate PIN/biometric, but the authenticator may require it

#### Configuration (wax_)

`config :wax_` values must match your deployment:

| Key | Value |
|-----|-------|
| `origin` | Full origin including scheme and port, e.g. `"https://forum.example.com"` |
| `rp_id` | eTLD+1 of your domain, e.g. `"example.com"` |
| `attestation` | `:none` (no attestation verification required) |
| `user_presence` | `true` |
| `user_verification` | `:preferred` |

`origin` and `rp_id` are read from `runtime.exs` and default to the value of
`PHX_HOST`. They must match `window.location.origin` as seen by the browser —
a mismatch causes all WebAuthn operations to fail with a client-side error.

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

- View open reports targeting articles, comments, local users, remote
  accounts, feed items, or direct messages
- A reported direct message shows a copy of that one message, taken when it
  was reported. The rest of the conversation is never shown, and the copy
  stays even if the sender deletes the message
- **Resolve** — mark resolved with optional notes (logged)
- **Dismiss** — mark dismissed, no action taken (logged)
- **Delete** reported content directly from the queue (soft-delete, logged)
- **Flag** — send AP `Flag` activity to remote instances for remote content.
  Available when the report names remote content, a remote account, or a
  message from one (its remote author is recorded as the reported actor). Reports that arrive from other instances
  show "Reported from <domain> by <actor>"; before v1.18.2 they were stored
  with the reporter in the reported-actor field, and the upgrade migration
  moves those rows.

### Moderation Log (`/admin/moderation-log`)

Immutable audit trail of all administrative actions:

- User bans/unbans, role changes, approvals, refused registrations
- Warnings, silences, suspensions and lifted restrictions
- Report resolution/dismissal, and Flags sent to remote instances
- Content deletions (articles, comments), removing an article from a board,
  pin/lock changes, and admins editing other users' articles
- Board CRUD operations, board federation toggles, board accept policy changes
- Domain blocks from the Federation dashboard, and every settings save (the
  entry lists the changed keys and the domains added to or removed from the
  blocklist/allowlist)
- End User Agreement edits and push (VAPID) key generation
- Federation key rotations
- Board moderator assignments
- Bot create/update/delete/toggle, error resets and favicon refreshes

Before v1.18.2, pin/lock changes and bot actions were silently not recorded.

Filterable by action type, paginated (25 per page).

### Acting on an account

Four things can be done to an account, in order of severity. All but a ban are
rows in the `sanctions` table with an explicit end, so each one has an author,
a reason and a date, and the account's whole history is one query on
`/admin/users/:id`.

| Action | Effect | Who | Duration |
|--------|--------|-----|----------|
| **Warn** | A notice to the member and a log entry. Nothing is refused | `moderator.sanction_user` | — |
| **Silence** | Read-only: no posts, comments, likes, boosts, forwards, votes, follows, DMs, invites, or changes to the public parts of their profile | `moderator.sanction_user` | optional |
| **Suspend** | Cannot sign in. Sessions are revoked and data exports and account moves cancelled. Invite codes are left alone — they expire in seven days | `moderator.sanction_user` | **required** |
| **Ban** | Permanent | `admin.manage_users` | permanent |

A global moderator may issue any of the three sanctions for **at most 30
days**; an admin has no cap and can silence indefinitely. Nobody can sanction
themselves, and nobody can sanction an account at or above their own role
level, whatever the permissions are configured to be.

**Restrictions end by the clock, not by a job.** A silence set to end on
Friday stops on Friday even if the hourly cleanup has not run for a week; the
cleanup only delivers the "it has ended" notice.

**Issuing only ever extends.** Adding a second silence while one is active
leaves the account restricted until the later of the two. To shorten or cancel
one, **lift** it — which clears every active restriction of that kind and
records who lifted it and why.

**A sanction does not touch existing content.** Removing a post is a separate,
per-item decision made from the report queue, where it leaves evidence.

The member is always told: an in-app notice they cannot switch off, a message
explaining the refusal when they try to act, and a banner on every page while
the restriction stands.

**Refusing a registration** (`/admin/pending-users`) records a ban with a
reason on an account that never became active; it appears in the log as
"Refuse Registration". Approving a registration is an admin decision;
refusing one can be done by a global moderator.

### User Blocks & Mutes

These are **member** tools, not staff ones.

**Blocks** stop interaction in both directions between the two accounts, on
this site only. No `Block` activity is ever sent to remote instances — a block
is a local decision and telling the other server gains nothing. Blocking
removes follows in both directions. Content stays publicly visible: a block
controls interaction, not visibility.

**Mutes** are lighter still — content is hidden from the muter's view without
preventing interaction. DM conversations with muted users are visually
de-emphasized rather than hidden.

Both blocks and mutes support local users and remote actors.

---

## Federation

### Enabling / Disabling

**Instance-level kill switch** (`ap_federation_enabled` at `/admin/settings`):

- When disabled: all `/ap/*` endpoints return 404, delivery worker skips jobs
- WebFinger and NodeInfo remain available for discovery
- Also togglable from `/admin/federation`

**Instance actor**: Baudrate publishes an Organization actor at `/ap/site`
representing the instance in the ActivityPub federation. It is discoverable
via WebFinger as `acct:site@<your-domain>` and is used for instance-level
signed fetches (authorized fetch mode). Its keypair is managed alongside
user and board keypairs (see [Key Rotation](#key-rotation)).

**Per-board toggle** (`ap_enabled` on each board at `/admin/boards`):

- When disabled: board AP endpoints return 404, delivery skips board followers
- WebFinger excludes the board

### Federation Modes

| Mode | Behavior |
|------|----------|
| `blocklist` (default) | Accept all domains except those with a row in `domain_blocks` |
| `allowlist` | Accept **only** domains in `ap_domain_allowlist`; empty list blocks all |

Domain filtering applies to both inbound (inbox) and outbound (delivery).
Comparison is case-insensitive. The mode and the allowlist are set at
`/admin/settings`; blocked domains are managed at `/admin/federation`, where
each block records who made it, when, and why, and can be lifted again
(ADR 0030). Both lists are cached in ETS for high-throughput lookups and
refreshed automatically whenever a block or a setting is written.

### Blocking an Instance

Block and unblock at `/admin/federation`. Both take a reason and both are
written to the moderation log. A block is a row in `domain_blocks` carrying the
reason, an optional public comment, and the admin who made it — see
[ADR 0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) for why
it is not a setting.

Blocking a domain:

- **Inbound**: activities are accepted (202) but dropped. Signature
  verification does not even complete, because resolving the actor behind the
  signature refuses the domain — so the instance gains no `remote_actors` row.
- **Outbound**: delivery jobs are abandoned with reason `"domain_blocked"`, and
  we stop fetching from the domain entirely: its actors, its objects, its reply
  chains, and its images through the media proxy.
- **Follows** in both directions are deleted, for every actor on the domain.
  Nothing is sent — delivery to the domain is refused by our own gate. Follows
  are **not** restored by unblocking.
- **Existing content** — its articles, comments and feed items — is hidden
  everywhere a guest or member can look, and stops being served over
  ActivityPub. It is **not deleted**.

Unblocking restores the hidden content by itself: hiding is computed when a
page is rendered, not stamped on the rows, so there is no repair step.

Staff surfaces deliberately keep showing hidden content — the moderation queue,
report details and the instance page. Moderators cannot judge what they cannot
see, and a block is often applied before the content has been reviewed.

### Suspending One Remote Account

Blocking a whole instance over one account takes every innocent account on it
with it. To suspend just the one, open `/admin/federation`, follow the domain
to its instance page, and suspend the account there with a reason. A report
about a remote account links straight to that page.

A suspended account's activities are refused at the inbox and its content is
hidden, exactly as a domain block would do, and lifting the suspension brings
it back. Nothing is deleted.

### Allowlist Mode

Set `ap_federation_mode` to `allowlist` and list the allowed domains in
`ap_domain_allowlist` at `/admin/settings`. An empty allowlist blocks
everything. Content from a domain that is not allowed is hidden the same way a
blocked domain's content is.

### Authorized Fetch

Optional "secure mode" requiring HTTP Signatures on GET requests to `/ap/*`
endpoints. Toggle at `/admin/settings` -> `ap_authorized_fetch`.

- When enabled: unsigned GET requests return 401 Unauthorized
- WebFinger and NodeInfo remain publicly accessible (spec requirement)
- Outbound actor resolution automatically falls back to signed GET when remote
  instances require it

### Delivery Queue (`/admin/federation`)

The federation dashboard shows:

- **Known instances** — domains with delivery statistics and last contact time,
  each linking to an instance page listing the accounts we know there
- **Blocked instances** — with the reason, the admin who blocked it, and an
  unblock control
- **Delivery queue** — pending, failed, delivered, and abandoned jobs

**When a delivery is sent.** Posts, comments, likes, follows and direct
messages write their delivery jobs in the same database transaction as the
change itself, so a restart can never save a post and lose its activities
([ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)).
The `DeliveryWorker` is woken by a PostgreSQL notification when that transaction
commits, and starts sending within moments. It keeps up to 10 deliveries in
flight (`delivery_max_concurrency`). A delivery still running 15 seconds after
the 60-second HTTP deadline is stopped and counts as a failed attempt.
`Accept` and `Reject` answers to remote follow requests go through the same
queue.

**Retry schedule for failed deliveries:**

| Failed attempt | Next try |
|----------------|----------|
| 1 | after 60 seconds |
| 2 | after 5 minutes |
| 3 | after 30 minutes |
| 4 | after 2 hours |
| 5 | after 12 hours |
| 6 | abandoned |

A final `4xx` response (anything but `401`, `408` and `429`) abandons the job
at once: the remote server has said a retry cannot succeed.

**Instances that are down.** Every result is also counted against the inbox's
domain (the `delivery_circuits` table). After 5 consecutive failures that say
the server is unreachable (connection errors, timeouts, `5xx`, `429`), the
domain's circuit opens. None of its jobs is attempted until the wait ends,
and then a single job is sent as a probe. A failed probe waits longer before
the next one: 5 minutes, 30 minutes, 2 hours, 6 hours, 12 hours, then every
24 hours. The first response that shows the server is up closes the circuit,
and the jobs held back go out. Held jobs keep their attempts, so any job still
waiting 7 days after it was queued is abandoned (`delivery_max_age`). The log
shows `federation.delivery_circuit_open` and
`federation.delivery_circuit_closed`. To list the open circuits:

```sql
SELECT domain, failures, trips, open_until, last_error
FROM delivery_circuits WHERE trips > 0 ORDER BY open_until;
```

Admin actions:
- **Retry** abandoned jobs
- **Abandon** pending/failed jobs
- **Abandon all for domain** (useful for unresponsive instances)

Job deduplication: a partial unique index on `(inbox_url, actor_uri,
activity_id)` for pending/failed jobs queues the same activity once per inbox.
Up to v1.17.0 the index omitted `activity_id`, so while one job for an inbox was
pending or retrying, later activities from the same actor to that inbox were
silently dropped (for example during a remote instance's outage).

### Inbound Queue

Inboxes answer quickly and do the work afterwards
([ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)).
Each request's signature is verified, it is rate-limited per domain and capped
at 256 KB, and the activity passes the admission checks: well-formed, from a
domain that is not blocked and an account that is not suspended, signed by the
actor it names. Then it is stored in `inbound_activities` and answered `202`.
A redelivery of an activity already stored is answered the same way and
dropped.

`InboundWorker` processes stored activities, at most 4 at a time
(`inbound_max_concurrency`, kept below `POOL_SIZE`) and one at a time per
remote account, in the order they arrived. The domain and suspension checks
run again at that point, so a block takes effect for activities that are
already queued.

| Status | Meaning |
|--------|---------|
| `pending` | Waiting, or being processed |
| `processed` | Handled |
| `rejected` | Refused by the handler; `last_error` says why (for example `:not_found` for a follow of an account that does not exist) |
| `failed` | Crashed or ran past 5 minutes on all 3 attempts (`inbound_max_attempts`); logged as `federation.inbound_failed` |

The stored JSON is cleared as soon as an activity leaves `pending`, since it
can be a direct message. Finished rows are deleted after 7 days. The backlog
is `SELECT count(*) FROM inbound_activities WHERE status = 'pending';`.

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

- **Referenced actors** -> refreshed
- **Unreferenced actors** -> deleted from the database
- Batched: 50 actors per cycle
- Skipped when federation is disabled

"Referenced" means *anything in the database still points at the actor*, read
from the database catalog rather than from a list in the code. Deleting an
actor cascades, so an incomplete list loses real data: before v1.21.0 only six
of the nineteen foreign keys were checked, and an account that had gone quiet
for a month took its followers' follows and feed items with it when it was
swept.

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
| Password reset | progressive delay (5s/30s/120s) | per account |
| Article creation | 10 / 15 min | per user |
| Article update | 20 / 5 min | per user |
| Comment creation | 30 / 5 min | per user |
| Content deletion | 20 / 5 min | per user |
| User muting | 10 / 5 min | per user |
| Search (authenticated) | 15 / min | per user |
| Search (guest) | 10 / min | per IP |
| Avatar upload | 5 / hour | per user |
| LiveView mount | 60 / min | per IP |
| AP endpoints | 120 / min | per IP |
| AP inbox | 60 / min | per remote domain |
| Feeds (RSS/Atom) | 30 / min | per IP |
| Data export download | 10 / 15 min | per IP |
| Direct messages | 20 / min | per user |
| Feed item replies | 20 / 5 min | per user |

Per-user rate limits are managed by `BaudrateWeb.RateLimits`. Admin users are
exempt from per-user content rate limits (their actions are already audit-logged).

Rate limiting uses [Hammer](https://hexdocs.pm/hammer/) with an ETS backend:
the counters live in the node's memory and start from zero after a restart.
Because Baudrate runs on one node ([Scaling](#scaling)), they are complete.

Rate limiting **fails open** — backend errors allow requests through rather
than causing denial of service.

### Reverse Proxy (Nginx)

Baudrate runs plain HTTP behind a reverse proxy. TLS termination happens at
Nginx — **you do not need to configure HTTPS in Phoenix itself**. The
production endpoint already sets `url: [scheme: "https", port: 443]` and
`force_ssl: [rewrite_on: [:x_forwarded_proto]]`, so Phoenix generates correct
`https://` URLs and redirects HTTP→HTTPS based on the `X-Forwarded-Proto`
header from Nginx.

#### Configuration

A complete nginx configuration is provided at
[`doc/examples/nginx.conf.example`](examples/nginx.conf.example). It includes:

- HTTP → HTTPS redirect with ACME challenge passthrough
- TLS 1.2/1.3 (Mozilla Intermediate profile) with OCSP stapling
- Security headers (HSTS, nosniff, DENY framing, referrer policy)
- Gzip compression for HTML, CSS, JS, JSON, and ActivityPub payloads
- LiveView WebSocket proxy (`/live/websocket`) with 24h timeouts
- **Direct static asset serving** — fingerprinted assets (`/assets/`) with
  1-year immutable cache; uploads and other static files with 1-hour cache.
  Served directly by nginx, bypassing the BEAM for better performance.
- Upstream keepalive connections to Phoenix
- Reverse proxy to Phoenix on port 4000
- **Data export downloads** (`/exports/`) — unbuffered, never written to a
  temp file, never retried or cached. Without this location nginx would buffer
  a user's data archive to its own disk. Keep it when you customise the
  config.
- **Near-zero downtime deploys** — `proxy_next_upstream` retries on 502 during
  restarts (up to 30s, 3 attempts); custom 502 maintenance page as fallback

To use it:

```bash
cp doc/examples/nginx.conf.example /etc/nginx/sites-available/baudrate
# Edit: replace "baudrate.example" with your domain,
#        replace "/path/to/baudrate" with your deployment path
ln -s /etc/nginx/sites-available/baudrate /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

#### Why This Matters

| Header / Setting | What breaks without it |
|------------------|------------------------|
| `X-Forwarded-For $remote_addr` | Rate limiting sees only the proxy's IP — all users share one limit |
| `X-Forwarded-Proto $scheme` | `force_ssl` can't detect HTTPS → infinite redirect loop |
| `Upgrade` + `Connection` | LiveView falls back to long-polling; real-time updates and form submissions break |
| `proxy_read_timeout 600s` | Nginx closes idle WebSocket connections after 60s default, causing LiveView disconnects |
| `proxy_next_upstream` | Without retry, users see raw 502 errors during deploys instead of a brief wait |

#### Critical Security Notes

- **`X-Forwarded-For` must be SET, not appended.** Using `$proxy_add_x_forwarded_for`
  allows clients to spoof their IP by sending a fake `X-Forwarded-For` header,
  breaking rate limiting and IP-based security logging.
- **`trusted_proxies` allow-list — fail closed.** `BaudrateWeb.Plugs.RealIp`
  honors the configured forwarded-IP header **only** when the immediate peer
  matches an entry in `trusted_proxies` (exact IPs or CIDR ranges). There is no
  trust-everything mode:

  - unconfigured defaults to `["127.0.0.1", "::1"]` — sufficient when Nginx and
    Phoenix run on the same host;
  - an explicitly empty list trusts nobody.

  If the proxy is on a different host or in a private subnet, set the runtime
  environment variable:

  ```bash
  BAUDRATE_TRUSTED_PROXIES="127.0.0.1,::1,10.0.0.0/8"
  ```

  A malformed entry raises at boot — that is a static configuration error, so
  failing loudly is safe. The header name is overridable with
  `BAUDRATE_REAL_IP_HEADER`.

  Requests from peers outside the allow-list keep their real `remote_ip` and
  cannot spoof rate-limit / audit IPs through the header.

  IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`) are treated as the IPv4
  address they carry. On the default dual-stack bind (`{0, 0, 0, 0, 0, 0, 0, 0}`),
  Nginx on `127.0.0.1` connects as `::ffff:127.0.0.1`, and it still matches the
  `127.0.0.1` entry. Before v1.15.0 it did not: the header was ignored and every
  request was logged and rate-limited as coming from the proxy.

  **To verify**, check that `ip=` fields in the application log show real
  client addresses rather than `127.0.0.1` or `::ffff:127.0.0.1`. Other
  IPv4-embedding prefixes (NAT64 `64:ff9b::/96`, 6to4) are *not* unwrapped, so
  list them explicitly if a proxy really connects that way.
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
| Revocation | Logout, bans, password change/reset, TOTP reset, sign out everywhere and expiry also close that session's open LiveView pages (`live_socket_id`) |

### Data Export

Users can download their own data at `/profile/export`
([ADR 0023](adr/0023-data-export-threat-model.md)). The design assumes a
request may come from a compromised account:

- **Eligibility:** an active, non-bot account with **TOTP enabled for at
  least 7 days**. Accounts that had TOTP before the `totp_enabled_at` column
  existed count from the upgrade.
- **Timing:** a request is downloadable **24 hours** later, for **48 hours**,
  at most **3 times**, with the password and TOTP code asked for each time.
  Users get always-delivered notices and a banner on every page, and any
  session can cancel. Password change, TOTP reset, a ban and sign out
  everywhere cancel requests automatically.
- **No archive is ever stored on the server.** It is built into the
  service's private `/tmp` at download time and deleted after sending. Keep
  the nginx `/exports/` location unbuffered (see the nginx notes).
- **Browsers:** downloads require Fetch Metadata headers
  (`Sec-Fetch-Site/Mode/Dest`), which all current browsers send. Very old
  browsers get 403.
- **Admins** can review requests at `/admin/data-exports`. There is
  deliberately no way to export another user's data from the web UI.

#### SysOp export (banned users, accounts without TOTP)

For someone who cannot use self-service (for example a banned user
exercising their right of access), run the audited release task. **Verify
the requester's identity out of band first.** There is no email in
Baudrate, so a message claiming to be from a user proves nothing. Use one of
these checks:

1. The request comes from the contact address or account the user registered
   with elsewhere and has used with you before, **and**
2. the user proves control of the account: for example, they sign in and
   post a phrase you give them in a private board or DM (not possible for
   banned users), or they answer details only the account owner would know
   and that are not public (recent private message recipients, approximate
   registration date, invite code used).

Record what you checked in your ticket, then:

```bash
sudo -u baudrate mkdir -m 700 -p /opt/baudrate/exports-out   # owner-only, outside web roots
cd /opt/baudrate/current
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; set +a; \
  bin/baudrate eval "Baudrate.Release.export_user_data(\"alice\", \"/opt/baudrate/exports-out\", reason: \"ticket 42\")"'
```

- **Refusals:** the task refuses an output directory readable by group or
  others, or inside `priv/static` or the uploads root, and it never
  overwrites a file.
- **What it records:** it writes a `0600` ZIP, logs a
  `data_export.sysop_export` warning with the OS user and reason, adds a
  `sysop` row to the export history, and notifies the user.
- **Handing it over:** deliver the file over a secure channel, then delete
  it (`shred -u` where the filesystem supports it).

### Account Migration

Users manage aliases and move their account to another server at
`/profile/move` ([ADR 0025](adr/0025-account-migration.md)). A move redirects
followers on other servers, and they cannot be brought back, so the design
assumes the request may come from a compromised account:

- **Eligibility:** the data export gate (active, non-bot, TOTP enabled for
  at least 7 days), and **no admin, moderator or board moderator role**.
  Demote staff before they move, so a hijacked staff account cannot leave the
  instance without moderators. One move per account every 30 days.
- **Destination:** it must already list the account in `alsoKnownAs`. This is
  checked when the move is requested and again when it is sent.
- **Timing:** the `Move` is sent by the hourly sweep **24 hours** after the
  request. Until then every page shows a warning banner with Cancel. A
  password change, TOTP reset, sign out everywhere or a ban cancels it.
- **Afterwards:** the account can still sign in, read, follow and export its
  data, but cannot post, comment, send DMs, like, boost, vote or create
  invites. Its profile points to the new account. The user can remove the
  redirect (password and TOTP) to post again; followers who already moved
  stay moved. Local followers are moved on their behalf.
- **Inbound moves:** when a remote account that local users follow moves,
  they unfollow it and send a `Follow` to the new account (pending until it
  accepts). **Board follows are never switched over**: admins get a notice
  naming the boards, and decide on `/boards/:slug/follows`. At most one move
  per remote account is processed every 30 days.
- **Logs:** `account_migration.move_requested`, `move_sent`, `move_failed`,
  `move_cancelled` and `redirect_removed` (user side), and
  `federation.move_complete`, `move_rejected` and `move_ignored` (inbound).
  There is no admin UI to move someone else's account.

### Content Security

- **HTML sanitization** — all federated content sanitized via Ammonia (Rust NIF,
  allowlist-based) before database storage
- **SSRF protection** — DNS-pinned connections, reject private/loopback/link-local
  IPs plus CGNAT (`100.64.0.0/10`), multicast/reserved (`224.0.0.0/4`,
  `240.0.0.0/4`), IETF/TEST-NET/benchmarking ranges (`192.0.0.0/24`,
  `192.0.2.0/24`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`), and
  IPv4-over-IPv6 tunnel prefixes (`::ffff:0:0/96`, `64:ff9b::/96`, `2002::/16`,
  `2001::/32`), HTTPS-only for remote fetches. Applies to ActivityPub
  federation, link-preview fetches, and Web Push delivery (push endpoints are
  validated and DNS-pinned on every send, closing the rebinding gap between
  validation and connect)
- **Content size limits** — 256 KB AP payload, 64 KB content body
- **File uploads** — magic byte validation, re-encoding as WebP (strips EXIF,
  destroys polyglots)
- **CSP** — restrictive Content-Security-Policy: no eval, `img-src 'self' data: blob:`
  (remote images are served through the local media proxy, so no page contacts a
  third-party host)
  (`https:` is required for federated remote actor avatars), `object-src 'none'`
  (blocks plugins entirely), `frame-src https://www.youtube-nocookie.com`
  (YouTube embeds only, privacy-enhanced domain), `frame-ancestors 'none'`
- **Referrer-Policy** — `strict-origin-when-cross-origin` prevents leaking full
  URL paths to external sites
- **X-Frame-Options** — DENY

### Bot & Scanner Blocking (Nginx)

The nginx configuration includes rules to silently drop connections from
automated vulnerability scanners and exploit probes before they reach Phoenix.
These rules use nginx status code `444` (close connection with no response),
which wastes fewer server resources than returning an error page.

**What is blocked:**

| Category | Examples |
|----------|----------|
| Exploit paths | `.php`, `.asp`, `.env`, `.git`, `.sql`, `.ini` |
| CMS probes | `/wp-admin`, `/xmlrpc.php`, `/administrator`, `/drupal` |
| Scanner paths | `/cgi-bin`, `/.aws`, `/.kube`, `/.docker`, `/vendor` |
| Malicious user agents | zgrab, masscan, nuclei, sqlmap, nikto, nmap, wpscan |
| Empty user agents | Bots that send no `User-Agent` header |

These rules are defined in the `server` block of the nginx config template
(`ansible/roles/nginx/templates/baudrate.conf.j2`) and the example config
(`doc/examples/nginx.conf.example`). They are placed before static asset
locations to ensure early matching.

**Customising:** Add additional patterns to the `location` or `if` directives
as needed. Restart nginx after changes: `nginx -t && systemctl reload nginx`.

### Clock Synchronization

HTTP Signatures validate the `Date` header within ±300 seconds (5 minutes,
`Baudrate.Federation` `signature_max_age`). If the server clock drifts further, all
incoming federation requests will fail signature verification.

```bash
timedatectl status          # Check time sync status
sudo systemctl enable ntp   # Enable NTP
```

---

## PWA (Progressive Web App)

Baudrate ships with a web app manifest at `/site.webmanifest`, allowing users
to install it as a standalone app from compatible browsers (Chrome, Edge,
Safari, Firefox).

**Requirements:**

- The site must be served over **HTTPS** (required for service workers and PWA)
- VAPID keys must be generated in Admin Settings for push notifications to work

**How it works:**

- `priv/static/site.webmanifest` declares the app name, start URL, display
  mode (`standalone`), theme color, and icon
- `root.html.heex` includes `<link rel="manifest">` and
  `<meta name="theme-color">` in the `<head>`
- Combined with the service worker (registered by `PushManagerHook`), browsers
  detect the app as installable and may show an install prompt

No additional configuration is required. The manifest uses the SVG favicon as
the app icon, which scales to any resolution.

---

## Backup & Restore

The Ansible `backup` role schedules a backup every night and keeps the newest
seven (ADR 0028). Each backup is a folder,
`/var/backups/baudrate/daily/<YYYYMMDDTHHMMSSZ>/` (UTC), holding:

- `db.dump`: a `pg_dump -Fc` dump, checked with `pg_restore --list`.
- `uploads/`: avatars, article, comment and reply images, and link preview
  images. `media_cache/` is left out: it only holds re-encoded copies of remote
  images, which are fetched again on demand. A file unchanged since the
  previous backup is hard-linked to its copy there, so each folder is complete
  while unchanged files are stored once.
- `MANIFEST.json`: the version, time, dump size and SHA-256, file counts, and
  the SHA-256 of the checksum list below.
- `CHECKSUMS.sha256`: every file in the backup, the dump included, in
  `sha256sum` format. Verify a backup anywhere with
  `cd <backup> && sha256sum -c CHECKSUMS.sha256`.

  A hard-linked file keeps the checksum the previous backup recorded rather
  than being hashed again. That is not only cheaper — it is what makes rot
  detectable. Re-hashing would read the bytes as they are *now* and record a
  checksum matching them, so a file that had decayed on disk would be
  certified intact by every backup taken after the decay.

The backup is built under `.incomplete-…` and renamed only when every step
has succeeded. It refuses to start when it would leave less than 1 GiB or 10%
of the disk free, and removes older backups only after a new one succeeded,
so failed runs never delete the last good copies.

The dump contains every account's data, including encrypted TOTP secrets and
federation keys. The backup directory is readable only by the `baudrate` user
and the `baudrate-backup` group. Restoring also needs the same
`SECRET_KEY_BASE`: keep an offline copy of your SOPS secrets file and its key.

> **Before v1.18.2** backups were only available as Mix tasks, which are not
> part of a release, and on an Ansible install `mix backup` archived an almost
> empty uploads directory without error. If you set up a backup cron job from
> an earlier version of this guide, remove it; the timer replaces it.

### Scheduled backups (Ansible install)

`deploy-baudrate.yml` applies the `backup` role (tag `backup`). Its variables
are in `inventory/group_vars/all.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `backup_path` | `/var/backups/baudrate` | Holds `daily/` and `predeploy/` |
| `backup_keep_daily` | `7` | Complete nightly backups to keep |
| `backup_keep_predeploy` | `3` | Pre-migration dumps to keep |
| `backup_schedule` | `*-*-* 04:30:00 Asia/Taipei` | systemd `OnCalendar`, plus up to 15 minutes' random delay |
| `backup_pull_public_key` | empty | Key allowed to pull off-host copies (below) |

The service runs at idle I/O priority, niceness 19, at most half a CPU and
768 MB of memory, and can write only the backup directory.

```bash
systemctl list-timers baudrate-backup.timer   # last and next run
journalctl -u baudrate-backup -n 20           # what the last runs wrote or why they failed
sudo systemctl start baudrate-backup          # back up now (waits until it finishes)
ls /var/backups/baudrate/daily/               # complete backups, newest last
```

A failed run exits non-zero and shows as failed in `systemctl status
baudrate-backup`; nothing was removed.

### Before each deploy

The deploy playbook dumps the database with the new release right before its
migrations, into `predeploy/<timestamp>-<tag>.dump`, keeping the newest
three. A failed dump stops the deploy before the database changes.

### Off-host copies

Backups on the server do not survive losing the server. Copy them to another
machine by **pulling** them: the server then holds no credential that could
reach or delete the copies.

1. On the pulling machine, create a key used only for this:
   `ssh-keygen -t ed25519 -f ~/.ssh/baudrate-backup-pull -N ''`.
2. Set `backup_pull_public_key` to the public key and run the playbook with
   `--tags backup`. This installs `rsync` and creates the `baudrate-pull` user,
   whose key may only run a read-only rsync of the backup directory
   (`rrsync -ro`): no shell, no forwarding, no writes.
3. Pull with `scripts/pull-backups.sh` from the repository. It uses rsync
   **without `--delete`**, so backups the server has since removed stay on the
   pulling machine and a server someone took over cannot erase what it already
   handed over. `-H` keeps the hard links, so the copy is as compact as the
   server's.

   After copying, it verifies the newest backup against the
   `CHECKSUMS.sha256` the server wrote — the dump **and every upload** — so
   corruption in transit, or bit rot on either disk, fails the run instead of
   waiting to be discovered at restore time. The list is itself checked
   against the hash in `MANIFEST.json` first: `sha256sum -c` on a truncated
   list exits 0, so without that step a backup missing most of its files would
   verify clean. The dump is then read with `pg_restore --list`.

   Each run also verifies **one older copy**: the one that has gone longest
   without a successful check, never-checked copies first. Every dump belongs
   to one copy only, and without this it would be checked only on the day it
   was newest; with 30 copies, each is re-checked about once a month.
   Successful checks are recorded as stamp files in `<dest>/.verified`. The
   summary line names the older copy (`also verified …`), and a failure names
   the copy that failed. A copy taken before checksum lists existed has only
   its dump checked.

   Backups still being built on the server (`.incomplete-…`) are never pulled.

   It keeps the newest 30 copies and fails when the newest backup is older
   than 36 hours — which is how a backup that quietly stopped running gets
   noticed.

   Exit codes: `0` all good, `1` the pull or a check failed, `2` the newest
   backup is stale. Under a systemd timer, either non-zero code marks the unit
   failed.

   ```bash
   BAUDRATE_BACKUP_HOST=baudrate-pull@your.server scripts/pull-backups.sh
   ```

   Settings come from the environment: `BAUDRATE_BACKUP_HOST`, `_PORT`, `_KEY`
   (default `~/.ssh/baudrate-backup-pull`), `_DEST` (default
   `~/Backups/baudrate`), `_KEEP` (30) and `_STALE_HOURS` (36).

4. Run it daily from a systemd **user** timer on that machine, so no root
   access is needed:

   ```ini
   # ~/.config/systemd/user/baudrate-backup-pull.service
   [Unit]
   Description=Pull Baudrate backups from the server
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   Environment=BAUDRATE_BACKUP_HOST=baudrate-pull@your.server
   ExecStart=%h/path/to/baudrate/scripts/pull-backups.sh
   Nice=10
   IOSchedulingClass=idle
   ```

   ```ini
   # ~/.config/systemd/user/baudrate-backup-pull.timer
   [Unit]
   Description=Daily pull of Baudrate backups

   [Timer]
   OnCalendar=*-*-* 05:30:00
   RandomizedDelaySec=15min
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now baudrate-backup-pull.timer
   systemctl --user list-timers baudrate-backup-pull.timer   # next run
   systemctl --user --failed                                 # a failed or stale pull shows here
   journalctl --user -u baudrate-backup-pull -n 20           # what the last pull did
   ```

   A user timer runs while that user has a session. `sudo loginctl enable-linger
   $USER` lets it run without one; otherwise `Persistent=true` catches up after
   the next login. Check the copies arrive: a missing day means either the
   server's backup or this pull stopped.

### Restore

**Stop the service first**; a restore overwrites the database and copies the
uploaded files back (files added after the backup are kept).

```bash
systemctl stop baudrate
cd /opt/baudrate/current
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; set +a;
  ./bin/baudrate eval "Baudrate.Release.restore_snapshot(\"/var/backups/baudrate/daily/20260916T203000Z\")"'
systemctl start baudrate
```

A pre-deploy dump restores the database only:

```bash
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; set +a;
  ./bin/baudrate eval "Baudrate.Release.restore_db(\"/var/backups/baudrate/predeploy/20260916T101500Z-v1.19.5.dump\")"'
```

Rehearse a restore now and then; a backup you have never restored is a guess.
A rehearsal that leaves production alone: create a scratch database, restore
the newest dump into it, compare row counts with the live database, then drop
it.

```bash
BK=$(ls -d /var/backups/baudrate/daily/*/ | tail -1)
sudo -u postgres createdb -O baudrate -T template0 baudrate_restore_check
sudo -u baudrate pg_restore -d baudrate_restore_check --no-owner "$BK/db.dump"
for t in users articles comments feed_items remote_actors schema_migrations; do
  echo "$t $(sudo -u postgres psql -Atd baudrate_prod -c "select count(*) from $t")" \
       "$(sudo -u postgres psql -Atd baudrate_restore_check -c "select count(*) from $t")"
done
sudo -u postgres dropdb baudrate_restore_check
```

Check the uploads too: `find "$BK/uploads" -type f | wc -l` against the live
count (`find /opt/baudrate/shared/uploads -path '*/media_cache' -prune -o -type
f -print | wc -l`), and `sha256sum` a few saved files against their live copies.

**Last rehearsed: 2026-09-16** on baudrate.tw, from the 2026-09-15 backup: the
restore took 70 s, every row count matched (101,369 articles, 28 users,
4,085 comments, 5,371 remote actors, schema version 20260914200000), all
11,861 saved upload files were present and the sampled checksums matched.
A rehearsal on a freshly provisioned host is still worth doing once.

### Manual backups

A one-off backup as two files, a dump and a `.tar.gz` of the uploads:

```bash
cd /opt/baudrate/current
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; set +a;
  ./bin/baudrate eval "Baudrate.Release.backup(\"/root/manual-backup\")"'
#   format: "sql" writes plain SQL instead of pg_restore's custom format
```

Restore those with `Baudrate.Release.restore("…dump", "…tar.gz")`.
From a source checkout:

```bash
mix backup                              # database + files into backups/
mix backup.db                           # custom format, for pg_restore
mix backup.db --format sql              # plain SQL, for psql
mix backup.files                        # uploads archive only
mix backup --output-dir /mnt/backups
mix restore backups/baudrate_db_20260228_120000.dump backups/baudrate_files_20260228_120000.tar.gz
```

`pg_dump`, `pg_restore` and `tar` must be on the `PATH` (the PostgreSQL client
matching the server version).

---

## Deployment

### Release artifacts

The Ansible deploy builds the release tag on the server (ADR 0037). CI also
builds one for every release, which you can install by hand instead — on a
host with no toolchain, or to install exactly what CI tested. Publishing a
GitHub release starts `.github/workflows/release.yml`, which:

1. builds the release in the project's build image (`ci/image/`, Debian 12 on
   x86-64, like production) from the release's tag, without caches;
2. smoke-tests it: the cookie guard, migrations, `/health`, the detailed
   report, `rpc`, and that nothing but the web port listens beyond loopback;
3. records a build-provenance attestation and attaches
   `baudrate-<version>-debian12-x86_64.tar.gz` (and its
   `.sigstore.json` bundle) to the release.

The same build and smoke test run on every push to `current`, so a change that
breaks the release fails there rather than after tagging.

The tarball holds the release directory itself (`bin/`, `erts-*/`, `lib/`,
`releases/`), including its own Erlang runtime, so the server needs neither
Erlang, Elixir nor Rust, only the system libraries a Debian 12 install has
(`libssl3`, `libtinfo6`) and the PostgreSQL client for backups. It runs only
on the Debian release it was built for.

To install it by hand, verify it first. `--source-digest` is the commit the tag names in your own
clone, so a tag moved on GitHub after you fetched it fails verification:

```bash
TAG=v1.26.0
gh release download "$TAG" --repo hiroshiyui/baudrate --pattern "baudrate-${TAG#v}-debian12-x86_64.tar.gz"
gh attestation verify "baudrate-${TAG#v}-debian12-x86_64.tar.gz" --repo hiroshiyui/baudrate \
  --signer-workflow hiroshiyui/baudrate/.github/workflows/release.yml \
  --source-ref "refs/tags/$TAG" --source-digest "$(git rev-parse "$TAG^{commit}")" \
  --deny-self-hosted-runners
DIR="releases/$(date -u +%Y%m%d_%H%M%S)"
mkdir "$DIR" && tar -xzf "baudrate-${TAG#v}-debian12-x86_64.tar.gz" -C "$DIR"
```

Then link `lib/baudrate-*/priv/static/uploads` to your persistent uploads directory,
run `bin/migrate`, and point your service at the new directory.

### Erlang distribution and the remote console

A release built in CI is public, and so is the cookie `mix release` writes into
`releases/COOKIE`. The release therefore refuses to join the Erlang
distribution with it: `start`, `daemon`, `remote`, `rpc`, `stop`, `restart` and
`pid` fail unless `RELEASE_COOKIE` is set to a cookie of the server's own
(`rel/env.sh.eex`). `eval` and `version` start no distribution and need none,
so migrations, backups and the pre-deploy dump are unaffected. Ansible
generates the cookie once per server into `/opt/baudrate/env/release_cookie`
(mode 0600, in the 0700 `env/` directory) and writes it into `baudrate.env`.

Distribution listens on `127.0.0.1` only. The node is named
`baudrate@127.0.0.1`, an epmd the release starts binds to loopback
(`ERL_EPMD_ADDRESS`), and the distribution port is bound to loopback in
`vm.args`. Other local users can still reach loopback, so on a shared server
the cookie is what keeps them out: never make `env/` or the cookie file
readable by another account.

For a remote console, or `rpc`, as root:

```bash
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; exec /opt/baudrate/current/bin/baudrate remote'
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; exec /opt/baudrate/current/bin/baudrate rpc "IO.puts(node())"'
```

`RELEASE_DISTRIBUTION=none` runs the node without distribution at all, if you
never use `remote` or `rpc`.

### Rolling back a deploy

`ansible/playbooks/rollback-baudrate.yml` points `current` and `static` back at
a release still on the server (the deploy keeps five), restarts the service
and waits for `/health`. With no arguments it restores the release before the
active one; `-e rollback_to=v1.24.0` (a tag or a release directory name)
chooses another, and `--check` only reports which release it would restore and
whether the schema allows it.

It refuses when the database has migrations the target release does not
contain, and names them. Rolling back code does not roll back the schema: the
older release may fail against columns or constraints it does not know, or
write rows the newer code then misreads. When it refuses:

1. **Prefer fixing forward.** Revert the change on `current` and release again.
2. **Or restore the pre-deploy dump, then roll back.** The deploy dumped the
   database right before those migrations ran, into
   `/var/backups/baudrate/predeploy/<time>-<tag>.dump`. Stop the service,
   restore that dump ([Restore](#restore)), and run the rollback playbook:
   the schema now matches the older release. Everything written since the dump
   is lost.
3. **Or force it** (`-e force=true`), only after checking that the older code
   works with the newer schema (for example, a migration that only added an
   index).

`Baudrate.Release.rollback/2` (below) can run a migration's `down` from the
**newer** release before rolling back, but only for a reversible migration, and
it discards whatever the migration added.

### Building a release yourself

This is what the Ansible deploy does on the server, and what you do for a fork
or a host Ansible does not manage. Build on the same Debian release and CPU
architecture the server runs: the release carries its own Erlang runtime, and
the HTML sanitizer, HTML parser and feed parser NIFs are compiled to native
code. `ci/release/build.sh` is the script CI runs; it expects the toolchain in
`ci/image/Dockerfile` (Erlang, Elixir, Rust, esbuild, Tailwind).

### Asset Build

```bash
MIX_ENV=prod mix assets.deploy   # Tailwind (minified) + esbuild (minified) + phx.digest
```

Generates fingerprinted files and `priv/static/cache_manifest.json`. Without
this step, pages load without CSS styling and JavaScript doesn't execute.

#### Build steps

**Before building**, ensure the `version` in `mix.exs` matches the release tag
(e.g. `"1.1.21"` for tag `v1.1.21`). This version appears in the release
directory name (`lib/baudrate-<version>/`) and in runtime diagnostics.

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The release is written to `_build/prod/rel/baudrate/`. It includes the compiled
BEAM code, the Ammonia NIF `.so`, ERTS, and the overlay convenience scripts
(`bin/server`, `bin/migrate`).

> **Note:** When upgrading versions, remove `_build/prod/rel/` before running
> `mix release` to avoid stale `lib/baudrate-<old-version>/` directories
> accumulating alongside the new version. The Ansible deploy playbook and
> `ci/release/build.sh` both do this.
>
> When `.tool-versions` changes the Erlang/OTP or Elixir version, remove all of
> `_build/prod/` instead. Compiled BEAM files and Rust NIFs belong to the
> toolchain that built them. The Ansible deploy playbook does this
> automatically: it compares the tag's `.tool-versions` with a
> `_build/prod/.tool-versions.stamp` written after each successful compile.
> Install the new toolchain first (`setup-server.yml --tags elixir`), or the
> build fails. CI always builds from a clean checkout.

### Uploads Directory

`priv/static/uploads/` stores avatars, article images, and link preview images:

- Must be **writable** by the application process
- Must be **persistent** across deployments
- For containers: mount a persistent volume at this path
- The Ansible deploy playbook symlinks the release's `uploads/` directory to
  the shared `shared/uploads/` directory, making uploads persistent across
  deploys
- Subdirectories (`avatars/`, `article_images/`, `link_preview_images/`,
  `media_cache/`) are created automatically on first use via `File.mkdir_p!/1`

#### Media cache

`uploads/media_cache/` holds locally re-encoded copies of remote images
(federated attachments, remote actor avatars, images inside RSS articles). It
exists so that viewing federated content never makes a visitor's browser contact
a third-party host, which would disclose their IP address and reading habits to
every instance whose content is on the page.

- It is a **cache**: safe to delete at any time, and excluded from backups
  without loss. Entries are re-fetched on next view.
- nginx must **deny** `/uploads/media_cache/` directly (the shipped config does)
  so the bytes are only reachable through the signed `/media/` route.
- Growth is bounded by `SessionCleaner`, which hourly evicts entries untouched
  for 30 days and then oldest-first until the directory fits within 2 GB. Tune
  with:

  ```elixir
  config :baudrate, Baudrate.Media,
    media_cache_ttl_days: 30,
    media_cache_max_bytes: 2 * 1024 * 1024 * 1024
  ```

  `media_cache_dir` overrides the directory itself. Production should leave it
  at the default (`uploads/media_cache/` — the only path the systemd unit and
  nginx rules cover); the test config uses it to give each partition its own
  directory.

**Important:** Upload directory paths are resolved at **runtime** using
`Application.app_dir/2` — never as compile-time module attributes. In OTP
releases, compile-time `:code.priv_dir/1` resolves to the build directory,
not the release directory, causing writes to go to the wrong location.

### Production Start

```bash
# With mix (development / staging)
PHX_SERVER=true mix phx.server

# With releases — convenience script (RELEASE_COOKIE must be set)
bin/server

# With releases — manual
PHX_SERVER=true bin/baudrate start
```

The endpoint binds to `{0, 0, 0, 0, 0, 0, 0, 0}` (all IPv6/IPv4 interfaces)
on the configured `PORT` (default 4000).

### Near-Zero Downtime Deploys

The Ansible deploy playbook minimises downtime through three mechanisms:

1. **Migrations before restart** — Database migrations run from the new release
   directory *before* the symlink swap and service restart. Since Ecto migrations
   are additive (new columns/tables), the old running code tolerates them.

2. **Graceful shutdown** — Thousand Island's `shutdown_timeout: 30_000` (in `runtime.exs`)
   drains in-flight HTTP requests for up to 30 seconds on SIGTERM. The systemd
   `TimeoutStopSec=35` gives it 5 extra seconds of margin. The unit deliberately
   has no `ExecStop=bin/baudrate stop`. By stop time the `current` symlink
   already points at the new release, and `stop` needs Erlang distribution and
   the cookie. SIGTERM needs neither and triggers the same orderly
   `init:stop()`. If you write your own unit file, do not add an `ExecStop`
   that uses the release's `stop` command.

3. **Nginx request buffering** — `proxy_next_upstream error timeout http_502`
   tells nginx to hold incoming requests and retry up to 3 times over 30 seconds
   when the upstream returns 502 during the restart window. If all retries fail,
   a custom 502 maintenance page with auto-refresh is shown.

The typical restart window (symlink swap → health check pass) is 2–5 seconds.
During this window, nginx buffers new requests and delivers them once the new
release is healthy.

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

### One-Shot Data Repair: `ap_id` Backfill

Until v1.8.2, ActivityPub canonical IDs were stamped with a separate
`Repo.update!/1` *after* the creation transaction committed. If the BEAM
process or DB connection died between commit and stamp, the article
(and any poll or comment) was durably persisted with `ap_id = nil`.
Stamping is now part of the same `Ecto.Multi` as the insert, so new
rows are always consistent — but instances that ran an earlier version
may still have orphan rows.

The task can be invoked two ways. Both are equivalent; pick whichever
fits your operational comfort:

**Against the running production node (recommended)** — `rpc` executes
the function inside the live VM, so the repo and config are already
running, with no port collision. It needs the server's `RELEASE_COOKIE`
([Erlang distribution](#erlang-distribution-and-the-remote-console)), so
source the env file, as the service user:

```bash
set -a; . /opt/baudrate/env/baudrate.env; set +a

# Inspect what would be stamped, without writing
bin/baudrate rpc "Baudrate.Release.backfill_ap_ids(dry_run: true)"

# Apply the backfill
bin/baudrate rpc "Baudrate.Release.backfill_ap_ids()"
```

Logs land in the production node's stdout (`journalctl -u baudrate.service`).

**In a one-shot eval VM** — `eval` boots a fresh VM, so it needs the
`DATABASE_URL` and friends from the systemd EnvironmentFile to be
present in the shell. The task uses `Ecto.Migrator.with_repo/2` so it
starts only the repo (not the endpoint), avoiding the port-4000
collision with the live node:

```bash
set -a; . /opt/baudrate/env/baudrate.env; set +a
bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"
bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
```

Either form is idempotent and skips remote rows (`remote_actor_id`
non-nil), so it is safe to re-run. Both log a per-row line plus a
final summary (`articles=N/N polls=N/N comments=N/N`). Locally during
development you can use `mix backfill_ap_ids` (with `--dry-run`) — same
underlying logic.

---

## Maintenance

### Background Workers

| Worker | Interval | What it does |
|--------|----------|--------------|
| `SessionCleaner` | 1 hour | The housekeeping jobs listed below |
| `DeliveryWorker` | On commit, and every 60 s ± 10% | Delivers due federation jobs, 10 at a time, with a per-domain circuit breaker ([Delivery Queue](#delivery-queue-adminfederation)) |
| `InboundWorker` | On arrival, and every 30 s | Processes stored inbox activities, 4 at a time and one per remote account ([Inbound Queue](#inbound-queue)) |
| `FeedWorker` | 60 s ± 10% | Fetches due RSS/Atom bot feeds, 5 bots at a time |
| `StaleActorCleaner` | 24 hours | Remote actors not re-fetched for 30 days: refreshes them if anything in the database still references them, deletes them otherwise. Batches of 50; skipped while federation is off |

`SessionCleaner` runs its jobs one after another, each on its own: a job that
fails is logged and the rest still run.

| Job | What it does |
|-----|--------------|
| `purge_expired_sessions` | Revokes sessions past their expiry and disconnects the pages still open on them |
| `purge_old_login_attempts` | Deletes login attempt records older than 7 days |
| `cleanup_orphan_article_images`, `cleanup_orphan_comment_images`, `cleanup_orphan_reply_images` | Deletes uploaded images that were never attached to a post, once they are 24 hours old |
| `cleanup_delivery_jobs` | Abandons jobs still waiting after 7 days, deletes delivered jobs after 7 days and abandoned jobs after 30 days, and removes circuit breaker rows not updated for 30 days |
| `purge_inbound_activities` | Deletes processed, rejected and failed inbox activities after 7 days |
| `refresh_stale_link_previews` | Re-fetches link previews older than 7 days |
| `purge_orphan_link_previews` | Deletes link previews fetched more than 30 days ago that no article, comment, direct message or feed item references, with their images |
| `purge_stale_media_cache` | Evicts media proxy cache files older than 30 days, then the oldest until the cache is under 2 GiB (`media_cache_ttl_days`, `media_cache_max_bytes`). A removed image is fetched again when next viewed |
| `sweep_data_exports` | Marks export requests ready or expired as their windows pass, removes archive staging left by a crash, and deletes finished request history after 365 days |
| `sweep_account_moves` | Sends account moves whose 24-hour cooling-off has passed |
| `cleanup_old_notifications` | Deletes notifications older than 90 days |
| `notify_ended_sanctions` | Tells members their silence or suspension has ended. Enforcement already stopped on its own, so a missed run only delays the notice |
| `purge_closed_report_evidence` | Clears the evidence copies of reports closed more than 90 days ago |

Each worker runs exactly once, on the one node ([Scaling](#scaling)). They are
not safe to run twice: two `DeliveryWorker`s would deliver the same jobs, and
two `InboundWorker`s would process one account's activities out of order.

### Health Check

`GET /health` returns the application and database health status as JSON:

| Status | HTTP Code | Response |
|--------|-----------|----------|
| Healthy | 200 | `{"status":"ok"}` |
| Unhealthy | 503 | `{"status":"error"}` |

The endpoint runs through the `:api` pipeline (no session, no CSRF token).
Use it as a health check target for load balancers and monitoring systems.

```bash
curl http://localhost:4000/health
```

It only says whether the application can reach its database, and it is public,
so it says nothing more.

### Detailed Health Report

The detailed report answers whether the site is working, not just running. It
is served by a separate listener bound to `127.0.0.1` (`HEALTH_DETAIL_PORT`,
4001 on an Ansible install). nginx does not proxy it and the firewall does not
open it, so it can only be read from the server itself
([ADR 0035](adr/0035-operational-visibility-stays-on-the-host.md)).

```bash
curl -s http://127.0.0.1:4001/health | jq
```

It answers `200` when every check passes and `503` when one fails, with the
report as JSON either way:

```json
{
  "status": "fail",
  "checks": {
    "database": {"status": "ok"},
    "delivery_queue": {"status": "ok", "waiting": 3, "oldest_due_seconds": 12, "open_circuits": 1},
    "inbound_queue": {"status": "ok", "pending": 0, "oldest_waiting_seconds": 0, "failed_last_24h": 0},
    "workers": {"status": "ok", "workers": {"delivery_worker": {"status": "ok", "last_run_seconds": 41}, "…": {}}},
    "disk": {"status": "ok", "free_bytes": 21474836480, "total_bytes": 42949672960, "floor_bytes": 4294967296},
    "backup": {"status": "fail", "reason": "the newest backup is more than 26 hours old", "newest_age_seconds": 97200, "count": 7}
  }
}
```

| Check | Fails when | Look at |
|-------|------------|---------|
| `database` | `SELECT 1` does not answer | `systemctl status postgresql`, `POOL_SIZE` |
| `delivery_queue` | a delivery has been due for more than 15 minutes. Jobs held back by an [open circuit](#delivery-queue-adminfederation) are waiting on purpose and not counted | `DeliveryWorker` in `journalctl -u baudrate` |
| `inbound_queue` | an inbox activity has waited more than 10 minutes. `failed_last_24h` counts activities that crashed three times | [Inbound Queue](#inbound-queue) |
| `workers` | `DeliveryWorker`, `InboundWorker`, `FeedWorker` or `SessionCleaner` has not completed a run for three of its intervals (at least 5 minutes; 3 hours for the hourly `SessionCleaner`). A worker that keeps crashing and being restarted counts as stopped | the log for crashes of that worker |
| `disk` | free space under `shared/uploads` is below 1 GiB or 10% of the filesystem, the floor backups keep | `df -h`, the media cache size |
| `backup` | the newest complete backup is more than 26 hours old, or there is none; skipped when `BAUDRATE_BACKUP_DIR` is unset | `journalctl -u baudrate-backup` |

The queue checks are `skipped` while federation is switched off. Each check has
5 seconds; one that runs out fails, so a hung database or disk shows up instead
of a report that never comes. The report holds counts, ages and statuses only:
no content, account names or remote domains.

**Alerting.** Baudrate does not send notifications; poll the report with
whatever already watches the server, and alert on a status other than `200`.
Some ways to do it:

- **A systemd timer.** `curl -fsS` exits non-zero on `503`, so the unit fails
  and `OnFailure=` can run any notifier you use (a mail command, a push
  service, a chat webhook):

  ```ini
  # /etc/systemd/system/baudrate-healthcheck.service
  [Unit]
  Description=Baudrate detailed health check
  OnFailure=notify-admin@%n.service

  [Service]
  Type=oneshot
  ExecStart=/usr/bin/curl -fsS -o /dev/null --max-time 30 http://127.0.0.1:4001/health

  # /etc/systemd/system/baudrate-healthcheck.timer
  [Timer]
  OnBootSec=5min
  OnUnitActiveSec=5min

  [Install]
  WantedBy=timers.target
  ```

- **A monitor running on the host** (monit, Uptime Kuma, a cron job): an HTTP
  check on `http://127.0.0.1:4001/health` expecting `200`.
- **A monitor elsewhere** can reach it only through something that runs on the
  host, such as an SSH command. Do not proxy the port or open it in the
  firewall.

To see which checks fail:

```bash
curl -s http://127.0.0.1:4001/health | jq -r '.checks | to_entries[] | select(.value.status == "fail") | "\(.key): \(.value.reason)"'
```

The backup check covers the server side of backups. A copy that fails
verification on the machine that pulls backups is reported by
`scripts/pull-backups.sh` exiting non-zero there; alert on that unit too.

### Logs

Baudrate logs to standard output, which systemd sends to the journal
(`journalctl -u baudrate`). The default text format is one event per line:

```
10:15:02.114 request_id=F1abc [info] federation.delivery_ok: inbox=https://…
```

With `LOG_FORMAT=json` (Ansible: `log_format: json`), each event is one JSON
object, for a log shipper or `jq`:

```bash
journalctl -u baudrate -o cat --since "1 hour ago" | jq -c 'select(.level == "error")'
```

```json
{"time":"2026-09-17T10:15:02.114Z","level":"info","message":"federation.delivery_ok: inbox=https://…","request_id":"F1abc","module":"Baudrate.Federation.Delivery","function":"deliver_one/1"}
```

The fields are `time` (UTC), `level`, `message`, and, when present,
`request_id`, `module` and `function`. No other metadata is written, so JSON
logs never show more than the text format. A newline inside a message is
escaped, so a message cannot fake a second log line. Errors are not sent to any
error-reporting service; the log is where they go.

### Delivery Job Purge

Completed delivery jobs are automatically purged:
- `delivered` jobs older than 7 days
- `abandoned` jobs older than 30 days

Jobs still `pending` or `failed` 7 days after they were queued (held back by an
open circuit) are abandoned first.

### Database Maintenance

```bash
mix ecto.migrate    # Run pending migrations
mix ecto.reset      # Drop + create + migrate (development only!)
```

Ensure the PostgreSQL `pg_trgm` extension is installed before migrations.
Increase `POOL_SIZE` if you see `DBConnection.ConnectionError` under load.

---

## Scaling

Baudrate runs on **one node**
([ADR 0033](adr/0033-baudrate-runs-on-one-node.md)). Never start a second node
against the same database, not even briefly. If you do:

- federation deliveries are sent twice;
- a domain block or a settings change applies only on the node where it was
  made;
- security-key sign-ins and data export downloads fail whenever a request
  reaches the other node;
- every rate limit is multiplied by the number of nodes.

To handle more load, give the one host more resources.

### A bigger host

- **CPU.** The Erlang VM starts one scheduler per core, so extra cores are used
  without any configuration. Re-encoding images and signing federation
  requests are the heaviest regular work.
- **Memory.** PostgreSQL uses spare memory as page cache. On a host running
  both, more memory usually helps the database first.
- **Disk.** Uploads, the media proxy cache and backups share the disk. A
  nightly backup refuses to start when it would leave less than 1 GiB or 10% of
  the disk free, so watch free space as uploads grow
  ([Backup & Restore](#backup--restore)).

### PostgreSQL

PostgreSQL's defaults suit a very small machine. On a host that runs both
Baudrate and PostgreSQL (the Ansible layout), these are reasonable starting
points in `postgresql.conf`:

| Setting | Starting point | Why |
|---------|----------------|-----|
| `shared_buffers` | 25% of RAM | PostgreSQL's own buffer cache. Takes effect after a restart |
| `effective_cache_size` | 50–75% of RAM | The query planner's estimate of memory available for caching data, the OS page cache included. Allocates nothing |
| `max_connections` | the default (100) | Enough while it stays well above `POOL_SIZE` |

Baudrate holds `POOL_SIZE` connections (default 10), plus one more that the
`DeliveryWorker` keeps open to `LISTEN` for new jobs. Keep `max_connections`
well above that, so backups (`pg_dump`), migrations and an administrator's
`psql` session still get a connection. Connect Baudrate to PostgreSQL directly:
a pooler in transaction mode (PgBouncer) cannot carry `LISTEN`, and deliveries
would then wait for the 60-second poll. Raise `POOL_SIZE` when the logs show
`DBConnection.ConnectionError` under load. A pool much larger than about twice
the number of CPU cores rarely makes a single host faster.

### Static assets and CDNs

nginx serves `/assets/` straight from disk with `expires 1y` and
`Cache-Control: public, immutable`. The files are fingerprinted, so a browser
downloads each one once per release, and those requests never reach Baudrate.
A CDN adds little on top of that.

If you put one in front anyway:

- **It must front the whole site, under the same hostname.** The Content
  Security Policy allows scripts, styles, images and fonts only from the site
  itself (`'self'`). Serving assets from a CDN hostname breaks the pages.
- **It must not cache HTML.** Pages are rendered per visitor.
- **Set `BAUDRATE_TRUSTED_PROXIES` and `BAUDRATE_REAL_IP_HEADER`**
  ([Environment Variables](#environment-variables)). Otherwise every visitor
  appears to come from the CDN's addresses and shares one rate-limit bucket.
- **It sees everything.** A CDN that terminates TLS reads every request in
  the clear, passwords and session cookies included.

---

## Admin Routes

| Route | Purpose |
|-------|---------|
| `/admin/settings` | Site name, registration mode, federation settings; read-only system information (Baudrate, Elixir, Erlang/OTP and ERTS versions) |
| `/admin/users` | User management (search, ban/unban, role changes) |
| `/admin/pending-users` | Approve pending registrations |
| `/admin/boards` | Board CRUD, permissions, moderator assignment |
| `/admin/federation` | Delivery queue, known instances, domain blocking, key rotation |
| `/admin/moderation` | Report queue (resolve, dismiss, delete content) |
| `/admin/moderation-log` | Audit trail of all admin actions |
| `/admin/invites` | Invite code generation and revocation |
| `/admin/login-attempts` | Login attempt history (filterable, paginated) |
| `/admin/data-exports` | Data export request history (admin-only, read-only; no export-on-behalf) |
| `/admin/verify` | Admin TOTP re-verification (sudo mode, 10-min timeout) |

---

## Further Reading

- [Troubleshooting Guide](troubleshooting.md) — common issues and solutions
- [AP Endpoint API Reference](api.md) — ActivityPub and public API documentation
- [Development Guide](development.md) — architecture, project structure, implementation details
