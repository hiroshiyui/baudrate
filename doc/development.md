# Development Guide

Baudrate is an **ActivityPub-enabled Bulletin Board System** and a **public information hub**, not a social network. Public content
should remain visible to all users; blocking controls interaction, not
visibility. Design decisions should reflect this philosophy.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.15+ / OTP 26+ |
| Web framework | Phoenix 1.8 / LiveView 1.2 |
| HTTP server | Bandit |
| HTTP client | Req (never HTTPoison, Tesla, or httpc) |
| Database | PostgreSQL (via Ecto) |
| CSS | Tailwind CSS + DaisyUI |
| JS bundler | esbuild |
| Image processing | image (libvips NIF) |
| Markdown | MDEx (comrak) |
| 2FA / WebAuthn | NimbleTOTP + EQRCode + wax_ (FIDO2/WebAuthn relying party) |
| HTML parsing | html5ever (Rust NIF via Rustler) |
| HTML sanitization | Ammonia (Rust NIF via Rustler) |
| Rate limiting | Hammer |
| Timezone data | tz (`Baudrate.Timezone`) |
| Feed parsing | feedparser-rs (Rust NIF via Rustler) — RSS 0.9x/2.0, RSS 1.0 (RDF), Atom 0.3/1.0, JSON Feed |
| i18n | Gettext (en, zh_TW, ja_JP) |
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |

## Architecture

### Project Structure

```
native/
├── baudrate_sanitizer/          # Rust NIF crate (Ammonia HTML sanitizer)
│   ├── Cargo.toml               # Crate manifest (ammonia, rustler, regex)
│   └── src/
│       └── lib.rs               # NIF functions: sanitize_federation, sanitize_markdown, strip_tags
├── baudrate_html_parser/        # Rust NIF crate (html5ever / scraper)
│   ├── Cargo.toml               # Crate manifest (scraper, rustler)
│   └── src/
│       └── lib.rs               # NIF functions: parse_og_metadata, extract_first_url
└── baudrate_feed_parser/        # Rust NIF crate (feedparser-rs)
    ├── Cargo.toml               # Crate manifest (feedparser-rs, rustler)
    └── src/
        └── lib.rs               # NIF function: parse_feed (RSS/Atom/JSON Feed → NifEntry list)
lib/
├── baudrate/                    # Business logic (contexts)
│   ├── application.ex           # Supervision tree
│   ├── repo.ex                  # Ecto repository + sanitize_like/1 helper
│   ├── pagination.ex            # Shared pagination (paginate_opts/3, paginate_query/3)
│   ├── auth.ex                  # Auth context facade: defdelegate to focused sub-modules
│   ├── auth/
│   │   ├── invite_code.ex       # InviteCode schema (invite-only registration)
│   │   ├── invites.ex           # Invite code generation, revocation, and quota logic
│   │   ├── login_attempt.ex     # LoginAttempt schema (per-account brute-force tracking)
│   │   ├── moderation.ex        # User-level moderation: ban, unban, role changes
│   │   ├── passwords.ex         # Password hashing, validation, and reset logic
│   │   ├── profiles.ex          # User profile updates: display name, bio, signature, profile_fields
│   │   ├── recovery_code.ex     # Ecto schema for one-time recovery codes
│   │   ├── reauthentication.ex  # Step-up re-authentication (password + TOTP) for factor changes
│   │   ├── reserved_handle.ex   # Reserved username/handle list (system, sysop, admin, etc.)
│   │   ├── second_factor.ex     # TOTP enrollment, verification, and recovery
│   │   ├── session_cleaner.ex   # GenServer: hourly cleanup (sessions, login attempts, orphan images)
│   │   ├── sessions.ex          # Session lifecycle: creation, rotation, eviction
│   │   ├── totp_vault.ex        # AES-256-GCM encryption for TOTP secrets
│   │   ├── user_block.ex        # UserBlock schema (local + remote actor blocks)
│   │   ├── user_mute.ex         # UserMute schema (local-only soft-mute/ignore)
│   │   ├── user_session.ex      # Ecto schema for server-side sessions
│   │   ├── users.ex             # User CRUD, lookup, and registration
│   │   ├── webauthn.ex          # WebAuthn context: registration, authentication, credential CRUD
│   │   ├── webauthn_challenges.ex # ETS-backed challenge store (60s TTL, single-use, GenServer)
│   │   └── webauthn_credential.ex # WebAuthnCredential schema (credential_id, public_key_cbor, sign_count)
│   ├── avatar.ex                # Avatar image processing (crop, resize, WebP)
│   ├── backup.ex                # pg_dump/pg_restore and uploads archive helpers (release + mix)
│   ├── backup/
│   │   └── snapshots.ex         # Nightly backup folders: hard-link uploads, retention, disk guard (ADR 0028)
│   ├── bots.ex                  # Bots context: bot CRUD, feed scheduling, deduplication
│   ├── bots/
│   │   ├── bot.ex               # Bot schema (1:1 with User, feed config, fetch state)
│   │   ├── bot_feed_item.ex     # BotFeedItem schema (posted GUID deduplication)
│   │   ├── favicon_fetcher.ex   # Fetch site favicon and set as bot avatar (best-effort)
│   │   ├── feed_parser.ex       # Feed parser facade: delegates to NIF, normalizes entries
│   │   ├── feed_parser_native.ex # Rustler NIF binding (baudrate_feed_parser crate)
│   │   └── feed_worker.ex       # GenServer: polls due bots every 60s, creates articles
│   ├── content.ex               # Content context facade: defdelegate to focused sub-modules
│   ├── content/
│   │   ├── articles.ex          # Article CRUD, cross-posting, revisions, pin/lock
│   │   ├── boards.ex            # Board CRUD, moderators, SysOp board seeding
│   │   ├── bookmarks.ex         # Article and comment bookmark operations
│   │   ├── comments.ex          # Comment CRUD, threading, activity timestamps
│   │   ├── feed.ex              # Public feed queries, user content statistics
│   │   ├── filters.ex           # Shared query helpers (block/mute, role visibility, LIKE sanitization)
│   │   ├── images.ex            # Article image management
│   │   ├── likes.ex             # Article and comment like operations
│   │   ├── permissions.ex       # Board access checks, granular permissions, slug generation
│   │   ├── polls.ex             # Poll creation, voting, counter management
│   │   ├── read_tracking.ex     # Per-user article/board read state tracking
│   │   ├── search.ex            # Full-text search across articles, comments, boards
│   │   ├── tags.ex              # Hashtag extraction, syncing, and querying
│   │   ├── article.ex           # Article schema (posts, local + remote, soft-delete)
│   │   ├── article_image.ex     # ArticleImage schema (gallery images on articles)
│   │   ├── article_read.ex      # ArticleRead schema (per-user article read tracking)
│   │   ├── board_read.ex        # BoardRead schema (per-user board "mark all read" floor)
│   │   ├── article_revision.ex  # ArticleRevision schema (edit history snapshots)
│   │   ├── article_image_storage.ex # Image processing (resize, WebP, strip EXIF)
│   │   ├── article_boost.ex     # ArticleBoost schema (local + remote boosts/reposts)
│   │   ├── article_like.ex      # ArticleLike schema (local + remote likes)
│   │   ├── article_tag.ex        # ArticleTag schema (article ↔ hashtag, extracted from body)
│   │   ├── board.ex             # Board schema (hierarchical via parent_id, role-based permissions)
│   │   ├── board_cache.ex       # ETS-backed cache for board lookups (GenServer + :ets.lookup)
│   │   ├── board_article.ex     # Join table: board ↔ article
│   │   ├── board_moderator.ex   # Join table: board ↔ moderator
│   │   ├── bookmark.ex          # Bookmark schema (article + comment bookmarks)
│   │   ├── boosts.ex            # Article and comment boost operations
│   │   ├── comment_boost.ex     # CommentBoost schema (local + remote boosts on comments)
│   │   ├── comment_like.ex      # CommentLike schema (local + remote likes on comments)
│   │   ├── comment.ex           # Comment schema (threaded, local + remote, soft-delete)
│   │   ├── comment_image.ex     # CommentImage schema (image attachments on comments)
│   │   ├── interactions.ex      # Shared like/boost/bookmark interaction helpers
│   │   ├── title_deriver.ex     # Title derivation for federation-imported articles
│   │   ├── markdown.ex          # Markdown → HTML rendering (MDEx + Ammonia NIF + hashtag/mention linkification + mention extraction)
│   │   ├── pagination.ex        # Content-specific paginated query helpers
│   │   ├── poll.ex              # Poll schema (inline polls attached to articles, single/multiple choice)
│   │   ├── poll_option.ex       # PollOption schema (poll choices with denormalized votes_count)
│   │   ├── poll_vote.ex         # PollVote schema (local + remote votes, anonymous dedup)
│   │   └── pubsub.ex            # PubSub helpers for real-time content updates
│   ├── sanitizer/
│   │   └── native.ex            # Rustler NIF bindings to Ammonia HTML sanitizer
│   ├── messaging.ex             # Messaging context: 1-on-1 DMs, conversations, DM access control
│   ├── messaging/
│   │   ├── conversation.ex      # Conversation schema (local-local and local-remote)
│   │   ├── conversation_read_cursor.ex # Per-user read position tracking
│   │   ├── direct_message.ex    # DirectMessage schema (local + remote, soft-delete)
│   │   └── pubsub.ex            # PubSub helpers for real-time DM updates
│   ├── federation.ex            # Federation context facade: defdelegate to focused sub-modules
│   ├── federation/
│   │   ├── actor_renderer.ex    # JSON-LD rendering for Person/Group/Organization actors
│   │   ├── actor_resolver.ex    # Remote actor fetching and caching (24h TTL, signed fetch fallback)
│   │   ├── announce.ex          # Announce (boost) schema
│   │   ├── attachment_extractor.ex # Extracts media attachments from AP objects
│   │   ├── blocklist_audit.ex   # Audit local blocklist against external known-bad-actor lists
│   │   ├── board_follow.ex      # BoardFollow schema (outbound board follows)
│   │   ├── collections.ex       # ActivityPub collection builders (Outbox, Followers, Following)
│   │   ├── delivery.ex          # Outgoing activity delivery (Accept, queue, retry, block delivery)
│   │   ├── delivery_job.ex      # DeliveryJob schema (delivery queue records)
│   │   ├── delivery_stats.ex    # Delivery queue stats and admin management
│   │   ├── delivery_worker.ex   # GenServer: polls delivery queue, retries failed jobs
│   │   ├── discovery.ex         # WebFinger and NodeInfo responses
│   │   ├── domain_block_cache.ex # ETS-backed cache for domain blocking decisions
│   │   ├── feed.ex              # Personal feed logic: Create(Note/Article) routing, boost handling
│   │   ├── feed_item.ex         # FeedItem schema (posts from followed remote actors)
│   │   ├── feed_item_boost.ex   # FeedItemBoost schema (local boosts on remote feed items)
│   │   ├── feed_item_like.ex    # FeedItemLike schema (local likes on remote feed items)
│   │   ├── feed_item_reply.ex   # FeedItemReply schema (local replies to remote feed items)
│   │   ├── feed_item_reply_image.ex # FeedItemReplyImage schema (image attachments on feed item replies)
│   │   ├── reply_images.ex      # Helper for feed item reply images
│   │   ├── follower.ex          # Follower schema (remote → local follows)
│   │   ├── follows.ex           # Local/remote follow logic, acceptance, and migration
│   │   ├── http_client.ex       # SSRF-safe HTTP client for remote fetches (unsigned + signed GET)
│   │   ├── http_signature.ex    # HTTP Signature signing and verification (POST + GET)
│   │   ├── inbox_handler.ex     # Incoming activity dispatch (Follow, Create, Like, Flag, etc.)
│   │   ├── instance_stats.ex    # Per-domain instance statistics
│   │   ├── key_store.ex         # RSA-2048 keypair management for actors (generate, ensure, rotate)
│   │   ├── key_vault.ex         # AES-256-GCM encryption for private keys at rest
│   │   ├── object_builder.ex    # ActivityStreams JSON builders for articles, comments, polls
│   │   ├── object_resolver.ex   # Two-phase remote object resolution (fetch/resolve)
│   │   ├── publisher.ex         # High-level activity publishing API
│   │   ├── pubsub.ex            # Federation PubSub (user feed events)
│   │   ├── remote_actor.ex      # RemoteActor schema (cached remote profiles)
│   │   ├── sanitizer.ex         # HTML sanitizer for federated content (Ammonia NIF)
│   │   ├── stale_actor_cleaner.ex # GenServer: daily stale remote actor cleanup
│   │   ├── user_follow.ex       # UserFollow schema (outbound follows: remote actors + local users)
│   │   ├── validator.ex         # AP input validation (URLs, sizes, attribution, allowlist/blocklist)
│   │   └── visibility.ex        # ActivityPub visibility derivation from addressing
│   ├── moderation.ex            # Moderation context: reports, resolve/dismiss, audit log
│   ├── moderation/
│   │   ├── log.ex               # ModerationLog schema (audit trail of moderation actions)
│   │   └── report.ex            # Report schema (article, comment, remote actor, user, feed item, DM targets)
│   ├── notification.ex          # Notification context: create, list, mark read, cleanup, admin announcements
│   ├── notification/
│   │   ├── hooks.ex             # Fire-and-forget notification creation hooks (comment, article, like, follow, report)
│   │   ├── notification.ex      # Notification schema (type, read, data, actor, article, comment refs)
│   │   ├── pubsub.ex            # PubSub helpers for real-time notification updates
│   │   ├── push_subscription.ex # PushSubscription schema (endpoint, p256dh, auth, user_id)
│   │   ├── vapid.ex             # VAPID key generation (ECDSA P-256) + ES256 JWT signing
│   │   ├── vapid_vault.ex       # AES-256-GCM encryption for VAPID private keys
│   │   └── web_push.ex          # RFC 8291 content encryption + push delivery via Req
│   ├── setup.ex                 # Setup context: first-run wizard, RBAC seeding, settings
│   ├── timezone.ex              # IANA timezone identifiers (compiled from tz library data)
│   └── setup/
│       ├── permission.ex        # Permission schema (scope.action naming)
│       ├── role.ex              # Role schema (admin/moderator/user/guest)
│       ├── role_permission.ex   # Join table: role ↔ permission
│       ├── setting.ex           # Key-value settings (site_name, timezone, setup_completed, etc.)
│       ├── settings_cache.ex    # ETS-backed cache for settings (GenServer + :ets.lookup)
│       └── user.ex              # User schema with password, TOTP, avatar, display_name, status, signature, is_bot, profile_fields
├── mix/
│   └── tasks/
│       ├── backup.ex            # mix backup — full instance backup (DB + files)
│       ├── backup/
│       │   ├── db.ex            # Database backup implementation
│       │   ├── files.ex         # File backup implementation (uploads, avatars)
│       │   └── helper.ex        # Shared backup/restore helpers
│       ├── restore.ex           # mix restore — full instance restore
│       ├── restore/
│       │   ├── db.ex            # Database restore implementation
│       │   └── files.ex         # File restore implementation
│       └── selenium_setup.ex    # mix selenium.setup — download Selenium + GeckoDriver
├── baudrate_web/                # Web layer
│   ├── components/
│   │   ├── comment_components.ex # Focused components for rendering comment threads
│   │   ├── core_components.ex   # Shared UI components (avatar, flash, input, etc.)
│   │   ├── layouts.ex           # App and setup layouts with nav, theme toggle, footer
│   │   └── safety_components.ex # Mute / block / report menu items for remote accounts
│   ├── controllers/
│   │   ├── activity_pub_controller.ex  # ActivityPub endpoints (content-negotiated)
│   │   ├── error_html.ex        # HTML error pages
│   │   ├── error_json.ex        # JSON error responses
│   │   ├── feed_controller.ex   # RSS 2.0 / Atom 1.0 syndication feeds
│   │   ├── feed_xml.ex          # Feed XML rendering (EEx templates, helpers)
│   │   ├── feed_xml/            # EEx templates for RSS and Atom XML
│   │   │   ├── rss.xml.eex     # RSS 2.0 channel + items template
│   │   │   └── atom.xml.eex    # Atom 1.0 feed + entries template
│   │   ├── health_controller.ex # Health check endpoint
│   │   ├── page_controller.ex   # Static page controller
│   │   ├── page_html.ex         # Page HTML view module
│   │   ├── handle_redirect_controller.ex  # Redirects /@username to /users/:username (Mastodon compat)
│   │   ├── push_subscription_controller.ex  # POST/DELETE /api/push-subscriptions (Web Push)
│   │   ├── session_controller.ex  # POST endpoints for session mutations
│   │   └── share_target_controller.ex  # PWA Web Share Target POST handler
│   ├── live/
│   │   ├── admin/
│   │   │   ├── boards_live.ex          # Admin board CRUD + moderator management
│   │   │   ├── federation_live.ex      # Admin federation dashboard
│   │   │   ├── invites_live.ex         # Admin invite code management (generate, revoke, invite chain)
│   │   │   ├── login_attempts_live.ex # Admin login attempts viewer (paginated, filterable)
│   │   │   ├── moderation_live.ex     # Admin moderation queue (every report)
│   │   │   ├── moderation_log_live.ex # Moderation audit log (filterable, paginated)
│   │   │   ├── bots_live.ex           # Admin bot management (create, edit, delete RSS/Atom feed bots)
│   │   │   ├── pending_users_live.ex  # Admin approval of pending registrations
│   │   │   ├── settings_live.ex       # Admin site settings (name, timezone, registration, federation)
│   │   │   └── users_live.ex          # Admin user management (paginated, filterable, ban, unban, role change)
│   │   ├── article_edit_live.ex  # Article editing form
│   │   ├── article_helpers.ex   # Pure helper logic extracted from ArticleLive
│   │   ├── article_history_live.ex # Article edit history with inline diffs
│   │   ├── article_live.ex      # Single article view with paginated comments
│   │   ├── article_new_live.ex  # Article creation form
│   │   ├── auth_hooks.ex        # on_mount hooks: require_auth, optional_auth, etc.
│   │   ├── board_follows_live.ex # Board follows management (AP follow policy, search remote actors)
│   │   ├── board_live.ex        # Board view with article listing
│   │   ├── bookmarks_live.ex    # User bookmarks list (articles + comments, paginated)
│   │   ├── conversation_live.ex # Single DM conversation thread view
│   │   ├── conversations_live.ex # DM conversation list
│   │   ├── feed_live.ex          # Personal feed (remote posts, local articles, comment activity)
│   │   ├── following_live.ex    # Following management (outbound remote actor follows)
│   │   ├── home_live.ex         # Home page (board listing, public for guests)
│   │   ├── login_live.ex        # Login form (phx-trigger-action pattern)
│   │   ├── notifications_live.ex # Notification center (paginated, mark read, real-time)
│   │   ├── password_reset_live.ex  # Password reset via recovery codes
│   │   ├── profile_live.ex      # User profile with avatar upload/crop, locale prefs, signature, WebAuthn security key management, blocked and muted accounts
│   │   ├── recovery_code_verify_live.ex  # Recovery code login
│   │   ├── recovery_codes_live.ex        # Recovery codes display
│   │   ├── register_live.ex     # Public user registration (supports invite-only mode, terms notice, recovery codes)
│   │   ├── safety_actions.ex    # Shared handlers: block/mute remote accounts, report feed items, DMs, accounts
│   │   ├── search_live.ex       # Full-text search + remote actor lookup (WebFinger/AP)
│   │   ├── tag_live.ex          # Browse articles by hashtag (/tags/:tag)
│   │   ├── user_invites_live.ex # User invite code management (quota-limited, generate, revoke)
│   │   ├── user_content_live.ex # Paginated user articles/comments (/users/:username/articles|comments)
│   │   ├── user_profile_live.ex # Public user profile pages (stats, recent articles)
│   │   ├── setup_live.ex        # First-run setup wizard
│   │   ├── totp_reset_live.ex   # Self-service TOTP reset/enable
│   │   ├── totp_setup_live.ex   # TOTP enrollment with QR code
│   │   ├── totp_verify_live.ex  # TOTP code verification
│   │   ├── admin_totp_verify_live.ex       # Admin re-verification for sudo mode (TOTP or WebAuthn security key)
│   │   ├── markdown_preview_hook.ex       # LiveView hook for markdown preview toggling
│   │   ├── autocomplete_suggest_hook.ex   # LiveView hook answering #hashtag / @mention suggest events
│   │   ├── sandbox_hook.ex                # Ecto sandbox hook for feature tests
│   │   ├── unread_dm_count_hook.ex         # Real-time @unread_dm_count via PubSub
│   │   └── unread_notification_count_hook.ex # Real-time @unread_notification_count via PubSub
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
│   ├── helpers.ex               # Shared translation helpers (translate_role/1, translate_status/1, etc.)
│   ├── locale.ex                # Locale resolution (Accept-Language + user prefs)
│   ├── linked_data.ex          # JSON-LD + Dublin Core metadata builders (SIOC/FOAF/DC)
│   ├── open_graph.ex            # Open Graph + Twitter Card meta tag builders
│   ├── rate_limiter.ex          # Rate limiter behaviour (Sandbox / Hammer backends)
│   ├── rate_limiter/
│   │   └── hammer.ex            # Hammer-based rate limiter backend
│   ├── rate_limits.ex           # Per-user rate limit checks (Hammer, fail-open)
│   ├── router.ex                # Route scopes and pipelines
│   └── telemetry.ex             # Telemetry metrics configuration
```

