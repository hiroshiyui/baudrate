# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older releases: [1.2.x](CHANGELOG-1.2.md) | [1.1.x](CHANGELOG-1.1.md) | [1.0.x](CHANGELOG-1.0.md)

## [1.3.17] — 2026-03-10

### Fixed

- **Inline form controls vertical alignment** — stripped DaisyUI fieldset
  and label padding in all inline form control rows (article new/edit,
  comment, reply, feed quick-post) for proper vertical centering
- **Comment and reply form controls left-aligned** — visibility selector
  and Post/Reply button are now left-aligned with flex-wrap for mobile
  responsiveness, consistent with article and feed forms
- **Search operators card readability** — bumped title and table text size
  for better readability
- **Ansible version comparison** — stripped `v` prefix before semver
  comparison to prevent false "deploying older version" warnings

## [1.3.15] — 2026-03-10

### Changed

- **Article form controls consolidated** — visibility selector, "Allow
  forwarding" checkbox, and Create/Save button now share a single inline
  row on article create and edit pages; visibility label removed (kept as
  `aria-label` for accessibility)
- **Markdown toolbar repositioned** — formatting toolbar now appears below
  the textarea instead of above it
- **Feed quick-post controls left-aligned** — visibility selector and Post
  button in the feed composer are now left-aligned with flex-wrap for
  mobile responsiveness

## [1.3.14] — 2026-03-10

### Fixed

- **Comment visibility selector layout** — moved the visibility selector
  before the Post/Reply button in comment and reply forms; fixed vertical
  misalignment caused by DaisyUI fieldset margin

## [1.3.13] — 2026-03-10

### Fixed

- **False "edited" indicator on Mastodon** — ActivityPub article objects no
  longer unconditionally include the `"updated"` field; it is now only emitted
  when the article was genuinely edited (>5s after creation), preventing
  Mastodon from showing an "edited" badge on unedited articles

### Reverted

- **Sitemap generation** — reverted v1.3.13–v1.3.15 sitemap feature due to
  OTP release read-only filesystem constraints; will revisit with a different
  approach

## [1.3.12] — 2026-03-10

### Added

- **Visibility selector** — article create/edit forms, comment forms, and feed
  quick post now include a visibility selector (Public, Unlisted, Followers-only,
  Direct) with full i18n support (en, zh_TW, ja_JP)
- **Remote object resolution via search** — paste a remote Fediverse post URL
  into search to preview it without storing; click "Import & interact" to
  materialize locally for liking, boosting, or forwarding (two-phase
  `ObjectResolver.fetch/1` + `resolve/1`, loop-safe)
- **Feed item and comment forwarding to boards** — users can forward feed items
  and comments to boards they have posting access to, with federation publishing
- **Forwarding UI** — forward buttons on feed items and comments with board
  selector modal
- **Nginx bot/scanner blocking rules** — example configuration for blocking
  common vulnerability scanners and malicious bots

### Fixed

- **Article title length validation** — all article changesets now enforce
  max 255 characters; `TitleDeriver` truncates remote AP object names to
  prevent oversized titles from malicious servers
- **Deterministic query ordering** — added `id` tiebreakers to all `order_by`
  queries across auth, content, federation, messaging, and moderation contexts
  to prevent nondeterministic results when timestamps collide
- **Comment creation mixed map keys** — normalized all keys to strings before
  merging `body_html` to prevent `Ecto.CastError` under concurrent execution
- **Visibility selector alignment** — fixed DaisyUI fieldset margin causing
  misalignment with Post button in feed quick post
- **Fuzzy gettext auto-matches** — cleared all incorrect fuzzy translations
  (e.g., "Public" → "Public Key") across en, zh_TW, ja_JP locales
- **Remote article forwardable flag** — added `:forwardable` to remote article
  changeset so visibility-based forwardability is persisted

### Changed

- **TitleDeriver extracted** — title derivation logic moved to shared
  `Content.TitleDeriver` module for reuse across inbox handler and
  ObjectResolver

## [1.3.11] — 2026-03-09

### Fixed

- **DM input not clearing after send** — message compose input now clears
  after sending by using a dynamic form ID that forces DOM recreation
- **Send button icon disappearing** — removed `phx-disable-with` that was
  stripping the paper airplane icon and not restoring it after re-enable

## [1.3.10] — 2026-03-09

### Added

- **YouTube video embeds** — link previews for YouTube URLs now render an
  embedded video player (via privacy-enhanced `youtube-nocookie.com`) instead
  of a static Open Graph card; supports watch, youtu.be, embed, and shorts URLs
- **Boosted content in personal feed** — articles boosted (Announced) by
  followed remote accounts now appear in the user's personal feed with
  boost attribution; supports both bare-URI and embedded-object Announce formats
  (Mastodon and Lemmy interop)
