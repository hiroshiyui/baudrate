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

## Architecture

### Project Structure

```
lib/
├── baudrate/                    # Business logic (contexts)
│   ├── auth.ex                  # Auth context: login, TOTP, sessions, avatars
│   ├── auth/
│   │   ├── recovery_code.ex     # Ecto schema for one-time recovery codes
│   │   ├── session_cleaner.ex   # GenServer: hourly expired session purge
│   │   ├── totp_vault.ex        # AES-256-GCM encryption for TOTP secrets
│   │   └── user_session.ex      # Ecto schema for server-side sessions
│   ├── avatar.ex                # Avatar image processing (crop, resize, WebP)
│   ├── content.ex               # Content context: boards and articles
│   ├── content/
│   │   ├── article.ex           # Article schema (posts)
│   │   ├── board.ex             # Board schema (hierarchical via parent_id)
│   │   ├── board_article.ex     # Join table: board ↔ article
│   │   └── board_moderator.ex   # Join table: board ↔ moderator
│   ├── setup.ex                 # Setup context: first-run wizard, RBAC seeding
│   └── setup/
│       ├── permission.ex        # Permission schema (scope.action naming)
│       ├── role.ex              # Role schema (admin/moderator/user/guest)
│       ├── role_permission.ex   # Join table: role ↔ permission
│       ├── setting.ex           # Key-value settings (site_name, setup_completed)
│       └── user.ex              # User schema with password, TOTP, avatar fields
├── baudrate_web/                # Web layer
│   ├── components/
│   │   ├── core_components.ex   # Shared UI components (avatar, flash, input, etc.)
│   │   └── layouts.ex           # App and setup layouts with nav
│   ├── controllers/
│   │   └── session_controller.ex  # POST endpoints for session mutations
│   ├── live/
│   │   ├── auth_hooks.ex        # on_mount hooks: require_auth, etc.
│   │   ├── board_live.ex        # Board view with article listing
│   │   ├── home_live.ex         # Authenticated home page
│   │   ├── login_live.ex        # Login form (phx-trigger-action pattern)
│   │   ├── profile_live.ex      # User profile with avatar upload/crop
│   │   ├── recovery_code_verify_live.ex  # Recovery code login
│   │   ├── recovery_codes_live.ex        # Recovery codes display
│   │   ├── setup_live.ex        # First-run setup wizard
│   │   ├── totp_reset_live.ex   # Self-service TOTP reset/enable
│   │   ├── totp_setup_live.ex   # TOTP enrollment with QR code
│   │   └── totp_verify_live.ex  # TOTP code verification
│   ├── plugs/
│   │   ├── ensure_setup.ex      # Redirect to /setup until setup is done
│   │   ├── rate_limit.ex        # IP-based rate limiting (Hammer)
│   │   ├── refresh_session.ex   # Token rotation every 24h
│   │   └── set_locale.ex        # Accept-Language detection
│   ├── endpoint.ex              # HTTP entry point, session config
│   └── router.ex                # Route scopes and pipelines
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

### Content Model

Boards are organized hierarchically via `parent_id`. Articles can be
cross-posted to multiple boards through the `board_articles` join table.
Board moderators are tracked via the `board_moderators` join table.

### Layout System

LiveView pages use **auto-layout** configured per `live_session` in the router:

```elixir
live_session :authenticated,
  layout: {BaudrateWeb.Layouts, :app},
  on_mount: [{BaudrateWeb.AuthHooks, :require_auth}]
```

The layout receives `@inner_content` (not `@inner_block`) and has access to
socket assigns like `@current_user`. The setup wizard uses a separate
`:setup` layout (minimal, no navigation).

### Request Pipeline

Every browser request passes through these plugs in order:

```
:accepts → :fetch_session → :fetch_live_flash → :put_root_layout →
:protect_from_forgery → :put_secure_browser_headers (CSP, X-Frame-Options) →
SetLocale (Accept-Language) → EnsureSetup (redirect to /setup) →
RefreshSession (token rotation)
```

### Supervision Tree

```
Baudrate.Supervisor (one_for_one)
├── BaudrateWeb.Telemetry          # Telemetry metrics
├── Baudrate.Repo                  # Ecto database connection pool
├── DNSCluster                     # DNS-based cluster discovery
├── Phoenix.PubSub                 # PubSub for LiveView
├── Baudrate.Auth.SessionCleaner   # Hourly expired session purge
└── BaudrateWeb.Endpoint           # HTTP server
```

## Running Tests

```bash
mix test
```
