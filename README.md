# Baudrate: Yet Another Bulletin Board System

## About

Baudrate is a BBS built with [Elixir](https://elixir-lang.org/) and [Phoenix](https://www.phoenixframework.org/).

### Features

- **Real-time UI** with Phoenix LiveView
- **Hierarchical boards** -- nested board structure with breadcrumb navigation, sub-board display, moderators, public/private visibility
- **Guest browsing** -- public boards and articles are accessible without login
- **Cross-posted articles** -- articles can span multiple boards
- **Threaded comments** -- with support for remote replies via ActivityPub
- **Role-based access control** -- admin, moderator, user, and guest roles
- **TOTP two-factor authentication** -- required for admin/moderator, optional for users, with recovery codes
- **ActivityPub federation** -- federate with Mastodon, Lemmy, and the Fediverse
  - WebFinger and NodeInfo discovery
  - Incoming follows, comments, likes, boosts, updates, deletes, and Flag reports
  - Outbound delivery of articles, deletes, announces, and Flag reports to remote instances
  - DB-backed delivery queue with exponential backoff retry
  - Shared inbox deduplication for efficient delivery
  - HTTP Signature verification and signing, HTML sanitization, SSRF-safe fetches
  - Domain blocklist and allowlist modes for instance-level federation control
  - Federation kill switch and per-board federation toggle
  - Cross-post deduplication for articles arriving via multiple board inboxes
  - Mastodon compatibility: `attributedTo` arrays, `sensitive`/`summary` content warnings, `to`/`cc` addressing, `<span>` tag preservation, article summary and hashtag tags
  - Lemmy compatibility: `Page` object type, `Announce` with embedded objects, `!board@host` WebFinger
- **User public profiles** -- public profile pages with stats, recent articles, and clickable author names
- **Avatar system** -- upload, crop, WebP conversion with server-side security
- **Flexible registration** -- open, approval-required, or invite-only modes with admin-managed invite codes
- **Admin dashboard** -- site settings, registration mode, pending user approval, federation dashboard, moderation queue, moderation log, invite code management
- **Rate limiting** on login, TOTP, registration, avatar uploads, and federation endpoints
- **Security hardened** -- HSTS, CSP, signed + encrypted cookies, TOTP/key encryption at rest
- **Internationalization** -- Gettext with supported locales and Accept-Language auto-detection

## Setup

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 15+
- libvips (for avatar image processing)

### Installation

```bash
# Clone the repository
git clone https://github.com/user/baudrate.git
cd baudrate

# Install dependencies
mix setup

# Generate a self-signed cert for local HTTPS
mix phx.gen.cert

# Start the server
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

Note: Federation private keys are encrypted using a key derived from
`SECRET_KEY_BASE`, so no additional environment variable is needed.

## Documentation

See [doc/development.md](doc/development.md) for architecture details, project structure, and development notes.

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
- [Earmark](https://hexdocs.pm/earmark/) (Markdown rendering)
- [Req](https://hexdocs.pm/req/) (HTTP client for federation)
