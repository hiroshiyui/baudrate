# 0012 — Hammer/ETS rate limiting behind a behaviour, with explicit failure modes

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09; `RealIp` hardened 2026-08-08

## Context

Every public endpoint needs a rate limit: login, registration, password reset,
search, content creation, DMs, feeds, the AP inbox, and LiveView mounts. Three
questions had to be settled once, not per call site.

1. **Where does the counter live?** A separate Redis is a second daemon for
   sysops to run.
2. **What happens when the limiter itself fails?** Failing closed on an ETS
   error takes the whole site down; failing open removes the limit.
3. **Whose IP is it?** Behind a reverse proxy, the client IP comes from
   `x-forwarded-for` — a header anyone can send.

## Decision

**Storage.** Hammer 7 with the ETS backend. The store is
`BaudrateWeb.RateLimit` (`use Hammer, backend: :ets`), started in the
supervision tree. There is no `config :hammer, backend:` — that was v6. Never
call `Hammer.check_rate/3` or `Hammer.delete_buckets/1`; both were removed in
v7 (`BaudrateWeb.RateLimit.reset_all/0` replaces the latter).

**Indirection.** All application checks go through the
`BaudrateWeb.RateLimiter` behaviour (`check_rate/3`). The `Hammer` adapter
delegates to `RateLimit.hit/3`, whose `{:allow, count}` / `{:deny, retry_after_ms}`
already matches the contract. Tests swap in `RateLimiter.Sandbox` —
`set_global_response({:allow, 1})` to bypass, or `set_fun/1` to exercise the
real backend.

**Two enforcement points.** IP limits run as a plug in the router pipeline
(`BaudrateWeb.Plugs.RateLimit`); per-user limits run from LiveView event
handlers (`BaudrateWeb.RateLimits`). Admins are exempt from per-user *content*
limits.

**Failure modes, chosen deliberately and differently:**

- **The limiter fails open.** An ETS backend error allows the request. A
  crashed limiter must not take down the site, and the limiter is a
  mitigation, not the only control.
- **`RealIp` fails closed.** An unconfigured `trusted_proxies` means loopback
  only; `[]` means trust nobody. There is deliberately **no**
  trust-everything branch: a spoofable `x-forwarded-for` defeats every per-IP
  limit at once *and* poisons the `ip_address` audit trail. Operators widen
  trust with CIDR entries in `BAUDRATE_TRUSTED_PROXIES`.

Per-domain inbox limiting (60/min) is separate from per-IP (120/min), because
one remote instance may present many IPs and many instances may share one.

## Consequences

- No extra daemon; limits are per-node, which is correct for the single-node
  deployments Baudrate targets and would need revisiting under clustering.
- Tests are deterministic — no sleeping to wait out a window.
- A misconfigured reverse proxy shows up as "everyone is 127.0.0.1", which is
  visible and safe, rather than as a silently disabled limiter. `doc/sysop.md`
  documents the required proxy configuration.

## Alternatives considered

- **Redis-backed Hammer.** Rejected: raises the ops floor for a single-node
  system.
- **Fail closed everywhere.** Rejected: converts a limiter bug into an outage.
- **Trust `x-forwarded-for` when no proxies are configured.** Rejected — this
  was the pre-2026-08 behaviour and is the exact hole the current code closes.
