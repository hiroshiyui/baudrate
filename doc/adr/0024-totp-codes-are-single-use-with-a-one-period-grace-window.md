# 0024 — TOTP codes are single-use, with a one-period grace window

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** Baudrate maintainers
- **Related:** extends [0009](0009-mandatory-2fa-and-admin-sudo-mode.md) (mandatory 2FA, admin sudo) and [0022](0022-step-up-reauthentication-for-second-factor-changes.md) (step-up re-authentication)

## Context

While building data export (ADR 0023), which asks for a password and a TOTP
code together, a test failed intermittently when a code was generated at the
end of a 30-second period and checked just after it. That exposed three
connected problems with how codes were verified.

1. **Only the current period was accepted.** `doc/sysop.md` promised ±30 s of
   clock-skew tolerance, but `NimbleTOTP.valid?/3` checks one period. A user
   who reads a code at second 28 and submits at second 31 is rejected. The
   more a form asks for, the more often this happens.
2. **Replay protection did not work.** `SecondFactor.valid_totp?/3` documented
   a `since:` option for replay protection, and the login step passed
   `since: get_session(conn, :totp_verified_at)`. That session key was only
   ever deleted, never set, so `since` was always `nil`. Since TOTP was first
   added, every path (login, admin sudo, step-up) accepted a used code again
   for the rest of its period. RFC 6238 §5.2 says a verifier MUST NOT accept
   a second attempt of an OTP after a successful validation. A cookie would
   not have been the right store anyway: an attacker replays with their own.
3. **The login TOTP step had no per-account bound.** Once the password is
   right, `/totp/verify` was limited only by 15 attempts per 5 minutes per IP
   and 5 attempts per cookie, which a fresh login resets. Failures were logged
   but not recorded in `login_attempts`. An attacker holding the password and
   100 addresses gets about 432,000 guesses a day, roughly a 35% chance per
   day of hitting a 6-digit code.

Widening the window alone would make 2 and 3 worse: it doubles the chance per
guess and doubles how long an observed code stays usable.

## Decision

1. **A code is accepted for the current or the previous 30-second period.**
   `SecondFactor.match_totp_step/3` computes both unconditionally and returns
   the matched step. The next period is not accepted: phone clocks follow
   network time, and the common failure is typing across a boundary, not a
   device clock running fast.
2. **Each code works once per account.** `users.totp_last_used_step` holds the
   most recent accepted step. `SecondFactor.verify_totp_code/3` accepts a code
   only if one conditional `UPDATE … WHERE totp_last_used_step < matched`
   succeeds, so concurrent requests with the same code cannot both pass, and a
   code older than the last accepted one is refused. Login, admin sudo and
   step-up re-authentication all go through it. The enrolment code is recorded
   as used (`enable_totp/3` with `used_step:`), and disabling TOTP clears the
   column.
3. **Step-up re-authentication consumes the code only when the password is
   also right** (`claim: password_valid`). A wrong password never burns the
   user's current code. The `UPDATE` runs either way, so timing does not show
   which factor failed.
4. **Failed codes at the login step count against the account.** They are
   recorded in `login_attempts` with `factor: "totp"`, and `totp_verify/2`
   checks `check_login_throttle/1` before verifying. `login_attempts.factor`
   (`password`, `totp`, `reauth`) is shown on `/admin/login-attempts`.
5. **Repeated login code failures warn the owner.** After 3 failed codes in an
   hour at the login step, the user gets an always-delivered
   `totp_login_failed` security notice linking to `/profile/password`, at most
   once an hour. Step-up re-authentication never sends it: that form does not
   say which factor was wrong, and the notice would tell a session thief that
   a guessed password was right. The login step already reveals it, because
   only the correct password reaches `/totp/verify`.
6. **Forms say codes are single-use, always.** Every TOTP field carries the
   `<.totp_code_hint>` text. Showing it only after a reused code would reveal
   that the rest of the form was correct.

## Consequences

- A code observed by shoulder-surfing, a keylogger or a proxy log can no longer
  be replayed after the user has used it.
- Two step-up checks within the same 30 seconds need two codes, for example
  changing the password and then immediately requesting an export. The hint
  covers this.
- Signing in on two devices within the same 30 seconds needs two codes.
- With the per-account throttle, a password holder gets about 720 guesses a
  day (up to 120 s between attempts after 15 failures). With the wider window
  that is roughly a 0.14% chance per day instead of 35% or more, and the owner
  is told within the first few attempts.
- An attacker who knows a username and password can slow the owner's logins
  with failed codes, as they already could with failed passwords.
- The per-cookie 5-attempt counter stays as a first bound, but it is no longer
  the one that matters.

## Alternatives considered

- **Accept ±1 period, as the old doc claimed.** Rejected: it triples the chance
  per guess for a case (a fast device clock) that network time makes rare.
- **Keep one period and correct the doc.** Rejected: real users keep failing
  at period boundaries, more so now that forms ask for a password and a code.
- **Store the last used step in the cookie session.** Rejected: an attacker
  replays with their own cookie. This is what the dead `:totp_verified_at` code
  would have done.
- **A hard lockout after N failed codes.** Rejected for now: it hands anyone
  who knows the password a way to lock the owner out for the lockout period.
  The progressive throttle plus the notice bounds guessing without that.
- **Send the notice from step-up re-authentication too.** Rejected: it would
  turn the generic "invalid credentials" answer into a password oracle.
