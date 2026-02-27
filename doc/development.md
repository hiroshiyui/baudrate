# Development Guide

Baudrate is a **public information hub**, not a social network. Public content
should remain visible to all users; blocking controls interaction, not
visibility. Design decisions should reflect this philosophy.

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
| HTML sanitization | Ammonia (Rust NIF via Rustler) |
| Rate limiting | Hammer |
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |

## Architecture

### Project Structure

```
native/
└── baudrate_sanitizer/          # Rust NIF crate (Ammonia HTML sanitizer)
    ├── Cargo.toml               # Crate manifest (ammonia, rustler, regex)
    └── src/
        └── lib.rs               # NIF functions: sanitize_federation, sanitize_markdown, strip_tags
lib/
├── baudrate/                    # Business logic (contexts)
│   ├── application.ex           # Supervision tree
│   ├── repo.ex                  # Ecto repository
│   ├── auth.ex                  # Auth context: login, registration, TOTP, sessions, avatars, invite codes (quota), password reset, user blocks, user mutes
│   ├── auth/
│   │   ├── invite_code.ex       # InviteCode schema (invite-only registration)
│   │   ├── login_attempt.ex     # LoginAttempt schema (per-account brute-force tracking)
│   │   ├── recovery_code.ex     # Ecto schema for one-time recovery codes
│   │   ├── session_cleaner.ex   # GenServer: hourly cleanup (sessions, login attempts, orphan images)
│   │   ├── totp_vault.ex        # AES-256-GCM encryption for TOTP secrets
│   │   ├── user_block.ex        # UserBlock schema (local + remote actor blocks)
│   │   ├── user_mute.ex         # UserMute schema (local-only soft-mute/ignore)
│   │   └── user_session.ex      # Ecto schema for server-side sessions
│   ├── avatar.ex                # Avatar image processing (crop, resize, WebP)
│   ├── content.ex               # Content context: boards, articles, comments, likes, user stats, revision tracking
│   ├── content/
│   │   ├── article.ex           # Article schema (posts, local + remote, soft-delete)
│   │   ├── article_image.ex     # ArticleImage schema (gallery images on articles)
│   │   ├── article_revision.ex  # ArticleRevision schema (edit history snapshots)
│   │   ├── article_image_storage.ex # Image processing (resize, WebP, strip EXIF)
│   │   ├── article_like.ex      # ArticleLike schema (local + remote likes)
│   │   ├── article_tag.ex        # ArticleTag schema (article ↔ hashtag, extracted from body)
│   │   ├── board.ex             # Board schema (hierarchical via parent_id, role-based permissions)
│   │   ├── board_article.ex     # Join table: board ↔ article
│   │   ├── board_moderator.ex   # Join table: board ↔ moderator
│   │   ├── comment.ex           # Comment schema (threaded, local + remote, soft-delete)
│   │   ├── markdown.ex          # Markdown → HTML rendering (Earmark + Ammonia NIF + hashtag/mention linkification + mention extraction)
│   │   └── pubsub.ex            # PubSub helpers for real-time content updates
│   ├── sanitizer/
│   │   └── native.ex            # Rustler NIF bindings to Ammonia HTML sanitizer
│   ├── messaging.ex             # Messaging context: 1-on-1 DMs, conversations, DM access control
│   ├── messaging/
│   │   ├── conversation.ex      # Conversation schema (local-local and local-remote)
│   │   ├── conversation_read_cursor.ex # Per-user read position tracking
│   │   ├── direct_message.ex    # DirectMessage schema (local + remote, soft-delete)
│   │   └── pubsub.ex            # PubSub helpers for real-time DM updates
│   ├── federation.ex            # Federation context: actors, outbox, followers, announces, key rotation
│   ├── federation/
│   │   ├── actor_resolver.ex    # Remote actor fetching and caching (24h TTL, signed fetch fallback)
│   │   ├── announce.ex          # Announce (boost) schema
│   │   ├── blocklist_audit.ex   # Audit local blocklist against external known-bad-actor lists
│   │   ├── delivery.ex          # Outgoing activity delivery (Accept, queue, retry, block delivery)
│   │   ├── delivery_job.ex      # DeliveryJob schema (delivery queue records)
│   │   ├── delivery_worker.ex   # GenServer: polls delivery queue, retries failed jobs
│   │   ├── domain_block_cache.ex # ETS-backed cache for domain blocking decisions
│   │   ├── stale_actor_cleaner.ex # GenServer: daily stale remote actor cleanup
│   │   ├── follower.ex          # Follower schema (remote → local follows)
│   │   ├── http_client.ex       # SSRF-safe HTTP client for remote fetches (unsigned + signed GET)
│   │   ├── http_signature.ex    # HTTP Signature signing and verification (POST + GET)
│   │   ├── inbox_handler.ex     # Incoming activity dispatch (Follow, Create, Like, Block, etc.)
│   │   ├── key_store.ex         # RSA-2048 keypair management for actors (generate, ensure, rotate)
│   │   ├── key_vault.ex         # AES-256-GCM encryption for private keys at rest
│   │   ├── remote_actor.ex      # RemoteActor schema (cached remote profiles)
│   │   ├── user_follow.ex       # UserFollow schema (outbound follows: remote actors + local users)
│   │   ├── feed_item.ex         # FeedItem schema (posts from followed remote actors)
│   │   ├── pubsub.ex            # Federation PubSub (user feed events)
│   │   ├── publisher.ex         # ActivityStreams JSON builders for outgoing activities
│   │   ├── sanitizer.ex         # HTML sanitizer for federated content (Ammonia NIF)
│   │   ├── delivery_stats.ex    # Delivery queue stats and admin management
│   │   ├── instance_stats.ex    # Per-domain instance statistics
│   │   └── validator.ex         # AP input validation (URLs, sizes, attribution, allowlist/blocklist)
│   ├── moderation.ex            # Moderation context: reports, resolve/dismiss, audit log
│   ├── moderation/
│   │   ├── log.ex               # ModerationLog schema (audit trail of moderation actions)
│   │   └── report.ex            # Report schema (article, comment, remote actor targets)
│   ├── notification.ex          # Notification context: create, list, mark read, cleanup, admin announcements
│   ├── notification/
│   │   ├── hooks.ex             # Fire-and-forget notification creation hooks (comment, article, like, follow, report)
│   │   ├── notification.ex      # Notification schema (type, read, data, actor, article, comment refs)
│   │   └── pubsub.ex            # PubSub helpers for real-time notification updates
│   ├── setup.ex                 # Setup context: first-run wizard, RBAC seeding, settings
│   ├── timezone.ex              # IANA timezone identifiers (compiled from tz library data)
│   └── setup/
│       ├── permission.ex        # Permission schema (scope.action naming)
│       ├── role.ex              # Role schema (admin/moderator/user/guest)
│       ├── role_permission.ex   # Join table: role ↔ permission
│       ├── setting.ex           # Key-value settings (site_name, timezone, setup_completed, etc.)
│       └── user.ex              # User schema with password, TOTP, avatar, display_name, status, signature fields
├── baudrate_web/                # Web layer
│   ├── components/
│   │   ├── core_components.ex   # Shared UI components (avatar, flash, input, etc.)
│   │   └── layouts.ex           # App and setup layouts with nav, theme toggle, footer
│   ├── controllers/
│   │   ├── activity_pub_controller.ex  # ActivityPub endpoints (content-negotiated)
│   │   ├── error_html.ex        # HTML error pages
│   │   ├── error_json.ex        # JSON error responses
│   │   ├── feed_controller.ex   # RSS 2.0 / Atom 1.0 syndication feeds
│   │   ├── feed_xml.ex          # Feed XML rendering (EEx templates, helpers)
│   │   ├── feed_xml/            # EEx templates for RSS and Atom XML
│   │   │   ├── rss.xml.eex     # RSS 2.0 channel + items template
│   │   │   └── atom.xml.eex    # Atom 1.0 feed + entries template
│   │   ├── page_controller.ex   # Static page controller
│   │   └── session_controller.ex  # POST endpoints for session mutations
│   ├── live/
│   │   ├── admin/
│   │   │   ├── boards_live.ex          # Admin board CRUD + moderator management
│   │   │   ├── federation_live.ex      # Admin federation dashboard
│   │   │   ├── invites_live.ex         # Admin invite code management (generate, revoke, invite chain)
│   │   │   ├── login_attempts_live.ex # Admin login attempts viewer (paginated, filterable)
│   │   │   ├── moderation_live.ex     # Moderation queue (reports)
│   │   │   ├── moderation_log_live.ex # Moderation audit log (filterable, paginated)
│   │   │   ├── pending_users_live.ex  # Admin approval of pending registrations
│   │   │   ├── settings_live.ex       # Admin site settings (name, timezone, registration, federation)
│   │   │   └── users_live.ex          # Admin user management (paginated, filterable, ban, unban, role change)
│   │   ├── article_edit_live.ex  # Article editing form
│   │   ├── article_history_live.ex # Article edit history with inline diffs
│   │   ├── article_live.ex      # Single article view with paginated comments
│   │   ├── article_new_live.ex  # Article creation form
│   │   ├── auth_hooks.ex        # on_mount hooks: require_auth, optional_auth, etc.
│   │   ├── board_live.ex        # Board view with article listing
│   │   ├── conversation_live.ex # Single DM conversation thread view
│   │   ├── conversations_live.ex # DM conversation list
│   │   ├── feed_live.ex          # Personal feed (remote posts, local articles, comment activity)
│   │   ├── following_live.ex    # Following management (outbound remote actor follows)
│   │   ├── home_live.ex         # Home page (board listing, public for guests)
│   │   ├── login_live.ex        # Login form (phx-trigger-action pattern)
│   │   ├── password_reset_live.ex  # Password reset via recovery codes
│   │   ├── profile_live.ex      # User profile with avatar upload/crop, locale prefs, signature
│   │   ├── recovery_code_verify_live.ex  # Recovery code login
│   │   ├── recovery_codes_live.ex        # Recovery codes display
│   │   ├── register_live.ex     # Public user registration (supports invite-only mode, terms notice, recovery codes)
│   │   ├── search_live.ex       # Full-text search + remote actor lookup (WebFinger/AP)
│   │   ├── tag_live.ex          # Browse articles by hashtag (/tags/:tag)
│   │   ├── user_invites_live.ex # User invite code management (quota-limited, generate, revoke)
│   │   ├── user_content_live.ex # Paginated user articles/comments (/users/:username/articles|comments)
│   │   ├── user_profile_live.ex # Public user profile pages (stats, recent articles)
│   │   ├── setup_live.ex        # First-run setup wizard
│   │   ├── totp_reset_live.ex   # Self-service TOTP reset/enable
│   │   ├── totp_setup_live.ex   # TOTP enrollment with QR code
│   │   └── totp_verify_live.ex  # TOTP code verification
│   ├── plugs/
│   │   ├── authorized_fetch.ex  # Optional HTTP Signature verification on AP GET requests
│   │   ├── cache_body.ex        # Cache raw request body (for HTTP signature verification)
│   │   ├── cors.ex              # CORS headers for AP GET endpoints (Allow-Origin: *)
│   │   ├── ensure_setup.ex      # Redirect to /setup until setup is done
│   │   ├── rate_limit.ex        # IP-based rate limiting (Hammer)
│   │   ├── rate_limit_domain.ex # Per-domain rate limiting for AP inboxes
│   │   ├── real_ip.ex           # Real client IP extraction from proxy headers
│   │   ├── refresh_session.ex   # Token rotation every 24h
│   │   ├── require_ap_content_type.ex  # AP content-type validation (415 on non-AP types)
│   │   ├── set_locale.ex        # Accept-Language + user preference locale detection
│   │   ├── set_theme.ex         # Inject admin-configured DaisyUI theme assigns
│   │   └── verify_http_signature.ex  # HTTP Signature verification for AP inboxes
│   ├── endpoint.ex              # HTTP entry point, session config
│   ├── gettext.ex               # Gettext i18n configuration
│   ├── locale.ex                # Locale resolution (Accept-Language + user prefs)
│   ├── linked_data.ex          # JSON-LD + Dublin Core metadata builders (SIOC/FOAF/DC)
│   ├── rate_limits.ex           # Per-user rate limit checks (Hammer, fail-open)
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

### Brute-Force Protection

> **See the [SysOp Guide](sysop.md#login-monitoring-adminlogin-attempts) for
> operational details on login monitoring and throttle thresholds.**

Login attempts are rate-limited at two levels:

1. **Per-IP** — Hammer ETS (10 attempts / 5 min)
2. **Per-account** — progressive delay based on failed attempts in the last
   hour (5s / 30s / 120s at 5 / 10 / 15+ failures)

This uses **progressive delay** (not hard lockout) to avoid a DoS vector where
an attacker could lock out any account by submitting wrong passwords. The delay
is checked before `authenticate_by_password/2` to avoid incurring bcrypt cost
on throttled attempts.

Key functions in `Auth`:
- `record_login_attempt/3` — records an attempt (username lowercased)
- `check_login_throttle/1` — returns `:ok` or `{:delay, seconds}`
- `paginate_login_attempts/1` — paginated admin query
- `purge_old_login_attempts/0` — cleanup (called by `SessionCleaner`)

### Session Management

> **See the [SysOp Guide](sysop.md#session-security) for operational details.**

| Aspect | Detail |
|--------|--------|
| Token type | Dual tokens: session token (auth) + refresh token (rotation) |
| Storage | SHA-256 hashes in `user_sessions` table; raw tokens in signed+encrypted cookie |
| TTL | 14 days from creation or last rotation |
| Rotation | `RefreshSession` plug rotates both tokens every 24 hours |
| Concurrency | Max 3 sessions per user; oldest (by `refreshed_at`) evicted |
| Cleanup | `SessionCleaner` GenServer purges expired sessions every hour |

### RBAC

> **See the [SysOp Guide](sysop.md#roles--permissions-rbac) for role
> management and user administration.**

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

#### Role Level Comparison

`Setup.role_level/1` maps role names to numeric levels for comparison:

| Role | Level |
|------|-------|
| guest | 0 |
| user | 1 |
| moderator | 2 |
| admin | 3 |

`Setup.role_meets_minimum?/2` checks if a user's role meets a minimum
requirement (e.g., `role_meets_minimum?("moderator", "user")` → `true`).

### Board Permissions

> **See the [SysOp Guide](sysop.md#board-management) for board administration.**

Boards have two role-based permission fields:

| Field | Values | Default | Purpose |
|-------|--------|---------|---------|
| `min_role_to_view` | guest, user, moderator, admin | guest | Minimum role required to see the board and its articles |
| `min_role_to_post` | user, moderator, admin | user | Minimum role required to create articles in the board |

Key functions in `Content`:

- `can_view_board?(board, user)` — checks `min_role_to_view` against user's role
- `can_post_in_board?(board, user)` — checks `min_role_to_post` + active status + `user.create_content` permission
- `list_visible_top_boards(user)` / `list_visible_sub_boards(board, user)` — role-filtered board listings

Only boards with `min_role_to_view == "guest"` are federated.

### Board Moderators

Users can be assigned as moderators of specific boards via the admin UI
(`/admin/boards` → "Moderators" button). Board moderators can:

- **Delete** articles and comments in their boards (soft-delete)
- **Pin/Unpin** articles in their boards
- **Lock/Unlock** threads in their boards

Board moderators **cannot** edit others' articles (only author and admin can edit).

`Content.board_moderator?(board, user)` returns `true` for:
- Users with admin or moderator role (global)
- Users explicitly assigned via the `board_moderators` join table

All board moderator actions are logged in the moderation log.

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

> **See the [SysOp Guide](sysop.md#registration-modes) for configuring
> registration modes, invite codes, and user approval.**

Public user registration is available at `/register`. The system supports three
modes controlled by the `registration_mode` setting (`approval_required`,
`open`, `invite_only`).

Registration is rate-limited to 5 attempts per hour per IP. The same password
policy as the setup wizard applies (12+ chars, complexity requirements).

Registration requires accepting terms: a system activity-logging notice (always
shown) and an optional site-specific End User Agreement (admin-configurable via
`/admin/settings`, stored as markdown). Recovery codes (10 high-entropy base32
codes in `xxxx-xxxx` format, ~41 bits each, HMAC-SHA256 hashed) are issued at
registration and displayed once for the user to save.

#### Invite Codes

All authenticated users can generate invite codes at `/invites`. Non-admin users
are subject to abuse prevention controls:

- **Quota**: 5 codes per rolling 30-day window
- **Account age**: must be at least 7 days old
- **Auto-expiry**: non-admin codes expire after 7 days

Admins have unlimited quota and optional expiry. When a user is banned, all their
active invite codes are automatically revoked. Invite chain tracking records which
user invited whom via `invited_by_id` on the users table.

Each active invite code provides an **invite link** (`/register?invite=CODE`) that
pre-fills the invite code field on the registration form. A **copy button**
(clipboard hook) and **QR code** (via `EQRCode`) are available on both the user
(`/invites`) and admin (`/admin/invites`) invite management pages.

### Password Reset

Password reset is available at `/password-reset`. Users enter their username,
a recovery code, and a new password. Each recovery code can only be used once.
Recovery codes are the sole password recovery mechanism — there is no email in
the system. Rate limited to 5 attempts per hour per IP.

### User Display Name

Users can set an optional display name (max 64 characters) in their profile at
`/profile`. The display name is sanitized on write: HTML tags stripped, control
characters and bidi override characters removed, whitespace normalized, and
truncated to 64 characters. When set, the display name is shown in place of
`username` across the UI (navbar, article bylines, comment authors, search
results, user profiles, moderation logs). The `username` remains the identifier
in URLs, `@mentions`, and admin user management. For ActivityPub federation, the
display name is mapped to the `name` field on the Person actor.

### User Bio

Users can set a plaintext bio (max 500 characters, no line limit) in their
profile at `/profile`. The bio supports hashtag linkification via
`Content.Markdown.linkify_hashtags/1` and is displayed on the public profile
page at `/users/:username`. For ActivityPub federation, the bio is HTML-escaped,
newlines converted to `<br>`, and hashtags linkified to produce the `summary`
field on the Person actor.

### User Signatures

Users can set a signature (max 500 characters, max 8 lines, markdown format) in
their profile at `/profile`. Signatures are rendered via `Content.Markdown.to_html/1`
and displayed below articles and comments authored by the user, as well as on
their public profile page at `/users/:username`.

### Article Creation

Authenticated users with active status and `user.create_content` permission
can create articles. Two entry points:

- `/boards/:slug/articles/new` — pre-selects the board
- `/articles/new` — user picks board(s) from a multi-select

Articles are assigned a URL-safe slug generated from the title with a random
suffix to avoid collisions. Articles can be cross-posted to multiple boards.
Board-less articles (created via feed without selecting a board) can be
forwarded to a board by the author or an admin via the "Forward to Board"
autocomplete on the article detail page.

### Article Images

Articles support up to 4 image attachments displayed as a responsive media
gallery at the end of the article body (before the signature). Images are
processed server-side for security, following the same patterns as the avatar
system:

1. Client selects up to 4 images (max 5 MB each, JPEG/PNG/WebP/GIF)
2. Server validates magic bytes, auto-rotates, downscales to max 1024px
   on the longest side (aspect-preserving), re-encodes as WebP with all
   EXIF/metadata stripped
3. Files stored at `priv/static/uploads/article_images/{filename}.webp`
   with server-generated 64-char hex filenames (no user input in paths)
4. Images are uploaded as orphans (`article_id = NULL`) during article
   composition and associated with the article on save
5. Orphan images older than 24 hours are cleaned up by `SessionCleaner`

Gallery layout adapts by image count: 1 = full width, 2 = side-by-side,
3-4 = 2×2 grid. Clicking opens the full-size image in a new tab.

Key modules:
- `Content.ArticleImage` — schema (`article_images` table)
- `Content.ArticleImageStorage` — image processing and storage
- `Content` — CRUD functions (`create_article_image/1`, `list_article_images/1`,
  `associate_article_images/3`, `delete_article_image/1`, `delete_orphan_article_images/1`)

### Article Hashtags

Hashtags (`#tag`) in article bodies are extracted, stored, and linkified:

