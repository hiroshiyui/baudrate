# 0006 — No third-party subresources: proxy all remote media

- **Status:** Accepted; the one thing a reader may deliberately load from
  elsewhere — an embedded video player, behind a click — is recorded in
  [0045](0045-the-video-player-loads-on-a-click.md)
- **Date:** 2026-08-08 (v1.12.0)

## Context

A federated page is assembled from many instances' content: remote actor
avatars, federated attachments, feed-item images, RSS bot article bodies,
images in user Markdown. If any of those render as an `<img>` pointing at the
originating host, then every viewer's IP address, User-Agent and reading time
is disclosed to every one of those hosts — including hosts run specifically to
harvest that. For a public information hub whose readers include people who did
not consent to being enumerated, that is unacceptable.

The naive fix, "rewrite URLs when we ingest content", leaves every row written
before the fix still hotlinking, and needs a backfill migration for content
whose original URL we would then have thrown away.

## Decision

**No page may emit a subresource pointing at a host we do not control.** CSP
enforces it with `img-src 'self' data: blob:`.

Every remote image URL is rewritten to `/media/<signature>/<encoded-url>` and
served by `BaudrateWeb.MediaController` from a locally re-encoded WebP copy:

| Module | Role |
|---|---|
| `Media.Proxy` | `url/1` signs, `verify/2` checks |
| `Media.Cache` | SSRF-safe fetch → magic bytes → libvips WebP → `uploads/media_cache/<sha256>.webp` |
| `Media.NegativeCache` | 1 h suppression of retries for failed URLs |
| `Media.Rewriter` | `rewrite_img_src/1` over already-sanitized HTML |
| `BaudrateWeb.SafeHTML` | `body_html/1` — use instead of bare `raw/1` |

Four design constraints, each of which is load-bearing:

1. **Deterministic signing.** HMAC-SHA256 over the URL alone — never
   `Phoenix.Token.sign/3`. Its embedded timestamp mints a new `src` on every
   render, defeating browser caching and producing a LiveView diff for every
   avatar on every patch.
2. **Not an open proxy.** Only a URL this instance itself signed can be
   fetched, and the fetch still goes through the SSRF-safe, DNS-pinned client
   (ADR 0007). SVG is never accepted or served.
3. **Rewrite at render, not at ingest.** `Markdown.to_html/1` and
   `SafeHTML.body_html/1` apply the rewrite, which covers every row written
   before the proxy existed with no migration, and preserves the canonical
   remote URL so a failed fetch stays retryable.
4. **Storage location is forced by ops.** systemd `ReadWritePaths` grants write
   access only to `shared/uploads`, and nginx denies `/uploads/media_cache/`
   directly so the signature cannot be bypassed.

Failures negative-cache for one hour and redirect to
`/images/media-unavailable.svg`. Eviction runs hourly in `SessionCleaner`:
untouched for 30 days, then oldest-first under `:media_cache_max_bytes` (2 GB).

`test/baudrate_web/no_hotlink_test.exs` is the acceptance gate — it seeds every
historical hotlinking source and asserts no rendered page contains an absolute
or protocol-relative `<img src>`.

## Consequences

- Viewers are not enumerable by remote instances.
- The instance bears the bandwidth and disk cost of every remote image, and
  fetches them under its own IP — which remote hosts can see.
- Any new template or ingest path that emits remote media must route through
  `Media.Proxy.url/1` or `SafeHTML.body_html/1`; a bare `raw(@body_html)` is a
  regression and the no-hotlink test is what catches it.

## Alternatives considered

- **`referrerpolicy="no-referrer"` on hotlinked images.** Rejected: hides the
  referring page, not the viewer's IP.
- **Rewrite at ingest.** Rejected: needs a backfill, discards the retryable
  canonical URL.
- **`Phoenix.Token` signing.** Rejected: non-deterministic output, see above.
