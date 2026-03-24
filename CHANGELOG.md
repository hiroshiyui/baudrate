# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older releases: [1.2.x](CHANGELOG-1.2.md) | [1.1.x](CHANGELOG-1.1.md) | [1.0.x](CHANGELOG-1.0.md)

## [1.5.3] — 2026-03-24

### Fixed

- **Images lost when forwarding a feed item to a board** — `forward_feed_item_to_board` was not passing `image_attachments` to `create_remote_article`, so AP attachment images stored on the feed item were never fetched and stored as article images. They are now correctly carried over and downloaded asynchronously when a feed item is materialised into a board article.

## [1.5.2] — 2026-03-24

### Removed

- **Wayback Machine fallback in favicon fetcher** — The `web.archive.org` fallback that was attempted when all direct favicon candidates failed has been removed. It added latency and rarely produced usable results; direct candidate resolution (HTML `<link>` tags + standard well-known paths) is now the final step.

## [1.5.1] — 2026-03-24

### Added

- **RSS/Atom feed HTML normalizer** — `normalize_feed_html/1` Rust NIF applies the markdown sanitization allowlist via Ammonia/html5ever, then removes common feed artefacts: empty `<p>` elements left behind when `<div>`/`<span>` wrappers are stripped, and runs of 3+ consecutive `<br>` collapsed to `<br><br>`. Used in `feed_parser.ex` for all bot feed body content.

### Fixed

- **Scroll-to-top FAB not appearing after LiveView navigation** — Cached DOM element references became stale when LiveView's morphdom patched the layout during navigation. Switched to looking up `#scroll-to-top-btn` by ID on every scroll/navigation event and handling clicks via `document` event delegation, so the FAB works correctly after any client-side navigation without a manual page refresh.

## [1.5.0] — 2026-03-24

### Added

- **Scroll-to-top FAB** — A floating action button (56 px, primary colour) appears after the user scrolls past the header and returns to the top of the page on click. Animated with a spring pop-in/out effect (cubic-bezier 0.34, 1.56, 0.64, 1). Positioned above the mobile bottom dock on small screens.

### Fixed

- **`&nbsp;` in article digests** — Leading and trailing `&nbsp;` entities are now trimmed inside the Rust `strip_tags` NIF (Ammonia); interior `&nbsp;` are decoded to regular spaces by `decode_html_entities/1`. Digest text on board, feed, and user-profile pages no longer contains stray non-breaking spaces.
- **Pagination scroll position** — Clicking a pagination link on a board page now scrolls the first article into view, offset by the sticky header height, instead of leaving the viewport anchored at the bottom of the previous page.

## [1.4.0] — 2026-03-22

### Added

- **Image attachments for comments** — Users can now attach up to 4 images (JPEG, PNG, WebP, GIF, max 8 MB each) when posting a comment or inline reply on an article page. Images are processed to WebP with EXIF stripped and dimensions capped at 1024 px, displayed as a gallery below the comment body. Attached images are included as `attachment` entries in federated `Create(Note)` ActivityPub activities so remote instances can display them. Orphaned uploads (never submitted) are cleaned up after 24 hours by `SessionCleaner`.
- **Image attachments for feed replies** — The same upload capability is available when replying to a remote actor's post on the `/feed` page. Up to 4 images per reply; images are sent as AP attachments to the remote actor's inbox and the replying user's AP follower inboxes. Previously sent reply images are shown in the local reply list.
- **`CommentImage` and `FeedItemReplyImage` schemas** — New DB tables (`comment_images`, `feed_item_reply_images`) with nullable FK columns supporting the upload-before-save pattern; cascade-deleted with their parent records.

## [1.3.58] — 2026-03-22

### Fixed