1. **Extraction**: `Content.extract_tags/1` scans text with a Unicode-aware
   regex (`\p{L}[\w]{0,63}`) supporting Latin, CJK, and other scripts.
   Code blocks and inline code are stripped before scanning.
2. **Storage**: Tags are persisted in the `article_tags` table (article_id, tag)
   via `Content.sync_article_tags/1`, called automatically on article
   create/update. Tags are stored as lowercase strings.
3. **Linkification**: `Content.Markdown.to_html/1` adds a post-sanitize step
   that converts `#tag` to `<a href="/tags/tag" class="hashtag">#tag</a>`.
   Tags inside `<pre>`, `<code>`, and `<a>` elements are skipped.
4. **Browse page**: `/tags/:tag` shows paginated articles matching the tag,
   respecting board visibility and block/mute filters.
5. **Autocomplete**: Article editors include a `HashtagAutocompleteHook` that
   suggests existing tags as the user types `#prefix`.
6. **Federation**: `Federation.extract_hashtags/1` delegates to
   `Content.extract_tags/1` for consistent hashtag parsing.

Key modules:
- `Content.ArticleTag` — schema (`article_tags` table)
- `Content.Markdown` — rendering pipeline (Earmark → Ammonia → linkification)
- `TagLive` — `/tags/:tag` browse page

