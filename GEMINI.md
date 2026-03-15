# Baudrate Project Context

Baudrate is an **ActivityPub-enabled Bulletin Board System (BBS)** and public information hub built with Elixir and the Phoenix framework. It follows a philosophy where public content remains visible to all, focusing on hierarchical board structures and federated interaction rather than social networking patterns.

**Information security is the top priority** — this is a public-facing system.

## Quick Reference (Essential Commands)

```bash
# Setup: Requires Elixir 1.15+, PostgreSQL, libvips, and Rust toolchain
mix setup              # Install deps, create DB, build assets
mix phx.server         # Start dev server (https://localhost:4001)

# Testing: Always use seed 9527 for deterministic order
mix test --seed 9527   # Run all tests
mix test --failed      # Re-run previously failed tests
mix precommit          # Pre-commit checks: compile, format, test

# Parallel testing (preferred for full suite):
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait

# Browser Testing:
mix selenium.setup    # Download Selenium + GeckoDriver
mix test --include feature --seed 9527
```

## Tech Stack

- **Language:** Elixir 1.15+ (Erlang/OTP 26+)
- **Web Framework:** Phoenix 1.8 / LiveView 1.1 (Bandit server)
- **Database:** PostgreSQL (via Ecto)
- **Frontend:** Tailwind CSS 4 + DaisyUI, esbuild
- **HTTP Client:** **Req** (Never use HTTPoison, Tesla, or httpc)
- **Native Interop:** Rustler (Rust NIFs) for HTML parsing (`html5ever`) and sanitization (`Ammonia`)
- **Security:** AES-256-GCM encryption, SSRF-safe HTTP client, TOTP (NimbleTOTP)
- **Image Processing:** `image` (libvips NIF) - WebP conversion, EXIF stripping

## Core Architecture & Contexts

- **Baudrate.Content** (`lib/baudrate/content.ex`): **Facade module** for all content logic. Delegates to focused sub-modules:
  - `Articles`, `Boards`, `Comments`, `Polls`, `Search`, `LinkPreview`, `ReadTracking`, `Tags`, `Images`, `Permissions`, `Boosts`, `Likes`.
  - **`Content.Interactions`**: Shared logic for likes/boosts, including visibility checks and transactional AP ID stamping.
- **Baudrate.Federation** (`lib/baudrate/federation.ex`): **Facade module** for ActivityPub logic (Actors, Inboxes, Outbox, Delivery, Signatures).
  - **`Federation.ObjectResolver`**: Two-phase resolution: `fetch/1` (preview) and `resolve/1` (materialize). Loop-safe and deduplicated.
  - **`Federation.Visibility`**: Derives visibility (`public`, `unlisted`, `followers_only`, `direct`) from AP addressing.
- **Baudrate.Auth** (`lib/baudrate/auth.ex`): **Facade module** for RBAC, Session management (dual tokens, rotation), TOTP, blocks, mutes, invite codes.
- **Baudrate.Messaging** (`lib/baudrate/messaging.ex`): 1-on-1 federated DMs and read cursors.
- **Baudrate.Moderation** (`lib/baudrate/moderation.ex`): Content reports and audit logs.
- **Baudrate.Notification** (`lib/baudrate/notification.ex`): Real-time in-app notifications and Web Push.

## Critical Developer "Gotchas"

- **Layouts:** Use `{@inner_content}` (NOT `@inner_block`) in layouts. Do NOT wrap templates with `<Layouts.app>` (causes duplicate flash IDs).
- **Session Writes:** LiveView uses the `phx-trigger-action` pattern to write sessions (POST to `SessionController`).
- **ActivityPub IDs:** All federated objects are stamped with a canonical `ap_id` post-insert. Use `Federation.actor_uri/2` as a fallback.
- **Soft Delete:** Articles and comments use `deleted_at` timestamps; never hard delete federated content.
- **Async vs Sync:** Federation delivery is async in production but **synchronous in tests** (`federation_async: false`) to avoid sandbox errors.
- **WebFinger:** Board subject must use a bare slug (no `!` prefix) to match Mastodon's `preferredUsername` expectations.
- **Polls:** Anonymous voting; counters are updated transactionally via `Ecto.Multi` with `FOR UPDATE` row-level locking.
- **ObjectResolver:** Two-phase resolution: `fetch/1` (preview) and `resolve/1` (materialize). Loop-safe and deduplicated.
- **OTP Releases:** Never use `:code.priv_dir/1` in module attributes. Use `Application.app_dir(:baudrate, "priv/...")` at runtime.
- **HTTP Signatures:** `HTTPSignature.sign/5` must **not** return a `"host"` header; this is managed by `HTTPClient.build_pinned_opts`.

## Development Conventions

### While Coding
- **Business Logic:** Always use the context facades (`Baudrate.Content`, `Baudrate.Auth`, `Baudrate.Federation`). Avoid calling sub-modules directly from the web layer.
- **Internationalization (i18n):** Never use bare English strings for UI text. Wrap in `gettext()`. Shared helpers belong in `BaudrateWeb.Helpers`.
- **Semantic HTML:** Use `<section>`, `<article>`, `<aside>`, and `<nav>`. Use `data-focus-target` for post-navigation focus management.
- **Accessibility:** Follow WAI-ARIA specs. Assign semantic `id` attributes to content containers.

### Security Mandates
- **No Unsafe Atoms:** Never use `String.to_atom/1` on user input.
- **Path Safety:** Never put user input in file paths.
- **Boundary Validation:** Validate all input at system boundaries (AP inboxes, forms).
- **SSRF Prevention:** Use `Baudrate.Federation.HTTPClient` (rejects private/loopback IPs, HTTPS only, DNS pinned).
- **HTML Sanitization:** Sanitize all incoming/outgoing content via Ammonia NIF before storage.
- **Login Security:** Use progressive delay (not hard lockout) for brute-force protection to avoid account DoS.

### Testing Strategy
- **Seed 9527:** Always use seed 9527 for deterministic test execution.
- **Test Stability:** Ensure tests pass deterministically across parallel partitions. Use explicit timestamps or `Repo.update_all` instead of `Process.sleep`.
- **Macros:** Use `setup_user("role")`, `log_in_user(conn, user)`, and `log_in_admin(conn, user)` (for TOTP sudo mode).
- **Rate Limiting:** Bypass via `BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})` in tests.

## Release Engineering
1. Update `CHANGELOG.md` (Keep a Changelog format).
2. Update `version` in `mix.exs`.
3. Commit, push, and create a git tag (e.g., `v1.3.25`).
4. Push tags and create a GitHub release.

## Documentation Reference
- `doc/development.md`: Detailed architecture and logic flows.
- `doc/sysop.md`: Installation and maintenance guide.
- `doc/api.md`: ActivityPub endpoint reference.
- `doc/TODOs.md`: Roadmap and pending tasks.
- `doc/troubleshooting.md`: Common issues and debug steps.

## Gemini CLI Specifics
- **Commit Co-Author:** Always include `Co-authored-by: Gemini <gemini@google.com>` at the end of every Git commit message.