### Auth Architecture

The `Baudrate.Auth` module is a **facade** — it delegates all calls to
focused sub-modules under `Baudrate.Auth.*`. External callers (LiveViews,
controllers, federation handlers, tests) always call `Auth.function_name`
and never need to know about the internal split.

| Sub-Module | Responsibility |
|---|---|
| `Auth.Users` | User CRUD, lookup (by ID, username, session), registration, admin approval, role updates, and capability checks |
| `Auth.Passwords` | Password hashing (bcrypt), verification, and recovery code-based resets |
| `Auth.Sessions` | Session lifecycle (dual-token rotation), server-side session storage, and login attempt throttling/monitoring |
| `Auth.SecondFactor` | TOTP enrollment, encryption/decryption of secrets, QR code generation, and recovery code management |
| `Auth.Reauthentication` | Step-up re-authentication from an authenticated session (password, plus TOTP when enabled; no recovery codes); feeds the per-account login throttle |
| `Auth.WebAuthn` | FIDO2/WebAuthn credential registration and authentication (hardware security keys); ETS-backed challenge lifecycle |
| `Auth.Invites` | Invite-only registration logic, quota management, and admin-issued invites |
| `Auth.Profiles` | User preference updates: display name, bio, signature, profile fields, avatar association, and notification settings |
| `Auth.Moderation` | Local user moderation: banning, blocking remote actors/users, and muting interactions |
| `Auth.Sanctions` | Warnings, silences and suspensions, refusing a pending registration, and `ensure_can_interact/1` — the one gate every posting and interaction path calls (ADR 0029) |

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

The TOTP step of login counts too. It is only reached with the correct
password, so its failures are recorded against the account
(`record_login_totp_failure/2`, `factor: "totp"`) and `totp_verify/2` checks the
same throttle. After 3 failed codes in an hour the owner gets a
`totp_login_failed` security notice, at most once an hour
([ADR 0024](adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md)).

Key functions in `Auth`:
- `record_login_attempt/4` — records an attempt (username lowercased; `factor` is
  `"password"` (default), `"totp"` or `"reauth"`)
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
| Cleanup | `SessionCleaner` GenServer purges expired sessions every hour. Each hourly step runs through `run_step/2`, so a step that raises is logged (`session_cleaner.step_failed`) and the remaining steps still run |
| LiveView sockets | Each session's cookie carries `live_socket_id` = `"user_session:<row id>"` (set at login, backfilled by `RefreshSession`); the row id is stable across rotation |
| Revocation | Every session deletion (`delete_session_by_token/1`, `delete_all_sessions_for_user/1`, `delete_other_sessions_for_user/2`, eviction, expiry, `purge_expired_sessions/0`) broadcasts `"disconnect"` to the deleted sessions' socket ids **after** the rows are gone, so open LiveView pages remount and hit the auth hooks instead of acting on a dead session |

**Password change and sign out everywhere** (`/profile/password`, `/profile` → Sessions)
both require step-up re-authentication (`Auth.verify_reauthentication/5`, password
plus TOTP when enabled). `Auth.change_password/3` validates the new password first
(`password_change_changeset/2`: policy, confirmation, different from the current one)
so mistakes do not use up re-authentication attempts. It then stores the hash and
revokes every *other* session. `Auth.sign_out_other_sessions/2` revokes other
sessions only. Both keep the caller's session by **row id** (tokens rotate daily
while a LiveView holds what it saw at mount) and send always-delivered security
notices (`password_changed`, `signed_out_everywhere`). They are the account-recovery
prerequisites for data export (ADR 0023).

### TOTP Code Verification

Every check of a stored TOTP secret goes through `Auth.verify_totp_code/3`
([ADR 0024](adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md)):

| Aspect | Detail |
|--------|--------|
| Window | The current or the previous 30-second period (`match_totp_step/3`), so a code that rolls over while being typed still works. The next period is not accepted |
| Single use | `users.totp_last_used_step` holds the last accepted period. One conditional `UPDATE` accepts only a later period, so a used code, or an older one, is refused, even for concurrent requests |
| Callers | Login (`totp_verify/2`), admin sudo (`admin_totp_verify/2`), step-up re-authentication. Enrolment records its confirming code as used (`enable_totp/3`, `used_step:`); `disable_totp/1` clears the column |
| Step-up | Consumes the code only when the password is also correct (`claim: password_valid`) |
| UI | Every TOTP field shows `<.totp_code_hint>` ("each code works only once") at all times, never only after a failure |

### Admin Sudo Mode

Admin routes (`/admin/*`) require periodic re-verification — similar to Unix
`sudo`. When an admin navigates to any admin page, the `:require_admin_totp`
hook checks the `admin_totp_verified_at` timestamp in the cookie session. If
missing or older than 10 minutes, the admin is redirected to `/admin/verify`
for re-verification, with `return_to` set to the requested admin path and query
(read from the `:uri` connect info), so verification lands back on that page.

Admins can verify using either **TOTP** (time-based one-time password) or a
registered **WebAuthn hardware security key** (FIDO2). Both methods set the
same `admin_totp_verified_at` session key on success.

Sudo attempts are limited to **5 per 15 minutes per user** by
`RateLimits.check_admin_sudo/1`, hit before the code or assertion is checked.
The bucket is keyed on the user id, so the lockout survives a discarded cookie
and cannot be spread across source IPs; the cookie's `admin_totp_attempts`
counter remains as defense in depth. WebAuthn assertions additionally fail with
`:sign_count_regressed` when the authenticator's signature counter does not
advance past the stored value (`WebAuthn.sign_count_advanced?/2`), the
specified signal of a cloned credential; authenticators that never implement a
counter (both sides `0`) are exempt.

| Aspect | Detail |
|--------|--------|
| Timeout | 10 minutes (`@admin_totp_timeout_seconds 600`) |
| Methods | TOTP code (NimbleTOTP) or WebAuthn hardware security key (wax_) |
| Live session | Admin routes use `:admin` live_session (separate from `:authenticated`) |
| Moderators | Pass through without re-verification (hook skips non-admin users) |
| Lockout | 5 failed attempts lock admin out of admin pages (session NOT dropped) |
| Verification page | `/admin/verify` stays in `:authenticated` to avoid redirect loops |
| Session key | `admin_totp_verified_at` — Unix timestamp set on successful verification |

### Step-up Re-authentication

Because sudo mode accepts any registered WebAuthn key, a session cookie alone
must never be able to change which factors an account has. Otherwise a stolen
admin session could register its own key and pass `/admin/verify`
([ADR 0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md)).

- `Auth.verify_reauthentication/5` (`Baudrate.Auth.Reauthentication`) checks
  the password, plus an unused TOTP code when TOTP is enabled (see TOTP Code
  Verification). Recovery codes are never accepted. Failures are recorded with
  `factor: "reauth"` and never send `totp_login_failed`, because this form does
  not say which factor was wrong.
- It enforces `Auth.check_login_throttle/1` before checking any credential,
  and records failures in `login_attempts`. The account throttle therefore
  survives page reloads, and a re-authentication form cannot be used to guess
  passwords around the login throttle.
- Callers first apply `RateLimits.check_reauth/1` (5 per 15 minutes per user,
  shared across all re-authentication forms).
- `/profile` requires it before registering or removing a security key. A
  success unlocks key management for 5 minutes, held in socket assigns and
  re-checked by every event handler.
- `/profile/totp-reset` requires it before resetting or enabling TOTP.
- WebAuthn challenges are bound to their purpose: `WebAuthnChallenges.pop/3`
  takes `:attestation` (registration) or `:authentication` (sudo assertion),
  and a mismatch consumes the entry.

The `:admin` live_session boundary forces a full page load when navigating
from authenticated pages to admin pages, ensuring the cookie session is
re-read for a fresh timestamp. Within admin pages, live-navigation shares
the WebSocket session without re-prompting.

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
   strips all EXIF/metadata, and produces 120×120, 48×48, 36×36, and 24×24 thumbnails
4. Files stored at `priv/static/uploads/avatars/{avatar_id}/{size}.webp`
   with server-generated 64-char hex IDs (no user input in paths)
5. Rate limited to 5 avatar changes per hour per user

**OTP release note:** Upload directory paths use `Application.app_dir/2` at
runtime — never compile-time module attributes with `:code.priv_dir/1`, which
would resolve to the build directory instead of the release directory.

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

Signed-in users change their password at `/profile/password` (see Session Management).

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

### User Profile Fields

Users can add up to 4 custom profile fields (name + value pairs, e.g. "Website",
"Location", "Affiliation") in their profile at `/profile`. Fields are stored as a
`jsonb[]` column (`profile_fields`) on the `users` table. Each field has a `name`
(max 255 characters) and a `value` (max 2048 characters). Empty-name fields are
silently discarded.

For ActivityPub federation, profile fields are published as `PropertyValue`
attachments on the Person actor following the Mastodon convention:

```json
"attachment": [
  {"type": "PropertyValue", "name": "Website", "value": "https://example.com"}
]
```

The `@context` includes `schema:PropertyValue` and `schema:value` from
`http://schema.org/` to ensure Mastodon and compatible clients render the fields
correctly. Values are HTML-escaped before publishing.

Incoming remote actors' `attachment` arrays are parsed by `ActorResolver` —
entries with `type: "PropertyValue"` are extracted (up to 4), stored in the
`profile_fields` column on `RemoteActor`, and displayed on the user's local
profile page.

**Files:**
- `lib/baudrate/setup/user.ex` — `profile_fields_changeset/2` with validation
- `lib/baudrate/auth/profiles.ex` — `update_profile_fields/2`
- `lib/baudrate/federation/actor_renderer.ex` — `render_profile_fields/1`
- `lib/baudrate/federation/actor_resolver.ex` — `extract_profile_fields/1`
- `lib/baudrate_web/live/profile_live.ex` — `save_profile_fields` event
- `lib/baudrate_web/live/user_profile_live.html.heex` — `<dl>` display

### User Signatures

Users can set a signature (max 500 characters, max 8 lines, markdown format) in
their profile at `/profile`. Signatures are rendered via `Content.Markdown.to_html/1`
and displayed below articles and comments authored by the user, as well as on
their public profile page at `/users/:username`.

### Article Creation

Authenticated users with active status and `user.create_content` permission
can create articles. Two entry points:

- `/boards/:slug/articles/new` — pre-selects the board via a fixed hidden input (no picker shown)
- `/articles/new` — user picks one or more boards via a debounced search input backed by `Content.search_boards/2`. Selected boards render as removable chips with hidden `board_ids[]` inputs so the form submission carries the full selection. Both the search query and the add-board handler go through `can_post_in_board?/2`.

