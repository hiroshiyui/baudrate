# 0079 — A bound is checked before the work it bounds

- **Status:** Accepted
- **Date:** 2026-10-30
- **Deciders:** Baudrate maintainers
- **Related:** [0012](0012-rate-limiting-behaviour-and-failure-modes.md)
  (rate limiting), [0006](0006-media-proxy-no-third-party-subresources.md)
  (the media proxy re-encodes). Found by the 2026-10-30 security audit, as
  one shape in several places.

## Context

Baudrate had a limit for everything the audit looked at, and in several
places the limit was checked after the cost had been paid, or keyed so that
it could be stepped around:

- Every image pipeline capped the **bytes** and then handed the image to
  libvips, which decodes on first pixel access. A 282-byte PNG declaring
  20 000 × 20 000 pixels passed the byte cap and decoded to 1.2 GB.
- The 256 KB federation payload cap ran in a plug *after* `Plug.Parsers` had
  read and JSON-decoded the inbox body at the 1 MB limit sized for uploads.
- Every per-IP rate limit keyed on the full IPv6 address. A residential
  allocation is a /64, so one client held 2^64 fresh buckets for login,
  registration, search and the inbox.
- A search query had no length; a remote poll had no option count; counts
  off the wire went into `change/2`, so a string raised in the adapter.

Each was a correct bound in the wrong place.

## Decision

**A bound is checked before the expensive step, on the input that decides the
cost, by the key the attacker cannot multiply.**

1. `Baudrate.Media.ImageBounds.validate/1` reads the header and refuses over
   40 megapixels or 12 000 pixels a side, immediately after `Image.open` or
   `Image.from_binary` and before `autorotate`, `crop`, `thumbnail` or
   `write`, in every pipeline that re-encodes.
2. `CacheBodyReader` applies the federation cap to any `POST …/inbox` as the
   body is read, so `Plug.Parsers` never decodes more than 256 KB of it.
3. `RateLimits.ip_bucket/1` is the key of every per-IP bucket: the IPv4
   address, the IPv6 /64. Logs keep the full address.
4. Remote input that sizes work is bounded at the changeset: at most 20 poll
   options, counts cast as non-negative integers, a search query cut at 256
   characters before parsing.

## Alternatives considered

- **Lower the byte caps.** A decompression bomb is small by construction;
  no byte cap reaches it.
- **Set libvips's own limits** (`VIPS_MAX_COORD`, the loader's `fail-on`).
  They bound a decode that has already started; the header check costs
  nothing and names the reason.
- **Key IPv6 by /48.** Stricter on an attacker holding a /48, and it puts a
  shared-hosting provider's customers in one bucket for login. The /64 is
  what an ISP hands a household; it can be widened later for a bucket that
  needs it.

## Consequences

- A member cannot upload a 50-megapixel panorama. Nobody has, and the
  thumbnail it would become is 1024 px wide.
- A new image pipeline, a new per-IP bucket and a new size-bearing remote
  field each have one place to be checked and one gate to be added to.

## Acceptance gate

`test/baudrate/media/image_bounds_test.exs`,
`test/baudrate_web/plugs/cache_body_test.exs` ("CacheBodyReader caps an
inbox POST"), `test/baudrate_web/rate_limits_test.exs` ("ip_bucket/1"),
`test/baudrate/federation/inbox_handler_poll_test.exs`.
