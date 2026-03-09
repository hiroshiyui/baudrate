# Changelog — 1.0.x

For the current changelog, see [CHANGELOG.md](CHANGELOG.md).

## [1.0.8] — 2026-03-03

### Added

- **User-facing abuse report UI** — report articles, comments, and users with
  duplicate check and rate limiting
- **Reported user info** displayed in admin moderation queue
- **Configurable site name** — use admin-configured site name in navbar and page
  title

## [1.0.7] — 2026-03-03

### Fixed

- **Avatar crop broken in production** — CropperJS initialization used a fixed
  `setTimeout(100ms)` that raced with the LiveView server round-trip. In
  production with network latency, the crop dialog was not yet visible when
  CropperJS tried to initialize, resulting in a 0×0 container and a silently
  broken crop UI. Replaced the timeout with the LiveView hook `updated()`
  lifecycle callback, which fires after the server's DOM patch renders the
  dialog.

## [1.0.6] — 2026-03-02

### Fixed

- **File uploads broken in production (avatars, article images)** — upload
  directory paths used compile-time module attributes with `:code.priv_dir/1`,
  which resolves to the build directory instead of the release directory in OTP
  releases. Combined with systemd's `ProtectSystem=strict`, writes to the build
  path were blocked. Converted to runtime `Application.app_dir/2` function calls.

### Changed

- **Deploy playbook runs as `baudrate` user** — all deploy tasks now default to
  the `baudrate` system user instead of root. Only systemd operations escalate
  to root. This fixes root-owned symlinks (`current`, `static`, `uploads`)
  created by the previous configuration.

## [1.0.5] — 2026-03-02

### Fixed

- **Stale OTP release directories break asset serving** — `mix release
  --overwrite` does not remove old `lib/baudrate-<version>/` directories,
  causing the static symlink glob to resolve to the wrong version. The
  deploy playbook now cleans `_build/prod/rel/` before each build.

## [1.0.4] — 2026-03-02

### Fixed

- **Assets 404 after redeployment** — the `static` symlink used a path
  through the `current` symlink with a version-specific directory name;
  when a new version was deployed, the old version path no longer existed.
  Now uses `readlink -f` to store an absolute resolved path.

### Changed

- **Registration page layout widened** — container changed from `max-w-sm`
  (384px) to `max-w-lg` (512px) for better readability

## [1.0.3] — 2026-03-02

### Fixed

- **Favicon and webmanifest 404 in production** — nginx location regex now
  matches Phoenix digest-stamped filenames (e.g. `favicon-abc123.svg`) in
  addition to the original filenames

## [1.0.2] — 2026-03-02

### Fixed

- **Markdown preview prose styling** — added `@tailwindcss/typography` plugin
  so the `prose` class renders headings, links, lists, code blocks, and
  blockquotes with proper styles across all markdown preview, article,
  comment, and DM views
- **Markdown preview reply pattern** — switched from `push_event` broadcast
  to `{:halt, reply, socket}` for immediate response to the JS hook
- **Ansible SOPS secrets not loading** — renamed `secrets.sops.yml` to
  `all.sops.yml` so the `community.sops.sops` vars plugin auto-decrypts
  it (files must be named after an Ansible group)
- **Ansible database migration failure** — added `DATABASE_SSL=false` to the
  migration task environment for servers without SSL-configured PostgreSQL
- **Ansible callback plugin removed** — replaced `community.general.yaml`
  with built-in `stdout_callback = default` + `result_format = yaml`
- **Ansible asdf v0.16 installation** — rewrote the Elixir role to download
  the Go binary from GitHub releases instead of git-cloning the legacy
  Bash-based asdf

### Security

- **Service worker open redirect** — validate same-origin URLs in
  notification click handler to prevent navigation to external sites

## [1.0.1] — 2026-03-02

### Added

- **Installation key for setup wizard** — optional `INSTALLATION_KEY` env var
  gates the first-run `/setup` wizard to prevent unauthorized setup completion.
  Uses constant-time comparison and locks after 3 failed attempts (30s cooldown).
- Ansible deployment automation (`deploy-baudrate.yml`) with OTP release build,
  symlink-based rollback, systemd management, and health checks
- Ansible server provisioning (`setup-server.yml`) with roles for common system
  packages, PostgreSQL, Elixir (asdf), Rust, and nginx with Let's Encrypt SSL
- SOPS-based secrets management for Ansible with GPG encryption
- Installation key auto-generation in the deploy playbook when not pre-configured
- zh_TW and ja_JP translations for installation key UI strings

### Changed

- Nginx templates updated to use `static_path` symlink for stable asset serving

## [1.0.0] — 2026-03-01

Initial stable release of Baudrate, a public BBS / Web Forum built with
Elixir/Phoenix + LiveView, federating via ActivityPub.

### Core Platform

- Role-based access control (admin, moderator, user, guest) with normalized
  permission system
- Board management with nesting (sub-boards), per-board role-based view/post
  permissions, and board moderator assignments
