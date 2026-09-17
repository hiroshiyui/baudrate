
<p align="center">
  <img src="priv/static/images/icon-192.png" alt="Baudrate" width="192" height="192">
</p>

# Baudrate: ActivityPub-enabled Bulletin Board System

## About

Baudrate is an ActivityPub-enabled BBS built with [Elixir](https://elixir-lang.org/) and [Phoenix](https://www.phoenixframework.org/).

### Features

- **Real-time UI** with Phoenix LiveView
- **Hierarchical boards** -- nested board structure with breadcrumb navigation, sub-board display, per-board role-based access (`min_role_to_view`, `min_role_to_post`), and board moderator management
- **Guest browsing** -- guest-visible boards and articles are accessible without login
- **Cross-posted articles** -- articles can span multiple boards, with author-controlled forwarding (`forwardable` toggle) and cross-board forwarding by any user; authors can remove their articles from specific boards
- **Threaded comments** -- with support for remote replies via ActivityPub
- **Role-based access control** -- admin, moderator, user, and guest roles with per-board permission levels
- **Board moderation** -- board moderators can pin/lock threads and delete articles/comments
- **TOTP two-factor authentication** -- required for admin/moderator, optional for users, with recovery codes
- **WebAuthn / FIDO2 security keys** -- register hardware security keys or passkeys (e.g. YubiKey, Touch ID) for second-factor and admin sudo-mode re-verification
- **Account security** -- password change and sign out everywhere behind step-up re-authentication; always-delivered notices when a password, second factor, or session changes
- **Account migration** -- aliases (`alsoKnownAs`) and ActivityPub `Move` to another server, with a 24-hour cooling-off and warning banner, a destination check at request and send time, and a read-only old account whose redirect can be removed; followers of accounts that move elsewhere are refollowed properly
- **Data export** -- download a JSON + media archive of what you wrote and own, designed against data leakage: TOTP-gated, 24-hour cooling-off with a site-wide warning banner, re-authentication for every download, and no archive ever stored on the server
- **ActivityPub federation** -- federate with Mastodon, Lemmy, and the Fediverse
  - WebFinger and NodeInfo discovery
  - Incoming follows, comments, likes, boosts, updates, deletes, and Flag reports
  - Outbound delivery of articles, deletes, announces, and Flag reports to remote instances
  - DB-backed delivery queue written in the same transaction as the post, sent as soon as it commits, with exponential backoff retry and a per-instance circuit breaker
  - Inbound activities stored and acknowledged at once, then processed in order per remote account with bounded concurrency
  - Shared inbox deduplication for efficient delivery
  - HTTP Signature verification and signing, HTML sanitization, SSRF-safe fetches
  - Domain blocklist and allowlist modes for instance-level federation control
  - Federation kill switch and per-board federation toggle
  - Cross-post deduplication for articles arriving via multiple board inboxes
  - Mastodon compatibility: `attributedTo` arrays, `sensitive`/`summary` content warnings, `to`/`cc` addressing, `<span>` tag preservation, article summary and hashtag tags
  - Lemmy compatibility: `Page` object type, `Announce` with embedded objects, `!board@host` WebFinger
- **Link previews** -- server-side Open Graph / Twitter Card metadata fetching with image proxy for articles, comments, and DMs
- **User public profiles** -- public profile pages with stats, recent articles, and clickable author names
- **Avatar system** -- upload, crop, WebP conversion with server-side security
- **Flexible registration** -- open, approval-required, or invite-only modes with admin-managed invite codes
- **Admin dashboard** -- site settings, registration mode, pending user approval, federation dashboard, moderation queue, moderation log, invite code management
- **Rate limiting** on login, TOTP, registration, avatar uploads, and federation endpoints
- **Security hardened** -- HSTS, CSP, signed + encrypted cookies, TOTP/key encryption at rest
- **Notifications** -- real-time in-app notifications for replies, mentions, follows, likes, boosts, and moderator actions
- **Direct messages** -- 1-on-1 conversations with read cursors, mute controls, and federated delivery
- **Search** -- full-text search across articles and comments with CJK support and search operators
- **Polls** -- single/multi-choice polls with anonymous voting, expiration, and denormalized counters
- **Bookmarks** -- bookmark articles and comments for later reference
- **Emoji autocomplete** -- type `:shortcode` in any textarea for instant emoji suggestions
- **Markdown toolbar** -- toolbar with formatting shortcuts for article and comment editing
- **RSS/Atom bot accounts** -- admin-managed feed bots that periodically fetch RSS 0.9x/2.0, RSS 1.0 (RDF), Atom, and JSON Feed sources and post articles to target boards; configurable fetch interval, per-bot bio and profile fields, automatic favicon avatar fetching, error tracking with exponential backoff, and manual reset-and-retry
- **User blocking, muting and reporting** -- block local or remote accounts to stop replies, likes, boosts, follows and messages in both directions; mute to hide content locally; report posts, comments, feed items, received messages and accounts to moderators
- **Push notifications** -- PWA with Web Push support and service worker
- **Web Share** -- share the current page to other apps via the OS-level share sheet (smartphone / installed PWA), powered by the Web Share API
- **Internationalization** -- Gettext with zh_TW and ja_JP locales and Accept-Language auto-detection

## Setup

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 15+
- libvips (for image processing)
- Rust toolchain (to compile the html5ever, Ammonia, and feedparser-rs NIFs)

### Installation

```bash
# Clone the repository
git clone https://github.com/hiroshiyui/baudrate.git
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
- `PHX_HOST` -- your production hostname
- `INSTALLATION_KEY` -- required until the setup wizard is completed; without
  it every page answers 503 (see the
  [SysOp Guide](doc/sysop.md#installation-key))

Recommended for operations: `HEALTH_DETAIL_PORT` serves a detailed health
report (queues, workers, disk, backup age) on `127.0.0.1` only, for a monitor on
the server to poll, and `LOG_FORMAT=json` switches the logs to one JSON object
per line (see the [SysOp Guide](doc/sysop.md#detailed-health-report)).

Note: Both TOTP secrets and federation private keys are encrypted at rest
using keys derived from `SECRET_KEY_BASE`, so no additional environment
variables are needed for encryption.

## Documentation

- [SysOp Guide](doc/sysop.md) — installation, configuration, and maintenance for system operators
- [Development Guide](doc/development.md) — architecture, project structure, and development notes
- [Architecture Decision Records](doc/adr/README.md) — why the architecture is the way it is: rationale, alternatives, and trade-offs
- [AP API Reference](doc/api.md) — ActivityPub and public API endpoint documentation
- [Troubleshooting](doc/troubleshooting.md) — common issues and solutions

## License

This project is licensed under the [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html) (AGPL-3.0).

## Acknowledgements

Built with these excellent open-source projects:

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
- [Tailwind CSS](https://tailwindcss.com/) + [DaisyUI](https://daisyui.com/)
- [NimbleTOTP](https://hexdocs.pm/nimble_totp/)
- [wax_](https://hexdocs.pm/wax_/) (WebAuthn / FIDO2 relying party)
- [Hammer](https://hexdocs.pm/hammer/)
- [MDEx](https://hexdocs.pm/mdex/) (Markdown rendering, CommonMark + GFM via comrak)
- [Req](https://hexdocs.pm/req/) (HTTP client for federation)
- [html5ever](https://github.com/servo/html5ever) (Rust HTML parser NIF for link preview extraction)
- [Ammonia](https://crates.io/crates/ammonia) (Rust HTML sanitizer)
- [feedparser-rs](https://crates.io/crates/feedparser-rs) (Rust feed parser NIF for RSS/Atom/JSON Feed)
- [Rustler](https://crates.io/crates/rustler) (Rust NIF bindings for Erlang/Elixir)
- [regex](https://crates.io/crates/regex) (Rust regular expressions)
