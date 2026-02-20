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

## Acknowledges

Built with these excellent open-source projects:

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
- [Tailwind CSS](https://tailwindcss.com/) + [DaisyUI](https://daisyui.com/)
- [NimbleTOTP](https://hexdocs.pm/nimble_totp/)
- [Hammer](https://hexdocs.pm/hammer/)