- **HTML entity double-encoding in article digests and display names** — `strip_tags` (Ammonia) re-encodes special characters as HTML entities (e.g. `&` → `&amp;`). When the output was interpolated into a HEEx template, Phoenix would escape it again (`&amp;amp;`), causing browsers to render literal `&amp;` instead of `&`. Added a public `decode_html_entities/1` helper to `Baudrate.Sanitizer.Native` and applied it after every `strip_tags` call whose result is used as plain text: `digest/1` in board, feed, and user-profile live views; `excerpt/1` in `linked_data.ex`; `sanitize_display_name/1` in `Federation.Sanitizer` and `Setup.User`; and `normalize_title/1` in the RSS/Atom feed parser.

## [1.3.57] — 2026-03-20

### Changed

- **Fediverse handle icon size increased** — The `hero-identification` icon next to the fediverse handle on user profile and board pages is now `size-6` (24 px) for better visual prominence.

## [1.3.56] — 2026-03-20

### Added

- **Handle reservation on deletion (anti-fraud)** — When a bot account or board is deleted, its username/slug is permanently recorded in a new `reserved_handles` table. Subsequent attempts to register a username or create a board with a reserved handle are rejected with a clear error message, preventing impersonation of well-known identities after deletion. Reservation happens inside the deletion transaction so no handle leaks on rollback. Both the `User` and `Board` changeset validators now check this table in addition to the existing cross-type conflict check.

## [1.3.55] — 2026-03-20

### Fixed

- **Username/board-slug WebFinger conflict prevented** — A username whose lowercase form matched an existing board slug would shadow that board in WebFinger resolution (users are checked before boards), making the board undiscoverable from Mastodon and other federation clients. Added `validate_username_not_board_slug/1` to `User` changeset and `validate_slug_not_username/1` to `Board` changeset so the conflict is caught at creation time with a clear error message on both sides.

## [1.3.54] — 2026-03-20

### Added

- **Fediverse handle on user profiles and board pages** — Registered users and federated boards now display their fediverse handle (e.g. `@hiroshiyui@baudrate.tw`) with a heroicon identification icon. The handle is always shown on user profile pages; on board pages it appears only when `ap_enabled` is true. Added `fediverse_handle/1` helper in `BaudrateWeb.Helpers` (delegated via `core_components.ex`). Translations added for zh_TW (`聯邦宇宙帳號`) and ja_JP (`Fediverseハンドル`).

## [1.3.53] — 2026-03-20

### Fixed

- **PWA draft content cleared on return from background** — When a user switched away from the app and came back, LiveView reconnected and re-rendered the page with empty server state, wiping any in-progress draft. Added a `reconnected()` callback to `DraftSaveHook` that restores saved draft content from `localStorage` via `requestAnimationFrame` after LiveView finishes patching the DOM.

## [1.3.52] — 2026-03-19

### Added

- **Real-time unread board indicators on the home page** — The boards listing now subscribes to `board:<id>` PubSub topics on mount (authenticated users only) and re-computes `unread_board_ids` whenever an `:article_created` event is received. The unread dot appears immediately without requiring a manual page reload.

## [1.3.51] — 2026-03-18

### Fixed

- **Bot feed deduplication now checks source URL in addition to GUID** — Previously, `already_posted?` only compared the feed entry GUID against `bot_feed_items`. If a feed publisher changed a `<guid>` between fetch cycles (e.g. switching from a relative path to a canonical URL), the same article would slip through and be posted twice. `already_posted?/3` now also queries `articles(user_id, url)` for any non-deleted article posted by the bot with the same source URL. A partial index on `articles(user_id, url) WHERE url IS NOT NULL` keeps the lookup efficient.

## [1.3.50] — 2026-03-18

### Fixed

- **Bot profile field inputs reset on every keystroke** — In the `/admin/bots` edit form, plain HTML `<input>` elements for profile fields (Label / Content) had their `value` bound to `@editing_bot_profile_fields`, which is only populated when the edit button is clicked and never updated during `phx-change="validate"`. Every keystroke triggered a LiveView re-render that reset the inputs to their original server-side values. Fixed by adding `phx-update="ignore"` to the profile fields container div, preventing LiveView from patching those DOM nodes after the initial mount. The `:if={@editing_bot}` wrapper ensures a fresh mount with correctly pre-filled values each time a bot's edit form is opened.

