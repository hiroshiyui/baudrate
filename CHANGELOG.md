# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-03-08

### Added

- **Article and comment boosts** — fully federated via ActivityPub `Announce` /
  `Undo(Announce)` activities, with self-boost prevention and soft-delete guards
- **Like and boost buttons** on article pages, board listings, and personal feed
  for both local content and remote feed items
- **Feed item interactions** — like and boost remote feed items, sending AP
  `Like` / `Announce` activities to the remote actor's inbox
- **Boost notification types** — `article_boosted` and `comment_boosted` with
  per-user notification preferences
- New database tables: `article_boosts`, `comment_boosts`, `feed_item_likes`,
  `feed_item_boosts`

### Changed

- **Comment likes now federated** — upgraded from local-only to sending AP
  `Like` / `Undo(Like)` activities with AP ID stamping (previously comment likes
  had no federation support)
- **Shared interaction helpers** — extracted `Content.Interactions` module
  (visibility checks, AP ID stamping, constraint detection) and
  `InteractionHelpers` module (generic LiveView toggle handlers), reducing ~336
  lines of duplication across likes, boosts, and three LiveViews

### Fixed

- **Unsafe integer parsing in feed toggle handlers** — replaced
  `String.to_integer` with `parse_id/1` to prevent crashes from malicious input
- **IDOR on feed item interactions** — added `feed_item_accessible?/2` check to
  verify user follows the remote actor before allowing like/boost
- **Board visibility bypass on like/boost** — added `article_visible_to_user?/2`
  to prevent interaction with articles in boards the user lacks permission to view
- **Remote Like/Announce on private content** — inbox handler now rejects
  incoming AP activities targeting articles in non-public or non-AP-enabled boards
- **Missing AP ID format validation** — remote boost schemas now validate that
  `ap_id` is an HTTP(S) URL
- **Missing `comment_liked` notification preference** in profile settings UI

### Security

- Board visibility enforcement on all like/boost toggle operations
- Feed item access validation requiring active follow relationship
- AP ID URL format validation on remote boost changesets
- Reject federation activities targeting non-federated content

## [1.2.18] — 2026-03-08

### Fixed

- **Mention/hashtag class stripped by federation sanitizer** — preserved CSS
  classes on anchor tags (`<a class="mention">`, `<a class="hashtag">`) during
  HTML sanitization of incoming ActivityPub content

## [1.2.17] — 2026-03-07

### Added

- **`/@username` handle redirect** — visiting `/@username` redirects to the
  user's ActivityPub profile URL for compatibility with Mastodon-style handles

## [1.2.16] — 2026-03-07

### Changed

- Increased comment and reply textarea rows to 6 for better editing UX
- Increased article body textarea rows to 12

## [1.2.15] — 2026-03-07

### Fixed

- **Missing hover state on board page cards** — added background darken on hover
  for sub-board and article cards

## [1.2.14] — 2026-03-07

### Added

- **Touch/tap feedback** on interactive cards with animated blur fade-out

### Fixed

- **AP IDs missing on existing local content** — backfill migration stamps AP IDs
  on existing articles, comments, likes, polls, and DMs
- **Remote reply chain resolution** — inbox handler now walks remote reply chains
  (up to 10 hops) to resolve intermediate replies as local comments
- **Comment AP ID stamping** — local comments now stamped with canonical AP IDs
  on creation for federation reply resolution

### Changed

- Federation publisher and article objects now use stored AP IDs with fallback to
  `Federation.actor_uri/2`

## [1.2.13] — 2026-03-06

### Added

- Unauthenticated access guard tests for all LiveViews
- Filters unit tests and `format_relative_time` helper tests

### Fixed

- **Reconnect error flash on PWA sleep/wake** — delayed error display to avoid
  jarring flicker
- **Semantic HTML** — use `<section>` with `aria-labelledby` on main pages
- **Search button accessibility** — added `aria-label` to search submit button
- **Article image ownership check** — `remove_image` in `ArticleNewLive` now
  validates ownership; fixed `:code.priv_dir` usage

### Changed

- Extracted `format_relative_time` to shared `Helpers` module

## [1.2.12] — 2026-03-06

### Added

- **Emoji autocomplete** — client-side emoji autocomplete dropdown for textareas

### Fixed

- Emoji autocomplete dropdown now appends to `document.body` to avoid clipping

## [1.2.11] — 2026-03-06

### Added

- E2E feature tests for likes, bookmarks, deletion, messages, invites, following

### Fixed

- **Link preview card layout** — removed `block` class overriding `card-side`
  flex layout
- **Rate limit test isolation** — clear Hammer buckets between feature tests

## [1.2.10] — 2026-03-06

### Fixed

- **Article/comment metadata overflow** — allow metadata row to wrap on narrow
  screens

## [1.2.9] — 2026-03-06

### Fixed

