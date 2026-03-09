# Changelog — 1.1.x

For the current changelog, see [CHANGELOG.md](CHANGELOG.md).

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