## [1.3.49] — 2026-03-18

### Changed

- **Feed parser replaced with feedparser-rs Rustler NIF** — The Elixir `fiet` and `saxy` libraries have been replaced by a new `baudrate_feed_parser` Rustler NIF backed by the [`feedparser-rs`](https://github.com/bug-ops/feedparser-rs) Rust crate. The new parser supports RSS 0.9x/2.0, RSS 1.0 (RDF), Atom 0.3/1.0, and JSON Feed natively in a single pass with no per-format fallback logic. Dates are returned as RFC 3339 strings and parsed by `DateTime.from_iso8601/1` on the Elixir side. HTML sanitization remains in Elixir via the existing `baudrate_sanitizer` NIF.

### Removed

- **`fiet` and `saxy` dependencies** — Both packages are no longer needed and have been removed from `mix.exs` and unlocked from `mix.lock`.

## [1.3.48] — 2026-03-18

### Added

- **Bot bio editing in admin UI** — The `/admin/bots` edit and create forms now include a `Bio` textarea. On creation, the bio defaults to the feed URL when left blank. On edit, the current bio is pre-filled and submitted explicitly, bypassing the legacy auto-bio-from-feed_url fallback. Admins can use this to add disclaimer text such as "Unofficial — not affiliated with the source."
- **Bot profile fields in admin UI** — The `/admin/bots` edit form now exposes 4 profile field rows (label + content) that are stored on the bot's user account and federated as `PropertyValue` attachments on the bot's AP actor, following the Mastodon convention. Admins can use these to add structured metadata such as a notice of non-affiliation with the feed source.

## [1.3.47] — 2026-03-18

### Added

- **User profile fields (Mastodon-compatible)** — Users can now add up to 4 custom profile fields (name + value pairs, e.g. "Website", "Location") at `/profile`. Fields are stored as a `jsonb[]` column on the `users` table, validated (name ≤ 255 chars, value ≤ 2048 chars, max 4 fields), and displayed on public profile pages. For ActivityPub federation, fields are published as `PropertyValue` attachments on the Person actor with the schema.org context (`schema:PropertyValue`, `schema:value`), ensuring compatibility with Mastodon and other AP clients that render profile metadata.
- **Remote actor profile fields** — Incoming AP actors' `attachment` arrays are parsed for `PropertyValue` entries (up to 4), stored in a new `profile_fields` column on `remote_actors`, and displayed on the remote user's local profile page.

### Database

- New `profile_fields jsonb[] NOT NULL DEFAULT '{}'` column on both `users` and `remote_actors` tables (migration `20260318000000_add_profile_fields_to_users_and_remote_actors`).

## [1.3.46] — 2026-03-17

### Changed

- **Article image upload limit raised to 8 MB** — The maximum file size for article image uploads (new and edit) has been increased from 5 MB to 8 MB, both client-side (`allow_upload`) and server-side (`Content.Images`).

## [1.3.45] — 2026-03-17

### Added

- **RSS bot favicon fetch retry limit** — Automatic favicon fetching is now paused after 3 consecutive failures per bot, preventing repeated requests to unreachable or bot-blocking sites. A new `favicon_fail_count` column on the `bots` table tracks consecutive failures; the counter resets to 0 on any successful fetch. The admin "Refresh Favicon" button bypasses the gate and always attempts a fetch, re-enabling automatic fetches on success.

### Tests

- Added essential WebAuthn unit tests: `begin_registration/1` (token+JSON structure, ETS storage, single-use), `begin_authentication/1` (token+JSON, empty/populated `allowCredentials`, challenge type), `finish_registration/4` (invalid base64 inputs), `finish_authentication/6` (`:unknown_credential` for missing, cross-user, and invalid base64 credential ID).
- Updated WebAuthn controller tests to use `Wax.new_authentication_challenge/1` instead of plain map challenges.
- Added tests for `favicon_fail_count` gate logic, `increment_favicon_fail_count/1`, and `mark_avatar_refreshed/1` counter reset.

## [1.3.44] — 2026-03-17

### Fixed

- **WebAuthn admin sudo verification — 500 error on `Wax.authenticate/6`** — The argument order was wrong: `challenge` and `credentials` were swapped (positions 5 and 6). Additionally, `credentials` must be a `[{credential_id, cose_key}]` tuple list, not a map, and the sign count is not part of the credentials list. The return value is `{:ok, Wax.AuthenticatorData.t()}` — the new sign count is read from `auth_data.sign_count`.

## [1.3.43] — 2026-03-17

### Fixed

- **WebAuthn admin sudo verification always failing with `:unknown_credential`** — Two bugs:
  1. `Wax.new_authentication_challenge/1` was passed `allow_credentials` as a list of raw credential ID binaries, but wax_ expects `[{credential_id, cose_key}]` tuples. When `allow_credentials` is non-empty, wax_ uses it (not the `cred_map` passed to `Wax.authenticate/6`) for key lookup, so verification always failed. Fixed by omitting `allow_credentials` from the challenge, causing wax_ to fall back to the `credentials` map passed directly to `Wax.authenticate/6`.
  2. The `WebAuthnAuthenticate` hook set hidden form inputs then pushed `webauthn_credential_received` to trigger `phx-trigger-action`. When LiveView sent back the diff, morphdom patched the DOM before form submission, resetting the JS-set `credential_id`/`signature`/etc. fields to empty. Fixed by calling `requestSubmit()` directly from JS (same as `WebAuthnRegister`), removing the `phx-trigger-action` approach for this form.

## [1.3.42] — 2026-03-17

### Fixed

- **WebAuthn registration — public key cast error** — `Wax.register/3` returns the credential public key as a decoded COSE key map (`Wax.CoseKey.t()`), not raw bytes. Storing it directly into a `:binary` schema field caused an Ecto cast error on every registration. The key is now CBOR-encoded before storage and decoded back (with `CBOR.Tag` byte-string unwrapping) before being passed to `Wax.authenticate/6`. Added `{:cbor, "~> 1.0"}` as an explicit dependency.

## [1.3.41] — 2026-03-17

### Fixed

- **WebAuthn registration always failing** — `Wax.Challenge` stores `attestation` and `user_verification` as strings (`"none"`, `"preferred"`), but the challenge options were passing atoms (`:none`, `:preferred`). The atom overwrote the string default, causing `AttestationStatementFormat.None.verify/4` to never match its `%Wax.Challenge{attestation: "none"}` clause and rejecting every registration attempt with `invalid_attestation_conveyance_preference`. The incorrect options are now removed from both challenge calls and the config, letting the correct string defaults take effect. `user_presence: true` (not a recognized `Wax.Challenge` option) was also removed.

## [1.3.40] — 2026-03-17

### Fixed

- **WebAuthn registration failure reason now logged** — The `else` clause in the registration controller was discarding the actual error, making production failures impossible to diagnose. The error is now included in the warning log line.

## [1.3.39] — 2026-03-17

### Added

- **WebAuthn / FIDO2 hardware security key support** — Users can register FIDO2-compatible hardware security keys (YubiKey, passkeys, Touch ID, etc.) at `/profile` → "Security Keys". Registered keys can be used as an alternative to TOTP when completing admin sudo-mode re-verification at `/admin/verify`. Multiple keys per user are supported; each has a user-defined label, a last-used timestamp, and a sign count for clone detection.

## [1.3.38] — 2026-03-16

### Fixed

- **User boosts not delivered to booster's followers** — When a local user boosted an article or comment, the `Announce` activity was incorrectly delivered to the *article author's* followers instead of the *booster's* followers, making the boost invisible to anyone following the booster on remote instances. The delivery now uses `enqueue_for_followers/2` with the booster's actor URI.

## [1.3.37] — 2026-03-16

### Fixed

- **Bot favicon wrong site for feed proxies** — Feed proxy services (e.g. FeedBurner at `feeds.feedburner.com`) and CDN feed subdomains (e.g. `feeds.bbci.co.uk`) serve feeds from a different host than the actual website, so the favicon was never found. The fetcher now reads the feed XML first and extracts the channel `<link>` element (the actual website URL) to use as the favicon base, falling back to the feed URL's origin if extraction fails.

## [1.3.36] — 2026-03-16

### Added

- **Wayback Machine favicon fallback** — When all direct favicon fetches fail (e.g. the production server IP is blocked at a CDN/WAF), the favicon fetcher now retries the same candidate list via the Internet Archive Wayback Machine (`web.archive.org/web/2if_/{url}`), which returns the most recently archived raw file. This allows bots to acquire favicons from sites like Bahamut that block non-browser IPs.

## [1.3.35] — 2026-03-16

### Added

- **Bot "Reset & Retry" button** — The admin bots page now shows a "Reset & Retry" button on any bot with errors. Clicking it clears the error count and last error message, resets `next_fetch_at` to now (bypassing exponential backoff), and immediately triggers a re-fetch without waiting for the next scheduled poll cycle.

## [1.3.34] — 2026-03-16

### Fixed

- **Feed parser rejects BOM-prefixed feeds** — Some feeds (e.g. news.ltn.com.tw) prepend a UTF-8 BOM (`EF BB BF`) which caused Saxy to fail with a parse error on the leading `<` of `<?xml`. The BOM is now stripped before any parsing.

## [1.3.33] — 2026-03-16

### Added

- **RSS 1.0 (RDF) feed support** — Feed bots can now subscribe to RSS 1.0/RDF feeds (e.g. Impress Watch). These use a flat `<rdf:RDF>` root with `<item>` siblings rather than nesting inside a `<channel>`. Parsed directly via `Saxy.SimpleForm` as a third fallback after RSS 2.0 and Atom 1.0. Supports `dc:date`, `content:encoded`, `rdf:about` as GUID, and standard `title`/`link` fields.

## [1.3.32] — 2026-03-16

### Fixed

- **Bot article titles "(untitled)"** — RSS feeds that embed raw HTML in `<title>` without CDATA wrapping (e.g. Drupal-style `<title><a href="...">text</a></title>`) caused fiet/Saxy to see nested XML elements and return an empty title, falling back to "(untitled)". The feed parser now pre-processes such title elements by stripping tags and re-wrapping the text in CDATA before parsing. HTML entities (e.g. `&amp;`) are also decoded so titles are stored as plain text.
- **Bot article bodies missing paragraphs / rendered as blockquotes** — Bot articles store sanitized HTML in the body field. `Markdown.to_html/1` runs input through Earmark, which requires blank lines between block-level elements to recognize them as HTML blocks. Without them, Earmark dropped all paragraphs after the first, and lines starting with `>` were misinterpreted as Markdown blockquotes. A normalization step now inserts `\n\n` after block-level closing tags and trims leading/trailing whitespace before handing text to Earmark. Fixes rendering for all existing bot articles without any DB migration.

## [1.3.31] — 2026-03-16

### Added

- **Bot favicon manual refresh** — Added a "Refresh Favicon" button to the admin bots page (`/admin/bots`). Clicking it immediately re-fetches the favicon from the feed site and sets it as the bot's avatar, without waiting for the next scheduled feed cycle. The action is logged to the moderation audit log.

## [1.3.30] — 2026-03-16

### Fixed

- **Bot favicon WAF bypass** — The favicon fetcher now uses a browser-like Firefox User-Agent for all favicon HTTP requests (homepage fetch + candidate downloads). Sites that block bot user-agents at the CDN/WAF layer (e.g. gnn.gamer.com.tw / Bahamut) now return the correct responses.
- **`HTTPClient.get_html/2`** — Added a `:user_agent` option to allow callers to override the default generic User-Agent string.

## [1.3.29] — 2026-03-16

### Fixed

- **Bot favicon CDN hotlink protection** — The favicon fetcher now sends the site's origin URL as the `Referer` header when downloading favicon candidates. CDNs that reject requests without a `Referer` (e.g. Bahamut's `i2.bahamut.com.tw`) now serve the image correctly.