- **Unread indicator clipped** — prevent dot from being clipped in flex layout
- **DaisyUI menu dividers** — use idiomatic dividers instead of non-functional
  `divider` class

## [1.2.8] — 2026-03-06

### Fixed

- **Image proxy return value mismatch** — match `Image.write/3` return value
  correctly in `ImageProxy`

## [1.2.7] — 2026-03-06

### Changed

- **Replaced Floki with html5ever NIF** for link preview HTML parsing — faster
  and consistent with the existing Rust NIF stack

## [1.2.6] — 2026-03-06

### Fixed

- **Article metadata overflow** on board page — prevent long text from exceeding
  card bounds

## [1.2.5] — 2026-03-05

### Fixed

- **Link preview fetcher crash** — handle `Ecto.Changeset` error gracefully

## [1.2.4] — 2026-03-05

### Fixed

- **Remote article timestamp link** — restored clickable datetime link to
  original source for remote articles on board listing

## [1.2.3] — 2026-03-05

### Changed

- **Clickable article cards** — entire article card on board page is now
  clickable via stretched link

## [1.2.2] — 2026-03-05

### Changed

- Article excerpt on board page now clickable

## [1.2.1] — 2026-03-05

### Added

- **Link previews** — automatic OG metadata extraction on content save, server-
  side image proxying (re-encoded to WebP via libvips), shared/deduplicated
  `link_previews` table, preview card UI component, stale refresh (>7 days) and
  orphan cleanup (>30 days) via `SessionCleaner`
- **Open Graph and Twitter Card meta tags** for rich social link previews on
  article, board, user profile, and home pages
- Link preview emitted as AP attachment in outbound articles

## [1.2.0] — 2026-03-05

### Fixed

- **Long URLs break layout** on Chrome Android — force word-break in prose
  content

## [1.1.30] — 2026-03-05

### Fixed

- **Mobile bottom navbar width** — constrain to viewport width

## [1.1.29] — 2026-03-05

### Fixed

- **Theme color alignment** — match theme color with favicon primary color
- **Mobile bottom navbar overflow** — prevent expansion with overflowing content

## [1.1.28] — 2026-03-05

### Changed

- Local article timestamps on board listing now link to the article page

## [1.1.27] — 2026-03-05

### Added

- Article timestamps on board listing now link to source URL for remote articles

### Changed

- Rebranded as "ActivityPub-enabled Bulletin Board System"

## [1.1.26] — 2026-03-05

### Added

- **Pagination for admin invite codes page**
- **Remote actor profile links** — clickable actor names link to their profile
  pages; store profile URL from ActivityPub JSON

### Fixed

- **External link rel attributes** — added `nofollow` to all external links

## [1.1.25] — 2026-03-05

### Fixed

- **Remote article titles** — derive meaningful titles for remote articles
  without a `name` field
- **Remote actor avatars** — show on board, article, tag, search, and bookmark
  pages

## [1.1.24] — 2026-03-05

### Changed

- Bold form labels and increased fieldset spacing in article forms
- Removed emoji prefixes from article form labels

## [1.1.23] — 2026-03-05

### Added

- **Public profile link** shown on user profile page

## [1.1.22] — 2026-03-05

### Fixed

- **HTML entities in federation display** — decode HTML entities in
  `strip_html` for correct display of remote content

## [1.1.21] — 2026-03-04

### Changed

- Thickened navbar border edges for better visual separation

## [1.1.20] — 2026-03-04

### Fixed

- **PWA installability** — added PNG icons and fetch handler required for
  browser install prompt

## [1.1.19] — 2026-03-04

### Fixed

- **Recovery codes regenerated on TOTP enable** — no longer regenerates recovery
  codes when user enables TOTP (existing codes are preserved)

## [1.1.18] — 2026-03-04

### Fixed

- **Federated article author display** — show remote actor as author on
  federated articles by preloading `remote_actor` association

## [1.1.17] — 2026-03-04

### Fixed

- **Board WebFinger subject** — removed non-standard `!` prefix from board
  WebFinger subject for Mastodon compatibility
- **Federation delivery error logging** — capture HTTP response body on delivery
  errors for debugging

## [1.1.16] — 2026-03-04

### Added

- **PWA Web Share Target** — receive shared content from other apps, pre-filling
  article form (supports boardless articles)
- E2E browser tests for search, editing, comments, profiles

### Fixed

- **Board follows page guard** — prevent access on non-federated boards
- **Cache-Control on AP endpoints** — add `no-store` to actor and WebFinger
  responses
- **Board WebFinger** — support bare board slug for Mastodon compatibility
- **Admin federation dashboard** — show all boards including sub-boards
- **Poll sync** — replace `Enum.each+update!` with `Enum.reduce_while`
- **Form accessibility** — improve inputs across login, search, uploads
- **Null byte check** — add to `sanitize_admin_return_to` for consistency
- **Report target IDs** — use safe `Integer.parse` to prevent crash

