# Baudrate: Yet Another Bulletin Board System

## About

Baudrate is a BBS built with [Elixir](https://elixir-lang.org/) and [Phoenix](https://www.phoenixframework.org/).

### Features

- **Phoenix LiveView** for real-time, server-rendered UI
- **Role-based access control** with a normalized 3-table design (roles, permissions, role_permissions) supporting admin, moderator, user, and guest roles
- **TOTP two-factor authentication** -- required for admin/moderator, optional for users, with encrypted-at-rest secrets (AES-256-GCM)
- **Server-side session management** -- DB-backed sessions with SHA-256 hashed tokens, max 3 concurrent sessions per user, 14-day expiry, and automatic token rotation
- **Rate limiting** on login and TOTP endpoints
- **Security hardened** -- HSTS, CSP, signed + encrypted cookies, database SSL in production
- **Internationalization** -- Gettext with zh-TW locale and Accept-Language auto-detection
- **DaisyUI + Tailwind CSS** for styling

### Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.15+ |
| Web framework | Phoenix 1.8 / LiveView 1.1 |
| Database | PostgreSQL (via Ecto) |
| CSS | Tailwind CSS + DaisyUI |
| JS bundler | esbuild |
| 2FA | NimbleTOTP + EQRCode |
| Rate limiting | Hammer |

## Architecture

### Project Structure

```
lib/
├── baudrate/                    # Business logic (contexts)
│   ├── auth.ex                  # Auth context: login, TOTP, session management
│   ├── auth/
│   │   ├── session_cleaner.ex   # GenServer: hourly expired session purge
│   │   ├── totp_vault.ex        # AES-256-GCM encryption for TOTP secrets
│   │   └── user_session.ex      # Ecto schema for server-side sessions
│   ├── setup.ex                 # Setup context: first-run wizard, RBAC seeding
│   └── setup/
│       ├── permission.ex        # Permission schema (scope.action naming)
│       ├── role.ex              # Role schema (admin/moderator/user/guest)
│       ├── role_permission.ex   # Join table: role ↔ permission
│       ├── setting.ex           # Key-value settings (site_name, setup_completed)
│       └── user.ex              # User schema with password + TOTP fields
├── baudrate_web/                # Web layer
│   ├── controllers/
│   │   └── session_controller.ex  # POST endpoints for session mutations
│   ├── live/
│   │   ├── auth_hooks.ex        # on_mount hooks: require_auth, etc.
│   │   ├── home_live.ex         # Authenticated home page
│   │   ├── login_live.ex        # Login form (phx-trigger-action pattern)
│   │   ├── setup_live.ex        # First-run setup wizard
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

## Setup

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 15+
- Node.js (for asset tooling, if needed)

### Development

```bash
# Clone the repository
git clone https://github.com/user/baudrate.git
cd baudrate

# Install dependencies
mix setup

# Generate a self-signed cert for local HTTPS
mix phx.gen.cert

# Start the dev server
mix phx.server
```

The app will be available at https://localhost:4001.

On first visit, you will be redirected to `/setup` to create the initial admin account.

### Environment Variables

For production, you will need to configure:

- `DATABASE_URL` -- PostgreSQL connection string
- `SECRET_KEY_BASE` -- at least 64 bytes of random data (`mix phx.gen.secret`)
- `TOTP_VAULT_KEY` -- 32-byte Base64-encoded AES key for TOTP secret encryption
- `PHX_HOST` -- your production hostname

### Running Tests

```bash
mix test
```

## License

This project is licensed under the [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html) (AGPL-3.0).

### Third-party Licenses

- **[DotGothic16](https://github.com/fontworks-fonts/DotGothic16)** font by Fontworks Inc. is licensed under the [SIL Open Font License 1.1](https://github.com/fontworks-fonts/DotGothic16/blob/master/OFL.txt).

## Acknowledges

Built with these excellent open-source projects:

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
- [Tailwind CSS](https://tailwindcss.com/) + [DaisyUI](https://daisyui.com/)
- [NimbleTOTP](https://hexdocs.pm/nimble_totp/)
- [Hammer](https://hexdocs.pm/hammer/)
