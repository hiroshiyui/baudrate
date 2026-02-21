# Development Guide

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.15+ |
| Web framework | Phoenix 1.8 / LiveView 1.1 |
| Database | PostgreSQL (via Ecto) |
| CSS | Tailwind CSS + DaisyUI |
| JS bundler | esbuild |
| Image processing | image (libvips NIF) |
| 2FA | NimbleTOTP + EQRCode |
| Rate limiting | Hammer |
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |

## Architecture

### Project Structure

```
lib/
├── baudrate/                    # Business logic (contexts)
│   ├── application.ex           # Supervision tree
│   ├── repo.ex                  # Ecto repository
│   ├── mailer.ex                # Email sending (Swoosh)
│   ├── auth.ex                  # Auth context: login, registration, TOTP, sessions, avatars
│   ├── auth/
│   │   ├── recovery_code.ex     # Ecto schema for one-time recovery codes
│   │   ├── session_cleaner.ex   # GenServer: hourly expired session purge
│   │   ├── totp_vault.ex        # AES-256-GCM encryption for TOTP secrets
│   │   └── user_session.ex      # Ecto schema for server-side sessions
│   ├── avatar.ex                # Avatar image processing (crop, resize, WebP)
│   ├── content.ex               # Content context: boards, articles, comments, likes
│   ├── content/
│   │   ├── article.ex           # Article schema (posts, local + remote, soft-delete)
│   │   ├── article_like.ex      # ArticleLike schema (local + remote likes)
│   │   ├── board.ex             # Board schema (hierarchical via parent_id, visibility)
│   │   ├── board_article.ex     # Join table: board ↔ article
│   │   ├── board_moderator.ex   # Join table: board ↔ moderator
│   │   ├── comment.ex           # Comment schema (threaded, local + remote, soft-delete)
│   │   └── markdown.ex          # Markdown → HTML rendering (Earmark)
│   ├── federation.ex            # Federation context: actors, outbox, followers, announces
│   ├── federation/
│   │   ├── actor_resolver.ex    # Remote actor fetching and caching (24h TTL)
│   │   ├── announce.ex          # Announce (boost) schema
│   │   ├── delivery.ex          # Outgoing activity delivery (Accept, queue, retry)
│   │   ├── delivery_job.ex      # DeliveryJob schema (delivery queue records)
│   │   ├── delivery_worker.ex   # GenServer: polls delivery queue, retries failed jobs
│   │   ├── follower.ex          # Follower schema (remote → local follows)
│   │   ├── http_client.ex       # SSRF-safe HTTP client for remote fetches
│   │   ├── http_signature.ex    # HTTP Signature signing and verification
│   │   ├── inbox_handler.ex     # Incoming activity dispatch (Follow, Create, Like, etc.)
│   │   ├── key_store.ex         # RSA-2048 keypair management for actors
│   │   ├── key_vault.ex         # AES-256-GCM encryption for private keys at rest
│   │   ├── remote_actor.ex      # RemoteActor schema (cached remote profiles)
│   │   ├── publisher.ex         # ActivityStreams JSON builders for outgoing activities
│   │   ├── sanitizer.ex         # Allowlist-based HTML sanitizer for federated content
│   │   └── validator.ex         # AP input validation (URLs, sizes, attribution)
│   ├── setup.ex                 # Setup context: first-run wizard, RBAC seeding, settings
│   └── setup/
│       ├── permission.ex        # Permission schema (scope.action naming)
│       ├── role.ex              # Role schema (admin/moderator/user/guest)
│       ├── role_permission.ex   # Join table: role ↔ permission
│       ├── setting.ex           # Key-value settings (site_name, setup_completed, etc.)
│       └── user.ex              # User schema with password, TOTP, avatar, status fields
├── baudrate_web/                # Web layer
│   ├── components/
│   │   ├── core_components.ex   # Shared UI components (avatar, flash, input, etc.)
│   │   └── layouts.ex           # App and setup layouts with nav, theme toggle
│   ├── controllers/
│   │   ├── activity_pub_controller.ex  # ActivityPub endpoints (content-negotiated)
│   │   ├── error_html.ex        # HTML error pages
│   │   ├── error_json.ex        # JSON error responses
│   │   ├── page_controller.ex   # Static page controller
│   │   └── session_controller.ex  # POST endpoints for session mutations
│   ├── live/
│   │   ├── admin/
│   │   │   ├── pending_users_live.ex  # Admin approval of pending registrations
│   │   │   └── settings_live.ex       # Admin site settings (name, registration mode)
│   │   ├── article_live.ex      # Single article view
│   │   ├── article_new_live.ex  # Article creation form
│   │   ├── auth_hooks.ex        # on_mount hooks: require_auth, optional_auth, etc.
│   │   ├── board_live.ex        # Board view with article listing
│   │   ├── home_live.ex         # Home page (board listing, public for guests)
│   │   ├── login_live.ex        # Login form (phx-trigger-action pattern)
│   │   ├── profile_live.ex      # User profile with avatar upload/crop, locale prefs
│   │   ├── recovery_code_verify_live.ex  # Recovery code login
│   │   ├── recovery_codes_live.ex        # Recovery codes display
│   │   ├── register_live.ex     # Public user registration
│   │   ├── setup_live.ex        # First-run setup wizard
│   │   ├── totp_reset_live.ex   # Self-service TOTP reset/enable
│   │   ├── totp_setup_live.ex   # TOTP enrollment with QR code
│   │   └── totp_verify_live.ex  # TOTP code verification
│   ├── plugs/
│   │   ├── cache_body.ex        # Cache raw request body (for HTTP signature verification)
│   │   ├── ensure_setup.ex      # Redirect to /setup until setup is done
│   │   ├── rate_limit.ex        # IP-based rate limiting (Hammer)
│   │   ├── rate_limit_domain.ex # Per-domain rate limiting for AP inboxes
│   │   ├── refresh_session.ex   # Token rotation every 24h
│   │   ├── set_locale.ex        # Accept-Language + user preference locale detection
│   │   └── verify_http_signature.ex  # HTTP Signature verification for AP inboxes
│   ├── endpoint.ex              # HTTP entry point, session config
│   ├── gettext.ex               # Gettext i18n configuration
│   ├── locale.ex                # Locale resolution (Accept-Language + user prefs)
│   ├── router.ex                # Route scopes and pipelines
│   └── telemetry.ex             # Telemetry metrics configuration
```

