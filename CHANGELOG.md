# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older releases: [1.2.x](CHANGELOG-1.2.md) | [1.1.x](CHANGELOG-1.1.md) | [1.0.x](CHANGELOG-1.0.md)

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
