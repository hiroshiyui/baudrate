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

Key gotchas to keep in mind:

- Layout receives `@inner_content` (NOT `@inner_block`) — use `{@inner_content}`
- Do NOT wrap templates with `<Layouts.app>` — causes duplicate flash IDs
- LiveView uses `phx-trigger-action` for session writes (POST to `SessionController`)

## Project Conventions

### While Planning

- When a feature requirement is unclear, ambiguous, please seek clarification on definition and scope rather than guessing.
- Each implementation should matches specs and industry standards and common practices.
- Alway consider to improve responsiveness and accessibility for UX/UI.

### After Every Change

1. Update all relevant documentation (`doc/`, README, moduledocs)
2. Add essential but missing tests to improve test coverage and ensure code quality
3. Keep i18n strings in sync across locales

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

## Key Entry Points

| File | Purpose |
|------|---------|
| `lib/baudrate_web/router.ex` | Routes with auth live_sessions |
| `doc/development.md` | Full architecture & project structure |
