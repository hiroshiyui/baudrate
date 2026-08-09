# 0008 — Server-side sessions with dual rotating tokens

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Phoenix's default is a signed (optionally encrypted) cookie holding the user id.
It is stateless and cheap, and it has properties we cannot accept on a
public-facing system: a stolen cookie is valid until it expires, the server
cannot revoke it, banning a user does not end their session, and there is no
way to show a user their active sessions or to bound how many exist.

## Decision

Store sessions **server-side** in `user_sessions`, with two tokens.

| Aspect | Detail |
|---|---|
| Tokens | Session token (authentication) + refresh token (rotation) |
| Storage | SHA-256 **hashes** in the DB; raw tokens only in a signed+encrypted cookie |
| TTL | 14 days from creation or last rotation |
| Rotation | `RefreshSession` plug rotates both tokens every 24 h |
| Concurrency | Max 3 sessions per user; oldest by `refreshed_at` evicted |
| Cleanup | `SessionCleaner` purges expired sessions hourly |

Because LiveView cannot write cookies, session writes use the
**`phx-trigger-action`** pattern: the LiveView validates, then triggers a hidden
form POST to `SessionController`, which writes the tokens.

Storing hashes rather than tokens means a database disclosure does not yield
usable sessions. Rotation bounds the value of a captured token; the session
cap bounds how many can exist at once.

## Consequences

- Sessions are revocable: ban, logout-everywhere, and admin action all work.
- Every authenticated request costs a session lookup — acceptable at this
  scale, and it is a single indexed query.
- The `phx-trigger-action` round trip is a recurring source of confusion; it is
  documented in `CLAUDE.md` and `doc/development.md` because it looks like
  unnecessary indirection until you know cookies cannot be set over a socket.
- Login itself is defended separately: per-IP Hammer limits plus a
  **progressive per-account delay** (5 s / 30 s / 120 s at 5 / 10 / 15+ failures
  in the last hour) rather than a hard lockout, which would let an attacker
  lock any account out at will. The delay is checked *before*
  `authenticate_by_password/2` so throttled attempts do not pay bcrypt cost.

## Alternatives considered

- **Signed cookie sessions.** Rejected: unrevocable.
- **JWTs.** Rejected: same revocation problem, plus a signature-verification
  footgun and no benefit here — there is no separate resource server.
- **Hard account lockout after N failures.** Rejected: a trivially exploitable
  denial-of-service against any known username.
