# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.0.0