## [1.3.28] — 2026-03-16

### Added

- **Bot profile shows feed URL** — Bot user profiles now display the feed URL in the bio field automatically. The bio is set on bot creation and kept in sync whenever the feed URL is updated.

### Fixed

- **Bot avatar fetching** — The favicon fetcher now handles two common failure cases:
  - Sites that advertise only an SVG favicon (e.g. gamer.com.tw) — SVG links are now skipped; the `apple-touch-icon` PNG is used instead.
  - Sites that advertise only a `favicon.ico` but don't include it in `<link>` tags (e.g. ithome.com.tw) — each candidate URL is now tried end-to-end (download + avatar process); if ICO fails the avatar pipeline, the standard `/apple-touch-icon.png` path is probed as a fallback.
- **Article timestamps** — Bot and federated articles now show their original `published_at` date (from RSS `<pubDate>` / Atom `<published>`) instead of the time the bot fetched them. Regular user articles are unaffected.

## [1.3.27] — 2026-03-16

### Added

- **RSS/Atom Feed Bot Accounts** — Administrators can now create bot accounts that periodically fetch RSS/Atom feeds and post entries as articles. Bots are full ActivityPub actors — remote users and boards can follow them and receive federated articles. Bots cannot be logged into by humans and cannot receive DMs. A "Bot" badge is shown on profiles and post bylines.
- **Admin Bot Management UI** — New admin page at `/admin/bots` for creating, editing, toggling, and deleting bot accounts with feed URL, target boards, and fetch interval configuration.
- **Board Follows discoverability** — Added a "Follows" action link to the admin board management table for federated boards, so admins can reach board follows pages without explicitly being board moderators.