### Changed

- Split Content context into focused sub-modules with facade pattern
- Extract `roles_at_or_below/1` to deduplicate role-level mapping

## [1.1.15] — 2026-03-04

### Fixed

- **Board keypair missing** — ensure board keypair exists before federation
  delivery

## [1.1.14] — 2026-03-04

### Changed

- Skip board picker when creating article from a board URL (auto-select current
  board)

## [1.1.13] — 2026-03-04

### Fixed

- **Sub-board missing from board list** — include sub-boards in article creation
  board picker

## [1.1.12] — 2026-03-04

### Changed

- Improved feed item layout — badges below time, home icon for local items
- Removed gap between "View original" and "Reply" buttons in feed

## [1.1.11] — 2026-03-04

### Changed

- Replaced feed "View original" text link with icon button
- Consolidated article actions into ellipsis dropdown menu
- Moved Bio & Signature sections below Display Name on profile page

### Fixed

- **Profile avatar mobile layout** — added `flex-wrap` for narrow screens

### Refactored

- Extracted shared `extract_peer_ip/1` helper with proxy header support

## [1.1.10] — 2026-03-03

### Changed

- **Performance** — merged sidebar article + comment count into single query,
  consolidated 3 feed count queries into single SQL round-trip, merged
  hidden_ids blocks + mutes into single `union_all` query
- Added `descendant_ids` to `BoardCache` for O(1) sub-board lookups,
  eliminating recursive CTE

## [1.1.9] — 2026-03-03

### Added

- **ETS-backed settings cache** — O(1) lookups via `Baudrate.Setup.SettingsCache`
  with automatic refresh on `set_setting/2`
- **ETS-backed board cache** — O(1) lookups via `Baudrate.Content.BoardCache`
  with automatic refresh on board mutations

## [1.1.8] — 2026-03-03

### Added

- **Inline feed replies** — reply to remote feed items via ActivityPub directly
  from the feed page
- 120px avatar size for profile pages

## [1.1.7] — 2026-03-03

### Fixed

- **HTTP Signature digest verification** — preserve raw body for signature
  verification instead of re-encoding

## [1.1.6] — 2026-03-03

### Fixed

- **Avatar URL in AP actor endpoint** — use integer size parameter instead of
  string

## [1.1.5] — 2026-03-03

### Fixed

- **Duplicate Host header** in HTTP Signature outgoing requests — removed
  duplicate header that caused signature verification failures on remote
  instances

## [1.1.4] — 2026-03-03

### Fixed

- **User keypair missing before follow** — ensure user keypair exists before
  federation follow delivery
- Ansible `inject_facts_as_vars` deprecation warnings

## [1.1.3] — 2026-03-03

### Security

- **Federated image CSP** — allow federated images in Content Security Policy
  and validate avatar URLs

## [1.1.2] — 2026-03-03

### Added

- **Mobile bottom navigation** — icon dock with `aria-current` tracking

### Changed

- Refactored board page layout and action buttons

## [1.1.1] — 2026-03-03

### Changed

- Unified mobile hamburger menu for all users
- Made admin menu collapsible in navigation dropdowns

## [1.1.0] — 2026-03-03

### Added

- **Admin sudo mode** — TOTP re-verification for admin routes with 10-minute
  session window, 5-attempt lockout, and moderator pass-through

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

[1.3.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.0
[1.2.18]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.18
[1.2.17]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.17
[1.2.16]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.16
[1.2.15]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.15
[1.2.14]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.14
[1.2.13]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.13
[1.2.12]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.12
[1.2.11]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.11
[1.2.10]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.10
[1.2.9]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.9
[1.2.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.8
[1.2.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.7
[1.2.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.6
[1.2.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.5
[1.2.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.4
[1.2.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.3
[1.2.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.2
[1.2.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.1
[1.2.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.2.0
[1.1.30]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.30
[1.1.29]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.29
[1.1.28]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.28
[1.1.27]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.27
[1.1.26]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.26
[1.1.25]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.25
[1.1.24]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.24
[1.1.23]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.23
[1.1.22]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.22
[1.1.21]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.21
[1.1.20]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.20
[1.1.19]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.19
[1.1.18]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.18
[1.1.17]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.17
[1.1.16]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.16
[1.1.15]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.15
[1.1.14]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.14
[1.1.13]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.13
[1.1.12]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.12
[1.1.11]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.11
[1.1.10]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.10
[1.1.9]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.9
[1.1.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.8
[1.1.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.7
[1.1.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.6
[1.1.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.5
[1.1.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.4
[1.1.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.3
[1.1.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.2
[1.1.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.1
[1.1.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.1.0
[1.0.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.8
[1.0.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.7
[1.0.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.6
[1.0.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.5
[1.0.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.4
[1.0.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.3
[1.0.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.2
[1.0.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.1
[1.0.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.0
