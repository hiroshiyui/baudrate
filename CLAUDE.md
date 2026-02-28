# Baudrate

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
| Database | PostgreSQL (Ecto) |
| CSS | Tailwind CSS + DaisyUI |
| HTTP client | Req (never use HTTPoison, Tesla, or httpc) |
| 2FA | NimbleTOTP + EQRCode |
| HTML sanitization | Ammonia (Rust NIF via Rustler) — requires Rust toolchain |
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |
| i18n | Gettext — zh_TW and ja_JP locales |

## Architecture

See [`doc/development.md`](doc/development.md) for full architecture documentation
(contexts, auth flow, sessions, RBAC, layout system, federation, etc.).

### Contexts

- **Auth** (`lib/baudrate/auth.ex`) — authentication (login, registration, TOTP, sessions, password reset), user management (avatars, invite codes, blocks, mutes)
- **Content** (`lib/baudrate/content.ex`) — boards, articles, comments, likes, permissions, board moderators, search
- **Federation** (`lib/baudrate/federation.ex`) — AP actors, outbox, followers, announces, delivery, user outbound follows
- **Messaging** (`lib/baudrate/messaging.ex`) — 1-on-1 direct messages, conversations, DM access control, federation
- **Setup** (`lib/baudrate/setup.ex`) — first-run wizard, RBAC seeding, settings, role level utilities
- **Moderation** (`lib/baudrate/moderation.ex`) — reports, resolve/dismiss, audit log
- **Notification** (`lib/baudrate/notification.ex`) — in-app notifications, unread counts, mark read, cleanup, admin announcements

### Key Gotchas

- Layout receives `@inner_content` (NOT `@inner_block`) — use `{@inner_content}`
- Do NOT wrap templates with `<Layouts.app>` — causes duplicate flash IDs
- LiveView uses `phx-trigger-action` for session writes (POST to `SessionController`)
- Soft-delete uses `deleted_at` timestamps (not hard delete) for articles and comments
- Federation delivery runs in async `Task` in production but synchronously in tests (`federation_async: false` in `config/test.exs`) to avoid sandbox ownership errors
- `can_manage_article?/2` is a backward-compat alias for `can_edit_article?/2` — prefer the granular functions (`can_edit_article?`, `can_delete_article?`, `can_pin_article?`, `can_lock_article?`)
- Only boards with `min_role_to_view == "guest"` and `ap_enabled == true` are federated
- Focus management: Add `data-focus-target` to the primary content container in list/browse pages. Do not add to form pages or pages with `autofocus`. JS in `app.js` auto-focuses the first interactive element after LiveView navigation.

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
- `errors_on(changeset)` — extracts validation errors as `%{field: [messages]}`
- Async tests using Mox **must** call `Mox.set_mox_private()` in setup to avoid stub leaks between concurrent tests
- **Test stability is a priority** — tests must pass deterministically across all partitions under concurrent execution, not just in isolation. Never rely on `Process.sleep` for timestamp separation; use explicit timestamps via `Repo.update_all` instead. Queries with user-visible ordering must include a tiebreaker (e.g. `desc: id`) to avoid nondeterminism when timestamps collide.

## Key Entry Points

| File | Purpose |
|------|---------|
| `lib/baudrate_web/router.ex` | Routes with auth live_sessions |
| `lib/baudrate/auth.ex` | Auth context: authentication, user management (blocks, mutes, invites) |
| `lib/baudrate/content.ex` | Content context: boards, articles, comments, permissions |
| `lib/baudrate/federation.ex` | Federation context: actors, outbox, followers |
| `lib/baudrate/messaging.ex` | Messaging context: DMs, conversations, read cursors |
| `lib/baudrate/setup.ex` | Setup context: roles, settings, role level utilities |
| `lib/baudrate/moderation.ex` | Moderation context: reports, audit log |
| `lib/baudrate/notification.ex` | Notification context: in-app notifications, PubSub |
| `lib/baudrate_web/live/auth_hooks.ex` | LiveView auth on_mount hooks |
| `lib/baudrate_web/components/core_components.ex` | Shared UI components |
| `doc/development.md` | Full architecture & project structure |
| `doc/sysop.md` | SysOp guide: installation, configuration, maintenance |