### Fixed

- **Bot login crash (critical)** — Logging in with a bot account username no longer causes a `CaseClauseError` (500 error). The attempt is now rejected with the same generic "Invalid username or password" message and recorded as a failed login attempt.
- **Feed item deduplication race** — `record_feed_item/3` now uses `on_conflict: :nothing` to safely handle concurrent duplicate GUID inserts without raising a constraint error.
- **User-Agent version** — The federation HTTP client now reads the version from `Application.spec/2` at runtime instead of hardcoding `0.1.0`, keeping the User-Agent accurate across releases.
- **Local handle search on board follows page** — Searching for a local user handle (e.g. `@botname`) on the board follows page now shows a helpful error directing the admin to configure bot board targets via Admin → Bots, instead of silently failing.

### Improved

- **Accessibility** — Bot badge spans now carry `role="img"` and `aria-label="Bot account"` for screen reader clarity. Profile page dropdown trigger has `aria-expanded`. Article thumbnail `alt` text now uses the article title instead of the generic "Article image".

## [1.3.26] — 2026-03-15

### Added

- **CI/CD Hardening** — Integrated `credo` linting, enforced `mix format` checks, and enabled `warnings-as-errors` in the GitHub CI pipeline to ensure long-term code quality.
- **Pending User Profiles** — Users awaiting administrative approval can now personalize their profile by uploading an avatar and updating their bio and display name.

