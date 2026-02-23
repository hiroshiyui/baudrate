# Baudrate

Public BBS / Web Forum built with Elixir/Phoenix + LiveView, federating via **ActivityPub**.
**Information security is the top priority** — this is a public-facing system.

## Quick Reference

```bash
mix setup              # Install deps, create DB, build assets
mix phx.server         # Start dev server (https://localhost:4001)
mix test               # Run all tests
mix test path/to/test  # Run specific test file
mix test --failed      # Re-run previously failed tests
mix precommit          # Pre-commit checks: compile --warnings-as-errors, unlock unused, format, test
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
| Federation | ActivityPub (HTTP Signatures, JSON-LD) |
| i18n | Gettext — zh_TW and ja_JP locales |

## Architecture

See [`doc/development.md`](doc/development.md) for full architecture documentation
(contexts, auth flow, sessions, RBAC, layout system, federation, etc.).

### Contexts

- **Auth** (`lib/baudrate/auth.ex`) — login, registration, TOTP, sessions, avatars, invite codes, password reset
- **Content** (`lib/baudrate/content.ex`) — boards, articles, comments, likes, permissions, board moderators, search
- **Federation** (`lib/baudrate/federation.ex`) — AP actors, outbox, followers, announces, delivery
- **Messaging** (`lib/baudrate/messaging.ex`) — 1-on-1 direct messages, conversations, DM access control, federation
- **Setup** (`lib/baudrate/setup.ex`) — first-run wizard, RBAC seeding, settings, role level utilities
- **Moderation** (`lib/baudrate/moderation.ex`) — reports, resolve/dismiss, audit log

### Key Gotchas

- Layout receives `@inner_content` (NOT `@inner_block`) — use `{@inner_content}`
- Do NOT wrap templates with `<Layouts.app>` — causes duplicate flash IDs
- LiveView uses `phx-trigger-action` for session writes (POST to `SessionController`)
- Soft-delete uses `deleted_at` timestamps (not hard delete) for articles and comments
- Federation delivery runs in async `Task` in production but synchronously in tests (`federation_async: false` in `config/test.exs`) to avoid sandbox ownership errors
- `can_manage_article?/2` is a backward-compat alias for `can_edit_article?/2` — prefer the granular functions (`can_edit_article?`, `can_delete_article?`, `can_pin_article?`, `can_lock_article?`)
- Only boards with `min_role_to_view == "guest"` and `ap_enabled == true` are federated

## Project Conventions

### Principle Maintenance

- Ensure this document is updated to reflect any changes in the workflow and maintain consistency.

### While Planning & Doing Code Review

- When a feature requirement is unclear or ambiguous, seek clarification on definition and scope rather than guessing.
- Each implementation should match specs, open standards, industry standards, and common practices.
- Always consider responsiveness and accessibility for UX/UI; follow the WAI-ARIA specification.
- Follow ActivityPub specification.
- Follow OWASP Top 10 to audit common security vulnerabilities.

### After Every Change

1. Update all relevant documentation (`doc/`, README, moduledocs)
2. Add essential but missing tests to improve test coverage and ensure code quality
3. Keep i18n strings in sync across locales. Rather than using fuzzy matching for uncertain translations, let the messages fallback to English to avoid inaccuracies.
4. Always consider responsiveness and accessibility for UX/UI; follow the WAI-ARIA specification.
5. Follow ActivityPub specification.
6. Follow OWASP Top 10 to audit common security vulnerabilities.

### Code Organization

- Tests in `test/` mirror the `lib/` structure
- Commit by topic — group related files per commit
- Never nest multiple modules in the same file
- Refactor regularly and resolve technical debt

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

## Testing

- `use BaudrateWeb.ConnCase` for LiveView/controller tests; `use Baudrate.DataCase` for context tests
- `setup_user("role_name")` — creates a test user with the given role (seeds roles if needed)
- `log_in_user(conn, user)` — authenticates a connection with session tokens
- `errors_on(changeset)` — extracts validation errors as `%{field: [messages]}`
- Tests mirror `lib/` structure under `test/`

## Key Entry Points

| File | Purpose |
|------|---------|
| `lib/baudrate_web/router.ex` | Routes with auth live_sessions |
| `lib/baudrate/auth.ex` | Auth context: login, registration, TOTP, sessions |
| `lib/baudrate/content.ex` | Content context: boards, articles, comments, permissions |
| `lib/baudrate/federation.ex` | Federation context: actors, outbox, followers |
| `lib/baudrate/messaging.ex` | Messaging context: DMs, conversations, read cursors |
| `lib/baudrate/setup.ex` | Setup context: roles, settings, role level utilities |
| `lib/baudrate/moderation.ex` | Moderation context: reports, audit log |
| `lib/baudrate_web/live/auth_hooks.ex` | LiveView auth on_mount hooks |
| `lib/baudrate_web/components/core_components.ex` | Shared UI components |
| `doc/development.md` | Full architecture & project structure |