### Authentication Flow

```
┌─────────┐     ┌─────────────┐     ┌──────────────────┐
│  Login   │────▶│   Password  │────▶│ login_next_step/1│
│  Page    │     │   Auth      │     │                  │
└─────────┘     └─────────────┘     └────────┬─────────┘
                                             │
                    ┌────────────────────────┬┴──────────────────┐
                    │                        │                   │
                    ▼                        ▼                   ▼
            ┌──────────────┐      ┌────────────────┐   ┌──────────────┐
            │ TOTP Verify  │      │  TOTP Setup    │   │ Authenticated│
            │ (has TOTP)   │      │ (admin/mod,    │   │ (no TOTP     │
            │              │      │  no TOTP yet)  │   │  required)   │
            └──────┬───────┘      └───────┬────────┘   └──────┬───────┘
                   │                      │                    │
                   └──────────────────────┴────────────────────┘
                                          │
                                          ▼
                                 ┌──────────────────┐
                                 │ establish_session │
                                 │ (server-side      │
                                 │  session created) │
                                 └──────────────────┘
```

The login flow uses the **phx-trigger-action** pattern: LiveView handles
credential validation, then triggers a hidden form POST to the
`SessionController` which writes session tokens into the cookie.

### Session Management

| Aspect | Detail |
|--------|--------|
| Token type | Dual tokens: session token (auth) + refresh token (rotation) |
| Storage | SHA-256 hashes in `user_sessions` table; raw tokens in signed+encrypted cookie |
| TTL | 14 days from creation or last rotation |
| Rotation | `RefreshSession` plug rotates both tokens every 24 hours |
| Concurrency | Max 3 sessions per user; oldest (by `refreshed_at`) evicted |
| Cleanup | `SessionCleaner` GenServer purges expired sessions every hour |

### RBAC

Roles and permissions use a normalized 3-table design. Higher roles inherit
all permissions of lower roles:

| Role | Permissions |
|------|-------------|
| admin | `admin.*` + all moderator + user + guest permissions |
| moderator | `moderator.*` + all user + guest permissions |
| user | `user.*` + guest permissions |
| guest | `guest.view_content` |

Permission names follow a `scope.action` convention (e.g., `admin.manage_users`,
`user.create_content`).

### Avatar System

User avatars are processed server-side for security:

1. Client selects image → Cropper.js provides interactive crop UI
2. Normalized crop coordinates (percentages) are sent to the server
3. Server validates magic bytes, re-encodes as WebP (destroying polyglots),
   strips all EXIF/metadata, and produces 48x48 and 36x36 thumbnails
4. Files stored at `priv/static/uploads/avatars/{avatar_id}/{size}.webp`
   with server-generated 64-char hex IDs (no user input in paths)
5. Rate limited to 5 avatar changes per hour per user

### User Registration

Public user registration is available at `/register`. The system supports two
modes controlled by the `registration_mode` setting:

| Mode | Default | Behavior |
|------|---------|----------|
| `"approval_required"` | Yes | New users get `status: "pending"` — can log in and browse, but cannot create articles or upload avatars until approved by an admin |
| `"open"` | No | New users get `status: "active"` immediately |

Registration is rate-limited to 5 attempts per hour per IP. The same password
policy as the setup wizard applies (12+ chars, complexity requirements).

Admin approval is available at `/admin/pending-users` (admin role only).

### Article Creation

Authenticated users with active status and `user.create_content` permission
can create articles. Two entry points:

- `/boards/:slug/articles/new` — pre-selects the board
- `/articles/new` — user picks board(s) from a multi-select

Articles are assigned a URL-safe slug generated from the title with a random
suffix to avoid collisions. Articles can be cross-posted to multiple boards.

### Content Model

Boards are organized hierarchically via `parent_id` and have a `visibility`
field (`"public"` or `"private"`, default `"public"`). Public boards and their
articles are accessible to unauthenticated visitors; private boards require
login. Articles can be cross-posted to multiple boards through the
`board_articles` join table. Board moderators are tracked via the
`board_moderators` join table.

Comments are threaded via `parent_id` (self-referential) and belong to an
article. Both articles and comments can originate locally (via `user_id`) or
from remote ActivityPub actors (via `remote_actor_id`). Soft-delete is
implemented via `deleted_at` timestamps on both articles and comments.

Article likes track favorites from local users and remote actors, with
partial unique indexes enforcing one-like-per-actor-per-article.

### ActivityPub Federation

Baudrate federates with the Fediverse (Mastodon, Lemmy, etc.) via ActivityPub.
The `Baudrate.Federation` context handles all federation logic.

**Actor mapping:**

| Local Entity | AP Type | URI Pattern |
|-------------|---------|-------------|
| User | Person | `/ap/users/:username` |
| Board | Group | `/ap/boards/:slug` |
| Site | Organization | `/ap/site` |
| Article | Article | `/ap/articles/:slug` |

**Discovery endpoints:**
- `/.well-known/webfinger` — resolve `acct:user@host` or `acct:!board@host`
- `/.well-known/nodeinfo` → `/nodeinfo/2.1` — instance metadata

**Outbound endpoints** (content-negotiated: JSON-LD for AP clients, HTML redirect otherwise):
- `/ap/users/:username` — Person actor with publicKey, inbox, outbox
- `/ap/boards/:slug` — Group actor
- `/ap/site` — Organization actor
- `/ap/articles/:slug` — Article object
- `/ap/users/:username/outbox` — `OrderedCollection` of `Create(Article)`
- `/ap/boards/:slug/outbox` — `OrderedCollection` of `Announce(Article)`

**Inbox endpoints** (HTTP Signature verified, per-domain rate-limited):
- `/ap/inbox` — shared inbox
- `/ap/users/:username/inbox` — user inbox
- `/ap/boards/:slug/inbox` — board inbox

**Incoming activities handled** (via `InboxHandler`):
- `Follow` / `Undo(Follow)` — follower management with auto-accept
- `Create(Note)` — stored as threaded comments on local articles
- `Create(Article)` / `Create(Page)` — stored as remote articles in target boards (Page for Lemmy interop)
- `Like` / `Undo(Like)` — article favorites
- `Announce` / `Undo(Announce)` — boosts/shares (bare URI or embedded object map)
- `Update(Note/Article/Page)` — content updates with authorship check
- `Update(Person/Group)` — actor profile refresh
- `Delete` — soft-delete with authorship verification