### Changed

- **Auth Context Refactor** — Major architectural cleanup of the `Baudrate.Auth` module. Logic has been extracted into specialized sub-modules (`Invites`, `Sessions`, `SecondFactor`, `Moderation`, `Users`, `Profiles`, `Passwords`) while maintaining a clean facade.
- **Federation Context Refactor** — Architectural cleanup of the `Baudrate.Federation` module. Logic has been extracted into focused sub-modules (`Follows`, `Feed`, `Discovery`, `Collections`, `ObjectBuilder`, `ActorRenderer`) to improve maintainability and testability.
- **ArticleLive Refactor** — Simplified the main `ArticleLive` module by extracting pure helper logic into `ArticleHelpers` and moving comment tree rendering into `CommentComponents`.
- **Invite Quota Relaxation** — Removed the 7-day account age requirement for generating invite codes, allowing new users to invite others immediately after registration.

### Fixed

- **Compiler Warnings** — Cleaned up unused default values in test helpers (`insert_board/2`, `create_image/3`).
- **Code Hygiene** — Fixed multiple linting issues including large number formatting and expensive list length checks.

## [1.3.25] — 2026-03-14

### Added

- **Remote comment/DM image attachments** — image attachments on incoming
  federated comments and DMs are now displayed as `<img>` tags in the
  rendered body (HTTPS only). Previously, images sent as AP attachments
  on Note objects were silently stripped by the sanitizer.
