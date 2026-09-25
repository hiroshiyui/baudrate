---
name: security-audit
description: Dedicated project-wide security audit of Baudrate — injection, XSS, SSRF, auth, authorization, federation trust, secrets, uploads, rate limits, dependencies — mapped to the OWASP Top 10, then report by severity, fix Critical/Major, and sweep for each class.
---

Information security is the **top priority**: a public, federated system. Treat every
finding as exploitable by an anonymous remote attacker until proven otherwise. Security
only; for correctness, tests, docs and a11y use `code-review`. The invariants below are
stated in `CLAUDE.md` (long form: `doc/gotchas.md`); check the code against them.

## 1. Threat model
Read `CLAUDE.md` and `doc/development.md`. Boundaries, most exposed first: the
federation inbox (`inbox_handler.ex`, `activity_pub_controller.ex`); public web
endpoints (register, login, recovery, WebFinger, NodeInfo, feeds); authenticated input
(posts, DMs, polls, profiles, uploads, search); bot feeds; link previews; `/admin`.
Inventory `mix.lock` and `native/`.

## 2. Injection and output
- No `String.to_atom/1` on input; `to_existing_atom` only with an allow-list.
- No input in file paths, shell, `Code.eval_*`, `binary_to_term`.
- Ecto parameterized; nothing interpolated into `fragment`; ILIKE via `Repo.sanitize_like/1`.
- HTML sanitized (Ammonia NIF) **before storage**; Markdown output sanitized; stored
  content rendered through `SafeHTML`; audit every `raw(`/`{:safe, …}`.
- Remote names through `Federation.Sanitizer` (HTML, control chars, bidi, length).

## 3. SSRF and outbound
Req only, through `Federation.HTTPClient` (DNS-pinned, HTTPS, `private_ip?/1` for every
IPv4/IPv6 form, redirects re-checked and bounded, bodies capped while streaming);
non-AP POSTs via `post_raw/3`. Every fetch: actors, objects, feeds, favicons,
previews, avatars, media proxy, Web Push.

## 4. Federation trust (ADR 0046)
Signature on every inbox delivery; no `host` header from `sign`/`sign_get`;
`same_host?/2` origin rules for actors, activities, objects, announces, Accept/Reject;
`Move` needs `alsoKnownAs`; Delete/Undo/Update only from the owner; the inbound and
outbound board gates (ADR 0004/0043); bounded reply-chain walk; visibility derived on
ingest and non-public rows never on public surfaces; payload size checked before parsing;
RSA ≥ 2048.

## 5. Authentication and sessions
Bots cannot log in; constant-time comparison; no enumeration oracle; the session state
machine cannot be skipped; TOTP single-use and encrypted; WebAuthn origin exact and
challenges popped by purpose; factor changes re-authenticate (ADR 0022); admin sudo on
every admin mutation; recovery rules (ADR 0058/0067); CSRF on `phx-trigger-action` POSTs.

## 6. Authorization
Right `live_session`/`on_mount` per route; re-check in every `handle_event`; context
functions enforce (DMs, board view/post on read **and** write incl. AP, search, feeds);
IDOR on every id a client supplies (`timeline_item_accessible?/2`, reports, uploads,
notifications); `ensure_can_interact/1` and `check_post/4` on every posting path; blocks
both ways; moderator scope; poll anonymity.

## 7. Secrets and crypto
Keyring vaults only (ADR 0038); nothing secret in logs, errors or AP JSON; keys from
runtime env; `:crypto.strong_rand_bytes` for tokens; scan the repo for committed secrets.
Never print a decrypted secrets line.

## 8. Uploads and media
Magic bytes, re-encode (EXIF stripped), size limits before processing, server-made
paths, remote images only through the media proxy (ADR 0006/0045).

## 9. Abuse resistance
Rate limits on every public endpoint and mount; registration modes, proof of work and
IP bans server-side; invite quota; delivery backoff and circuits cannot amplify; size
limits at every ingress.

## 10. Configuration and logging
CSP, frame-ancestors, nosniff, referrer policy, HSTS; cookie flags; no dev routes in
prod; no stack traces to users or peers; security events logged without secrets;
`RealIp` fail-closed.

## 11. Dependencies (OWASP A06)
`mix hex.audit` always (and `mix deps.audit` if present); Rust crates against
advisories (`ammonia`, `scraper`/`html5ever` are critical); esbuild/Tailwind/daisyUI.
Triage each: production vs test-only (`mix deps.tree`), update vs replace (retired and
unpatched means replace), existing mitigation. Report package, current → fixed,
severity, scope, advisory id.

## 12. OWASP close-out
A01 → 5, 6 · A02 → 5, 7 · A03 → 2 · A04 → 1, 4, 9 · A05 → 10 · A06 → 11 · A07 → 5 ·
A08 → 4, 7 · A09 → 10 · A10 → 3. Name where each was checked.

## Report
**Critical:** remotely exploitable (auth bypass, injection, SSRF, secret exposure, IDOR
on private data, federation spoofing). **Major:** exploitable with preconditions
(missing rate limit, weak validation, disclosure). **Minor:** hardening. Each finding:
`file:line`, the attack (who, from where, what payload), the fix. Say which categories
are clean.

## Fix
Fix Critical and Major with negative-path regression tests, sweep the whole project for
each class found, run the full suite (seed 9527, 4 partitions). Not done until it passes.