### Content Model

Boards are organized hierarchically via `parent_id` and have role-based access
control via `min_role_to_view` and `min_role_to_post` fields (see
[Board Permissions](#board-permissions) above). Board pages display breadcrumb
navigation (ancestor chain from root to current board) and list sub-boards
above articles. Sub-boards and board listings are filtered by the user's role.
Articles can be cross-posted to multiple boards through the `board_articles`
join table. Board moderators are tracked via the `board_moderators` join table.

Comments are threaded via `parent_id` (self-referential) and belong to an
article. Both articles and comments can originate locally (via `user_id`) or
from remote ActivityPub actors (via `remote_actor_id`). Soft-delete is
implemented via `deleted_at` timestamps on both articles and comments.

Article likes track favorites from local users and remote actors, with
partial unique indexes enforcing one-like-per-actor-per-article.

### Search

Full-text search is available at `/search` for both articles and comments,
with a tabbed UI. Search uses a dual strategy to support both English and CJK
(Chinese, Japanese, Korean) text:

| Strategy | Used for | Mechanism |
|----------|----------|-----------|
| tsvector | English article queries | `websearch_to_tsquery('english', ...)` on a `GENERATED ALWAYS AS STORED` tsvector column |
| Trigram ILIKE | CJK article queries, all comment queries | `pg_trgm` GIN indexes on `title`, `body` (articles) and `body` (comments) |

The strategy is auto-detected per query: if the search string contains CJK
Unicode characters (`\p{Han}`, `\p{Hiragana}`, `\p{Katakana}`, `\p{Hangul}`),
the trigram ILIKE path is used; otherwise, the tsvector path is used.

Comments always use trigram ILIKE (no tsvector column) since comment bodies are
short and a trigram GIN index is efficient for both CJK and English.

Key functions in `Content`:

- `search_articles/2` — dual-path article search with pagination and board visibility
- `search_comments/2` — trigram ILIKE comment search with pagination and board visibility
- `contains_cjk?/1` — detects CJK characters in search query (private)
- `sanitize_like/1` — escapes `%`, `_`, `\` for safe ILIKE queries (private)

User input is escaped via `sanitize_like/1` before interpolation into ILIKE
patterns to prevent SQL wildcard injection.

### User Public Profiles

Public profile pages are available at `/users/:username` for any active user.
Profiles display the user's avatar, role badge, member-since date, article and
comment counts, and a list of recent articles. Author names in board listings
and article views are clickable links to the author's profile. Banned or
nonexistent users are redirected away.

### Direct Messages

1-on-1 direct messaging between users, federated via ActivityPub. DMs are
standard AP `Create(Note)` activities with restricted addressing (only the
recipient in `to`, no `as:Public`, no followers collection).

**Database tables:**

| Table | Purpose |
|-------|---------|
| `conversations` | 1-on-1 conversations with canonical participant ordering |
| `direct_messages` | Message bodies (local + remote), soft-delete via `deleted_at` |
| `conversation_read_cursors` | Per-user read position tracking |

**DM access control:**

Users set `dm_access` on their profile (`/profile`):

| Setting | Effect |
|---------|--------|
| `anyone` (default) | Any authenticated user or remote actor can DM |
| `followers` | Only AP followers can DM |
| `nobody` | DMs are disabled entirely |

Bidirectional blocks (via `Auth.blocked?/2`) are always enforced regardless of
the `dm_access` setting.

**Key functions in `Messaging`:**

- `can_send_dm?/2` — checks dm_access, blocks, status
- `find_or_create_conversation/2` — canonical ordering prevents duplicates
- `create_message/3` — creates message, broadcasts PubSub, schedules federation
- `receive_remote_dm/3` — handles incoming federated DMs
- `list_conversations/1` — ordered by `last_message_at` desc
- `unread_count/1` — counts unread across all conversations
- `soft_delete_message/2` — sender-only deletion, schedules AP Delete
- `mark_conversation_read/3` — upserts read cursor

**Real-time updates via PubSub:**

| Topic | Format | Events |
|-------|--------|--------|
| User | `"dm:user:<user_id>"` | `:dm_received`, `:dm_read`, `:dm_message_created` |
| Conversation | `"dm:conversation:<conversation_id>"` | `:dm_message_created`, `:dm_message_deleted` |

**Navbar notification badge:** The navbar "Messages" link displays a real-time
unread count badge when the user has unread DMs. `UnreadDmCountHook` subscribes
to the user's DM PubSub topic via `attach_hook/4` and re-fetches the count on
`:dm_received` and `:dm_read` events. Wired into both `:require_auth` and
`:optional_auth` on_mount hooks so the badge appears on all authenticated pages.

**Federation:**

- Outgoing DMs: `Publisher.build_create_dm/3` → `Delivery.enqueue/3` to
  recipient's personal inbox (not shared inbox, for privacy)
- Incoming DMs: `InboxHandler` detects DMs via restricted addressing
  (`direct_message?/1`) and routes to `Messaging.receive_remote_dm/3`
- DM deletion: `Publisher.build_delete_dm/3` sends `Delete(Tombstone)`

**Rate limiting:** 20 messages per minute per user (via Hammer in LiveView).

**UI routes:**

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/messages` | `ConversationsLive` | Conversation list with unread badges |
| `/messages/new` | `ConversationLive` | Recipient selection (live-search, excludes self) |
| `/messages/new?to=username` | `ConversationLive` | New conversation with specified recipient |
| `/messages/:id` | `ConversationLive` | Existing conversation thread |

### Moderation

> **See the [SysOp Guide](sysop.md#moderation) for moderation operations.**

The moderation system includes a content reporting queue (`/admin/moderation`)
and an audit log (`/admin/moderation-log`). All moderation actions — banning,
unbanning, role changes, report resolution, board CRUD, and content deletion —
are automatically recorded in the moderation log with actor, action type,
target, and contextual details. The log is filterable by action type and
paginated.

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

**Outbound endpoints** (content-negotiated: JSON-LD for AP/JSON clients, HTML redirect otherwise):
- `/ap/users/:username` — Person actor with publicKey, inbox, outbox, published, icon
- `/ap/boards/:slug` — Group actor with sub-board/parent-board links
- `/ap/site` — Organization actor
- `/ap/articles/:slug` — Article object with replies link and `baudrate:*` extensions
- `/ap/users/:username/outbox` — paginated `OrderedCollection` of `Create(Article)`
- `/ap/boards/:slug/outbox` — paginated `OrderedCollection` of `Announce(Article)`
- `/ap/boards` — `OrderedCollection` of all public AP-enabled boards
- `/ap/articles/:slug/replies` — `OrderedCollection` of comments as Note objects
- `/ap/search?q=...` — paginated full-text article search

**Inbox endpoints** (HTTP Signature verified, per-domain rate-limited):
- `/ap/inbox` — shared inbox
- `/ap/users/:username/inbox` — user inbox
- `/ap/boards/:slug/inbox` — board inbox

**Incoming activities handled** (via `InboxHandler`):
- `Follow` / `Undo(Follow)` — follower management with auto-accept
- `Create(Note)` — stored as threaded comments on local articles, or as DMs if privately addressed (no `as:Public`, no followers collection)
- `Create(Article)` / `Create(Page)` — stored as remote articles in target boards (Page for Lemmy interop)
- `Like` / `Undo(Like)` — article favorites
- `Announce` / `Undo(Announce)` — boosts/shares (bare URI or embedded object map)
- `Update(Note/Article/Page)` — content updates with authorship check
- `Update(Person/Group)` — actor profile refresh
- `Delete(content)` — soft-delete with authorship verification
- `Delete(actor)` — removes all follower records and soft-deletes all content (articles, comments, DMs) from the deleted actor
- `Flag` — incoming reports stored in local moderation queue
- `Block` / `Undo(Block)` — remote actor blocks (logged for informational purposes)
- `Accept(Follow)` / `Reject(Follow)` — mark outbound user follows as accepted/rejected
- `Move` — stub handler (future: account migration)

**Outbound delivery** (via `Publisher` + `Delivery` + `DeliveryWorker`):
- `Create(Article)` — automatically enqueued when a local user publishes an article
- `Delete` with `Tombstone` (includes `formerType`) — enqueued when an article is soft-deleted
- `Announce` — board actor announces articles to board followers
- `Update(Article)` — enqueued when a local article is edited
- `Create(Note)` — DM to remote actor, delivered to personal inbox (not shared inbox) for privacy
- `Delete(Tombstone)` — DM deletion, delivered to remote recipient's personal inbox
- `Block` / `Undo(Block)` — delivered to the blocked actor's inbox when a user blocks/unblocks a remote actor
- `Follow` / `Undo(Follow)` — sent when a local user follows/unfollows a remote actor
- `Update(Person/Group/Organization)` — distributed to followers on key rotation or profile changes
- Delivery targets: followers of the article's author + followers of all public boards
- Shared inbox deduplication: multiple followers at the same instance → one delivery
- DB-backed queue (`delivery_jobs` table) with `DeliveryWorker` GenServer polling (graceful shutdown via `terminate/2`)
- Exponential backoff: 1m → 5m → 30m → 2h → 12h → 24h, then abandoned after 6 attempts
- Domain blocklist respected: deliveries to blocked domains are skipped
- Job deduplication: partial unique index on `(inbox_url, actor_uri)` for pending/failed jobs prevents duplicates on retry/race conditions

**Followers collection endpoints** (paginated with `?page=N`):
- `/ap/users/:username/followers` — paginated `OrderedCollection` of follower URIs
- `/ap/boards/:slug/followers` — paginated `OrderedCollection` (public boards only, 404 for private)

**Following collection endpoints** (paginated with `?page=N`):
- `/ap/users/:username/following` — paginated `OrderedCollection` of accepted followed actor URIs
- `/ap/boards/:slug/following` — paginated `OrderedCollection` of accepted board follow actor URIs

**User outbound follows** (Phase 1 — backend only, UI in Phase 2):
- `Federation.lookup_remote_actor/1` — WebFinger + actor fetch by `@user@domain` or actor URL
- `Federation.create_user_follow/2` — create pending follow record, returns AP ID
- `Federation.accept_user_follow/1` / `reject_user_follow/1` — state transitions on Accept/Reject
- `Federation.delete_user_follow/2` — delete follow record (unfollow)
- `Federation.list_user_follows/2` — list follows with optional state filter
- `Publisher.build_follow/3` / `build_undo_follow/2` — build Follow/Undo(Follow) activities
- `Delivery.deliver_follow/3` — enqueue follow/unfollow delivery to remote inbox
- Rate limited: 10 outbound follows per hour per user (`RateLimits.check_outbound_follow/1`)

**Personal feed** (Phase 3):
- `feed_items` table — stores incoming posts from followed actors that don't land in boards/comments/DMs
- One row per activity (keyed by `ap_id`), visibility via JOIN with `user_follows` at query time
- `Federation.create_feed_item/1` — insert + broadcast to followers via `Federation.PubSub`
- `Federation.list_feed_items/2` — paginated union query: remote feed items + local articles from followed users + comments on articles the user authored or participated in
- Inbox handler fallback: Create(Note) without reply target, Create(Article/Page) without board → feed item
- Delete propagation: soft-deletes feed items on content or actor deletion
- `Federation.migrate_user_follows/2` — Move activity support (migrate + deduplicate)
- `/feed` LiveView — paginated personal timeline with real-time PubSub updates

**Local user follows** (Phase 4):
- `user_follows.followed_user_id` — nullable FK to `users`, with check constraint (exactly one of `remote_actor_id`/`followed_user_id`)
- `Federation.create_local_follow/2` — auto-accepted immediately, no AP delivery
- `Federation.delete_local_follow/2` / `get_local_follow/2` / `local_follows?/2`
- `/search` — "Users" tab with local user search, follow/unfollow buttons
- `/following` — shows both local and remote follows with Local/Remote badges
- User profile — follow/unfollow button next to mute button
- `following_collection/2` — includes local follow actor URIs
- Feed includes articles from locally-followed users and comments on authored/participated articles via union query

**Board-level remote follows** (moderator-managed):
- `boards.ap_accept_policy` — `"open"` (accept from anyone) or `"followers_only"` (only accept from actors the board follows); default: `"followers_only"`
- `board_follows` table — tracks outbound follow relationships from boards to remote actors
- `BoardFollow` schema — `board_id`, `remote_actor_id`, `state` (pending/accepted/rejected), `ap_id`
- `Federation.create_board_follow/2` — create pending follow, returns AP ID
- `Federation.accept_board_follow/1` / `reject_board_follow/1` — state transitions on Accept/Reject
- `Federation.delete_board_follow/2` — delete follow record (unfollow)
- `Federation.boards_following_actor/1` — returns boards with accepted follows for auto-routing
- `Publisher.build_board_follow/3` / `build_board_undo_follow/2` — build Follow/Undo(Follow) from board actor
- Accept policy enforcement: `followers_only` boards reject Create(Article/Page) from unfollowed actors
- Auto-routing: when a followed actor sends content without addressing a board, it is routed to following boards
- Accept/Reject fallback: when user follow not found, tries board follow as fallback
- `/boards/:slug/follows` — management UI for board moderators (follow/unfollow, accept policy toggle)
- Board page shows "Manage Follows" link for board moderators when `ap_enabled`

**Mastodon/Lemmy compatibility:**
- `attributedTo` arrays — extracts first binary URI for validation
- `sensitive` + `summary` — content warnings prepended as `[CW: summary]`
- Lemmy `Page` objects treated identically to `Article` (Create and Update)
- Lemmy `Announce` with embedded object maps — extracts inner `id`
- `<span>` tags with safe classes (`h-card`, `hashtag`, `mention`, `invisible`) preserved by sanitizer
- Outbound Note objects include `to`/`cc` addressing (required by Mastodon for visibility)
- Outbound Article objects include `cc` with board actor URIs (improves discoverability)
- Outbound Article objects include plain-text `summary` (≤ 500 chars) for Mastodon preview display
- Outbound Article objects include `tag` array with `Hashtag` objects (extracted from body, code blocks excluded)
- Cross-post deduplication: same remote article arriving via multiple board inboxes links to all boards
- Forwarding a board-less article sends `Create(Article)` to board followers and `Announce` from the board actor

**Admin controls:** See the [SysOp Guide](sysop.md#federation) for federation
administration (kill switch, federation modes, domain blocklist/allowlist,
per-board toggle, delivery queue management, key rotation, blocklist audit).

**User blocks:**

Users can block local users and remote actors. Blocks prevent interaction
and are communicated to remote instances via `Block` / `Undo(Block)` activities:

- `Auth.block_user/2` / `Auth.unblock_user/2` — local user blocks
- `Auth.block_remote_actor/2` / `Auth.unblock_remote_actor/2` — remote actor blocks
- `Auth.blocked?/2` — check if blocked (works with local users and AP IDs)
- Content filtering: blocked users' content is hidden from article listings, comments, and search results
- Database: `user_blocks` table with partial unique indexes for local and remote blocks

**User mutes:**

Users can mute local users and remote actors. Muting is a lighter action than
blocking — it hides content from the muter's view without preventing interaction
or sending any federation activity. Mutes are purely local:

- `Auth.mute_user/2` / `Auth.unmute_user/2` — local user mutes
- `Auth.mute_remote_actor/2` / `Auth.unmute_remote_actor/2` — remote actor mutes
- `Auth.muted?/2` — check if muted (works with local users and AP IDs)
- Content filtering: muted users' content is combined with blocked users' content via `hidden_filters/1` and filtered from article listings, comments, and search results
- SysOp board exemption: admin articles in the SysOp board (slug `"sysop"`) are never hidden, even if the admin is muted — this ensures system announcements are always visible
- DM conversations with muted users are visually de-emphasized (reduced opacity, no unread badge) rather than hidden
- Mute management: toggle on user profiles, manage list on `/profile` settings page
- Database: `user_mutes` table with partial unique indexes for local and remote mutes

**Authorized fetch mode:**

Optional "secure mode" requiring HTTP signatures on GET requests to AP endpoints.
Implemented as `BaudrateWeb.Plugs.AuthorizedFetch` in the `:activity_pub`
pipeline. WebFinger and NodeInfo remain publicly accessible (spec requirement).
`HTTPSignature.sign_get/3` and `HTTPClient.signed_get/4` provide signed GET
support for outbound requests.

> See the [SysOp Guide](sysop.md#authorized-fetch) for configuration.

**Key rotation:**

Actor RSA keypairs can be rotated and new public keys are distributed to
followers via `Update` activities:

- `Federation.rotate_keys/2` — rotate keypair for user, board, or site actor
- `KeyStore.rotate_user_keypair/1`, `rotate_board_keypair/1`, `rotate_site_keypair/0` — low-level rotation functions
- `Publisher.build_update_actor/2` — builds `Update(Person/Group/Organization)` activity

> See the [SysOp Guide](sysop.md#key-rotation) for admin UI details.

**Domain blocklist audit:**

- `BlocklistAudit.audit/0` — fetches external list, compares to local blocklist, returns diff
- Supports multiple formats: JSON array, newline-separated, CSV (Mastodon export format)

> See the [SysOp Guide](sysop.md#blocklist-audit) for configuration and usage.

**Stale actor cleanup:**

The `StaleActorCleaner` GenServer runs daily to clean up remote actors whose
`fetched_at` exceeds the configured max age. Referenced actors are refreshed
via `ActorResolver.refresh/1`; unreferenced actors are deleted. Processing is
batched (50 per cycle) and skips when federation is disabled.

> See the [SysOp Guide](sysop.md#stale-actor-cleanup) for configuration.

**Security:**
- HTTP Signature verification on all inbox requests
- Inbox content-type validation — rejects non-AP content types with 415 (via `RequireAPContentType` plug)
- HTML sanitization via Ammonia (Rust NIF, html5ever parser) — allowlist-based, applied before database storage
- Remote actor display name sanitization — strips all HTML (including script content), control characters, truncates to 100 chars
- Attribution validation prevents impersonation
- Content size limits (256 KB AP payload, 64 KB article body enforced in all changesets)
- Domain blocklist (configurable via admin settings)
- SSRF-safe remote fetches — DNS-pinned connections prevent DNS rebinding; manual redirect following with IP validation at each hop; reject private/loopback IPs including IPv6 `::` and `::1`; HTTPS only
- Per-domain rate limiting (60 req/min per remote domain)
- Real client IP extraction — `RealIp` plug reads from configurable proxy header (e.g., `x-forwarded-for`) for accurate per-IP rate limiting behind reverse proxies
- Private keys encrypted at rest with AES-256-GCM
- Recovery codes verified atomically via `Repo.update_all` to prevent TOCTOU race conditions
- Non-guest boards (`min_role_to_view != "guest"`) hidden from all AP endpoints (actor, outbox, inbox, WebFinger, audience resolution)
- Optional authorized fetch mode — require HTTP signatures on GET requests to AP endpoints (exempt: WebFinger, NodeInfo)
- Signed outbound GET requests — actor resolution falls back to signed GET when remote instances require authorized fetch
- Session cookie `secure` flag handled by `force_ssl` / `Plug.SSL` in production
- CSP `img-src` allows `https:` for remote avatars; all other directives remain restrictive

**Public API:**

The AP endpoints double as the public API — no separate REST API is needed.
External clients can use `Accept: application/json` to retrieve data.
See [`doc/api.md`](api.md) for the full AP endpoint reference.

- **Content negotiation** — `application/json`, `application/activity+json`, and `application/ld+json` all return JSON-LD. Content-negotiated endpoints (actors, articles) redirect `text/html` to the web UI.
- **CORS** — all GET `/ap/*` endpoints return `Access-Control-Allow-Origin: *`. OPTIONS preflight returns 204.
- **Vary** — content-negotiated endpoints include `Vary: Accept` for proper caching.
- **Pagination** — outbox, followers, and search collections use AP-spec `OrderedCollectionPage` pagination with `?page=N` (20 items/page). Without `?page`, the root `OrderedCollection` contains `totalItems` and a `first` link.
- **Rate limiting** — 120 requests/min per IP; 429 responses are JSON (`{"error": "Too Many Requests"}`).
- **`baudrate:*` extensions** — Article objects include `baudrate:pinned`, `baudrate:locked`, `baudrate:commentCount`, `baudrate:likeCount`. Board actors include `baudrate:parentBoard` and `baudrate:subBoards`.
- **Enriched actors** — User actors include `published`, `summary` (user bio, plaintext with hashtag linkification), and `icon` (avatar as WebP). Board actors include parent/sub-board links.

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
of the user menu. A site-wide footer links to the Baudrate project repository.
The setup wizard uses a separate `:setup` layout (minimal, no navigation).

**Accessibility (WAI-ARIA):**

- Skip-to-content link (`<a href="#main-content">`) at top of `<body>` in `root.html.heex`
- `id="main-content"` on `<main>` in the app layout for skip-link target
- `aria-haspopup="true"` and `aria-expanded` on all dropdown trigger buttons (mobile hamburger, desktop user menu, language picker); `aria-expanded` is synced dynamically via JS event delegation on `focusin`/`focusout` in `app.js`
- `aria-live="polite"` on the comment tree container and flash group for screen reader announcements
- `aria-invalid="true"` and `aria-describedby="<id>-error"` on form inputs with validation errors
- Error messages wrapped in `<div id="<id>-error" role="alert">` for programmatic association
- `aria-expanded` on reply buttons and moderator management toggle
- `aria-label` on all icon-only buttons (cancel upload, delete comment)
- Pagination wrapped in `<nav aria-label>` with `aria-current="page"` on the active page and `aria-label` on prev/next/page links
- Password strength `<progress>` has `aria-label` and dynamic `aria-valuetext` ("Weak"/"Fair"/"Strong"); requirement icons are `aria-hidden` with sr-only met/unmet state text

**Auth hooks:**

| Hook | Behavior |
|------|----------|
| `:require_auth` | Requires valid session; redirects to `/login` if unauthenticated or banned |
| `:require_admin` | Requires admin role; redirects non-admins to `/` with access denied flash. Must be used after `:require_auth` (needs `@current_user`) |
| `:optional_auth` | Loads user if session exists; assigns `nil` for guests or banned users (no redirect) |
| `:require_password_auth` | Requires password-level auth (for TOTP flow); redirects banned users to `/login` |
| `:redirect_if_authenticated` | Redirects authenticated users to `/` (for login/register pages); allows banned users through |

### Request Pipeline

Every browser request passes through these plugs in order:

```
:accepts → :fetch_session → :fetch_live_flash → :put_root_layout →
:protect_from_forgery → :put_secure_browser_headers (CSP, X-Frame-Options) →
SetLocale (Accept-Language) → EnsureSetup (redirect to /setup) →
SetTheme (inject admin-configured DaisyUI themes) → RefreshSession (token rotation)
```

ActivityPub GET requests use the `:activity_pub` pipeline:

```
RateLimit (120/min per IP) → CORS → AuthorizedFetch (optional sig verify) →
ActivityPubController (content-negotiated response)
```

ActivityPub inbox (POST) requests use a separate pipeline:

```
RateLimit (120/min per IP) → RequireAPContentType (415 on non-AP types) →
CacheBody (256 KB max) → VerifyHttpSignature →
RateLimitDomain (60/min per domain) →
ActivityPubController (dispatch to InboxHandler)
```

Feed requests use a lightweight pipeline (no session, no CSRF):

```
RateLimit (30/min per IP) → FeedController (XML response)
```

### Rate Limiting

> **See the [SysOp Guide](sysop.md#rate-limiting) for operational details
> and reverse proxy configuration.**

| Endpoint | Limit | Scope |
|----------|-------|-------|
| Login | 10 / 5 min | per IP |
| Login | progressive delay (5s/30s/120s) | per account |
| TOTP | 15 / 5 min | per IP |
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
| AP endpoints | 120 / min | per IP |
| AP inbox | 60 / min | per remote domain |
| Feeds (RSS/Atom) | 30 / min | per IP |
| Direct messages | 20 / min | per user |

IP-based rate limits use `BaudrateWeb.Plugs.RateLimit` (Plug-based, in the
router pipeline). Per-user rate limits use `BaudrateWeb.RateLimits` (called
from LiveView event handlers). Both use Hammer with ETS backend and fail open
on backend errors. Admin users are exempt from per-user content rate limits.

### Supervision Tree

```
Baudrate.Supervisor (one_for_one)
├── BaudrateWeb.Telemetry              # Telemetry metrics
├── Baudrate.Repo                      # Ecto database connection pool
├── DNSCluster                         # DNS-based cluster discovery
├── Phoenix.PubSub                     # PubSub for LiveView
├── Baudrate.Auth.SessionCleaner       # Hourly cleanup (sessions, login attempts, orphan images)
├── Baudrate.Federation.TaskSupervisor # Async federation delivery tasks
├── Baudrate.Federation.DeliveryWorker     # Polls delivery queue every 60s
├── Baudrate.Federation.StaleActorCleaner # Daily stale remote actor cleanup
└── BaudrateWeb.Endpoint                  # HTTP server
```

### Real-time Updates

LiveViews subscribe to PubSub topics to receive real-time content updates
without page refresh. The centralized helper module `Baudrate.Content.PubSub`
encapsulates topic naming and broadcast logic.

**Topics:**

| Topic | Format | Events |
|-------|--------|--------|
| Board | `"board:<board_id>"` | `:article_created`, `:article_deleted`, `:article_updated`, `:article_pinned`, `:article_unpinned`, `:article_locked`, `:article_unlocked` |
| Article | `"article:<article_id>"` | `:comment_created`, `:comment_deleted`, `:article_deleted`, `:article_updated` |
| DM User | `"dm:user:<user_id>"` | `:dm_received`, `:dm_message_created` |
| DM Conversation | `"dm:conversation:<conversation_id>"` | `:dm_message_created`, `:dm_message_deleted` |

**Message format:** `{event_atom, %{id_key: id}}` — only IDs are broadcast,
no user content. Subscribers re-fetch data from the database to respect
access controls.

**Subscription pattern:**

```elixir
# In LiveView mount (only when connected):
if connected?(socket), do: ContentPubSub.subscribe_board(board.id)

# In handle_info — re-fetch from DB:
def handle_info({event, _payload}, socket) when event in [...] do
  articles = Content.paginate_articles_for_board(socket.assigns.board, ...)
  {:noreply, assign(socket, ...)}
end
```

**Subscribing LiveViews:**

| LiveView | Topic | Behavior |
|----------|-------|----------|
| `BoardLive` | `board:<id>` | Re-fetches article list on article mutations |
| `ArticleLive` | `article:<id>` | Re-fetches comment tree on comment mutations; redirects on article deletion; re-fetches article on update |
| `ConversationsLive` | `dm:user:<id>` | Re-fetches conversation list on DM events |
| `ConversationLive` | `dm:conversation:<id>` | Appends new messages, removes deleted messages |

**Design decisions:**
- Re-fetch on broadcast (not incremental patching) — simpler, always correct, respects access controls
- Messages carry only IDs — no user content in PubSub messages (security by design)
- Double-refresh accepted — when a user creates content, both `handle_event` and `handle_info` refresh; the cost is one extra DB query

## LiveView JS Hooks

### `AvatarCropHook`

Handles client-side image cropping for avatar uploads. Attached to the crop
container on the profile page.

### `ScrollBottomHook`

Auto-scrolls the DM message list to the bottom on mount and when new messages
are added. Attached to the message container in `ConversationLive`.

Source: `assets/js/scroll_bottom_hook.js`

### `MarkdownToolbarHook`

Attaches a Markdown formatting toolbar above any `<textarea>` that carries
`phx-hook="MarkdownToolbarHook"`. Enable it on `<.input type="textarea">` by
adding the `toolbar` attribute:

```heex
<.input field={@form[:body]} type="textarea" toolbar />
```

Formatting buttons are purely client-side — they read `selectionStart`/`selectionEnd`,
wrap or prefix with Markdown syntax, and dispatch an `input` event so
LiveView picks up the change. No server round-trips are needed.

Toolbar buttons: **Bold**, *Italic*, ~~Strikethrough~~, Heading, Link, Image,
Inline Code, Code Block, Blockquote, Bullet List, Numbered List, Horizontal Rule.

#### Live Preview

A **Write/Preview** toggle button (right-aligned, eye/pencil icons) lets users
preview their markdown before posting. Preview rendering is done **server-side**
via `Content.Markdown.to_html/1` to guarantee consistent sanitization.

The JS hook sends the textarea content via `pushEvent("markdown_preview", ...)`
and listens for a `"markdown_preview_result"` event pushed back from the server.
On the server side, `BaudrateWeb.MarkdownPreviewHook` intercepts the event via
`attach_hook/4` (attached in `AuthHooks` for `:require_auth` and `:optional_auth`
scopes). A 64 KB body size limit is enforced to prevent abuse.

In preview mode, the textarea is hidden and a preview `<div>` (rendered with
`phx-update="ignore"`) displays the rendered HTML. Formatting buttons are
disabled while in preview mode.

Source: `assets/js/markdown_toolbar_hook.js`, `lib/baudrate_web/live/markdown_preview_hook.ex`

### `HashtagAutocompleteHook`

Provides hashtag autocomplete in article/comment textareas. Attached to a
wrapper `<div>` around the textarea (since `MarkdownToolbarHook` already
occupies `phx-hook` on the textarea itself). Automatically enabled when the
`toolbar` attribute is set on `<.input type="textarea">`.

When the user types `#` followed by one or more characters, the hook debounces
(200ms) then sends `pushEvent("hashtag_suggest", %{prefix: "..."})` to the
server. The server queries `Content.search_tags/2` and pushes back
`"hashtag_suggestions"` with matching tags. The hook renders a positioned
dropdown with keyboard navigation (ArrowUp/Down, Enter/Tab, Escape).

Source: `assets/js/hashtag_autocomplete_hook.js`

### Syndication Feeds (RSS / Atom)

RSS 2.0 and Atom 1.0 feeds are available at three scopes:

| Endpoint | Format | Scope |
|----------|--------|-------|
| `/feeds/rss` | RSS 2.0 | Site-wide (all public boards) |
| `/feeds/atom` | Atom 1.0 | Site-wide (all public boards) |
| `/feeds/boards/:slug/rss` | RSS 2.0 | Single public board |
| `/feeds/boards/:slug/atom` | Atom 1.0 | Single public board |
| `/feeds/users/:username/rss` | RSS 2.0 | User's articles in public boards |
| `/feeds/users/:username/atom` | Atom 1.0 | User's articles in public boards |

**Design decisions:**

- **Local articles only** — remote/federated articles are excluded to respect
  intellectual property rights (obtaining authorization from every Fediverse
  author is infeasible)
- **20 items per feed** — matches AP pagination
- **EEx templates** — RSS/Atom are fixed XML formats; no library dependency needed
- **CDATA** wraps HTML content in both formats to avoid double-escaping
- **Caching** — `Cache-Control: public, max-age=300` with `Last-Modified` /
  `If-Modified-Since` → 304 support for efficient polling by feed readers
- **Rate limited** — 30 requests/min per IP (via `:feeds` rate limit action)
- **Board feeds** return 404 for private or nonexistent boards
- **User feeds** return 404 for nonexistent or banned users

**Autodiscovery:** `<link rel="alternate">` tags are injected into `<head>` on
the home page (site-wide feeds) and public board pages (board-specific feeds)
via optional socket assigns (`feed_site`, `feed_board_slug`).

### Linked Data (JSON-LD + Dublin Core)

Public pages embed structured RDF metadata in `<head>` using JSON-LD
(`<script type="application/ld+json">`) and Dublin Core `<meta>` tags.
This allows search engines, crawlers, and linked-data consumers to understand
the semantic relationships between Baudrate entities.

**Vocabularies:**

| Prefix     | URI                                | Used for                              |
|------------|------------------------------------|---------------------------------------|
| `sioc`     | `http://rdfs.org/sioc/ns#`         | Site, Forum, Post, UserAccount        |
| `foaf`     | `http://xmlns.com/foaf/0.1/`       | Person, name, nick, depiction         |
| `dc`       | `http://purl.org/dc/elements/1.1/` | title, creator, date, description     |
| `dcterms`  | `http://purl.org/dc/terms/`        | created, modified                     |

**Entity mappings:**

| Page | JSON-LD @type | Dublin Core meta |
|------|---------------|-----------------|
| Home (`/`) | `sioc:Site` | — |
| Board (`/boards/:slug`) | `sioc:Forum` | DC.title, DC.description |
| Article (`/articles/:slug`) | `sioc:Post` | DC.title, DC.creator, DC.date, DC.type, DC.description |
| User profile (`/users/:username`) | `foaf:Person` + `sioc:UserAccount` | DC.title |

**Implementation:** `BaudrateWeb.LinkedData` provides pure builder functions
(`site_jsonld/1`, `board_jsonld/2`, `article_jsonld/1`, `user_jsonld/1`,
`dublin_core_meta/2`). Each LiveView calls the relevant builder in `mount/3`
and assigns the pre-encoded JSON string + DC meta list. The root layout
(`root.html.heex`) conditionally renders them in `<head>`.

**Security:** JSON-LD is encoded via `Jason.encode!/1` with `</script>`
sequences escaped. Dublin Core meta values are auto-escaped by Phoenix
attribute binding.

## Further Reading

- [SysOp Guide](sysop.md) — installation, configuration, and maintenance for system operators
- [AP Endpoint API Reference](api.md) — external-facing documentation for all ActivityPub and public API endpoints
- [Troubleshooting Guide](troubleshooting.md) — common issues and solutions for operators and developers

## Running Tests

```bash
mix test
```

### Browser Testing (Wallaby + Selenium)

End-to-end browser tests use [Wallaby](https://hexdocs.pm/wallaby/) with
Selenium 4 and Firefox (headless). Feature tests are **excluded by default**
from the regular test suite.

#### Prerequisites

- Java runtime (for Selenium Server)
- Firefox browser
- GeckoDriver + Selenium Server JAR in `tmp/selenium/`

#### Setup

```bash
mix selenium.setup    # Downloads Selenium Server 4.27.0 + GeckoDriver 0.36.0
```

#### Running Feature Tests

```bash
# Run all feature tests (auto-starts Selenium if needed):
mix test --include feature test/baudrate_web/features/ --seed 9527

# Run a single feature test:
mix test --include feature test/baudrate_web/features/home_page_test.exs --seed 9527
```

Regular tests (`mix test`) do **not** start Selenium or include feature tests.

#### Architecture

Feature tests solve a key compatibility issue: Wallaby 0.30 sends legacy JSON
Wire Protocol requests, but Selenium 4.x requires W3C WebDriver format. Two
layers handle this:

1. **`BaudrateWeb.W3CWebDriver`** — wraps session creation capabilities in W3C format.
2. **`wallaby_httpclient_patch.exs`** — runtime patch (loaded in `test_helper.exs`) that
   fixes empty POST bodies (`{}` instead of `""`), transforms `set_value` to
   W3C `{text: ...}` format, and rewrites legacy URLs (`/execute` → `/execute/sync`,
   `/window/current/size` → `/window/rect`).

The Ecto SQL sandbox is shared with browser processes via:
1. `Phoenix.Ecto.SQL.Sandbox` plug in the endpoint (injects metadata into HTTP)
2. `BaudrateWeb.SandboxHook` on_mount hook (allows LiveView processes to share
   the test's database connection via user-agent metadata)

Each test partition gets its own HTTP port (`4002 + partition`) to avoid
collisions when running tests in parallel.

#### Feature Test Helpers

`BaudrateWeb.FeatureCase` provides shared helpers:

- **`log_in_via_browser/2`** — fills the login form and waits for redirect. Only
  works for `"user"` role (admin/moderator require TOTP).
- **`create_board/1`** — creates a board with `ap_enabled: false` (prevents
  federation delivery in tests).
- **`create_article/3`** — creates an article in a board for a given user.

#### Test Coverage

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `home_page_test.exs` | 4 | Guest welcome, board listing, personalized greeting, board navigation |
| `login_test.exs` | 4 | Successful login, failed login, registration link, redirect if authenticated |
| `registration_test.exs` | 2 | Registration with recovery codes, acknowledging codes |
| `browsing_test.exs` | 3 | Home→board→article flow, empty board, article with author/comments |
| `article_creation_test.exs` | 2 | Create article via form, new article link from board |
| `logout_test.exs` | 1 | Sign out redirects to login |
| `setup_wizard_test.exs` | 1 | Full setup wizard flow (DB→Site Name→Admin→Recovery Codes) |

#### Key Files

| File | Purpose |
|------|---------|
| `test/support/feature_case.ex` | Feature test case template + helpers |
| `test/support/w3c_webdriver.ex` | W3C WebDriver session creation |
| `test/support/wallaby_httpclient_patch.exs` | W3C compatibility patch for Wallaby HTTP client |
| `test/support/selenium_server.ex` | Selenium auto-start |
| `lib/baudrate_web/live/sandbox_hook.ex` | LiveView sandbox hook |
| `lib/mix/tasks/selenium_setup.ex` | `mix selenium.setup` task |
| `test/baudrate_web/features/` | Feature test directory |
| `config/test.exs` | Wallaby + Firefox config |
