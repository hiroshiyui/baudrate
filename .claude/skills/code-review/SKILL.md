---
name: code-review
description: Perform a project-wide full-scope code review covering correctness, security auditing, test coverage, locale sync, documentation quality, code smells, UI/UX accessibility, and project conventions, then report findings and fix critical issues.
---

When performing a code review, conduct a **full project-wide sweep** — do not limit scope to recent changes. Read broadly across the codebase and apply every check below.

---

## Step 1 — Orient and Plan

Before reviewing, understand the system's current shape:
- Read `CLAUDE.md` for architecture, conventions, and known gotchas
- Skim `lib/` directory structure: all contexts, LiveViews, controllers, components, schemas
- Check `doc/TODOs.md` for known issues that may overlap with findings
- Prioritise: public endpoints, federation boundary, auth flows, content handling, admin routes

---

## Step 2 — Correctness

- Logic errors, off-by-one mistakes, incorrect pattern matches, missing `nil`/`{:error, _}` guards
- Ecto: missing `Repo.preload`, N+1 risks, missing `FOR UPDATE` locks on counter updates (use `Ecto.Multi`), unescaped ILIKE inputs (require `Repo.sanitize_like/1`)
- LiveView: missing `handle_info` clauses for all subscribed PubSub topics, stale socket assigns after redirects, race conditions between `mount` and `handle_params`
- Pagination: uses `Baudrate.Pagination` (`paginate_opts/3` + `paginate_query/3`) — no hand-rolled `LIMIT`/`OFFSET`
- Schema timestamps: `published_at` (original feed entry date, bot posts only) vs `inserted_at` (local creation) — usage must match intent
- Federation: AP objects stamped with `ap_id` post-insert; Publisher falls back to `Federation.actor_uri/2` only when stored `ap_id` is nil
- Soft-delete: articles and comments use `deleted_at`; queries must filter `is_nil(deleted_at)` where appropriate

---

## Step 3 — Security Audit

Information security is the **top priority**. Treat every finding as potentially exploitable.

**Input and injection**
- No `String.to_atom/1` on any external or user input (atom table exhaustion)
- No user input in file paths (path traversal)
- All user-generated and federated HTML sanitized via `Baudrate.Sanitizer.Native` (Ammonia NIF) before storage
- All dynamic assigns in HEEx rendered with `{@var}` (auto-escaped); `{:safe, ...}` never wraps untrusted content (XSS)
- All user values parameterized in Ecto queries; no raw interpolation into `fragment()` (SQL injection)

**Network and federation**
- Remote HTTP fetches: SSRF-safe (reject private/loopback IPs, HTTPS only); use only `Req` (never `HTTPoison`, `Tesla`, `httpc`)
- AP payload ≤ 256 KB, content body ≤ 64 KB enforced at inbox
- Remote actor display names sanitized (strip HTML, control chars, truncate)

**Authentication and authorization**
- Every public LiveView route has the correct `on_mount` hook (`:require_auth`, `:require_admin`, `:require_admin_or_moderator`, `:require_admin_totp`, etc.)
- Admin sudo mode (`:require_admin_totp`) enforced on all admin-only actions — 10-minute TOTP re-verification window
- Bot accounts (`is_bot: true`) rejected by `authenticate_by_password/2`; managed exclusively via `Baudrate.Bots` context
- Rate limiting applied to all public endpoints (auth, registration, AP inbox, API)

**Key material and secrets**
- Federation private keys encrypted via `KeyVault`; TOTP secrets via `TotpVault`; no plaintext secrets in DB or logs
- `KeyStore.ensure_user_keypair/1` called before enqueuing any signed outbound activity
- `HTTPSignature.sign/5` / `sign_get/3` must not return a `"host"` header (causes signature verification failures)

**File handling**
- File uploads: magic bytes validated; avatars re-encoded as WebP (EXIF stripped)
- No user-supplied filenames used directly on the filesystem

**OWASP Top 10 checklist** — cross-check each category:
  A01 Broken Access Control · A02 Cryptographic Failures · A03 Injection · A04 Insecure Design · A05 Security Misconfiguration · A06 Vulnerable Components · A07 Auth Failures · A08 Software Integrity · A09 Logging Failures · A10 SSRF

---

## Step 4 — Test Coverage

- Every public context function and LiveView action has a corresponding test in `test/` mirroring `lib/`
- LiveView/controller tests use `BaudrateWeb.ConnCase`; context tests use `Baudrate.DataCase`
- Security-sensitive paths (auth, federation inbox, file uploads, rate limiting) have dedicated negative-path tests
- No `Process.sleep` for timestamp ordering — use `Repo.update_all` with explicit timestamps instead
- All queries with user-visible ordering include a deterministic tiebreaker (e.g., `desc: :id`)
- Rate limiter stubbed via `BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})` in tests that hit rate-limited paths
- Federation delivery tests run synchronously (`federation_async: false` in `config/test.exs`) — no async Task races
- Tests pass deterministically across all 4 partitions under concurrent execution — no shared mutable state, no order dependencies

---

## Step 5 — Locale Sync

