# Baudrate: ActivityPub-enabled Bulletin Board System

Public BBS / Web Forum built with Elixir/Phoenix + LiveView, federating via **ActivityPub**.
Baudrate is a **public information hub**, not a social network — public content
should remain visible to all; blocking controls interaction, not visibility.
**Information security is the top priority** — this is a public-facing system.

## Quick Reference

```bash
# Requires: Elixir 1.15+, PostgreSQL, libvips, Rust toolchain (for Ammonia NIF)
mix setup              # Install deps, create DB, build assets
mix phx.server         # Start dev server (https://localhost:4001)
mix test --seed 9527   # Run all tests (use seed 9527 for deterministic order)
mix test path/to/test  # Run specific test file
mix test --failed      # Re-run previously failed tests
mix precommit          # Pre-commit checks: compile --warnings-as-errors, unlock unused, format, test

# Run tests in parallel with 4 partitions (preferred for full suite):
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

## Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.15+ / OTP 26+ |
| Web | Phoenix 1.8 / LiveView 1.1 |
| HTTP server | Bandit |
| Database | PostgreSQL (Ecto) |
| CSS | Tailwind CSS + DaisyUI |
| HTTP client | Req (never use HTTPoison, Tesla, or httpc) |
| Markdown | Earmark |
| 2FA / WebAuthn | NimbleTOTP + EQRCode + wax_ (FIDO2/WebAuthn relying party) |
| HTML parsing | html5ever (Rust NIF via Rustler) |
| HTML sanitization | Ammonia (Rust NIF via Rustler) — requires Rust toolchain |
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |
| Timezone data | tz |
| Feed parsing | feedparser-rs (Rust NIF via Rustler) — RSS 0.9x/2.0, RSS 1.0 (RDF), Atom 0.3/1.0, JSON Feed |
| i18n | Gettext — zh_TW and ja_JP locales |

## Architecture

See [`doc/development.md`](doc/development.md) for full architecture documentation
(contexts, auth flow, sessions, RBAC, layout system, federation, etc.).

### Contexts

- **Auth** (`lib/baudrate/auth.ex`) — authentication (login, registration, TOTP, WebAuthn/FIDO2 security keys, sessions, password reset), user management (avatars, invite codes, blocks, mutes)
- **Content** (`lib/baudrate/content.ex`) — boards, articles, comments, likes, boosts, polls, permissions, board moderators, search, link previews
- **Federation** (`lib/baudrate/federation.ex`) — AP actors, outbox, followers, announces, delivery, user outbound follows, feed item replies, feed item likes/boosts
- **Messaging** (`lib/baudrate/messaging.ex`) — 1-on-1 direct messages, conversations, DM access control, federation
- **Setup** (`lib/baudrate/setup.ex`) — first-run wizard, RBAC seeding, settings, role level utilities
- **Moderation** (`lib/baudrate/moderation.ex`) — reports, resolve/dismiss, audit log
- **Notification** (`lib/baudrate/notification.ex`) — in-app notifications, unread counts, mark read, cleanup, admin announcements
- **Bots** (`lib/baudrate/bots.ex`) — RSS/Atom feed bot accounts: CRUD, feed scheduling, deduplication, favicon fetcher

### Key Gotchas

- Layout receives `@inner_content` (NOT `@inner_block`) — use `{@inner_content}`
- Do NOT wrap templates with `<Layouts.app>` — causes duplicate flash IDs
- LiveView uses `phx-trigger-action` for session writes (POST to `SessionController`)
- Soft-delete uses `deleted_at` timestamps (not hard delete) for articles and comments
- Federation delivery runs in async `Task` in production but synchronously in tests (`federation_async: false` in `config/test.exs`) to avoid sandbox ownership errors
- All local AP objects (articles, comments, likes, boosts, polls, DMs) are stamped with a canonical `ap_id` on creation (post-insert, since the URI includes the DB-assigned ID). Publisher functions use the stored `ap_id` with fallback to `Federation.actor_uri/2`. The inbox handler walks remote reply chains (up to 10 hops) to resolve intermediate replies that aren't stored locally.
- Only boards with `min_role_to_view == "guest"` and `ap_enabled == true` are federated
- Announce (boost) routing: when a followed actor boosts Article/Page content, it is routed to boards that follow the booster and creates feed items for user followers. Loop-safe: `create_remote_article` does NOT trigger outbound `publish_article_created`, so no re-announce storm. Notes are feed-only (not routed to boards).
- Site actor (instance actor) is discoverable via WebFinger as `acct:site@host` with `preferredUsername: "site"`, resolved before user/board lookups. The `/ap/site` endpoint returns an Organization actor. WebFinger response includes `properties` with `type: "Organization"`.
- Board WebFinger subject must use bare slug (no `!` prefix) matching `preferredUsername` — Mastodon derives WebFinger queries from `preferredUsername` and rejects subject mismatches with 422. The `properties` field with `type: "Group"` disambiguates boards from users (Lemmy convention).
- Focus management: Add `data-focus-target` to the primary content container in list/browse pages. Do not add to form pages or pages with `autofocus`. JS in `app.js` auto-focuses the first interactive element after LiveView navigation. Links get a `focus-visible` inset box-shadow highlight via `app.css`.
- Poll votes are anonymous — DB tracks voters for dedup but UI never reveals individual votes. Polls use denormalized counters (`voters_count`, `votes_count`) updated transactionally via `Ecto.Multi` with `FOR UPDATE` locking.
- Auth hooks: `:require_admin` (admin only), `:require_admin_or_moderator` (admin + moderator), `:require_admin_totp` (admin re-verification, 10-min sudo mode — accepts TOTP or WebAuthn; skips non-admin users), `:require_auth` (any authenticated user), `:optional_auth` (load user if present), `:require_password_auth` (password-verified session), `:redirect_if_authenticated` (guest-only pages), `:rate_limit_mount` (WebSocket mount rate limit)
- WebAuthn challenges: `WebAuthnChallenges.put/2` stores the full `Wax.Challenge` struct (not a plain map) in ETS — Wax needs `challenge.issued_at` and other fields during `Wax.register/3` and `Wax.authenticate/6`. ETS match specs use Erlang atom `:"=<"` (not Elixir `:<=`) for the TTL sweep.
- `wax_` config: `origin` must match `window.location.origin` exactly (scheme + host + port). Set in `runtime.exs` for production, `dev.exs` for dev, `test.exs` for tests (uses per-partition port). A mismatch causes all WebAuthn operations to fail with a client-side `NotAllowedError`.
- Pagination: use `Baudrate.Pagination` for cross-context paginated queries (`paginate_opts/3` + `paginate_query/3`)
- LIKE sanitization: use `Repo.sanitize_like/1` to escape `%`, `_`, `\` in user input for ILIKE queries
- OTP release paths: Never use `:code.priv_dir/1` in module attributes (`@var`) — it resolves to the build directory at compile time, not the release directory. Use `Application.app_dir(:baudrate, "priv/...")` in a function for runtime resolution.
- Avatar sizes are integers `[120, 48, 36, 24]` — never pass string names like `"medium"` to `Avatar.avatar_url/2`
- HTTP Signature signing: `HTTPSignature.sign/5` and `sign_get/3` must NOT return a `"host"` header — `HTTPClient.build_pinned_opts` manages the `Host` header for DNS-pinned connections. Duplicates cause signature verification failures on remote instances.
- Federation outbound delivery: always call `KeyStore.ensure_user_keypair/1` before enqueuing signed activities (Follow, Undo, etc.) to guarantee the user has an RSA keypair
- Settings are cached in ETS via `Baudrate.Setup.SettingsCache`; `set_setting/2` auto-refreshes the cache on success. Direct DB writes to the `settings` table must call `SettingsCache.refresh()` manually.
- Boards are cached in ETS via `Baudrate.Content.BoardCache`; board mutations in `Content` (`create_board`, `update_board`, `delete_board`, `toggle_board_federation`) auto-refresh the cache. Settings cache is disabled in tests via `settings_cache_enabled: false`; board cache runs normally in tests.
- Link previews: async fetch of OG metadata after content save (first URL only). Images are proxied server-side (re-encoded to WebP via libvips). The `link_previews` table is shared/deduplicated by URL hash. Preview cards render via `<.link_preview>` component in `core_components.ex`. Stale previews (>7 days) are refreshed hourly by `SessionCleaner`; orphans (>30 days, no FK refs) are purged.
- AP visibility: articles, comments, and feed items have a `visibility` field (`public`, `unlisted`, `followers_only`, `direct`) derived from `to`/`cc` addressing on ingest via `Federation.Visibility.from_addressing/1`. Local content defaults to `public`. Forwarding permissions respect visibility: only `public`/`unlisted` content is forwardable by non-author/non-admin users.
- Bot accounts: users with `is_bot: true` cannot log in — `authenticate_by_password/2` rejects them. Bot users have `dm_access: "nobody"` and a locked random password. Managed exclusively via `Baudrate.Bots` context and the `/admin/bots` admin UI.
- `published_at` on articles: stores the original publication timestamp from RSS/Atom feed entries (via bot posting). Nil for locally-created articles. Used to preserve original feed entry dates when bots create articles.
- Plain HTML inputs inside `phx-change` forms are reset on every re-render: `<input value={@assign}>` elements not backed by a Phoenix form changeset have their values overwritten by the server assign on each re-render triggered by `phx-change`. Fix: wrap them in a container with `id` + `phx-update="ignore"` so LiveView skips patching that subtree after the initial mount. Example: bot profile field rows in `/admin/bots` edit form.

## Project Conventions

### Principle Maintenance

- Ensure this document is updated to reflect any changes in the workflow and maintain consistency.

### While Planning, Refactoring & Doing Code Review

- When a feature requirement is unclear or ambiguous, seek clarification on definition and scope rather than guessing.
- Each implementation should match specs, open standards, industry standards, and common practices.
- Follow ActivityPub specification

### While Coding

- **Always** consider responsiveness and accessibility for UX/UI; follow the WAI-ARIA specification.
- **Use HTML5 semantic elements** — `<section>` with `aria-labelledby` for headed content areas, `<article>` for self-contained content items in lists, `<aside>` for supplementary content, `<nav>` for navigation. Assign semantic `id` attributes to content containers and unique `id` + semantic CSS class to each list item.
- **Never use bare English strings for user-visible text** — always wrap in `gettext()`. This applies to flash messages, template text, feed metadata, HTML attributes like `title`, and any other text shown to users. Use `gettext()` with `%{var}` interpolation (not string interpolation) for dynamic values. Shared translation helpers (e.g. `translate_role/1`, `translate_status/1`) belong in `BaudrateWeb.Helpers`.
- **Always** keep i18n strings in sync across locale.

### After Every Change

1. Update all relevant documentation (`doc/`, README, `@moduledoc` and `@doc`)
2. Add essential but missing tests to improve test coverage and ensure code quality
3. check if there is any missing or incomplete test
4. check if there is any missing or incomplete locale translations
5. Remove the finishied tasks from TODOs
6. When a bug is discovered, **always** check for similar issues across the project after applying the fix

### Release Engineering

When creating a new release:

1. Update `CHANGELOG.md` with the new version entry (follow [Keep a Changelog](https://keepachangelog.com/) format)
2. Update `version` in `mix.exs` to match the new tag version
3. Commit, push, and create the git tag (e.g. `v1.1.21`)
4. Push the tag (`git push --tags`)
5. Create the GitHub release via `gh release create`

### Code Organization

- Tests in `test/` mirror the `lib/` structure
- Commit by topic — group related files per commit
- Never nest multiple modules in the same file

### Security Rules

- Never use `String.to_atom/1` on user input
- Never put user input in file paths
- Validate at system boundaries (user input, external APIs, federation)
- All federation content is HTML-sanitized before storage
- SSRF-safe remote fetches (reject private/loopback IPs, HTTPS only)
- Rate limit all public endpoints
- File uploads: validate magic bytes; avatars are re-encoded as WebP (EXIF stripped)
- Federation private keys encrypted at rest (AES-256-GCM via `KeyVault`)
- Content size limits: 256 KB AP payload, 64 KB content body
- Remote actor display names sanitized (strip HTML, control chars, truncate)
- Follow OWASP Top 10 to audit common security vulnerabilities

## Testing

- **Always use seed 9527 and 4 partitions** when running the full test suite
- **Always run the full test suite without asking** — never ask for permission to run tests
- `use BaudrateWeb.ConnCase` for LiveView/controller tests; `use Baudrate.DataCase` for context tests
- `setup_user("role_name")` — creates a test user with the given role (seeds roles if needed)
- `log_in_user(conn, user)` — authenticates a connection with session tokens
- `log_in_admin(conn, user)` — authenticates an admin with TOTP sudo mode enabled (sets `admin_totp_verified_at`)
- `errors_on(changeset)` — extracts validation errors as `%{field: [messages]}`
- Rate limiter stubbing: tests use `BaudrateWeb.RateLimiter.Sandbox` — call `set_global_response({:allow, 1})` to bypass rate limits, or `set_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)` for real Hammer backend
- **Test stability is a priority** — tests must pass deterministically across all partitions under concurrent execution, not just in isolation. Never rely on `Process.sleep` for timestamp separation; use explicit timestamps via `Repo.update_all` instead. Queries with user-visible ordering must include a tiebreaker (e.g. `desc: id`) to avoid nondeterminism when timestamps collide.

## Key Entry Points

| File | Purpose |
|------|---------|
| `lib/baudrate_web/router.ex` | Routes with auth live_sessions |
| `lib/baudrate/auth.ex` | Auth context: authentication, user management (blocks, mutes, invites) |
| `lib/baudrate/content.ex` | Content context: boards, articles, comments, polls, permissions |
| `lib/baudrate/federation.ex` | Federation context: actors, outbox, followers, feed items, feed item replies |
| `lib/baudrate/messaging.ex` | Messaging context: DMs, conversations, read cursors |
| `lib/baudrate/setup.ex` | Setup context: roles, settings, role level utilities |
| `lib/baudrate/moderation.ex` | Moderation context: reports, audit log |
| `lib/baudrate/notification.ex` | Notification context: in-app notifications, PubSub |
| `lib/baudrate/bots.ex` | Bots context: RSS/Atom feed bot CRUD, fetch scheduling, deduplication |
| `lib/baudrate_web/live/auth_hooks.ex` | LiveView auth on_mount hooks |
| `lib/baudrate_web/components/core_components.ex` | Shared UI components |
| `doc/development.md` | Full architecture & project structure |
| `doc/sysop.md` | SysOp guide: installation, configuration, maintenance |