**Outbound delivery** (via `Publisher` + `Delivery` + `DeliveryWorker`):
- `Create(Article)` — automatically enqueued when a local user publishes an article
- `Delete` with `Tombstone` — enqueued when an article is soft-deleted
- `Announce` — board actor announces articles to board followers
- `Update(Article)` — for article edits (builder available, not yet hooked)
- Delivery targets: followers of the article's author + followers of all public boards
- Shared inbox deduplication: multiple followers at the same instance → one delivery
- DB-backed queue (`delivery_jobs` table) with `DeliveryWorker` GenServer polling
- Exponential backoff: 1m → 5m → 30m → 2h → 12h → 24h, then abandoned after 6 attempts
- Domain blocklist respected: deliveries to blocked domains are skipped

**Followers collection endpoints:**
- `/ap/users/:username/followers` — `OrderedCollection` of follower URIs
- `/ap/boards/:slug/followers` — `OrderedCollection` (public boards only, 404 for private)

**Mastodon/Lemmy compatibility:**
- `attributedTo` arrays — extracts first binary URI for validation
- `sensitive` + `summary` — content warnings prepended as `[CW: summary]`
- Lemmy `Page` objects treated identically to `Article` (Create and Update)
- Lemmy `Announce` with embedded object maps — extracts inner `id`
- `<span>` tags with safe classes (`h-card`, `hashtag`, `mention`, `invisible`) preserved by sanitizer
- Outbound Note objects include `to`/`cc` addressing (required by Mastodon for visibility)
- Outbound Article objects include `cc` with board actor URIs (improves discoverability)

**Security:**
- HTTP Signature verification on all inbox requests
- HTML sanitization (allowlist-based) before database storage
- Attribution validation prevents impersonation
- Content size limits (256 KB payload, 64 KB content)
- Domain blocklist (configurable via admin settings)
- SSRF-safe remote fetches (reject private/loopback IPs, HTTPS only)
- Per-domain rate limiting (60 req/min per remote domain)
- Private keys encrypted at rest with AES-256-GCM
- Private boards hidden from all AP endpoints (actor, outbox, inbox, WebFinger, audience resolution)

### Layout System

LiveView pages use **auto-layout** configured per `live_session` in the router:

```elixir
live_session :authenticated,
  layout: {BaudrateWeb.Layouts, :app},
  on_mount: [{BaudrateWeb.AuthHooks, :require_auth}]
```

The layout receives `@inner_content` (not `@inner_block`) and has access to
socket assigns like `@current_user`. When `@current_user` is `nil` (guest
visitors on public pages), the layout shows Sign In / Register links instead
of the user menu. The setup wizard uses a separate `:setup` layout (minimal,
no navigation).

**Auth hooks:**

| Hook | Behavior |
|------|----------|
| `:require_auth` | Requires valid session; redirects to `/login` if unauthenticated |
| `:optional_auth` | Loads user if session exists; assigns `nil` for guests (no redirect) |
| `:require_password_auth` | Requires password-level auth (for TOTP flow) |
| `:redirect_if_authenticated` | Redirects authenticated users to `/` (for login/register pages) |

### Request Pipeline

Every browser request passes through these plugs in order:

```
:accepts → :fetch_session → :fetch_live_flash → :put_root_layout →
:protect_from_forgery → :put_secure_browser_headers (CSP, X-Frame-Options) →
SetLocale (Accept-Language) → EnsureSetup (redirect to /setup) →
RefreshSession (token rotation)
```

ActivityPub inbox requests use a separate pipeline:

```
:accepts (activity+json) → CacheBody (256 KB max) →
RateLimitDomain (60/min per domain) → VerifyHttpSignature →
ActivityPubController (dispatch to InboxHandler)
```

### Rate Limiting

| Endpoint | Limit | Scope |
|----------|-------|-------|
| Login | 10 / 5 min | per IP |
| TOTP | 15 / 5 min | per IP |
| Registration | 5 / hour | per IP |
| Avatar upload | 5 / hour | per user |
| AP endpoints | 120 / min | per IP |
| AP inbox | 60 / min | per remote domain |

### Supervision Tree

```
Baudrate.Supervisor (one_for_one)
├── BaudrateWeb.Telemetry              # Telemetry metrics
├── Baudrate.Repo                      # Ecto database connection pool
├── DNSCluster                         # DNS-based cluster discovery
├── Phoenix.PubSub                     # PubSub for LiveView
├── Baudrate.Auth.SessionCleaner       # Hourly expired session purge
├── Baudrate.Federation.TaskSupervisor # Async federation delivery tasks
├── Baudrate.Federation.DeliveryWorker # Polls delivery queue every 60s
└── BaudrateWeb.Endpoint               # HTTP server
```

## Running Tests

```bash
mix test
```