- **Board routing for boosts** — boosted Article/Page content is routed to
  boards following the booster, with deduplication by `ap_id` to prevent
  duplicates when multiple actors boost the same content; Notes remain feed-only
- **Remote image attachments** — image attachments from remote ActivityPub
  objects are displayed in the feed timeline (up to 4 images per item)

### Fixed

- **Flaky federation tests** — `ValidatorTest` no longer relies on
  `Application.get_env` which could return `nil` during concurrent test runs;
  `ActorResolverTest` uses unique `ap_id` values to prevent race conditions

### Security

- **CSP frame-src** — added `frame-src https://www.youtube-nocookie.com` to
  Content Security Policy; only YouTube embeds are allowed, no other iframes

## [1.3.9] — 2026-03-09

### Fixed

- **Remote article "View original" links** — links now point to the
  human-readable URL (e.g. `https://instance/@user/123`) instead of the
  canonical AP ID (e.g. `https://instance/ap/users/.../statuses/...`);
  a new `url` field on articles stores the browsable permalink from
  incoming ActivityPub objects

### Added

- **"View original" link on article page** — remote articles now show a
  "View original" link on the full article detail page

## [1.3.8] — 2026-03-09

### Added

- **@mention autocomplete** — typing `@` in article, comment, and feed text
  areas shows a dropdown of matching users; supports keyboard navigation
  (Arrow keys, Enter/Tab to accept, Escape to dismiss)
- **Federated mention suggestions** — the @mention dropdown includes remote
  actors who participated in the current discussion thread (article author
  and commenters), displayed as `@username@domain`

## [1.3.7] — 2026-03-09

### Added

- **Article images in ActivityPub payload** — federated articles now include
  uploaded images as Document attachments, visible on remote instances
- **Article images in feed and board views** — article image thumbnails are
  displayed in the feed timeline and board article listings
- **Add Images icon button** — replaced the file input widget with a compact
  icon button; "Add Images" and "Add Poll" now share a single toolbar row

### Fixed

- **Multi-image upload stalling** — fixed parallel uploads silently failing by
  consuming each upload entry individually as it completes
- **Oversized file upload errors not shown** — per-entry upload errors (e.g.
  file too large) are now displayed to the user

## [1.3.6] — 2026-03-09

### Added

- **Full-featured feed post composer** — the feed quick-post form now includes
  a markdown formatting toolbar, image uploads (up to 4 images), and optional
  polls, matching the article creation page
- **Collapsible markdown toolbar** — all markdown toolbars now have a pencil
  icon toggle to collapse/expand formatting buttons; collapsed by default,
  state persisted in localStorage

## [1.3.5] — 2026-03-08

### Fixed

- **Wrong repository URL in NodeInfo** — `software.repository` in `/nodeinfo/2.1`
  now points to the correct GitHub repository

## [1.3.4] — 2026-03-08

### Fixed

- **Instance actor not discoverable via WebFinger** — remote instances querying
  `acct:site@host` now correctly resolve to the site actor (`/ap/site`) instead
  of returning 404, enabling proper instance-level federation discovery

## [1.3.3] — 2026-03-08

### Added

- **"Remove from board" action** on multi-board articles — when an article exists
  in multiple boards, the dropdown shows per-board removal buttons that detach
  the article from individual boards without affecting forwarded copies

### Fixed

- **Forwarded article disappears from all boards on delete** — deleting a
  multi-board article now only removes the board association, not the article
  itself; forwarded copies in other boards remain visible
- **Soft-deleted articles accessible via direct URL** — `get_article_by_slug!`
  now filters out articles with `deleted_at` set, returning 404 instead of
  showing deleted content

## [1.3.2] — 2026-03-08

### Fixed

- **Startup crash in v1.3.1** — `shutdown_timeout` must be nested under
  `thousand_island_options` in Bandit config, not at the top level

## [1.3.1] — 2026-03-08

### Added

- **Near-zero downtime deploys** — nginx `proxy_next_upstream` retries requests
  during restarts (up to 30s, 3 attempts) with custom 502 maintenance page as
  fallback; Bandit `shutdown_timeout` drains in-flight requests for 30s on
  SIGTERM; systemd `TimeoutStopSec=35` for graceful shutdown margin

### Changed

- Database migrations now run **before** symlink swap and service restart during
  Ansible deploys, reducing the restart window to just the symlink swap + restart

### Documentation

- Added "Near-Zero Downtime Deploys" section to SysOp guide
- Added CHANGELOG.md update step to release engineering checklist in CLAUDE.md

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

[1.3.17]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.17
[1.3.16]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.16
[1.3.15]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.15
[1.3.14]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.14
[1.3.13]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.13
[1.3.12]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.12
[1.3.11]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.11
[1.3.10]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.10
[1.3.9]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.9
[1.3.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.8
[1.3.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.7
[1.3.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.6
[1.3.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.5
[1.3.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.4
[1.3.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.3
[1.3.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.2
[1.3.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.1
[1.3.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.0