- Every user-visible string is wrapped in `gettext()` — no bare English strings in templates, flash messages, HTML attributes (`title`, `aria-label`, `placeholder`), feed metadata, or error messages
- `%{var}` interpolation used inside `gettext()` — never Elixir string interpolation (`"#{}"`)
- After scanning `lib/` and `priv/gettext/en/`, verify that both `priv/gettext/zh_TW/` and `priv/gettext/ja_JP/` `.po` files contain translations for every `msgid`
- Terminology is consistent across all locales:
  - `Board` → `zh_TW: 看板` (not 版面/板塊), `ja_JP: 掲示板` (not ボード)
  - `User` → `zh_TW: 使用者` (not 用戶)
- No stale/orphaned `msgid` entries remaining in `.po` files after string removal

---

## Step 6 — Documentation Quality

- `@moduledoc` present and accurate for every public-facing module; `@doc` on every public function with non-obvious behaviour
- `doc/development.md` reflects current architecture, contexts, auth flow, federation mechanics
- `doc/sysop.md` reflects current installation, configuration, and maintenance procedures
- `doc/api.md` documents all public AP and web API endpoints
- `doc/TODOs.md` contains no items already completed
- `CLAUDE.md` — stack table, key gotchas, and project conventions match the current codebase
- `README.md` — feature list, prerequisites, and acknowledgements are current
- No commented-out dead code left in place of proper documentation

---

## Step 7 — Code Smells

- **Duplication**: repeated logic across modules that should be extracted into a shared helper or context function
- **Bloated functions**: functions doing more than one thing; complex `with` chains that should be broken into named steps
- **Primitive obsession**: raw strings/integers used where a well-named type, struct, or enum would be clearer
- **Feature envy**: a module reaching deeply into another context's internals instead of calling its public API
- **Unnecessary complexity**: over-engineered abstractions for one-time operations; speculative generality (YAGNI)
- **Stale code**: unused functions, dead branches, obsolete modules, leftover `IO.inspect` / `dbg` calls, commented-out blocks
- **Inconsistent naming**: functions or variables that don't follow Elixir conventions or contradict surrounding code
- **No nested modules in a single file** — one module per file, always
- **OTP paths**: no `:code.priv_dir/1` in module attributes (`@var`); use `Application.app_dir(:baudrate, "priv/...")` in functions (runtime resolution)
- **Cache coherence**: settings and board mutations go through context functions; direct `Repo` writes to `settings`/`boards` must call `SettingsCache.refresh()` / `BoardCache.refresh()` manually
- **Avatar sizes**: integers `[120, 48, 36, 24]` only — never string names

---

## Step 8 — UI/UX and Accessibility (a11y)

**Semantic HTML**
- `<section aria-labelledby="…">` for headed content areas
- `<article>` for self-contained content items in lists
- `<aside>` for supplementary content
- `<nav>` for navigation landmarks
- Semantic `id` attributes on content containers; unique `id` + semantic CSS class on each list item

**WAI-ARIA compliance**
- Interactive elements (buttons, links, inputs) have descriptive labels — either visible text, `aria-label`, or `aria-labelledby`
- Dynamic regions that update without a page navigation use `aria-live` appropriately
- Modal dialogs trap focus and restore it on close; `role="dialog"` + `aria-modal="true"` present
- Icon-only buttons and icon links always have `aria-label` or visually-hidden text
- Form fields have associated `<label>` elements (via `for`/`id` or wrapping); error messages linked via `aria-describedby`

**Keyboard and focus**
- All interactive elements reachable and operable via keyboard alone
- Focus order is logical and follows visual reading order
- `data-focus-target` present on primary content container in list/browse pages for post-navigation auto-focus
- No keyboard traps outside intentional modal dialogs
- Focus-visible ring visible on focused elements (check `app.css` `focus-visible` styles)

**Responsive design**
- Layouts adapt correctly across mobile, tablet, and desktop breakpoints
- No horizontal overflow on small viewports from fixed widths
- Touch targets ≥ 44×44 px on interactive elements

**Colour and contrast**
- Text contrast ratio ≥ 4.5:1 (normal text) / 3:1 (large text) per WCAG 2.1 AA
- Information is not conveyed by colour alone — always paired with text, icon, or pattern

**Layout correctness**
- `{@inner_content}` (not `@inner_block`) in layouts
- Templates not wrapped in `<Layouts.app>` (causes duplicate flash IDs)

---

## Reporting

Present all findings grouped by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | Security vulnerabilities, data loss, auth bypass, key material exposure — fix immediately |
| **Major** | Logic errors, missing test coverage for observable behaviour, broken conventions that cause runtime failures, a11y barriers that block screen-reader or keyboard users |
| **Minor** | Style, clarity, missing docs, i18n gaps, cosmetic a11y issues, minor code smells |

For each finding: cite the **file and line number**, describe the issue, explain the impact, and provide a **concrete fix**.

---

## Fixing

After reporting, **apply fixes for all Critical and Major findings directly**. Then run the full test suite:

```bash
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

Do not consider the review complete until all tests pass. Diagnose and resolve any failures before finishing.
