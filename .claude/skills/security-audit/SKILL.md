---
name: security-audit
description: Perform a dedicated, project-wide security audit of Baudrate — injection, XSS, SSRF, authentication/authorization, federation trust boundaries, key material, file handling, rate limiting, and dependencies — mapped to the OWASP Top 10, then report findings by severity and fix critical issues.
---

Information security is the **top priority** of this project — it is a public-facing,
federated system. Conduct a **full project-wide security sweep**: every finding is
potentially exploitable by an anonymous remote attacker until proven otherwise.

This skill audits security only. For correctness, tests, docs, and a11y, use `code-review`.

---

## Step 1 — Orient and Threat-Model

Before auditing, map the attack surface:

- Read `CLAUDE.md` (Security Rules, Key Gotchas) and `doc/development.md`
- Enumerate trust boundaries, most-exposed first:
  1. **Federation inbox** (`lib/baudrate/federation/inbox_handler.ex`, `activity_pub_controller.ex`) — unauthenticated remote JSON, signed by arbitrary actors
  2. **Public web endpoints** — registration, login, password reset, WebFinger, NodeInfo, feeds
  3. **Authenticated user input** — articles, comments, DMs, polls, profiles, uploads, search
  4. **Bot/feed ingestion** (`lib/baudrate/bots.ex`) — remote RSS/Atom/JSON feeds, favicons
  5. **Link preview fetcher** — attacker-influenced URLs fetched server-side
  6. **Admin surface** — every route under `/admin`, sudo-mode enforcement
- Skim `mix.exs` / `mix.lock` and `native/` (Rust NIF crates) for the dependency inventory

---

## Step 2 — Injection and Output Encoding