- Article creation/editing with revision history and inline diffs
- Threaded comments with soft-delete
- Full-text search with CJK support, advanced search operators, and board search
- Cross-board article forwarding with forwardable controls
- Inline article polls with anonymous voting and denormalized counters
- Article and comment likes/favorites
- Article and comment bookmarks
- Hashtag extraction, storage, and tag browse page
- Per-article and per-board read tracking with unread indicators
- Pagination across all list views

### Authentication & Security

- TOTP two-factor authentication (required for admin/moderator, optional for
  users) with encrypted secrets (AES-256-GCM)
- Recovery codes (high-entropy base32 + HMAC-SHA256)
- Server-side session management with token rotation
- Per-account brute-force protection with progressive delay
- Per-user rate limiting on content endpoints
- WebSocket mount rate limiting
- SSRF-safe remote fetches (reject private/loopback IPs, HTTPS only)
- Content Security Policy, HSTS, and Referrer-Policy headers
- File upload validation with magic bytes; avatars re-encoded as WebP
- 1 MB body size limit on browser requests

### ActivityPub Federation

- Full ActivityPub protocol support for User (Person) and Board (Group) actors
- HTTP Signature verification for inbound activities
- Authorized fetch mode (signed GET fallback)
- Inbox handling for Follow, Create, Like, Announce, Delete, Update, Move,
  Flag, and their Undo variants
- DB-backed delivery queue with exponential backoff retry
- Mastodon and Lemmy compatibility (Page to Article, embedded Announce objects,
  attributedTo arrays, content warnings)
- Board-level remote follows with accept policy enforcement
- User-level outbound follows with personal feed
- ActivityPub direct messages (1-on-1)
- Poll federation (Create/Update Question, vote delivery)
- Article forwarding federation (Create + Announce)
- Key rotation support with encrypted private keys (AES-256-GCM)
- Domain blocklist with audit trail
- Stale remote actor cleanup worker
- Public API via content-negotiated AP endpoints with CORS

### User Features

- User profiles with display name, bio, avatar (crop + WebP), and stats
- Invite code system with per-user quota, expiry, revoke-on-ban, and chain
  tracking
- Registration modes: open, approval required, invite only
- User blocking (controls interaction, not visibility)
- User muting (local-only soft-mute)
- Draft autosave for articles and comments
- Markdown editor toolbar with live preview
- Article image uploads with gallery display

### Direct Messaging

- 1-on-1 direct messages with conversations and read cursors
- Real-time unread DM count badge in navbar
- Federation support for DMs via restricted AP addressing

### Notifications

- In-app notification system (reply, mention, follow, like, forward, moderation,
  admin announcement)
- Real-time unread count badge with PubSub
- Per-type notification preferences
- Self-notification, blocked, and muted suppression

### Web Push & PWA

- Web Push notifications (RFC 8291 encryption, VAPID ES256)
- Admin VAPID key management UI
- User push subscription preferences
- Service worker with offline fallback
- PWA manifest with theme color

### Moderation

- Report system with resolve/dismiss workflow
- Moderation audit log
- Bulk moderation actions (admin users and moderation queue pages)
- Admin board management (CRUD, permissions, moderators)
- Admin user management with banning
- Admin federation dashboard with delivery stats and instance overview
- Admin-configurable DaisyUI themes
- Admin site settings (site name, registration mode, timezone, tagline)
- Admin analytics for known remote instances

### Accessibility

- WAI-ARIA attributes across all UI components
- Semantic HTML5 elements with ARIA landmarks
- Focus management with skip-link and auto-focus after navigation
- Focus-visible highlight for keyboard navigation
- Modal focus trapping
- WCAG contrast compliance (text-base-content/70 minimum)
- Screen reader feedback on dynamic actions
- Minimum font size enforcement with zoom controls

### Internationalization

- Gettext-based i18n with zh_TW and ja_JP locales
- Accept-Language auto-detection with user locale preferences
- Localized Markdown editor toolbar

### Feeds & Discovery

- RSS 2.0 and Atom 1.0 syndication feeds
- JSON-LD and Dublin Core metadata for SEO
- WebFinger and NodeInfo discovery endpoints

### Infrastructure

- First-run setup wizard with RBAC seeding
- Mix tasks for data backup and restore
- Selenium setup task for browser testing
- Health endpoint for load balancers
- Graceful shutdown for delivery worker
- Telemetry events for federation delivery
- ETS-cached domain blocking decisions
- Partial database indexes for soft-delete queries
- Denormalized last_activity_at for bump ordering

### Developer Experience

- Comprehensive test suite (2400+ tests, 4-partition parallel execution)
- Browser testing with Wallaby + Selenium + Firefox
- HTML sanitization via Ammonia Rust NIF (Rustler)
- Extensive documentation (development guide, SysOp guide, API reference,
  troubleshooting guide)

[1.0.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.8
[1.0.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.7
[1.0.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.6
[1.0.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.5
[1.0.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.4
[1.0.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.3
[1.0.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.2
[1.0.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.1
[1.0.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.0
