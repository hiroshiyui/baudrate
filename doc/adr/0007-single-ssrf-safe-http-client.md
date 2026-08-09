# 0007 — One SSRF-safe, DNS-pinned HTTP client for all outbound requests

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Baudrate makes outbound HTTP requests on behalf of attacker-supplied input in
several places: resolving remote actors, walking reply chains, fetching remote
objects, fetching link-preview metadata, fetching feeds for bot accounts,
fetching remote images for the media proxy, and delivering Web Push.

Every one of those is a server-side request forgery vector. Validating a
hostname and then handing it to an HTTP library also leaves a DNS-rebinding
gap: the name can resolve to a public address at validation time and to
`169.254.169.254` or `127.0.0.1` at connect time.

## Decision

- **`Req` is the only HTTP client.** Never HTTPoison, Tesla, or `httpc`.
- **All outbound traffic goes through `Federation.HTTPClient`**, which:
  - requires HTTPS,
  - resolves the host and rejects private, loopback, link-local and
    otherwise-reserved addresses,
  - **pins the connection to the validated IP** and sets the `Host` header
    itself (`build_pinned_opts`), closing the rebinding gap,
  - caps response size.
- **Non-ActivityPub POSTs use `HTTPClient.post_raw/3`**, not bare `Req.post`.
  Web Push was the case that proved this necessary: it is not an AP delivery,
  but it is still an outbound POST to a host named by user-controlled data.
- Because `HTTPClient` owns the `Host` header, `HTTPSignature.sign/5` and
  `sign_get/3` **must not** return a `"host"` header — a duplicate breaks
  signature verification on the receiving instance.

Reply-chain walking gets additional bounds beyond SSRF, because each hop is an
attacker-chosen fetch: ≤5 hops, ≤3 distinct hosts, a visited-URI cycle guard,
and two rate limits — `check_reply_chain_fetch/1` keyed on the **target** host
(10/min, so many hostile domains cannot combine against one victim) and
`check_reply_chain_domain/1` on the sender (20/min). There is deliberately no
negative cache; the rate limiter is the bound.

## Consequences

- There is exactly one place to audit and one place to fix SSRF.
- New outbound call sites must be reviewed for using this client; a direct
  `Req.get/post` in application code is a finding.
- DNS pinning means SNI/`Host` handling is manual and subtly easy to break —
  hence the "no `host` header from the signer" rule.
- Instances behind a proxy that requires plaintext or non-standard resolution
  are not supported.

## Alternatives considered

- **Validate the URL, then use a plain client.** Rejected: DNS rebinding.
- **Allowlist remote hosts.** Rejected: incompatible with open federation.