- No `String.to_atom/1` on any external input (atom table exhaustion); `String.to_existing_atom/1` only with a rescue and a known-atom allowlist
- No user input in file paths (path traversal); no user-supplied filenames on the filesystem
- All Ecto queries parameterized; no interpolation of user values into `fragment()` (SQL injection)
- ILIKE/LIKE inputs escaped via `Repo.sanitize_like/1` (`%`, `_`, `\`)
- All user-generated and federated HTML sanitized via `Baudrate.Sanitizer.Native` (Ammonia NIF) **before storage**, never only at render time
- HEEx: all dynamic values rendered with `{@var}` (auto-escaped); `raw/1` / `{:safe, ...}` never wraps untrusted content (XSS); audit every `raw(` call site
- No user input in shell commands, `Code.eval_*`, or `:erlang.binary_to_term/1` (unsafe deserialization)
- Remote actor display names sanitized: strip HTML, control chars, truncate
- Markdown rendering (Earmark) output passes through `sanitize_markdown/1`

---

## Step 3 — SSRF and Outbound Requests

- HTTP client is `Req` only — flag any `HTTPoison`, `Tesla`, or `:httpc` usage
- Every server-side fetch of a remote URL (actor documents, feeds, favicons, link previews, avatars, Web Push) goes through the SSRF guard: reject private/loopback/link-local IPs (IPv4 **and** IPv6, including mapped/embedded forms), HTTPS only
- DNS rebinding: outbound requests use the DNS-pinned transport (`HTTPClient.build_pinned_opts`); non-AP POSTs (e.g. Web Push) go through `Federation.HTTPClient.post_raw/3`, never raw `Req.post`
- Redirect handling: redirects re-validated against the SSRF guard, bounded hop count
- Response size limits enforced on all fetched bodies (AP payload ≤ 256 KB, content ≤ 64 KB, image/feed fetches bounded)

---

## Step 4 — Federation Trust Boundary

- **HTTP Signature verification** on all inbox deliveries; `HTTPSignature.sign/5` / `sign_get/3` must not emit a `"host"` header (breaks remote verification)
- **Actor origin-binding**: `ActorResolver` rejects actor documents whose `id` host differs from the fetch URL (`:actor_id_origin_mismatch`) — never trust `json["id"]` blindly (cache poisoning)
- **Inbound `Move`**: target actor must claim the mover in `alsoKnownAs` (force-refreshed) or reject with `:move_not_authorized` (follower hijack)
- Object/actor attribution checks: activity `actor` must match the signature's key owner; `Create` object `attributedTo` must match the actor (spoofed authorship)
- `Delete`/`Undo`/`Update` only honored from the owning actor
- Non-federated boards: inbox/outbox/actor endpoints 404; Follow → `Reject(Follow)`; verify the documented Like/Announce exceptions are not wider than specified
- Reply-chain walking bounded (≤ 10 hops); recursive fetches cannot be driven unbounded by a hostile instance
- Visibility (`Federation.Visibility.from_addressing/1`) correctly derived on ingest; `followers_only`/`direct` content never leaks into public views or feeds
- Payload size, depth, and collection-page limits enforced before JSON processing

---

## Step 5 — Authentication and Session Management

- `authenticate_by_password/2` rejects bot accounts (`is_bot: true`) and uses constant-time comparison; no user-enumeration oracle in login, registration, or password-reset responses
- Session state machine (Unauthenticated → Password → TOTP → Authenticated) cannot be skipped; TOTP required for admin/moderator
- TOTP secrets encrypted at rest (`TotpVault`, AES-256-GCM); no secrets in logs
- WebAuthn: `wax_` `origin` matches exactly per environment; challenges stored as full `Wax.Challenge` structs with TTL sweep
- Password reset tokens: single-use, expiring, hashed at rest; session tokens rotated on privilege change
- Admin sudo (`:require_admin_totp`): 10-minute window enforced on **all** admin mutations; 5-attempt lockout
- `phx-trigger-action` session writes POST to controllers with CSRF protection intact

---

## Step 6 — Authorization and Access Control

- Every LiveView route sits in the correct `live_session` with the right `on_mount` hook (`:require_admin`, `:require_admin_or_moderator`, `:require_admin_totp`, `:require_auth`, `:optional_auth`, `:require_password_auth`, `:redirect_if_authenticated`)
- **Re-check authorization in every `handle_event`** — mount-time checks alone are insufficient (stale socket privilege)
- Context-boundary enforcement: DM authorization in `Messaging.create_message/3` (not just conversation start); board `min_role_to_view`/`min_role_to_post` checked on read **and** write paths, including AP endpoints, search, and feeds
- IDOR: every fetch-by-id scoped to the current user or permission-checked (articles, comments, DMs, notifications, invite codes, uploads)
- Blocking controls interaction, not visibility (project principle) — but blocked/muted users must not be able to DM, reply-notify, or otherwise interact
- Moderator powers limited to their scope (no editing others' articles); SysOp board protected (`delete_board` → `:protected`)
- Poll anonymity: no code path or API response reveals individual voters

---

## Step 7 — Key Material, Secrets, and Crypto

- Federation private keys encrypted at rest via `KeyVault` (AES-256-GCM); TOTP secrets via `TotpVault`
- No plaintext secrets in DB, logs, error reports, or AP JSON output (public key only)
- `KeyStore.ensure_user_keypair/1` called before enqueuing signed activities; `Delivery.get_private_key/1` self-healing, never leaks bare `:error`
- Vault key sourcing from runtime env (`runtime.exs`), never compiled in; no secrets committed to the repo (scan for accidental keys/tokens)
- Randomness from `:crypto.strong_rand_bytes/1` for tokens, invite codes, challenges — never `:rand` for security material

---

## Step 8 — File Uploads and Media

- Magic-byte validation on all uploads; declared Content-Type never trusted
- Avatars/images re-encoded to WebP via libvips (EXIF stripped) — original bytes never served
- Size limits enforced pre-processing (decompression-bomb protection via libvips limits)
- Upload storage paths server-generated; no user-controlled path components
- Link-preview images proxied and re-encoded server-side, never hotlinked

---

## Step 9 — Rate Limiting and Abuse Resistance

- All public endpoints rate-limited (Hammer): login, registration, password reset, TOTP attempts, AP inbox, WebFinger, search, DM send, report submission, WebSocket mount (`:rate_limit_mount`)
- Registration modes (`open` / `approval_required` / `invite_only`) enforced server-side; invite quota (5/30 days, 7-day min age, 7-day expiry) not bypassable
- Federation delivery retry/backoff cannot be weaponized for amplification; per-instance failure tracking
- Content size limits enforced at every ingress (256 KB AP payload, 64 KB body)

---

## Step 10 — Configuration and Logging

- Security headers on all responses: CSP, `x-frame-options`/frame-ancestors, `x-content-type-options`, referrer-policy; HTTPS enforced with HSTS in production
- Cookies: `secure`, `http_only`, `same_site` set on session cookies
- Debug/dev routes (`/dev/*`, LiveDashboard) unreachable in production config
- Error handling: no stack traces or internal details in user-facing/federation responses
- Security-relevant events logged (failed logins, sudo failures, signature rejections, SSRF blocks) — without logging secrets, tokens, or full request bodies
- OTP release paths: no `:code.priv_dir/1` in module attributes

---

## Step 11 — Dependency Vulnerabilities (OWASP A06)

Known-vulnerable dependencies are a first-class part of the audit, not an
afterthought — a shipped CVE in a transitive package is exploitable even when
every line of app code is perfect. Scan **every** ecosystem (see the
`check-updates` skill for the full mechanics):

- **Elixir/Hex — always run `mix hex.audit`.** It reports both *retired* packages
  and packages with *security advisories* (from the Erlang Ecosystem Foundation /
  GHSA / OSV feeds). Also run `mix deps.audit` if `mix_audit` is present.
- **Rust NIF crates** — check each `native/*/Cargo.toml` version against advisories
  (`cargo audit` / osv.dev). `ammonia` (sanitizer) and `scraper`/`html5ever`
  (parser) sit on the XSS/federation boundary — treat their advisories as critical.
- **Frontend** — check the pinned esbuild/Tailwind versions and the vendored
  daisyUI against npm advisories.

For every advisory, triage on three axes before rating it:

1. **Exposure scope — production vs test-only.** Use `mix deps.tree` to find who
   pulls it. A HIGH advisory in a `only: :test` dependency (e.g. `hackney`/`tesla`
   pulled by `wallaby`) is **not shipped** — real, but not production-exploitable.
   A MEDIUM in a production dependency (e.g. `decimal` via `ecto`) outranks it.
2. **Fix availability — update vs replace.** Prefer bumping to the patched version.
   But some advisories have **no fix in the current major line** — the package is
   unmaintained/retired and must be **replaced**, not updated (this project moved
   the retired `earmark`, which had an unpatched stored-XSS CVE, to `mdex`). A
   coupled bump may be required (e.g. `decimal` v3's DoS mitigation only ships via
   `ecto` 3.14).
3. **Existing mitigation.** Note any defense-in-depth that already contains the
   flaw (e.g. all Markdown output passes through the Ammonia allowlist, so a
   renderer's HTML-injection CVE is contained) — it lowers urgency but does not
   substitute for the fix.

Report each finding with: package, **current → fixed version** (or "no fix —
replace with X"), severity, **production vs test-only**, the advisory ID
(CVE/GHSA/EEF), and any mitigation. A retired-but-unpatched dependency on the
security boundary is a Critical/Major finding, not a housekeeping note.

---

## Step 12 — OWASP Top 10 Cross-Check

Explicitly close out each category, citing where it was checked:

| Category | Primary audit steps |
|----------|--------------------|
| A01 Broken Access Control | 5, 6 |
| A02 Cryptographic Failures | 5, 7 |
| A03 Injection | 2 |
| A04 Insecure Design | 1, 4, 9 |
| A05 Security Misconfiguration | 10 |
| A06 Vulnerable & Outdated Components | 11 |
| A07 Identification & Auth Failures | 5 |
| A08 Software & Data Integrity Failures | 4, 7 |
| A09 Logging & Monitoring Failures | 10 |
| A10 SSRF | 3 |

---

## Reporting

Present all findings grouped by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | Remotely exploitable: auth bypass, injection, SSRF, key/secret exposure, IDOR on private data, federation spoofing |
| **Major** | Exploitable with preconditions: missing rate limits, weak validation, information disclosure, missing negative-path enforcement |
| **Minor** | Hardening opportunities: missing headers, defense-in-depth gaps, logging improvements |

For each finding: cite the **file and line number**, describe the vulnerability, give a
concrete **attack scenario** (who, from where, with what payload), and provide a **concrete fix**.
If a category was audited and found clean, say so explicitly — silence is not a clean bill.

---

## Fixing

Apply fixes for all **Critical** and **Major** findings directly. Add regression tests for each
fix (negative-path tests in `test/` mirroring `lib/`). Then run the full test suite:

```bash
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

The audit is not complete until all tests pass. When a vulnerability class is found once,
**always sweep the whole project for other instances of the same class** before finishing.