- **Test coverage** — added 55 tests for `Content.Search`, `Content.ReadTracking`,
  and `InteractionHelpers` modules

### Fixed

- **Announce-to-boards missing images** — articles routed via Announce
  (boost) to boards now correctly extract and store image attachments
- **Actor resolver nil TTL** — `stale?()` no longer returns false when
  `actor_cache_ttl` config is nil (Elixir term ordering edge case),
  preventing stale actors from being served without refetch
- **AttachmentExtractor** — `Image` type attachments without a URL are
  now correctly rejected

## [1.3.24] — 2026-03-14

### Improved

- **Board search in article forwarding** — the forward-to-board search now
  matches against board slugs in addition to board names, making it easier
  to find boards by their URL identifier

## [1.3.23] — 2026-03-12

### Fixed

- **Actor discovery on Threads.net and similar instances** — expanded the
  signed fetch fallback to also trigger on 403 and 404 HTTP responses, not
  just 401. Threads.net returns 404 for unsigned actor profile requests,
  which previously prevented discovering and following accounts there

## [1.3.22] — 2026-03-12

### Fixed

- **Federation delivery crash on remote article like/boost** — liking or
  boosting a remote article (no local user) crashed `enqueue_for_article`
  with `BadMapError` when accessing `article.user.username`. Now skips user
  follower inbox resolution for remote articles

## [1.3.21] — 2026-03-12

### Added

- **User profile: boosted articles & comments** — user profile pages now show
  a two-column layout with recent articles & comments on the left and boosted
  articles & comments on the right, with content digests, image previews, and
  load-more pagination
- **Profile username link** — username on the profile settings page is now a
  clickable link to the public profile, with a copy-to-clipboard button for
  the full profile URL

### Fixed

- **Rate limiting gap** — the PWA Web Share Target endpoint (`POST /share`)
  now has rate limiting (10 req/min per IP)
- **Accessibility** — link preview images now have descriptive `alt` text,
  article elements have `aria-labelledby`/`aria-label` attributes, admin panel
  text opacity raised from 60% to 70% for WCAG AA contrast compliance
- **Defensive `Repo.get!` calls** — `stamp_local_ap_id` and `stamp_ap_id` now
  use `Repo.get` with graceful nil handling instead of raising on deleted
  records

### Tests

- Added 27 dedicated tests for `ArticleImageStorage` (image processing, edge
  cases, invalid inputs)
- Added 26 dedicated tests for `Content.Interactions` (visibility checks, role
  access, AP ID stamping)

## [1.3.20] — 2026-03-11

### Fixed

- **Remote article images** — articles imported via federation (inbox delivery,
  auto-routing to boards, and `/search` import) now fetch and store image
  attachments from the AP object's `attachment` array. Images go through the
  same security pipeline as local uploads (magic byte validation, WebP
  re-encoding, EXIF strip, max 1024px)

## [1.3.19] — 2026-03-10

### Changed

- **Draft save indicator** — replaced "Draft saved" text with a loading dots
  animation during debounce and a cloud-arrow-up Heroicon when saved;
  indicator is now inline after the submit button in all forms

## [1.3.18] — 2026-03-10

### Fixed

- **Draft indicator layout shift** — moved "Draft saved" indicator outside
  the inline controls row in article new, edit, and comment forms so it no
  longer pushes the visibility selector and submit button when appearing
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

[1.3.19]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.19
[1.3.18]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.18
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