The `/feed` quick-post composer uses the same search-and-chip pattern for its optional board selection. Leaving the picker empty creates a board-less personal article (the composer's default behavior); adding boards cross-posts the article to them.

Articles are assigned a URL-safe slug generated from the title with a random
suffix to avoid collisions. Articles can be cross-posted to multiple boards.
Any authenticated user can forward a public or unlisted article to a board
via the "Forward to Board" autocomplete on the article detail page, provided
the article's `forwardable` flag is `true` (the default). Authors and admins
can forward regardless of visibility or the forwardable flag. Authors control
forwarding via the "Allow forwarding" checkbox on the create/edit forms.
Authors and admins can also remove an article from specific boards via the
edit form, potentially making it boardless again.

All three forward paths (`Content.forward_article_to_board/3`,
`forward_comment_to_board/3`, `forward_feed_item_to_board/3`) enforce two
invariants at the context boundary rather than relying on their callers:

- **Source-board view gate** — the acting user must be able to view the board
  the source content lives in (`Interactions.article_visible_to_user?/2`).
  Local content defaults to `visibility: "public"` regardless of the board's
  `min_role_to_view`, so the visibility check alone would let a user guess an
  ID in a private board and republish its body publicly.
- **Soft-delete gate** — a source record with a non-nil `deleted_at` returns
  `{:error, :not_found}`. The LiveView handlers resolve the source from a
  client-supplied ID with a bare `Repo.get/2`, which does not filter
  `deleted_at`, so a removed comment or a withdrawn feed item could otherwise
  be resurrected as a permanent board article.

For feed items specifically, a third gate applies. `feed_items` rows are
global — feed membership is a query-time JOIN on `user_follows`, not a
per-user column — so `Federation.feed_item_accessible?/2` is the single
reachability predicate shared by every entry point that resolves a feed item
from a client-supplied ID: like, boost, reply, and forward-to-board. It
requires an `accepted` follow on the item's **source** actor — the author for
`Create`, the **booster** for `Announce` (for a boost, `remote_actor_id` is
the original author, whom the user need not follow) — and rejects
soft-deleted items. Admins bypass the follow requirement when forwarding.

The `visibility` field on articles, comments, and feed items records the
ActivityPub visibility derived from `to`/`cc` addressing:
- `public` — `as:Public` in `to` (default for local content)
- `unlisted` — `as:Public` in `cc` only
- `followers_only` — addressed to followers collection, no public
- `direct` — addressed to specific actors only

Visibility is derived on ingest by `Federation.Visibility.from_addressing/1`
and respected in outbound activities by the Publisher.

Local articles and comments only accept `public` or `unlisted` (the composers
offer nothing else, and `Article.changeset/2`, `trusted_changeset/2`,
`update_changeset/2` and `Comment.changeset/2` reject the rest). Board content
is readable on this site by anyone the board lets in, whatever its federation
addressing, so offering "Followers only" or "Direct" there promised a privacy
the site never enforced. Direct messages are the private channel. Remote rows
keep all four values.

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
- `Content.Images` — CRUD functions (`create_article_image/1`, `list_article_images/1`,
  `associate_article_images/3`, `delete_article_image/1`, `delete_orphan_article_images/1`,
  `fetch_and_store_remote_images/2`)
- `Federation.AttachmentExtractor` — extracts image attachment metadata from AP objects

**Remote article images:** When a remote article is imported (via federation inbox
or `/search`), image attachments from the AP object's `attachment` array are
extracted by `AttachmentExtractor` and fetched asynchronously via
`Images.fetch_and_store_remote_images/2`. Remote images go through the same
security pipeline (magic byte validation, re-encode to WebP, EXIF strip, max
1024px) and are stored locally as `ArticleImage` records with `user_id = NULL`.

**Remote comment/DM images:** Image attachments on incoming Note objects (comments
and DMs) are appended as `<img>` tags to `body_html` during ingestion. Only HTTPS
URLs are allowed. The `AttachmentExtractor` extracts the attachment metadata and
`InboxHandler.append_attachment_images/2` builds the sanitized HTML, emitting the
**proxied** path rather than the remote URL (see below).

### Media Proxy

No page may emit a subresource pointing at a host we do not control: that would
disclose every viewer's IP address, User-Agent, and reading times to every remote
instance whose content appears on the page. CSP enforces it with
`img-src 'self' data: blob:`.

Remote images are therefore rewritten to `/media/<signature>/<encoded-url>` and
served by `BaudrateWeb.MediaController` from a local re-encoded copy.

| Module | Role |
|--------|------|
| `Media.Proxy` | `url/1` signs a remote URL; `verify/2` checks it |
| `Media.Cache` | SSRF-safe fetch → magic bytes → libvips WebP → `uploads/media_cache/<sha256>.webp` |
| `Media.NegativeCache` | 1-hour suppression of retries for URLs that failed |
| `Media.Rewriter` | `rewrite_img_src/1` over already-sanitized HTML |
| `Media.Warmer` | opportunistic pre-fetch at ingest (disabled in tests) |
| `BaudrateWeb.SafeHTML` | `body_html/1` — use instead of `raw/1` for stored HTML |

Design notes:

- **Deterministic signing.** HMAC-SHA256 over the URL alone, never
  `Phoenix.Token.sign/3` — its embedded timestamp would produce a different
  `src` on every render, defeating browser caching and generating a LiveView
  diff for every avatar on every patch.
- **Not an open proxy.** Only a URL this instance itself signed can be
  requested, and the fetch still goes through `Federation.HTTPClient`
  (HTTPS-only, DNS-pinned, private-IP-rejecting, size-capped). SVG is never
  accepted or served.
- **Rewrite at render, not ingest.** Applying the rewrite in
  `Markdown.to_html/1` and `SafeHTML.body_html/1` covers every row written
  before the proxy existed, so no migration or backfill was needed, and the
  canonical remote URL is preserved so a failed fetch stays retryable.
- **Storage location is forced by ops.** The systemd unit grants write access
  only to `shared/uploads`, and only that directory is symlinked into each
  release. nginx denies `/uploads/media_cache/` so the signature cannot be
  bypassed.
- **Eviction** runs hourly in `SessionCleaner`: entries untouched for 30 days,
  then oldest-first until under `:media_cache_max_bytes` (2 GB default). Both
  are configured under `config :baudrate, Baudrate.Media`.

`test/baudrate_web/no_hotlink_test.exs` is the acceptance gate — it seeds each
historical hotlinking source and asserts no rendered page contains an absolute
or protocol-relative `<img src>`.

**OTP release note:** Same as the avatar system — upload directory paths must
use runtime `Application.app_dir/2` calls, not compile-time module attributes.

### Drafts / Autosave

Article and comment forms auto-save drafts to `localStorage` via a generic
`DraftSaveHook` (Phoenix LiveView JS hook). No server-side storage is needed.

**How it works:**

- A single `DraftSaveHook` is attached to `<.form>` elements via `phx-hook`
- On typing, form field values are debounced (1.5s) and saved to localStorage
- On mount, the hook checks for a matching draft; if found and < 30 days old,
  it populates the fields and dispatches `input` events to sync with LiveView
- On form submit, the draft is immediately cleared from localStorage
- Empty drafts (all fields blank) are removed instead of saved
- A brief "Draft saved" / "Draft restored" indicator fades in near the submit
  button (translated via `data-` attributes and gettext)

**Draft key scheme:**

| Context | Key | Fields |
|---------|-----|--------|
| New article | `draft:article:new` | `article[title]`, `article[body]` |
| Edit article | `draft:article:edit:{slug}` | `article[title]`, `article[body]` |
| Top-level comment | `draft:comment:{article_id}` | `comment[body]` |
| Reply to comment | `draft:comment:{article_id}:reply:{comment_id}` | `comment[body]` |

**Data attributes on the form element:**

- `data-draft-key` — localStorage key
- `data-draft-fields` — comma-separated field `name` attributes to save
- `data-draft-indicator` — CSS selector for indicator `<span>`
- `data-draft-saved-text` / `data-draft-restored-text` — i18n strings

Key files:
- `assets/js/draft_save_hook.js` — the hook implementation
- `assets/js/app.js` — hook registration

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
- `Content.Markdown` — rendering pipeline (MDEx → Ammonia → linkification)
- `TagLive` — `/tags/:tag` browse page

### Content Architecture

The `Baudrate.Content` module is a **facade** — it delegates all calls to
focused sub-modules under `Baudrate.Content.*`. External callers (LiveViews,
controllers, federation handlers, tests) always call `Content.function_name`
and never need to know about the internal split.

| Sub-Module | Responsibility |
|---|---|
| `Content.Filters` | Shared query helpers (block/mute filters, role visibility, LIKE sanitization, CJK detection) |
| `Content.Boards` | Board CRUD, board cache integration, federation toggle, board moderator assignments, SysOp board |
| `Content.Permissions` | Board access checks, granular article/comment permissions, slug generation |
| `Content.Articles` | Article CRUD (local + remote), cross-posting, revisions, pin/lock |
| `Content.Comments` | Comment CRUD (local + remote), threaded listing, article activity timestamps |
| `Content.Likes` | Article and comment likes (local + remote), toggle, counts |
| `Content.Boosts` | Article and comment boosts (local + remote), toggle, batch queries, federation via AP Announce/Undo(Announce) |
| `Content.Bookmarks` | Article and comment bookmarks, toggle, paginated listing |
| `Content.Images` | Article image creation, association, cleanup |
| `Content.Tags` | Hashtag extraction from article bodies, tag syncing, tag-based browsing |
| `Content.Search` | Full-text search across articles, comments, and boards (FTS + CJK ILIKE + operators) |
| `Content.Feed` | Public feed listings, per-user article/comment queries, content statistics |
| `Content.ReadTracking` | Per-user article/board read state, unread indicators |
| `Content.Polls` | Poll creation, voting (local + remote), denormalized counter management |

### Content Model

Boards are organized hierarchically via `parent_id` and have role-based access
control via `min_role_to_view` and `min_role_to_post` fields (see
[Board Permissions](#board-permissions) above). Board pages display breadcrumb
navigation (ancestor chain from root to current board) and list sub-boards
above articles. Sub-boards and board listings are filtered by the user's role.
Articles can be cross-posted to multiple boards through the `board_articles`
join table. Each article has a `forwardable` boolean (default `true`) that
controls whether other users can cross-forward it to additional boards.
Authors and admins can remove an article from specific boards via
`Content.remove_article_from_board/3`. Board moderators are tracked via the
`board_moderators` join table.

Comments are threaded via `parent_id` (self-referential) and belong to an
article. Both articles and comments can originate locally (via `user_id`) or
from remote ActivityPub actors (via `remote_actor_id`). Soft-delete is
implemented via `deleted_at` timestamps on both articles and comments.
Articles also record `deleted_by_id` (the local author or moderator who deleted
it, via `Content.soft_delete_article(article, deleted_by: user_id)`). Remote
deletions and rows deleted before the column existed stay `nil`, meaning
attribution unknown, and the data export excludes them (ADR 0023).

Article likes track favorites from local users and remote actors, with
partial unique indexes enforcing one-like-per-actor-per-article. Comment
likes follow the same pattern (`comment_likes` table with `CommentLike`
schema). Local users can toggle likes on articles and comments; self-likes
are prevented. Article and comment likes are federated outbound
(Like/Undo(Like) activities).

Article boosts (`article_boosts` table with `ArticleBoost` schema) and
comment boosts (`comment_boosts` table with `CommentBoost` schema) follow
the same pattern as likes. Toggle functions (`toggle_article_boost/2`,
`toggle_comment_boost/2`) prevent self-boosts and boosts on deleted content.
Batch queries return user boost state as MapSets and boost counts as Maps
for efficient rendering. Boosts are federated as AP Announce/Undo(Announce)
activities.

#### Polls

Articles may optionally have an inline poll attached at creation time (one poll
per article, enforced by a unique constraint on `article_id`). Polls support two
modes: **single-choice** (radio buttons, exactly one selection) and
**multiple-choice** (checkboxes, one or more selections). An optional `closes_at`
timestamp makes the poll time-limited; after expiry, votes are rejected.

**Database tables:**

| Table | Purpose |
|-------|---------|
| `polls` | Poll metadata: mode (single/multiple), closes_at, voters_count, ap_id, article_id |
| `poll_options` | Choices: text, position (ordering), denormalized votes_count |
| `poll_votes` | Individual votes: links user or remote_actor to a poll_option |

**Constraints and indexes:**

- `polls.article_id` — unique (one poll per article)
- `polls.ap_id` — unique (federation dedup)
- `poll_votes` — partial unique index on `(poll_id, poll_option_id, user_id)` for local voters
- `poll_votes` — partial unique index on `(poll_id, poll_option_id, remote_actor_id)` for remote voters

**Poll creation flow:**

Polls are created alongside articles via nested `cast_assoc` in the article
creation form. Options are limited to 2--4 per poll. Option text is capped at
200 characters. The `closes_at` timestamp must be in the future at creation time.

**Vote flow:**

`Content.cast_vote/3` handles local voting within an `Ecto.Multi` transaction:

1. Acquires a `FOR UPDATE` row lock on the poll to prevent races
2. Deletes any existing votes by the user on this poll (enables vote changing)
3. Inserts new vote rows for the selected option(s)
4. Recalculates denormalized counters (`votes_count` on each option,
   `voters_count` on the poll) via raw SQL for accuracy

Votes are **anonymous** — the database tracks voters for dedup but the UI never
reveals individual votes; only aggregate counts are displayed.

**Key functions in `Content`:**

- `get_poll_for_article/1` — returns poll with preloaded options, or nil
- `get_user_poll_votes/2` — returns option IDs a user has voted for
- `cast_vote/3` — transactional vote cast/change for local users
- `create_remote_poll_vote/1` — inserts a remote actor's vote
- `recalc_poll_counts/1` — recalculates denormalized counters from vote rows
- `update_remote_poll_counts/2` — updates counters from inbound `Update(Question)`

**Federation mapping:**

Polls are federated as `Question` attachments on `Article` objects. The mapping
follows the Mastodon convention:

| Local concept | ActivityPub representation |
|---------------|--------------------------|
| Single-choice poll | `Question` with `oneOf` array |
| Multiple-choice poll | `Question` with `anyOf` array |
| Poll option | `Note` with `name` (text) and `replies.totalItems` (vote count) |
| Poll expiry | `endTime` on the `Question` |
| Voter count | `votersCount` on the `Question` |

Outgoing articles with polls embed the `Question` in the `attachment` array of
the `Article` object (via `Federation.article_object/1` → `maybe_embed_poll/2`).

Incoming `Create(Article)` or `Create(Question)` activities are parsed by
`InboxHandler.extract_poll_from_object/2`, which looks for either a top-level
`Question` type or a `Question` in the `attachment` array.

Vote federation uses the Mastodon vote protocol: each selected option produces a
separate `Create(Note)` with `name` matching the option text and `inReplyTo`
pointing to the article AP URI. Incoming vote Notes are detected by
`maybe_handle_poll_vote/2` in `InboxHandler`, which matches the `name` against
poll options and records the remote vote.

`Update(Question)` activities refresh denormalized vote counts on remote polls
without re-processing individual votes.

### Search

Full-text search is available at `/search` for articles, comments, and boards,
with a tabbed UI (Articles, Comments, Boards, Users). Search uses a dual
strategy to support both English and CJK (Chinese, Japanese, Korean) text:

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
- `search_visible_boards/2` — board search by name/description with pagination and view-role visibility
- `contains_cjk?/1` — detects CJK characters in search query (private)
- `sanitize_like/1` — escapes `%`, `_`, `\` for safe ILIKE queries (private)

User input is escaped via `sanitize_like/1` before interpolation into ILIKE
patterns to prevent SQL wildcard injection.

#### Advanced Search Operators (Articles Tab)

The Articles tab supports inline search operators mixed with free-text queries.
Operators are `key:value` tokens parsed from the query string; remaining text
becomes the free-text search term.

| Operator | Example | Semantics |
|----------|---------|-----------|
| `author:username` | `author:alice` | Filter by author (case-insensitive). Multiple = OR. |
| `board:slug` | `board:general` | Filter by board slug. Multiple = OR. |
| `tag:tagname` | `tag:elixir` | Filter by tag (lowercase). Multiple = AND (must have all). |
| `has:images` | `has:images` | Articles with attached images. |
| `before:YYYY-MM-DD` | `before:2026-01-15` | Articles before end of that day (exclusive). |
| `after:YYYY-MM-DD` | `after:2026-01-01` | Articles on or after that day (inclusive). |

Example query: `author:alice tag:elixir phoenix tutorial` parses as operators
`{author: ["alice"], tag: ["elixir"]}` with free text `"phoenix tutorial"`.

If all tokens are operators (no free text remains), text search is skipped and
results are ordered by `inserted_at desc`. Invalid dates are silently ignored.
Operator parsing uses string keys internally (never `String.to_atom/1` on user
input). A collapsible help section is shown below the search bar on the Articles
tab.

Key functions in `Content`:

- `parse_search_query/1` — extracts operator tokens from query string (private)
- `apply_search_operators/2` — dispatches to per-operator filter functions (private)

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
the `dm_access` setting. Authorization is re-checked on **every** message in
`create_message/3` (the context boundary), not only when a conversation is
first started — so a recipient who blocks the sender or switches `dm_access`
to `nobody`/`followers` after an existing conversation began cannot be messaged
further (`{:error, :not_allowed}`).

**Key functions in `Messaging`:**

- `can_send_dm?/2` — checks dm_access, blocks, status (local recipient)
- `find_or_create_conversation/2` — canonical ordering prevents duplicates
- `create_message/3` — authorizes the send, creates the message, broadcasts PubSub, schedules federation
- `receive_remote_dm/3` — handles incoming federated DMs
- `list_conversations/1` — ordered by `last_message_at` desc
- `list_messages/2` — the newest `:limit` messages (default 100), returned oldest first; `:before_id` pages back, and `messages_before?/2` tells the conversation page whether to offer "Load older messages"
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

The moderation system includes a content reporting queue (`/admin/moderation`,
20 reports a page, newest first, `?status=` and `?page=` in the URL) and an
audit log (`/admin/moderation-log`). Moderation and administrative
actions — banning, role changes, report resolution and Flags, board CRUD and
federation settings, content deletion, pin/lock, settings saves, and bot
management — are recorded with actor, action type, target, and contextual
details. The log is filterable by action type and paginated.

Every action name must be listed in `Moderation.Log`'s `@valid_actions`,
or the insert fails. Callers do not check the result, so `log_action/3` logs
a refused entry as an error, and `test/baudrate/moderation/log_test.exs`
walks every `log_action` call in `lib/` to reject unknown names.

#### Sanctions short of a ban

[ADR 0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md). Before this,
the only thing staff could do to an account was ban it permanently: a first
offence either went unanswered or ended the account.

A sanction is a **row in `sanctions`**, not a `users.status` value — `status`
keeps exactly `active | pending | banned`, because several checks in the
codebase ask `status != "banned"` and would silently admit a value they had
never heard of. A row also carries what a status cannot: an end, an author, a
reason and a history. Rows are append-only; a sanction is lifted, never
deleted.

| Kind | What it does | End date |
|------|--------------|----------|
| `warn` | A notice and an audit entry. Nothing is refused, and no acknowledgement is demanded — a "accept this to post again" gate is a silence wearing a different hat | none |
| `silence` | The account becomes read-only, including the parts of its profile other people read | optional |
| `suspend` | The account cannot sign in; sessions are revoked and exports and moves cancelled, as for a ban. Invite codes are left alone: they expire in seven days by themselves | **required** |

**Active is decided by the clock**, never by a sweep:
`lifted_at IS NULL AND (expires_at IS NULL OR expires_at > now())`. No
background job sets or clears a flag, so a failed hourly run can neither hold
a member past their time nor lift one early. `SessionCleaner` only sends the
"it has ended" notice.

**One gate.** `Auth.ensure_can_interact/1` returns `:ok` or
`{:error, :banned | :account_suspended | :account_silenced | :account_moved}`
in a single query, and is what every context function calls before it lets an
account create content or interact — articles, edits, comments, feed replies,
likes, boosts, forwards, poll votes, follows, DMs, invites, and display name,
bio, avatar, signature and profile fields. It replaced
`AccountMigration.ensure_not_moved/1` at every call site, because two parallel
gates mean two lists of call sites and one of them goes stale.
`test/baudrate/auth/sanctions_gate_test.exs` walks the AST of `lib/` and fails
if the old check is called anywhere but the two files that legitimately ask
about the *followed* account.

Deliberately still allowed to a silenced member: undoing an earlier like or
boost, deleting their own content, **reporting abuse**, every account-security
action, and narrowing `dm_access` — a sanction must not stop someone making
their account safer. Existing content stays up: removal is a per-item decision
made through the report queue, where it leaves evidence (P1-D6).

Sanctions **stack forward only**. Several active rows are harmless: the
account is restricted while any is active and the end shown is the furthest
away, so issuing can only extend. To shorten one, lift it — there is no
partial unique index, because "active" depends on `now()`.

**Who may do what** is the `moderator.sanction_user` permission, so P1-D3 is
configuration and not a hard-coded role name, plus two rules checked in `Auth`
whatever the roles say: nobody sanctions themselves, and nobody sanctions an
account whose role level is at or above their own. Without
`admin.manage_users` the duration is capped at 30 days, measured server-side
against `issued_at`. Every issue and lift goes through `Moderation.log_action/3`
(`warn_user`, `silence_user`, `suspend_user`, `lift_sanction`, `reject_user`)
and `RateLimits.check_sanction/1`.

**The member is always told** (P1-D4), three ways: an always-delivered
`sanction_applied` / `sanction_lifted` / `sanction_ended` notice, the refusal
they meet when they try to act (`Helpers.refusal_message/3`), and a banner on
every page while the restriction stands. A post that fails with a shrug is
worse than the sanction, and a composer that simply vanishes explains nothing.

**Refusing a pending registration** is a ban with a reason on an account that
is still `pending`, logged as `reject_user`. Approving stays an admin decision
(`admin.manage_users`); refusing needs only `moderator.sanction_user`, which is
why `/admin/pending-users` is open to moderators. Registration that leaves an
account pending notifies staff.

**The user detail page** (`/admin/users/:id`) gathers the record a moderator
needs before deciding about a person rather than a post: role, status, sanction
history, reports by and against the account, recent content, inviter and
invitees — with the warn / silence / suspend / lift actions beside it. **IP
addresses and sign-in attempts are admin-only**, and are not fetched at all for
a moderator.

Sanctions are **local**: nothing is sent over ActivityPub, following P1-D1.

**User-facing reports:** Authenticated users can report articles, comments,
other users, feed items, direct messages they received, and remote accounts
directly from the UI. Report controls appear on article pages (for articles and
comments by other users), user profile pages, the "More actions" menu of remote
feed items and remote comments, the header menu of a conversation with a remote
actor, and on every received message. Reports are submitted via a modal dialog
with a required reason category (P1-D9: spam, harassment, illegal content,
breaks a rule, other) and a required free-text reason (max 2000 chars). Only
those two fields come from the client (`SafetyActions.report_details/1`); the
target always comes from server-side assigns. A report that arrives as a
federated `Flag` carries no category, so `reports.category` is required only
when `reporter_id` is set. Duplicate prevention ensures one
open report per reporter per exact target (`Moderation.has_open_report?/2`
compares every target field, so reporting a post does not count as reporting
its author). Report creation is rate-limited to 5 per 15 minutes per user.
Reports target `article_id`, `comment_id`, `remote_actor_id`,
`reported_user_id`, `feed_item_id` or `message_id`.

**Board moderators** have their own queue at `/moderation`
(`BaudrateWeb.ModerationLive`), outside `/admin` because they are ordinary
members (role `user`). It lists only reports about articles in the boards
they moderate and comments on those articles
(`Moderation.paginate_reports(boards: …)`, scoped by
`Content.moderated_board_ids/1`, which returns every board for staff): never
reports about accounts, direct messages or feed items, and never another
board's. Every action re-checks the scope (`Moderation.report_in_boards?/2`)
and the delete permission, since the report id comes from the client. Boards
link to it for their moderators. Both queues render a report through
`BaudrateWeb.ModerationComponents.report_card/1`, so they cannot drift apart.

A new report notifies every admin and global moderator, plus the board
moderators of the board the reported article or comment is in
(`Notification.Hooks.notify_report_created/1`).

**Outcomes (P1-D4).** Resolving a report tells its reporter that it was
reviewed, with no detail about the decision; dismissing tells nobody.
Removing content tells its author (`notify_content_removed/3`), with the
reason category of the report the removal came from. That notice is always
delivered: `content_removed` is in
`Notification.Notification.always_delivered_types/0`, so notification
preferences cannot switch off being told your own post was removed, and
`configurable_types/0` leaves it out of the preferences table. Deleting your
own content notifies nobody (the remover is the notification's actor, and a
notification is never delivered to its own actor).

**Cross-posted articles (P1-D5).** Deleting, pinning or locking an article
that lives in several boards needs moderation rights on **every** one of them
(`Permissions.board_moderator_for_all?/2`); the same goes for deleting a
comment on it, since a comment is removed from every board at once. A
moderator of one board can still take the article out of *their* board
(`can_remove_from_board?/3`, enforced in
`Content.remove_article_from_board/3`), and the article page offers that for
exactly the boards a member may remove it from. Authors, admins and global
moderators are not held to the all-boards rule.

**Evidence (P1-D6).** When content is removed from a queue, the report keeps a
copy of its text (`reports.evidence_body`, `evidence_taken_at`, set by
`Moderation.capture_evidence/2` from the stored record, never cast from
attributes), so a closed report still explains itself once the content reads
as deleted. `Moderation.purge_closed_report_evidence/0` clears that copy and
the copied direct message 90 days after the report was closed, hourly from
`SessionCleaner`; an open report keeps its evidence however old it is.
Content an author deletes themselves is still wiped at once.

Deletions record who made them: articles already had `deleted_by_id`, and
comments now do too. Moderators removing other people's content are not held
to the author limit of 20 deletions per 5 minutes; they have
`RateLimits.check_moderator_delete/1` (100 per 5 minutes).

Each row in the queue shows the category, the full reported text, a link to
the reported article, comment (at its place on the article), account or
original post, and how many **other** open reports share that exact target
(`Moderation.other_open_report_counts/1`, one grouped query per target field,
so no N+1).

Feed items, messages and remote accounts are reported through
`Moderation.report_feed_item/3`, `report_message/3` and
`report_remote_actor/3`, which check that the reporter can see the target (a
feed item must pass `Federation.feed_item_accessible?/2`; a message must be in
the reporter's conversation, sent by the other participant, and not deleted).
The remote author or sender becomes `remote_actor_id`, so "Send Flag" works; it
forwards the reported objects' `ap_id`s. A message report stores a copy of that
one message's text in `reports.message_body`, taken when the report is made and
never cast from attributes: moderators see the reported message and nothing
else from the conversation, and the copy survives the sender deleting it.

### Notifications

In-app notification system with real-time delivery via PubSub.

**Notification types:**
- `reply_to_article` — someone replied to your article
- `reply_to_comment` — someone replied to your comment
- `mention` — someone @mentioned you
- `new_follower` — someone followed you
- `article_liked` — someone liked your article
- `comment_liked` — someone liked your comment
- `article_boosted` — someone boosted your article
- `comment_boosted` — someone boosted your comment
- `article_forwarded` — your article was forwarded to another board
- `moderation_report` — a new moderation report (admins only)
- `admin_announcement` — announcement from an admin
- `security_key_added` / `security_key_removed` — a WebAuthn key was registered or removed (`data.label`)
- `totp_enabled` / `totp_disabled` — TOTP was set up or turned off
- `password_changed` — the password was changed while signed in
- `signed_out_everywhere` — all other sessions were signed out (`data.count`)
- `totp_login_failed` — the correct password was entered but the TOTP code failed 3 times within an hour at login; links to `/profile/password` (ADR 0024)

**Account security notices** (the types from `security_key_added` on, and the
`data_export_*` types; `Notification.Notification.security_types/0`)
are emitted by the Auth context itself: `WebAuthn.create_webauthn_credential/2`,
`WebAuthn.delete_webauthn_credential/2`, `SecondFactor.enable_totp/2` and
`SecondFactor.disable_totp/1` (the latter only when TOTP was on) call
`Hooks.notify_account_security/3`, so every path that changes a factor
produces one. They have no actor, so they are never deduplicated. They are
**always delivered**: `create_notification/1` and push delivery ignore
notification preferences for these types, and
`User.notification_preferences_changeset/2` does not accept them. The web push
payload is rendered in the recipient's preferred locale and links to
`/profile`. They let a user notice a factor change they did not make
([ADR 0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md)).

**Key design decisions:**
- Self-notification suppression — users never receive notifications for their own actions
- Blocked/muted suppression — notifications from blocked or muted users are silently dropped
- Deduplication via COALESCE-based unique indexes on `(user_id, type, actor_*, article_id, comment_id)` — on conflict returns `{:ok, :duplicate}`
- Per-notification-type preferences — users can opt out of specific types via `notification_preferences` (JSON column); account security notices cannot be turned off. `Notification.Notification.configurable_types/0` is the single list behind both the preferences changeset and the `/profile` toggles (they used to drift apart)
- Web push titles are built from the same translated `Helpers.notification_text/1` fragment as the in-app list (actor name + text), in the recipient's preferred locale; the icon is the actor's 120 px avatar rendition
- Real-time via PubSub events: `:notification_created`, `:notification_read`, `:notifications_all_read`
- `UnreadNotificationCountHook` on_mount hook maintains `@unread_notification_count` for the nav badge
- Notification hooks in `Notification.Hooks` are called fire-and-forget from context functions

**Files:**
- `lib/baudrate/notification.ex` — context (create, list, mark read, unread count, preferences)
- `lib/baudrate/notification/notification.ex` — schema with type validation
- `lib/baudrate/notification/hooks.ex` — hook functions called from Content/Federation/Auth contexts
- `lib/baudrate/notification/pubsub.ex` — PubSub broadcast helpers
- `lib/baudrate_web/live/notifications_live.ex` — paginated notification center with mark-read

### Data Export

Self-service download of a user's own data, designed against data leakage
([ADR 0023](adr/0023-data-export-threat-model.md)). `Baudrate.DataPortability`
holds every rule; the web layer only collects credentials.

| Piece | Responsibility |
|-------|----------------|
| `DataPortability` | Eligibility (active, non-bot, TOTP ≥ 7 days); `request_export/3` and `authorize_download/4` with step-up re-authentication inside the context; 24 h cooling-off, 48 h window, 3 downloads (`claim_download/2`, one conditional `UPDATE … RETURNING`); `cancel_export/3`, `cancel_active_exports/2`; `sweep_transitions/1` (hourly + before reads, notices exactly once) |
| `DataPortability.ExportRequest` | `export_requests` rows: request records only, never an archive. A partial unique index allows one active request per user. Stores a browser family, never an IP |
| `DataPortability.Collector` | Allow-list serializers and the viewer-gated board predicate. Own articles live or self-deleted (`deleted_by_id`); other people's content as URIs; the user's own DMs only; no active invite codes |
| `DataPortability.Files` | Rebuilds media paths from a strict hex filename (ignores `storage_path`), resolves the symlinked uploads root, and rejects any symlinked component |
| `DataPortability.Archive` | Builds at download time under `pg_try_advisory_xact_lock`, with a deadline, `statement_timeout` and size cap. `0700` staging and a `0600` zip in `System.tmp_dir!()`; JSON + README only; `sweep_temp/0` removes leftovers |
| `DataPortability.DownloadNonces` | ETS single-use nonces for download tokens (per node, 90 s) |
| `DataExportLive` (`/profile/export`) | Eligibility, request, cancel, "cancel and sign out everywhere else", download (re-auth → token → `phx-trigger-action`), history |
| `ExportController` (`POST /exports/:id/download`) | Per-IP rate limit (10 / 15 min, `:data_export_download`, 429), Fetch Metadata (`same-origin`/`navigate`/`document`), session-bound 60 s token, nonce consumed once, then build → claim → `send_file` with `attachment`/`no-store`/`nosniff` and cleanup. Any other failure is the same 404; a busy slot is 503 + `Retry-After` |
| `Layouts.data_export_banner/1` | Warning on every page while a request is pending/ready (`AuthHooks` assigns `:active_data_export`) |
| `DataPortability.sysop_export/3` / `Release.export_user_data/3` | Audited SysOp export for users who cannot self-serve. Requires operator and reason; output directory owner-only and outside web roots; `O_EXCL` + `0600`; records a `sysop` request row and a notice |
| `Admin.DataExportsLive` (`/admin/data-exports`) | Admin-only, read-only history (not moderators, not the moderation log); no export-on-behalf |

Security notices `data_export_requested`, `_ready`, `_downloaded` and
`_cancelled` are always delivered. The acceptance gate is the canary test in
`test/baudrate/data_portability/archive_test.exs`.

### Account Migration

Moving an account between servers with ActivityPub aliases and `Move`
([ADR 0025](adr/0025-account-migration.md)). `Baudrate.AccountMigration` owns the
rules; `/profile/move` (`AccountMigrationLive`) only collects input.

| Piece | Detail |
|-------|--------|
| `users.also_known_as` | Actor ids this account claims, published as `alsoKnownAs` (only when non-empty). Needed on the destination for an outbound move, and here for an inbound one |
| `AccountMigration.add_alias/2` | Input `@user@domain` or `https://` URI → `Federation.lookup_remote_actor/1` (WebFinger + `ActorResolver`, HTTPS and SSRF-guarded); stores the resolved actor id. Refuses non-`Person` actors, local actors, duplicates, more than 5, and moved accounts. Row locked `FOR UPDATE` |
| `AccountMigration.remove_alias/2` | Removes one alias |
| Step-up | `/profile/move` unlocks alias changes for 5 minutes after `Auth.verify_reauthentication/5`, held in socket assigns and re-checked by every handler (the ADR 0022 pattern). Lookups run in `start_async/3` behind `RateLimits.check_account_alias/1` (10/hour per user) |
| Notices | `account_alias_added` / `account_alias_removed`, always delivered, link to `/profile/move` |
| `users.moved_to` / `moved_at` | Set when a move is sent; published as `movedTo`. `AccountMigration.moved?/1` |
| `remote_actors.moved_to_ap_id` / `moved_at` | Where a remote actor moved: its `movedTo` (parsed by `ActorResolver`) or the target of the last processed `Move`. `moved_at` is set only when a `Move` is processed |
| `AccountMigration.move_eligibility/1` | The data export gate (active, non-bot, TOTP ≥ 7 days), plus: not moved, no admin/moderator role, not a board moderator, no move sent in the last 30 days |
| `AccountMigration.verify_move_target/2` | Resolves like an alias, then force-refreshes (`ActorResolver.refresh/1`): a `Person` listing this account in `alsoKnownAs`, without `movedTo` |
| `AccountMigration.request_move/4` | Eligibility → no pending move → target (network) → step-up re-authentication inside the context → `account_moves` row (`pending`, `send_after` = +24 h) → `account_move_requested` notice |
| `AccountMove` | `account_moves` rows: `pending`/`sent`/`cancelled`/`failed`, one pending per user (partial unique index), browser family but never an IP |
| Cancellation | `cancel_move/3` (owner, any session) and `cancel_active_moves/2`, called next to `cancel_active_exports/2` on password change, TOTP disable, sign out everywhere and ban; `account_move_cancelled` notice |
| Banner | `Layouts.account_move_banner/1` on every page while a move is pending (`:active_account_move`, from `active_move_summary/1` in `AuthHooks`) |
| `AccountMigration.sweep_due_moves/0` / `send_move/1` | Hourly (`SessionCleaner`). Re-checks eligibility and the target at send time; failures mark the move `failed` (`failure_reason`) with an `account_move_failed` notice. Success: one transaction marks it `sent` (conditional on `pending`, so a concurrent cancel wins) and sets `moved_to`/`moved_at`; then an actor `Update` (with `movedTo`) and `Publisher.build_move/2` go to remote followers, local followers are moved, and `account_moved` is sent |
| `AccountMigration.migrate_local_followers/2` | Each active local follower: remove the local follow, `follow_on_behalf/2` (pending `UserFollow` + `Follow` delivery, skipped if already following), `actor_moved` notice (configurable type) |
| Read-only | `AccountMigration.ensure_not_moved/1` at the context boundary: `Content.create_article/3` (Multi-shaped `{:error, :account, :account_moved, _}`; `forwarded_comment: true` exempts a comment forwarded by someone else), `update_article/3` (editor), `create_comment/2`, the create branch of article/comment like and boost toggles and feed item like/boost, `create_feed_item_reply/4`, `cast_vote/3`, `Messaging.can_send_dm?/2`, `Auth.can_generate_invite?/1`, and `can_create_content?/1` (so board posting and forwards). `create_local_follow/2` refuses following a moved account. Undoing, deleting, following and reading stay allowed |
| After the move | `Layouts.account_moved_notice/1` for the owner; `/users/:name` shows "moved" with a link and no Follow/Message; `AccountMigration.remove_redirect/3` (step-up) clears the redirect, publishes an actor `Update`, sends `account_redirect_removed`; the move still counts toward 30 days |
| Inbound `Move` | `AccountMigration.handle_inbound_move/2` (called by `InboxHandler`): alias check, `Undo(Follow)` + pending `Follow` per local follower (`follow_on_behalf/2`), `actor_moved` notices, feed item migration, `board_actor_moved` to admins, 30-day bound per origin |

### Bookmarks

Users can bookmark articles or comments for later reference. Bookmarks are
private (only visible to the user who created them) and local-only (not
federated).

**Key design:**
- Each bookmark targets exactly one of article or comment, enforced by a database check constraint
- Unique constraints prevent duplicate bookmarks per user/article and user/comment
- Toggle functions (`toggle_article_bookmark/2`, `toggle_comment_bookmark/2`) handle insert-or-delete atomically
- Both toggles authorize at the context boundary: the target must exist, not be
  soft-deleted, and be visible to the user (`Interactions.article_visible_to_user?/2`).
  The IDs are client-supplied, so without this a user could bookmark a guessed
  article or comment ID in a board they cannot view and read its title and body
  excerpt back off `/bookmarks`. An **already-bookmarked** target skips the check
  so a board whose `min_role_to_view` was raised afterwards cannot strand a row
  on the user's list. See [ADR 0016](adr/0016-authorization-at-the-context-boundary.md).
- `comment_bookmarks_by_user/2` returns the bookmarked subset of a comment-ID list
  as a `MapSet`, so a thread renders its bookmark state in one query
- `list_bookmarks/2` returns a paginated mixed list (articles + comments) ordered by bookmark creation time

**UI:**
- Articles: the bookmark toggle in the article action bar (`toggle_bookmark`)
- Comments: a bookmark button in each comment's action row (`toggle_comment_bookmark`),
  rendered by `BaudrateWeb.CommentComponents.comment_node/1`

**Files:**
- `lib/baudrate/content/bookmark.ex` — schema with validation
- `lib/baudrate/content/bookmarks.ex` — context module: toggles, authorization, listing
- `lib/baudrate_web/live/bookmarks_live.ex` — paginated bookmarks page at `/bookmarks`

### Bots (RSS/Atom Feed Aggregation)

Baudrate supports administrator-managed bot accounts that periodically fetch
RSS 2.0, RSS 1.0 (RDF), Atom 1.0, and JSON Feed documents and post entries as
articles. Bots are managed via the `/admin/bots` admin UI.

**Architecture:**

Each bot consists of:

1. A `User` account with `is_bot: true`, `dm_access: "nobody"`, and a locked
   random password. Bot accounts cannot be logged into — `authenticate_by_password/2`
   rejects any user with `is_bot: true`.
2. A `Bot` record linking the user to feed configuration (URL, target boards,
   fetch interval).
3. `BotFeedItem` records tracking posted entry GUIDs for deduplication.

**Workflow (FeedWorker → FeedParser → FaviconFetcher):**

1. `Baudrate.Bots.FeedWorker` (GenServer) polls `Bots.list_due_bots/0` every
   60 seconds (±10% jitter). Up to 5 bots are processed concurrently via
   `Task.Supervisor.async_stream_nolink/3` (120s per-bot timeout).
2. For each due bot, the worker optionally triggers `FaviconFetcher.fetch_and_set/1`
   (best-effort, in a separate Task) to refresh the bot's avatar from the site favicon.
3. The feed URL is validated (SSRF-safe via `HTTPClient.validate_url/1`) and
   fetched (max 5 MB). The raw bytes are parsed by `FeedParser.parse/1`.
4. `FeedParser` delegates to the `baudrate_feed_parser` Rustler NIF (backed by
   the `feedparser-rs` Rust crate), which natively supports RSS 0.9x/2.0,
   RSS 1.0 (RDF), Atom 0.3/1.0, and JSON Feed in a single pass. Each entry is
   normalized to `%{guid, title, body, link, tags, published_at}`.
   HTML content is sanitized via `Baudrate.Sanitizer.Native.sanitize_markdown/1`.
   `published_at` is clamped: dates more than 10 years in the past or in the
   future are set to `nil`.
5. For each new entry (not yet in `bot_feed_items`), the worker calls
   `Content.create_article/2` with the bot user as author. The `published_at`
   field on the article records the original feed entry publication date.
6. On success, `Bots.mark_fetch_success/1` schedules the next fetch. On failure,
   `Bots.mark_fetch_error/1` applies exponential backoff (5 min → 10 min → 20 min,
   capped at 24 hours).

**FaviconFetcher:** Scans the site HTML for `<link rel="apple-touch-icon">` and
`<link rel="icon">` tags, downloads the best candidate, and processes it through
the avatar pipeline (magic bytes validation, libvips re-encode to WebP, EXIF
strip). Avatar refreshes run at most once every 7 days per bot. After 3
consecutive favicon fetch failures, automatic refreshes are paused
(`favicon_fail_count >= 3`); the admin "Refresh Favicon" button bypasses this
gate and resets the counter on success.

**Bot bio and profile fields:** Admins can set a custom bio and up to 4 profile
fields (e.g. "Notice: Unofficial — not affiliated with source") on each bot via
the `/admin/bots` edit form. On creation the bio defaults to the feed URL when
left blank. When `update_bot/2` receives an explicit `"bio"` key it takes
priority over the legacy auto-bio-from-feed_url behaviour; omitting `"bio"`
preserves the legacy fallback for programmatic callers. Profile fields are stored
on the bot's `User` record and federated as `PropertyValue` attachments (same as
regular user profile fields).

**Database tables:**

| Table | Purpose |
|-------|---------|
| `bots` | Bot config: `user_id`, `feed_url`, `board_ids` (int array), `fetch_interval_minutes`, `active`, `last_fetched_at`, `next_fetch_at`, `error_count`, `last_error`, `avatar_refreshed_at`, `favicon_fail_count` |
| `bot_feed_items` | GUID deduplication: `bot_id`, `guid`, `article_id` (nullable on permanent failure) |

**Key functions in `Bots`:**

- `list_bots/0` / `get_bot!/1` — listing and lookup
- `create_bot/1` — creates bot user + bot record in a transaction, ensures RSA keypair
- `update_bot/2` / `delete_bot/1` — update/delete bot and its user account
- `list_due_bots/0` — bots with `next_fetch_at` nil or in the past
- `already_posted?/2` — GUID dedup check
- `record_feed_item/3` — records a posted entry
- `mark_fetch_success/1` / `mark_fetch_error/1` — update fetch state with backoff
- `avatar_needs_refresh?/1` / `mark_avatar_refreshed/1` — favicon refresh tracking (gate + 7-day cooldown)
- `increment_favicon_fail_count/1` — increments consecutive failure counter

**Security:**

- Feed URLs are validated via `HTTPClient.validate_url/1` (SSRF-safe: rejects
  private/loopback IPs, HTTPS only)
- Feed content is fetched with a 5 MB size limit
- Parsed content is sanitized via Ammonia NIF before article creation
- Bot users cannot log in (`is_bot: true` check in `authenticate_by_password/2`)
- Bot creation requires admin privileges (`/admin/bots` is in the `:admin` live_session)

**Files:**

- `lib/baudrate/bots.ex` — context (CRUD, scheduling, dedup)
- `lib/baudrate/bots/bot.ex` — Bot schema
- `lib/baudrate/bots/bot_feed_item.ex` — BotFeedItem schema (GUID dedup)
- `lib/baudrate/bots/feed_worker.ex` — GenServer poller
- `lib/baudrate/bots/feed_parser.ex` — feed parser facade (normalizes NIF output)
- `lib/baudrate/bots/feed_parser_native.ex` — Rustler NIF bindings to `baudrate_feed_parser`
- `lib/baudrate/bots/favicon_fetcher.ex` — site favicon → bot avatar
- `lib/baudrate_web/live/admin/bots_live.ex` — admin UI

### Federation Architecture

The `Baudrate.Federation` module is a **facade** — it delegates all calls to
focused sub-modules under `Baudrate.Federation.*`. External callers (LiveViews,
controllers, inbox handlers, tests) always call `Federation.function_name`
and never need to know about the internal split.

| Sub-Module | Responsibility |
|---|---|
| `Federation.Discovery` | Remote actor lookup, WebFinger, and NodeInfo discovery |
| `Federation.ActorRenderer` | JSON-LD representation of local actors (Person, Group, Organization) |
| `Federation.ObjectBuilder` | ActivityStreams JSON-LD serialization for articles, comments, and polls |
| `Federation.Collections` | Paginated OrderedCollection endpoints (Outbox, Followers, Boards) |
| `Federation.Follows` | Inbound follower management and outbound user/board follow lifecycle |
| `Federation.Feed` | Inbound activity routing to personal user feeds, feed item interactions (likes, boosts) |
| `Federation.InboxHandler` | Dispatches incoming Activities (Follow, Create, Like, Delete, etc.) to sub-modules |
| `Federation.Publisher` | High-level API for publishing activities (Create, Update, Delete, Announce, Like, Undo, Move, PollVote) |
| `Federation.Delivery` | DB-backed delivery queue, background workers, and exponential backoff retry logic |
| `Federation.ActorResolver` | Fetches, caches, and verifies remote actor profiles (24h TTL, signed fetch fallback). Rejects a fetched document whose `id` host differs from the URL it was fetched from (`:actor_id_origin_mismatch`), preventing cross-origin actor forgery and cache poisoning during signature verification |
| `Federation.HTTPSignature` | HTTP Signature signing (outgoing) and cryptographic verification (incoming POSTs) |
| `Federation.KeyStore` | RSA-2048 keypair management for actors: generation, persistence, and rotation |
| `Federation.Validator` | AP payload validation: size limits, attribution checks, and domain allowlist/blocklist |
| `Federation.Visibility` | Derives ActivityPub visibility (`public`, `unlisted`, `followers_only`, `direct`) from addressing fields |

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

**AP ID stamping** — all local AP objects receive a canonical `ap_id` immediately after creation:

| Object | URI Pattern | Stamped In |
|--------|-------------|------------|
| Article | `{base}/ap/articles/{slug}` | `Content.Articles.create_article/2,3` |
| Comment | `{actor_uri}#note-{id}` | `Content.Comments.create_comment/1` |
| ArticleLike | `{actor_uri}#like-{id}` | `Content.Likes.like_article/2` |
| Poll | `{article_ap_id}#poll` | `Content.Articles.create_article/2,3` |
| DirectMessage | `{actor_uri}#dm-{id}` | `Messaging.create_message/3` |

AP IDs are generated post-insert (require the DB-assigned `id`) and stored via immediate
`Repo.update!`. Publisher functions use the stored `ap_id` field with a fallback to
`Federation.actor_uri/2` for backwards compatibility.

**Discovery endpoints:**
- `/.well-known/webfinger` — resolve `acct:site@host` (instance actor), `acct:user@host` (user), or `acct:board-slug@host` (board, also accepts `!` prefix for Lemmy compat); site and board responses include `properties` with actor type (`"Organization"` / `"Group"`)
- `/.well-known/nodeinfo` → `/nodeinfo/2.1` — instance metadata

**Outbound endpoints** (content-negotiated: JSON-LD for AP/JSON clients, HTML redirect otherwise):
- `/ap/users/:username` — Person actor with publicKey, inbox, outbox, published, icon
- `/ap/boards/:slug` — Group actor with sub-board/parent-board links
- `/ap/site` — Organization actor (instance actor, discoverable as `acct:site@host`)
- `/ap/articles/:slug` — Article object with replies link and `baudrate:*` extensions
- `/articles/:slug` — content-negotiated: AP `Accept` headers (`application/activity+json`, `application/ld+json`, `application/json`) are forwarded to the AS2 article endpoint by `BaudrateWeb.Plugs.ArticleApContentNeg`; browser requests fall through to `ArticleLive`. The article LiveView also emits `<link rel="alternate" type="application/activity+json" href="…/ap/articles/:slug">` for federated articles, so remote implementations can discover the AP `id` from the human URL when content negotiation isn't attempted
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
- `Follow` / `Undo(Follow)` — follower management with auto-accept. Follow activities targeting a non-federated board actor (`ap_enabled: false`) are answered with `Reject(Follow)` — the board inbox controller already returns 404 for such boards, but the shared inbox path also applies the guard so that a Follow addressed directly to a board actor URI cannot create a spurious follower record.
- `Create(Note)` — stored as threaded comments on local articles (with remote reply chain walking up to 10 hops to resolve intermediate replies), or as DMs if privately addressed (no `as:Public`, no followers collection)
- `Create(Article)` / `Create(Page)` — stored as remote articles in target boards (Page for Lemmy interop)
- `Like` / `Undo(Like)` — article favorites. Remote articles (`remote_actor_id` set) always accept likes regardless of their board's `ap_enabled`; local articles require membership in at least one public, AP-enabled board (enforced by `article_federated?/1` in `InboxHandler`).
- `Announce` / `Undo(Announce)` — boosts/shares (bare URI or embedded object map); routes boosted Article/Page to boards following the booster, creates feed items for user followers with boost attribution (loop-safe). Article-target boosts follow the same remote-vs-local federation rule as Likes.
- `Update(Note/Article/Page)` — content updates with authorship check
- `Update(Person/Group)` — actor profile refresh
- `Delete(content)` — soft-delete with authorship verification
- `Delete(actor)` — removes all follower records and soft-deletes all content (articles, comments, DMs) from the deleted actor
- `Flag` — incoming reports stored in the local moderation queue. The signer is recorded as `reports.reporter_remote_actor_id`; the Flag's objects that name local accounts, articles and comments become the report's targets, and a Flag naming nothing local is dropped. `content` is optional. An open report from the same reporter about the same targets is not duplicated, and each remote domain may file 10 per hour (`RateLimits.check_inbound_flag/1`). `reports.remote_actor_id` is always the **reported** remote actor (set when a local user reports remote content), never the reporter
- `Block` / `Undo(Block)` — remote actor blocks (logged for informational purposes)
- Local user blocks (ADR 0026): a remote actor's `Follow` of a user who blocked it is answered with `Reject(Follow)`, and its `Like`, `Announce` and replies on that user's articles and comments are dropped with `:ok`
- `Accept(Follow)` / `Reject(Follow)` — mark outbound user follows as accepted/rejected
- `Move` — handled by `AccountMigration.handle_inbound_move/2` (ADR 0025). Authorized only when the signer matches the Move `actor` and `object`, **and** the target claims the moving actor in `alsoKnownAs` (force-refreshed with `ActorResolver.refresh/1`; a local target is checked against `users.also_known_as`), otherwise `{:error, :move_not_authorized}`, so a remote actor cannot redirect its local followers onto a non-consenting target. Each active local follower sends `Undo(Follow)` to the old actor and a pending `Follow` to the new one (a local target gets a local follow), with an `actor_moved` notice. Feed items are repointed (`migrate_feed_items/2`, both `remote_actor_id` and `boosted_by_actor_id`) so history shows again once the new follow is accepted. Board follows are not repointed; admins get `board_actor_moved`. A target that has itself moved is ignored, and one Move per origin is processed every 30 days (`remote_actors.moved_at`). Articles and comments keep their original `remote_actor_id`: they are board content with their own permalinks and remain published under the old actor upstream.

**Outbound delivery** (via `Publisher` + `Delivery` + `DeliveryWorker`):
- `Create(Article)` — automatically enqueued when a local user publishes an article
- `Delete` with `Tombstone` (includes `formerType`) — enqueued when an article is soft-deleted
- `Announce` (board actor) — board announces articles to board followers
- `Announce` / `Undo(Announce)` (user actor) — enqueued when a local user boosts/unboosts an article or comment; delivered to the **booster's** followers (not the article author's followers)
- `Update(Article)` — enqueued when a local article is edited
- `Create(Note)` — DM to remote actor, delivered to personal inbox (not shared inbox) for privacy
- `Delete(Tombstone)` — DM deletion, delivered to remote recipient's personal inbox
- `Reject(Follow)` / `Undo(Follow)` — sent when a user blocks a remote actor, to end the actor's follow of the user and the user's follow of the actor (`Federation.sever_remote_follows/2`). No `Block` activity is ever sent (ADR 0026)
- `Follow` / `Undo(Follow)` — sent when a local user follows/unfollows a remote actor
- `Update(Person/Group/Organization)` — distributed to followers on key rotation or profile changes
- Delivery targets vary by activity type: `Create`/`Update`/`Delete` go to followers of the article's author + followers of all public boards the article is in; user `Announce`/`Undo(Announce)` (boosts) go to the **booster's** followers via `enqueue_for_followers/2`
- Shared inbox deduplication: multiple followers at the same instance → one delivery
- DB-backed queue (`delivery_jobs` table) with `DeliveryWorker` GenServer polling (graceful shutdown via `terminate/2`)
- Exponential backoff: 1m → 5m → 30m → 2h → 12h → 24h, then abandoned after 6 attempts
- Domain blocklist respected: deliveries to blocked domains are skipped
- Job deduplication: partial unique index on `(inbox_url, actor_uri, activity_id)` for pending/failed jobs, so the same activity is queued once per inbox while different activities are all queued. `activity_id` is the activity's `id` (MD5 of the JSON when absent), set by `DeliveryJob.create_changeset/2`. The index once omitted `activity_id` and silently dropped every later activity from an actor to an inbox while one job was pending or retrying
- `KeyStore.ensure_user_keypair/1` must be called before enqueuing any signed delivery — ensures the user has an RSA keypair for HTTP Signature signing

**Followers collection endpoints** (paginated with `?page=N`):
- `/ap/users/:username/followers` — paginated `OrderedCollection` of follower URIs
- `/ap/boards/:slug/followers` — paginated `OrderedCollection` (public boards only, 404 for private)

**Following collection endpoints** (paginated with `?page=N`):
- `/ap/users/:username/following` — paginated `OrderedCollection` of accepted followed actor URIs
- `/ap/boards/:slug/following` — paginated `OrderedCollection` of accepted board follow actor URIs

**User outbound follows**:
- `Federation.lookup_remote_actor/1` — WebFinger + actor fetch by `@user@domain` or actor URL
- `Federation.create_user_follow/2` — create pending follow record, returns AP ID
- `Federation.accept_user_follow/1` / `reject_user_follow/1` — state transitions on Accept/Reject
- `Federation.delete_user_follow/2` — delete follow record (unfollow)
- `Federation.list_user_follows/2` — list follows with optional state filter
- `Publisher.build_follow/3` / `build_undo_follow/2` — build Follow/Undo(Follow) activities
- `Delivery.deliver_follow/3` — enqueue follow/unfollow delivery to remote inbox
- Rate limited: 10 outbound follows per hour per user (`RateLimits.check_outbound_follow/1`)

**Personal feed**:
- `feed_items` table — stores incoming posts from followed actors that don't land in boards/comments/DMs
- One row per activity (keyed by `ap_id`), feed membership via JOIN with `user_follows` at query time
- `visibility` field records AP visibility (`public`, `unlisted`, `followers_only`, `direct`) derived from `to`/`cc` addressing on ingest
- `Federation.create_feed_item/1` — insert + broadcast to followers via `Federation.PubSub`
- `Federation.list_feed_items/2` — paginated union query: remote feed items + local articles from followed users + comments on articles the user authored or participated in
- Inbox handler fallback: Create(Note) without reply target, Create(Article/Page) without board → feed item
- Announce → feed item: when a followed actor boosts content, the boosted object is fetched and stored as a feed item with `activity_type: "Announce"` and `boosted_by_actor_id` pointing to the booster. Original author is resolved via `attributedTo`. Board routing: if the booster is followed by a board, boosted Article/Page content is also routed to that board (loop-safe: `create_remote_article` does not trigger outbound federation).
- Delete propagation: soft-deletes feed items on content or actor deletion
- `Federation.migrate_feed_items/2` — Move activity support (repoint feed items to the new actor)
- `/feed` LiveView — paginated personal timeline with real-time PubSub updates

**Feed item replies**:
- `feed_item_replies` table — local users can reply to remote feed items inline
- `Federation.create_feed_item_reply/3` — renders Markdown body to HTML, generates AP ID, inserts record, schedules `Create(Note)` delivery with `inReplyTo` pointing to the feed item's AP ID
- `Publisher.build_create_feed_item_reply/3` — builds the `Create(Note)` activity
- `Publisher.publish_feed_item_reply/2` — ensures user keypair, delivers to remote actor inbox + user's AP followers
- Rate limited: 20 feed item replies per 5 minutes per user (`RateLimits.check_feed_reply/1`)

**Feed item likes and boosts**:
- `feed_item_likes` table — local users can like remote feed items inline
- `feed_item_boosts` table — local users can boost remote feed items inline
- `Federation.toggle_feed_item_like/2` — toggles like, schedules AP Like/Undo(Like) delivery to the remote actor
- `Federation.toggle_feed_item_boost/2` — toggles boost, schedules AP Announce/Undo(Announce) delivery to the remote actor
- Comment likes and boosts are federated outbound (Like/Undo(Like) and Announce/Undo(Announce) activities), matching the article federation pattern

**Local user follows**:
- `user_follows.followed_user_id` — nullable FK to `users`, with check constraint (exactly one of `remote_actor_id`/`followed_user_id`)
- `Federation.create_local_follow/2` — auto-accepted immediately, no AP delivery
- `Federation.delete_local_follow/2` / `get_local_follow/2` / `local_follows?/2`
- `/search` — "Users" tab with local user search, follow/unfollow buttons; "Boards" tab with board search by name/description
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
- Outbound activities use visibility-aware `to`/`cc` addressing (respects stored `visibility` field; `Federation.Visibility` derives visibility from AP addressing on ingest)
- Outbound Article objects include board actor URIs merged into `cc` (improves discoverability)
- Interactions with remote posts also go to the remote author: comments (and their deletion) reach the remote article author and the remote author of the parent comment; likes/unlikes reach the liked article's or comment's remote author; boosts/unboosts reach the boosted post's remote author as well as the booster's followers (`Delivery.enqueue_for_article/4` `:remote_authors`). Before v1.18.2 they went only to followers, so remote authors never saw them
- Outbound Article objects include plain-text `summary` (≤ 500 chars) for Mastodon preview display
- Outbound Article objects include `tag` array with `Hashtag` objects (extracted from body, code blocks excluded)
- Cross-post deduplication: same remote article arriving via multiple board inboxes links to all boards
- Forwarding an article to a board sends `Create(Article)` to board followers and `Announce` from the board actor (works for both boardless and cross-board forwarding)
- Board WebFinger uses bare slug in `subject` (no `!` prefix) matching Mastodon's expectation from `preferredUsername`; includes `properties` with `type: "Group"` for Lemmy disambiguation; `!` prefix accepted in queries for backward compat
- Federation HTTP errors include response body (truncated to 4 KB) for diagnostics — delivery failures log the body

**Admin controls:** See the [SysOp Guide](sysop.md#federation) for federation
administration (kill switch, federation modes, domain blocklist/allowlist,
per-board toggle, delivery queue management, key rotation, blocklist audit).

**User blocks** ([ADR 0026](adr/0026-blocks-stop-interaction-locally.md)):

Users can block local users and remote actors. A block stops interaction in both
directions and is enforced on this site only; no `Block` activity is sent:

- `Auth.block_user/2` / `Auth.unblock_user/2` — local user blocks; blocking deletes the local follows in both directions
- `Auth.block_remote_actor/2` / `Auth.unblock_remote_actor/2` — remote actor blocks; blocking a known actor sends `Undo(Follow)` and `Reject(Follow)` and deletes both follows. Unblocking restores no follows
- `Auth.blocked?/2` — check if blocked (works with local users and AP IDs)
- `Auth.blocked_between?/2` (either local user blocked the other), `Auth.remote_actor_blocked_by?/2`, and `Auth.blocked_with_author?/2` (a block between a user and the author of an article, comment or feed item)
- Refused with `{:error, :blocked}` at the context boundary: comments on the other's articles and replies to their comments, likes and boosts (undo stays allowed), local and remote follows, and feed item likes, boosts and replies. Forwards are refused with `{:error, :unauthorized}`, and DMs by `Messaging.can_send_dm?/2`. Any new way to interact must add the same check
- Inbound activities from a blocked remote actor on the blocker's content are refused (see Inbound handling)
- Content filtering: blocked users' content is hidden from the blocker's article listings, comments, feed, and search results. The blocked account can still read the blocker's public content
- UI: Block / Unblock in the user profile's "More actions" menu; Mute, Block and Report account in the "More actions" menu of remote feed items and remote comments and in the header of a conversation with a remote actor (`BaudrateWeb.SafetyActions`, `BaudrateWeb.SafetyComponents`); a Blocked Accounts list with unblock controls on `/profile`
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
- Mute management: toggle on user profiles, mute remote accounts from feed items, remote comments and remote conversations, manage list on `/profile` settings page (remote actors shown as `@user@domain` when known)
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

**Remote Object Resolution (`ObjectResolver`):**

The `ObjectResolver` module resolves remote ActivityPub objects (Notes, Articles, Pages) by URL.
It uses a two-phase approach:

1. `fetch/1` — fetches and parses a remote object for preview display without any database write.
   Returns a map with `ap_id`, `title`, `body`, `body_html`, `visibility`, `url`, `published_at`,
   `remote_actor`, and the raw `object` JSON. If the object already exists locally (by `ap_id`),
   returns `{:ok, :existing, article}` instead.

2. `resolve/1` — fetches + materializes as a local remote article for interaction (like, boost,
   forward). Deduplicates by `ap_id`. Uses `Content.create_remote_article/2` with empty `board_ids`,
   which does NOT trigger outbound federation publishing (loop-safe).

The search page uses `fetch/1` for preview when a user pastes a remote post URL, and only
materializes via `resolve/1` when the user explicitly clicks "Import & interact".

Exposed via `Federation.fetch_remote_object/1` (preview) and `Federation.lookup_remote_object/1`
(materialize).

**Security:**
- HTTP Signature signing (outbound) — `hs2019` algorithm (RSA PKCS1v15 + SHA-256), signed headers: `(request-target)`, `host`, `date`, `digest`; key ID format: `{actor_uri}#main-key`. The `host` header is managed by `HTTPClient` (not returned by `HTTPSignature.sign/5`) to avoid duplication with DNS-pinned connections
- HTTP Signature verification on all inbox requests
- Inbox content-type validation — rejects non-AP content types with 415 (via `RequireAPContentType` plug)
- HTML sanitization via Ammonia (Rust NIF, html5ever parser) — allowlist-based, applied before database storage
- Remote actor display name sanitization — strips all HTML (including script content), control characters, truncates to 100 chars
- Attribution validation prevents impersonation
- Content size limits (256 KB AP payload, 64 KB article body enforced in all changesets)
- Domain blocklist (configurable via admin settings)
- SSRF-safe remote fetches — DNS-pinned connections prevent DNS rebinding; manual redirect following with IP validation at each hop; HTTPS only. `HTTPClient.private_ip?/1` rejects, across IPv4 and IPv6:
  - private, loopback, CGNAT, link-local, multicast and reserved space (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `0/8`, `100.64/10`, `169.254/16`, `224/4` and above)
  - IPv4 special-purpose ranges that are not globally routable: IETF protocol assignments (`192.0.0/24`), TEST-NET-1/2/3 (`192.0.2/24`, `198.51.100/24`, `203.0.113/24`), and benchmarking (`198.18/15`, which is routed to lab equipment on some networks)
  - IPv6 `::`, `::1`, `fc00::/7`, `fe80::/10`, `ff00::/8`, the documentation prefix `2001:db8::/32`, and the discard-only prefix `100::/64`
  - **tunnelled IPv4**, by decoding the embedded address and re-checking it: IPv4-mapped (`::ffff:0:0/96`), NAT64 (`64:ff9b::/96`), IPv4-compatible (`::a.b.c.d`), and 6to4 (`2002::/16`). Teredo (`2001::/32`) obfuscates its embedded address rather than carrying it plainly, so the prefix is refused outright — an ActivityPub peer has no business being reachable only through a Teredo relay.
- Per-domain rate limiting (60 req/min per remote domain)
- Real client IP extraction — `RealIp` plug reads from configurable proxy header (e.g., `x-forwarded-for`) for accurate per-IP rate limiting behind reverse proxies; honored only when the immediate peer matches the `trusted_proxies` allow-list (exact IPs or CIDR ranges) so untrusted peers cannot spoof their IP. Fail closed: an unconfigured allow-list defaults to loopback only and an empty list trusts nobody, configurable at runtime via `BAUDRATE_TRUSTED_PROXIES`
- Private keys encrypted at rest with AES-256-GCM
- Recovery codes verified atomically via `Repo.update_all` to prevent TOCTOU race conditions
- Non-guest boards (`min_role_to_view != "guest"`) hidden from all AP endpoints (actor, outbox, inbox, WebFinger, audience resolution)
- Optional authorized fetch mode — require HTTP signatures on GET requests to AP endpoints (exempt: WebFinger, NodeInfo)
- Signed outbound GET requests — actor resolution falls back to signed GET when remote instances require authorized fetch
- Session cookie `secure` flag handled by `force_ssl` / `Plug.SSL` in production
- CSP `img-src` allows only `'self' data: blob:` — remote actor avatars and every other remote image are served through the local media proxy (`Baudrate.Media.Proxy`), so no page issues a third-party subresource request
- CSP `script-src` is `'self'` plus one hash: the root layout's theme bootstrap (`BaudrateWeb.ThemeBootstrap`), hashed at compile time from the bytes the layout renders. Never add `'unsafe-inline'`; a new inline script needs its own hash the same way

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
- **Enriched actors** — User actors include `published`, `summary` (user bio, plaintext with hashtag linkification), `icon` (avatar as WebP, 48px size), and `attachment` (profile fields as `PropertyValue` entries, schema.org context). Board actors include parent/sub-board links.

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

- **[TOP PRIORITY] Every meaningful element in every page template carries a stable, semantic `id` and/or `class`** so any element can be located precisely — a first-class accessibility requirement (for assistive tooling, automated testing, and styling), not optional polish. Rules:
  - *Coverage* — region/section containers, all interactive elements (buttons, links, inputs, selects, textareas, toggles), every loop-rendered list/table/card item, and key content nodes (headings, labels, values, empty states, error/preview blocks). Skip purely presentational layout wrappers (bare `flex`/`grid`/spacer divs) and leaf presentational components (`<.icon>`).
  - *Naming* — simple kebab-case, page/section-prefixed (no BEM `__`): `id="profile-bio-section"`, `class="profile-bio-label"`, `class="profile-bio-value"`.
  - *Uniqueness* — `id` unique per rendered page; loop (`:for`) items derive a dynamic id from the record (`id={"muted-user-#{mute.id}"}`) plus a shared stable `class` (`class="muted-user"`).
  - *Non-destructive* — only ADD `id`/`class`; never remove or reorder existing Tailwind utilities, `phx-*`, `aria-*`, `data-*`, `:if`/`:for`, or `gettext()`. Semantic class first, utilities after.
  - *Stylesheets target the semantic selectors* — custom CSS in `assets/css/app.css` (theme layers, focus styles, component tweaks) MUST hook onto the semantic `id`/`class` selectors, not fragile structural/positional selectors (`.card > .card-body > .card-title`, `:nth-child`, tag chains). Every custom style rule's selector must correspond to a meaningful element's semantic `id`/`class`; if the target element lacks one, add it first. This keeps styling stable against markup refactors and makes each rule's intent self-documenting.
- Skip-to-content link (`<a href="#main-content">`) at top of `<body>` in `root.html.heex`
- `id="main-content"` and `tabindex="-1"` on `<main>` in both app and setup layouts — enables the skip-to-content link to move keyboard focus (not just scroll) to the main content area
- `aria-haspopup="true"` and `aria-expanded` on all dropdown trigger buttons (mobile hamburger, desktop user menu, language picker, article/profile menus); `aria-expanded` is driven only by `focusin`/`focusout` delegation in `app.js` (no click toggle), and Escape closes the dropdown and returns focus to its trigger. Dropdown menus must not carry `tabindex="0"`
- **Live regions announce summaries, never whole lists.** Flashes use `role="alert"` (the flash group itself is not `aria-live`, which double-announced). PubSub-driven pages render a dedicated `sr-only` `role="status"` node whose text the server sets on the event: `#comments-live-status` ("New comment by …"), `#feed-live-status`, `#notifications-live-status`, `#conversations-live-status`. Never put `aria-live` on `#comments`, `#feed-items`, or a `<tbody>` — every re-render would be read out
- Toggle buttons (like, boost, bookmark, admin filters) expose state with `aria-pressed`; when a button has visible text, that text is its accessible name (no overriding `aria-label`, WCAG 2.5.3). Repeated row actions name their subject (`gettext("Ban %{username}", …)`), starting with the visible verb
- Button-based search pickers (board picker, forward-to-board, DM recipient search) are plain `<button>`s in a labelled `<ul>` with the result count in a sibling `role="status"` node — not a half-implemented `combobox`/`listbox`
- Hidden file inputs use `sr-only peer` (never `hidden`) so the styled `<label for>` stays keyboard-operable, with `peer-focus-visible:outline…` on the label
- `<.input type="textarea">`'s `<label for>` holds only the label text; the Markdown toolbar and preview are siblings, not label content
- `<.avatar decorative>` renders `alt=""` where the name is already visible next to it
- `aria-invalid="true"` and `aria-describedby="<id>-error"` on form inputs with validation errors
- Error messages wrapped in `<div id="<id>-error" role="alert">` for programmatic association
- `aria-expanded` on reply buttons and moderator management toggle
- `aria-label` on all icon-only buttons (cancel upload, delete comment)
- Pagination wrapped in `<nav aria-label>` with `aria-current="page"` on the active page and `aria-label` on prev/next/page links
- Password strength `<progress>` has `aria-label` and dynamic `aria-valuetext` ("Weak"/"Fair"/"Strong"); requirement icons are `aria-hidden` with sr-only met/unmet state text

**Semantic HTML Structure:**

- Use `<section>` (not `<div>`) for major content areas that have headings; connect via `aria-labelledby`
- Use `<article>` for self-contained content items in lists (article cards in boards, search results, tag pages, user content)
- Use `<aside>` for supplementary content (sidebar, moderator info)
- Use `<nav>` for navigation blocks (breadcrumbs, pagination)
- Layout provides `<header>`, `<nav>`, `<main>`, `<footer>` — do not duplicate with ARIA roles
- Every content-listing container should have a semantic `id` (e.g., `id="articles"`, `id="comments"`)
- Every list item should have a unique `id` (e.g., `id={"article-#{slug}"}`) and a semantic CSS class (e.g., `class="article"`)
- This extends to **all** meaningful elements, not just list containers/items — see the TOP PRIORITY requirement above. Field labels, values, section wrappers, forms, and every interactive control carry page-prefixed kebab-case `id`/`class` (e.g. `id="profile-bio-save"`, `class="profile-field-label"`)

**Mobile Bottom Navigation:**

- A fixed DaisyUI `dock` component (`id="mobile-bottom-nav"`) appears below `lg` breakpoint (< 1024px), hidden on desktop via `lg:hidden`; background matches the top navbar (`bg-base-200 border-t border-base-300`)
- Icon-only items with `aria-label` for accessibility (no text labels)
- Authenticated users see 5 items: Home (`hero-home`), Feed (`hero-rss`), Search (`hero-magnifying-glass`), Messages (`hero-chat-bubble-left-right` + unread badge), Notifications (`hero-bell` + unread badge)
- Guests see 4 items: Home (`hero-home`), Search (`hero-magnifying-glass`), Sign In (`hero-arrow-right-on-rectangle`), Register (`hero-user-plus`)
- Mobile hamburger menu only shows for authenticated users (admin/user sections); guest nav items are exclusively in the bottom dock
- Active item gets `dock-active` class and `aria-current="page"` based on `@current_path` (exact match for `/`, prefix match for others)
- `@current_path` is set via `attach_hook(:set_current_path, :handle_params, ...)` in auth hooks and updates on every navigation
- `<main>` has extra bottom padding on mobile (`pb-24 lg:pb-20`) to prevent content from being obscured by the dock
- `viewport-fit=cover` in `root.html.heex` ensures proper rendering on iOS devices with safe areas

**Focus Management After Navigation:**

- `data-focus-target` on primary content containers signals where focus should go after LiveView navigation
- JS in `app.js` finds the first `[data-focus-target]` inside `<main>` and focuses its first interactive child
- Skips initial page load and pages with `autofocus` inputs
- Add `data-focus-target` to list/browse pages; do NOT add to form pages or pages with `autofocus`
- **Pagination is shared, never per page.** `<.pagination>` builds the `?page=N` patch links; `BaudrateWeb.PaginationScrollHook`, mounted for every LiveView by `use BaudrateWeb, :live_view`, pushes `scroll-to-top` whenever the page number changes (pager, `push_patch` or back/forward; never on the initial load); the `phx:scroll-to-top` handler in `app.js` scrolls to the pager's `scroll_target` (e.g. `comments-section` on an article) or the page's `[data-focus-target]`, and the focus handler then moves focus into that same element. A new paginated page only needs `<.pagination>` plus `data-focus-target` or `scroll_target`; `test/baudrate_web/pagination_consistency_test.exs` fails without one, if a LiveView pushes `scroll-to-top` itself, or if a LiveView bypasses `use BaudrateWeb, :live_view`. Before v1.19.3 only the board and search pages scrolled, each with its own code
- Links (`<a>`) get a 2px `focus-visible` inset ring in `base-content` (≥3:1 in every theme) plus a transparent `outline`, so the ring still shows under Windows `forced-colors`
- **Server-driven focus:** `push_event(socket, "focus", %{id: "…"})` is handled by a global `phx:focus` listener in `app.js` (adds `tabindex="-1"` to non-focusable targets). Use it when an action removes the focused control — destructive admin row actions, setup wizard step changes — so focus lands on the page/section heading instead of `<body>`
- LiveView patches strip attributes JS set on server-rendered elements; `app.js` passes a `dom.onBeforeElUpdated` callback that carries over the theme buttons' `aria-pressed`, dropdown `aria-expanded`, the textarea autocomplete attributes, and the Markdown preview's `aria-live`/`aria-busy`
- `prefers-reduced-motion: reduce` disables the card, scroll-to-top, and theme-indicator transitions in `app.css`, and JS scrolling uses `behavior: "auto"`

**Auth hooks:**

| Hook | Behavior |
|------|----------|
| `:require_auth` | Requires valid session; redirects to `/login` if unauthenticated or banned |
| `:require_admin` | Requires admin role; redirects non-admins to `/` with access denied flash. Must be used after `:require_auth` (needs `@current_user`) |
| `:require_admin_or_moderator` | Requires admin or moderator role; redirects others to `/` with access denied flash |
| `:require_admin_totp` | Admin re-verification (10-min sudo mode); non-admin users (e.g. moderators) pass through. Admins without TOTP are redirected to `/profile`; admins with expired verification are redirected to `/admin/verify` (supports both TOTP and WebAuthn) |
| `:optional_auth` | Loads user if session exists; assigns `nil` for guests or banned users (no redirect) |
| `:require_password_auth` | Requires password-level auth (for TOTP flow); redirects banned users to `/login` |
| `:redirect_if_authenticated` | Redirects authenticated users to `/` (for login/register pages); allows banned users through |
| `:rate_limit_mount` | Rate limits WebSocket connections: 60/min per IP. Fails open on backend errors. Only checked on connected mounts |

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
| Feed item replies | 20 / 5 min | per user |
| LiveView mount | 60 / min | per IP |

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
├── Baudrate.Auth.SessionCleaner       # Hourly cleanup (sessions, login attempts, orphan images, export requests/temp, notifications >90 days)
├── Baudrate.DataPortability.DownloadNonces # ETS single-use nonces for data export download tokens
├── Baudrate.Setup.SettingsCache       # ETS cache for site settings (must start before DomainBlockCache)
├── Baudrate.Content.BoardCache        # ETS cache for board lookups (by ID, slug, hierarchy)
├── Baudrate.Federation.TaskSupervisor # Async federation delivery tasks
├── Baudrate.Federation.DomainBlockCache  # ETS cache for domain blocking decisions
├── Baudrate.Federation.DeliveryWorker     # Polls delivery queue every 60s
├── Baudrate.Federation.StaleActorCleaner # Daily stale remote actor cleanup
├── Baudrate.Bots.FeedWorker              # Polls RSS/Atom bots every 60s
└── BaudrateWeb.Endpoint                  # HTTP server
```

**Startup order dependency:** `SettingsCache` must start before `DomainBlockCache`
because `DomainBlockCache.init/1` calls `Setup.get_setting/1`, which reads from
the settings ETS cache.

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

Auto-scrolls the DM message list to the bottom on mount, and on updates only
when the reader was already within ~80px of the bottom (so reading history is
not interrupted). Never moves focus. Attached to `#message-list`
(`role="log"`) in `ConversationLive`.

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
and receives the rendered HTML in the reply callback. On the server side,
`BaudrateWeb.MarkdownPreviewHook` intercepts the event via `attach_hook/4`
(attached in `AuthHooks` for `:require_auth` and `:optional_auth` scopes) and
uses the `{:halt, reply, socket}` pattern for immediate response. A 64 KB body
size limit is enforced to prevent abuse.

In preview mode, the textarea is hidden and a preview `<div>` (styled with the
`prose` class from `@tailwindcss/typography` for proper heading, link, list, and
code block rendering) displays the rendered HTML. Formatting buttons are
disabled while in preview mode.

Source: `assets/js/markdown_toolbar_hook.js`, `lib/baudrate_web/live/markdown_preview_hook.ex`

### `HashtagAutocompleteHook`

Provides hashtag autocomplete in article/comment textareas. Attached to a
wrapper `<div>` around the textarea (since `MarkdownToolbarHook` already
occupies `phx-hook` on the textarea itself). Automatically enabled when the
`toolbar` attribute is set on `<.input type="textarea">`.

When the user types `#` (or `@`) followed by one or more characters, the hook
debounces (200ms) then sends `pushEvent("hashtag_suggest", %{prefix: "..."})`
(or `"mention_suggest"`) to the server, and renders the pushed-back
`"hashtag_suggestions"` / `"mention_suggestions"` as a positioned dropdown with
keyboard navigation (ArrowUp/Down, Enter/Tab, Escape).

The server side is `BaudrateWeb.AutocompleteSuggestHook`, attached with
`attach_hook/4` in `AuthHooks` next to `MarkdownPreviewHook`, so every
authenticated LiveView answers both events: tags from `Content.search_tags/2`,
local users from `Auth.search_users/2`, plus the remote actors in the
article's discussion when the LiveView has an `:article` assign. Events that a
shared JS hook pushes from any page must be handled this way, never per
LiveView: until v1.19.2 each page had its own handlers, `/profile` and
`/admin/settings` had none, and typing `@` in those fields crashed the
LiveView.

Accessibility: the textarea keeps its native textbox role (ARIA does not allow
`role="combobox"` on `<textarea>`) and gets `aria-autocomplete="list"`,
`aria-controls` pointing at the `role="listbox"`, and `aria-activedescendant`
tracking the highlighted `role="option"`. The emoji autocomplete
(`emoji_autocomplete.js`) follows the same pattern. The suggestion count is
announced through a shared polite live region (`autocomplete_announcer.js`)
using the translated `data-i18n-suggestions` template (`%{count}` placeholder)
rendered on the hook wrapper and on `<body>`; without it nothing is announced.

Source: `assets/js/hashtag_autocomplete_hook.js`, `lib/baudrate_web/live/autocomplete_suggest_hook.ex`

### `PushManagerHook`

Manages Web Push subscription lifecycle. Attached to a `<div>` on the profile
page. On mount, registers the service worker (`/service_worker.js`), checks
existing subscription state, and reports `push_support` to the server.

Handles `subscribe_push` (request permission → `pushManager.subscribe` →
POST `/api/push-subscriptions`) and `unsubscribe_push` (unsubscribe → DELETE
endpoint). Reports back `push_subscribed`, `push_unsubscribed`,
`push_permission_denied`, or `push_subscribe_error`.

Source: `assets/js/push_manager_hook.js`

### Web Push Architecture

Baudrate implements Web Push notifications using VAPID (RFC 8292) and
aes128gcm content encryption (RFC 8291), with zero external dependencies
beyond OTP `:crypto`.

**Key components:**

| Module | Purpose |
|--------|---------|
| `Notification.VapidVault` | AES-256-GCM encryption for VAPID private keys at rest |
| `Notification.VAPID` | ECDSA P-256 keypair generation, ES256 JWT signing |
| `Notification.WebPush` | RFC 8291 encryption (ECDH + HKDF + AES-128-GCM) + delivery |
| `Notification.PushSubscription` | Ecto schema for browser push endpoints |
| `PushSubscriptionController` | API endpoints for subscription create/delete |

**Flow:**

1. Admin generates VAPID keys in Settings (stored encrypted in `settings` table)
2. `root.html.heex` emits VAPID public key as `<meta name="vapid-public-key">`
3. `PushManagerHook` registers service worker and subscribes to push
4. Browser sends `PushSubscription` (endpoint, p256dh, auth) to server
5. On notification creation, `maybe_send_push/1` checks user preferences
6. `WebPush.deliver_notification/1` encrypts the payload and POSTs to the
   push service via `Federation.HTTPClient.post_raw/3` — the same SSRF
   guard and DNS-pinned transport used for federation delivery, so a
   subscription endpoint that resolves to a private/loopback IP (or
   rebinds to one between validation and connect) is rejected
7. Service worker receives push event and displays native notification

**Service worker:** `assets/js/service_worker.js` — handles `push` (show
notification) and `notificationclick` (focus/open window) events. Built
separately via the `service_worker` esbuild target to `/service_worker.js`
(must be at root for maximum scope).

### PWA Manifest

`priv/static/site.webmanifest` declares Baudrate as an installable
Progressive Web App. The manifest is linked from `root.html.heex` via
`<link rel="manifest">` alongside a `<meta name="theme-color">` tag.

With the service worker (Phase 6) and manifest in place, browsers show an
"Install" prompt. The app opens in `standalone` mode (no browser chrome) and
uses the SVG favicon as the app icon.

#### Web Share Target

The manifest includes a `share_target` configuration that allows users to
share text from other apps directly into Baudrate when installed as a PWA.

- **Endpoint**: `POST /share` (CSRF-exempt via `:share_target` pipeline)
- **Parameters**: `title`, `text`, `url` (form-urlencoded)
- **Flow**: `ShareTargetController` checks session authentication:
  - **Authenticated**: redirects to `/articles/new?title=...&text=...&url=...`
    with the shared content as query params. `ArticleNewLive` pre-fills the
    form and allows boardless article submission.
  - **Unauthenticated**: stores the target path in `:return_to` session key
    and redirects to `/login`. After successful login,
    `SessionController.establish_session/3` consumes the stored path and
    redirects to the pre-filled article form.
- **Limits**: title truncated to 200 chars, text to 64 KB, url to 2048 chars

#### Outbound Web Share

The header renders a "Share this page" button (`share_button/1` in
`BaudrateWeb.Layouts`) that invokes the browser's [Web Share API] to surface
the OS-level share sheet — useful on smartphones and installed PWAs for
forwarding the current page to other apps (Messages, Mail, Mastodon, etc.).

- **Component**: `share_button/1` in `lib/baudrate_web/components/layouts.ex`
  renders a `<button>` with `id="web-share-button"`, the `hero-share` icon,
  and `aria-label="Share this page"`. The button is rendered with both the
  HTML5 `hidden` attribute and the Tailwind `hidden` class so it stays
  invisible by default.
- **Hook**: `WebShareHook` in `assets/js/web_share_hook.js` checks
  `navigator.share` on mount; if unavailable (most desktop browsers) the
  button stays hidden, otherwise it's revealed and the click handler calls
  `navigator.share({title, text, url})`.
- **Default payload**: `document.title` and `location.href`. Per-page
  overrides are supported via `data-share-title`, `data-share-text`, and
  `data-share-url` attributes on the button element.
- **AbortError** (user dismissed the share sheet) is silently ignored;
  other errors are logged via `console.warn`.

[Web Share API]: https://developer.mozilla.org/en-US/docs/Web/API/Navigator/share

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

### Open Graph & Twitter Card Meta Tags

Public pages emit Open Graph (`og:*`) and Twitter Card (`twitter:*`) meta tags
in `<head>` to enable rich link previews when URLs are shared on Mastodon,
Slack, Discord, and other platforms.

**Implementation:** `BaudrateWeb.OpenGraph` provides builder functions
(`article_tags/2`, `board_tags/1`, `user_tags/3`, `home_tags/1`, `default_tags/1`).
Each returns a list of `{property, content}` tuples. LiveViews assign `og_meta`
in `mount/3`; the root layout renders them with the correct attribute
(`property` for OG, `name` for Twitter Card / profile).

**Tag mappings:**

| Page | og:type | twitter:card | og:image |
|------|---------|-------------|----------|
| Article (`/articles/:slug`) | `article` | `summary_large_image` (with image) / `summary` | First article image → author avatar → site icon |
| Board (`/boards/:slug`) | `website` | `summary` | Site icon |
| User profile (`/users/:username`) | `profile` | `summary` | User avatar → site icon |
| Home (`/`) | `website` | `summary` | Site icon |

## Continuous Integration

CI (`.github/workflows/elixir.yml`) runs two jobs on every push and pull
request to `main` and `current`, both inside the project's own CI image
([ADR 0027](adr/0027-ci-runs-in-a-pinned-attested-image.md)):

| Job | Runs |
|-----|------|
| Test (4 partitions) | format check, `compile --warnings-as-errors`, `mix lint`, `mix test --partitions 4 --seed 9527` |
| Browser tests | `mix assets.build`, then `mix test --only feature` (Wallaby + Selenium + headless Firefox ESR); failure screenshots and the Selenium log are uploaded |

The image (`ci/image/Dockerfile`) contains Erlang/OTP, Elixir, Rust, Firefox
ESR, Java, the PostgreSQL client, esbuild, Tailwind, GeckoDriver and Selenium
Server, all from pinned, checksum-verified inputs. GeckoDriver is built from
its crates.io source crate: its 0.37.x release binaries are signed only by a
Mozilla subkey revoked as compromised. Jobs use it only through the
digest in `ci/image/image.lock`, after `ci-image-ref.yml` verifies its build
provenance, and each job first runs `ci/image/verify-toolchain.sh`. Only
GitHub-owned actions are used, pinned to commit SHAs; the PostgreSQL service is
pinned by digest. Inside the container the database is reached as `postgres`
(`PGHOST`), and esbuild, Tailwind and Selenium come from the image
(`MIX_ESBUILD_PATH`, `MIX_TAILWIND_PATH`, `BAUDRATE_SELENIUM_DIR`).

Changing Erlang, Elixir, Rust, esbuild, Tailwind, GeckoDriver or Selenium needs
the Dockerfile's version and SHA-256 updated too; see `ci/image/README.md`.
`.github/workflows/ci-image.yml` rebuilds the image on Dockerfile changes and
weekly, and proposes the new digest.

## Dependency Monitoring

Dependency updates are watched from two places, which together cover every pin:

| Tool | Covers |
|------|--------|
| Dependabot (`.github/dependabot.yml`) | Hex packages in `mix.exs`/`mix.lock` (including the `heroicons` git dependency and the esbuild/Tailwind *installer* packages), the three Rust NIF crates under `native/`, and GitHub Actions. Security updates get one PR each; minor/patch version updates are grouped weekly. |
| Dependency drift workflow (`.github/workflows/dependency-drift.yml`) | Pins Dependabot cannot read: the esbuild/Tailwind binary `version:` in `config/config.exs`, vendored assets in `assets/vendor/` (daisyUI version; `daisyui-theme.js` byte-compared against the matching daisyUI release; topbar; Cropper.js), Erlang/Elixir in `.tool-versions`, and retired Hex packages via `mix hex.audit`. Runs weekly (and on manual dispatch) and keeps one rolling "Dependency drift report" issue, closed automatically once everything is current. |

The drift check is a plain script (`.github/scripts/dependency-drift.sh`, needs `curl` and `jq`) that also runs locally; in CI, `mix hex.audit` runs inside the CI image while the script runs on the runner; it exits non-zero when anything is outdated. Upgrading is still a manual step — the `check-updates` skill walks through risk-grouping the results.

## Further Reading

- [Architecture Decision Records](adr/README.md) — *why* the architecture is the way it is: rationale, rejected alternatives, and the consequences we live with. This guide documents *what* the system does; the ADRs document why.
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
- Rust toolchain (`cargo`), which builds GeckoDriver
- GeckoDriver + Selenium Server JAR in `tmp/selenium/`

#### Setup

```bash
mix selenium.setup    # Selenium Server 4.49.0 + GeckoDriver 0.37.1 (built from source)
```

Both inputs are checked against pinned SHA-256s. GeckoDriver is compiled from
its crates.io crate with `cargo build --locked`, outside the repository (its
build script embeds the enclosing checkout's commit in `--version`). Re-run the
task after a version bump: it rebuilds a GeckoDriver whose `--version` differs.
The tests start Selenium Server on `127.0.0.1:4444` only; Selenium Grid has no
authentication.

#### Running Feature Tests

```bash
# Run all feature tests (auto-starts Selenium if needed):
mix test --include feature test/baudrate_web/features/ --seed 9527

# Run a single feature test:
mix test --include feature test/baudrate_web/features/home_page_test.exs --seed 9527
```

Regular tests (`mix test`) do **not** start Selenium or include feature tests.

JS hooks have no other tests, so run the feature tests after changing
`assets/js/` or a template's hooks. `js_errors_test.exs` crawls the member
and public pages, re-mounts each through a live navigation, types into every
textarea and opens every dropdown, and fails on any JavaScript error,
`console.error` (e.g. an unregistered `phx-hook`) or LiveView crash. It also
types into every `phx-change` form field by field and fails when a re-render
erases a field that was already filled in. The admin
crawl signs in with TOTP and passes sudo verification first, and every crawl
fails if a page redirects instead of rendering. The regular suite still guards
hook names: `js_hooks_registered_test.exs` fails when a template's `phx-hook`
is not registered in `app.js`.

`layout_test.exs` checks rendered layout without screenshots. For member and
admin pages, in the Aqua light and dark themes, at Firefox's minimum window
width (500 px; Firefox allows nothing narrower, and it is below Tailwind's
`sm` breakpoint) and at desktop width, it fails when the page is wider than
the window, naming the innermost element that sticks out (including text
overflowing its box), or when a dropdown menu leaves the viewport or one of
its items is not the topmost element at its centre (clipped by a card or
covered by the mobile dock). The test data includes long unbreakable tokens
and a one-line feed post, the shapes behind earlier layout bugs.

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

The Firefox preferences in `config/test.exs` turn on the WebAuthn software
token and turn off USB tokens (Firefox answers from the WebDriver virtual
authenticator only then; otherwise requests fail or hang), and save downloads
to `tmp/wallaby_downloads` without a prompt.

#### Feature Test Helpers

`BaudrateWeb.FeatureCase` provides shared helpers:

- **`log_in_via_browser/2`** — fills the login form and waits for redirect. Only
  works for `"user"` role (admin/moderator require TOTP).
- **`submit_login_form/3`** — submits the login form with a given password,
  without waiting for the outcome; **`log_out_via_browser/1`** signs out.
- **`start_another_session/0`** — a second browser sharing the test's sandbox,
  e.g. another signed-in device.
- **`wait_for_path/2`** — waits for a redirect that leaves nothing to assert on.
- **`add_virtual_authenticator/1`** — adds a WebDriver virtual authenticator, so
  WebAuthn registration and assertions complete without a physical key.
- **`enable_totp!/1`**, **`totp_code/2`** — give a user TOTP and produce a valid
  code (clearing the single-use marker, so a test can authenticate twice).
- **`log_in_with_totp_via_browser/3`**, **`log_in_admin_via_browser/1`** — sign
  in through the password and TOTP pages.
- **`visit_admin/3`** — visits an `/admin` page, passing `/admin/verify` sudo
  verification when it is asked for.
- **`js_value/2`** — runs a script in the browser and returns its value.
- **`create_board/1`** — creates a board with `ap_enabled: false` (prevents
  federation delivery in tests).
- **`create_article/3`** — creates an article in a board for a given user.

#### Test Coverage

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `admin_login_test.exs` | 1 | Admin signs in with TOTP and passes sudo verification |
| `article_bookmark_test.exs` | 3 | Bookmark, remove bookmark, no button for guests |
| `article_creation_test.exs` | 2 | Create article via form, new article link from board |
| `article_deletion_test.exs` | 3 | Delete button for author only, not for others or guests |
| `article_editing_test.exs` | 2 | Author edits, non-author cannot open the edit page |
| `article_likes_test.exs` | 3 | Like, unlike, cannot like own article |
| `bookmarks_test.exs` | 2 | Bookmarks page and empty state |
| `browsing_test.exs` | 3 | Home→board→article flow, empty board, article with author/comments |
| `comments_test.exs` | 2 | Member posts a comment, guest cannot |
| `composer_test.exs` | 4 | Markdown preview, draft kept and restored then cleared on posting, posting and voting on a poll, image upload attached to the article |
| `data_export_test.exs` | 1 | Request an export, download the archive through the Fetch Metadata check once ready |
| `feed_pagination_test.exs` | 3 | Pager (including from `?page=2`), scroll back to the list, `@mention` autocomplete |
| `following_test.exs` | 2 | Following page and empty state |
| `home_page_test.exs` | 4 | Guest welcome, board listing, personalized greeting, board navigation |
| `invites_test.exs` | 3 | Invites page, generate button, generate a code and copy its link |
| `js_errors_test.exs` | 3 | Member, guest and admin page crawls with no JS errors, LiveView crashes, or form fields erased by a re-render |
| `layout_test.exs` | 2 | Member and admin pages in both Aqua themes at narrow and desktop width: no sideways scrolling, every dropdown item reachable |
| `login_test.exs` | 4 | Successful login, failed login, registration link, redirect if authenticated |
| `logout_test.exs` | 1 | Sign out redirects to login |
| `messages_test.exs` | 4 | Messages page, empty state, new message page, send a message that arrives on the recipient's open inbox |
| `moderation_queue_test.exs` | 3 | Report an article from its menu, resolve with a note; delete reported content and dismiss; bulk resolve |
| `notifications_test.exs` | 2 | Notifications page and empty state |
| `password_change_test.exs` | 1 | Change the password; the old one is refused and the new one signs in |
| `password_reset_test.exs` | 3 | Reset page from login, full reset with a recovery code then sign-in, required-field validation |
| `registration_test.exs` | 2 | Registration with recovery codes, acknowledging codes |
| `security_keys_test.exs` | 1 | Register a security key on `/profile`, then pass admin sudo verification with it |
| `safety_test.exs` | 3 | Block from a profile (stops comments) and unblock from Blocked Accounts; mute hides a member's articles until unmuted; report and mute from a remote post's menu |
| `search_test.exs` | 3 | Keyword search, no results, `author:` operator |
| `sign_out_everywhere_test.exs` | 1 | Signing out everywhere else disconnects another browser's open page |
| `setup_wizard_test.exs` | 1 | Full setup wizard flow (DB→Site Name→Admin→Recovery Codes) |
| `two_factor_test.exs` | 3 | TOTP enrollment at first sign-in, wrong then right code, single-use recovery code |
| `user_profile_test.exs` | 2 | Profile page with stats, author link navigates to profile |

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

## Inbound Link Previews

When users post URLs in articles, comments, or DMs, the system fetches Open Graph / Twitter Card metadata from the linked page and renders a rich preview card.

### Architecture

```
Content Creation → Extract First URL → Async Fetch OG Metadata → Store LinkPreview → PubSub → UI Update
```

- **First URL only** per content item (like Mastodon/Slack)
- **Async fetch** — content saves immediately; preview appears via PubSub push
- **Shared `link_previews` table** — deduplicated by SHA-256 URL hash; FK from each content table
- **Server-side image proxy** — OG images are fetched, re-encoded to WebP via libvips, and served locally (no remote image loading in browser)

### Key Files

| File | Purpose |
|------|---------|
| `lib/baudrate/content/link_preview.ex` | Schema + changeset |
| `lib/baudrate/content/link_preview/url_extractor.ex` | HTML → first external URL |
| `lib/baudrate/content/link_preview/fetcher.ex` | URL → OG metadata → DB |
| `lib/baudrate/content/link_preview/image_proxy.ex` | Image fetch + WebP re-encode |
| `lib/baudrate/content/link_preview/worker.ex` | Async scheduling via TaskSupervisor |

### Security

- **SSRF**: Reuses `HTTPClient` (HTTPS-only, private IP rejection, DNS pinning)
- **Image proxy**: Remote images are never loaded in the browser — fetched server-side, re-encoded to WebP, served from `/uploads/link_preview_images/`
- **XSS**: All metadata sanitized with `Sanitizer.Native.strip_tags/1`, control chars stripped, truncated
- **Rate limiting**: 10 fetches/min per target domain + 5/min per posting user
- **Domain blocks**: Checked before fetching

### Invalidation

- **TTL**: 7 days; stale previews re-fetched hourly by `SessionCleaner`
- **Failed previews**: Shown as fallback card (URL + domain only), not retried for 24 hours
- **Content edit**: When an article's first URL changes, old preview is cleared and new one fetched
- **Orphan purge**: Previews with no content associations older than 30 days are hard-deleted

### Federation

- **Outbound**: Fetched previews are emitted as `attachment` entries (`type: "Document"`) on outgoing Article objects
- **Inbound**: Remote content with links triggers the same async fetch pipeline
