# 0084 — A half-finished sign-in expires, and is bound to the credentials

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Baudrate maintainers
- **Related:** [0022](0022-step-up-reauthentication-for-second-factor-changes.md)
  (factor changes), [0024](0024-totp-codes-are-single-use-with-a-one-period-grace-window.md)
  (single-use TOTP), [0058](0058-account-recovery-is-anchored-outside-the-instance.md) (account reset)

## Context

Between the password step and the second factor, a sign-in is held in the
cookie session: `:user_id`, and for an enrolment a `:totp_setup_secret`.
`Plug.Session.COOKIE` never expires a cookie it can decrypt — its `max_age`
only sets the browser's expiry — and nothing recorded when the password step
happened or which password it was. A copy of that cookie stayed good until
`SECRET_KEY_BASE` rotated.

So the usual remedy for a leaked password did not work. Whoever once passed
the password step could, after the owner changed the password, finish the
sign-in with one phished TOTP code or one leaked recovery code; and after an
admin cleared the account's second factor, enrol a secret they held.
Password change and account reset delete session *rows*; none of them can
reach a cookie.

## Decision

`BaudrateWeb.HalfLogin` owns the state. Starting one writes `:user_id`, the
time, and a fingerprint: an HMAC under the endpoint secret over the user id,
the password hash and whether TOTP is enrolled. `HalfLogin.user/1` — the only
reader, used by `totp_verify`, `totp_enable`, `recovery_verify` and the
`:require_password_auth` hook — answers only while the state is at most ten
minutes old and the fingerprint still matches. A TOTP reset starts its
half-login from the account as it is after the reset.

## Consequences

- Changing the password, a recovery-code reset, an account reset that sets a
  new password, or enrolling or clearing TOTP ends every half-login begun
  before it.
- A member who leaves the TOTP prompt open for more than ten minutes signs in
  again.
- Nothing derived from the password hash can be checked offline from the
  cookie: the fingerprint is keyed with the endpoint secret, and the cookie is
  encrypted besides.

## Acceptance gate

"a half-login expires and is bound to the credentials" in
`test/baudrate_web/controllers/session_controller_test.exs`, and the stale
half-login case in `test/baudrate_web/live/totp_verify_live_test.exs`.

## Alternatives considered

- **Server-side half-login rows.** Would allow revocation by row, but adds a
  table and a sweep for a state that lasts a minute; the fingerprint gives
  the same revocation for every change that matters.
- **A `security_stamp` column changed on each credential event.** Equivalent,
  but every credential path would have to remember to bump it; deriving the
  fingerprint from the credentials themselves cannot be forgotten.
