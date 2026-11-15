# 0086 — A session ends ninety days after sign-in

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Baudrate maintainers
- **Amends** [0008](0008-server-side-dual-token-sessions.md): its TTL ("14 days
  from creation or last rotation") stands, with an absolute end added.

## Context

0008 gives a session 14 days from creation or from its last rotation, and
`RefreshSession` rotates every 24 hours of use. Each rotation pushed the expiry
out again, so a session that kept being used never ended. A stolen cookie that
the thief kept using was therefore good for ever: nothing short of the member
noticing it in their session list, or changing their password, would end it.

## Decision

`Auth.Sessions.refresh_user_session/1` never sets `expires_at` past the
session's `inserted_at` plus 90 days, and refuses (deleting the row) a session
already past that. The 14-day window still applies inside it.

## Consequences

- Every member signs in again at least once a quarter.
- A stolen session cookie is useful for at most 90 days, however it is used.
- No migration: `inserted_at` is already on every row.

## Acceptance gate

`describe "refresh_user_session/1"` in `test/baudrate/auth/user_session_test.exs`.

## Alternatives considered

- **A shorter absolute lifetime (30 days).** Safer, but a forum is read a few
  times a month; signing in every few weeks with a second factor is a cost
  members would pay often, for a cookie that is already encrypted, bound to a
  hashed row and revocable.
- **Re-authentication for sensitive actions only.** Already done for factor
  changes (ADR 0022); it does not end a session that only reads.
