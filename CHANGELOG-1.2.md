# Changelog — 1.2.x

For the current changelog, see [CHANGELOG.md](CHANGELOG.md).

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
