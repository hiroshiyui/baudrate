# 0022 — Changing an account's second factors requires step-up re-authentication

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** Baudrate maintainers
- **Related:** extends [0009](0009-mandatory-2fa-and-admin-sudo-mode.md) (admin sudo mode)

## Context

ADR 0009 made admin routes require a second factor every 10 minutes ("sudo
mode"), so that a stolen admin session is not a full compromise. Sudo accepts
TOTP *or* any WebAuthn key registered on the account.

Registering a WebAuthn key, however, required nothing beyond the session. A
security review (v1.14.3) found the resulting chain:

1. With only an admin's session cookie, open `/profile` and register the
   attacker's own authenticator. A software authenticator is enough.
2. At `/admin/verify`, choose WebAuthn and assert with that key. Sudo is
   granted.

That fully cancels ADR 0009. Removing keys was equally unguarded, so the
attacker could also delete the admin's real keys.

Two further weaknesses made the gap wider:

- **Challenges were not bound to a purpose.** `Wax.register/3` checks the
  *client-supplied* `clientData.type`, but not whether the stored challenge was
  issued for registration or authentication. An authentication challenge, which
  `/admin/verify` hands to any admin session, could be spent on registering a
  key. So gating only the registration challenge would not have been enough.
- **The only existing re-authentication form had no durable throttle.**
  `/profile/totp-reset` kept its 5-attempt lockout in socket assigns, and a
  reload reset it. Its failures were not recorded against the account, so a
  stolen session could use it to guess the password around the per-account
  login throttle.

## Decision

1. **Any change to an account's second factors requires step-up
   re-authentication from within the session.** This covers registering or
   removing a WebAuthn key, and resetting or enabling TOTP.
   - The user re-enters the password, plus the current TOTP code when TOTP is
     enabled, through `Auth.verify_reauthentication/5`
     (`Baudrate.Auth.Reauthentication`).
   - On `/profile`, a success unlocks key management for 5 minutes in that
     LiveView process only. The deadline lives in socket assigns, which the
     client cannot set, and a reload locks it again.
   - Every event handler checks the deadline server-side. Hiding the buttons
     is only presentation.
2. **Re-authentication failures feed the per-account login throttle.** They are
   recorded in `login_attempts`, and `check_login_throttle/1` is enforced
   before any credential is checked. On top of that, a per-user Hammer bucket
   (`RateLimits.check_reauth/1`, 5 per 15 minutes) is shared by every
   re-authentication form, so switching forms does not multiply guesses.
3. **Recovery codes never satisfy step-up re-authentication.** They exist to
   recover a lost device; a leaked recovery sheet must not authorize changes to
   an account's factors.
4. **WebAuthn challenges are bound to their purpose.**
   `WebAuthnChallenges.pop/3` requires the expected `Wax.Challenge` type
   (`:attestation` or `:authentication`). A mismatched pop still consumes the
   entry, so a token cannot be retried for another purpose.

## Consequences

- A stolen session cookie on its own can no longer enrol or remove a second
  factor, and so can no longer satisfy admin sudo mode. An attacker also needs
  the password, plus the TOTP code on accounts that have TOTP. Admins and
  moderators always do.
- Users re-enter their password when managing security keys. This is a small
  cost for a rare action.
- Failed step-up attempts appear as failed logins in the admin login-attempt
  view and count toward the account throttle. A thief holding a session can
  delay the real user's logins (at most 120 s per attempt), which they could
  already do from the public login form.
- For accounts **without** TOTP, step-up is the password alone. That still
  stops cookie-only theft, but not malware that steals saved passwords and
  cookies together. Features that need more than that (e.g. data export) must
  add their own requirements rather than assume this ADR provides them.
- No security notification is sent when a factor changes yet. Only
  `Logger` lines (`auth.reauth_*`, `auth.webauthn_register_success`) record it.
  In-app security notifications are follow-up work.

## Alternatives considered

- **Gate only `begin_registration`.** Rejected: without purpose binding, an
  authentication challenge from `/admin/verify` registers a key anyway.
- **Require the existing sudo timestamp (`admin_totp_verified_at`) to manage
  keys.** Rejected: it applies to admins only, and sudo can itself be satisfied
  with a WebAuthn key, which is circular.
- **Ask for the second factor only, not the password.** Rejected for the same
  reason ADR 0009 gives. Also, for accounts without TOTP there would be nothing
  left to ask for.
- **Keep the lockout in socket assigns or the cookie.** Rejected: both reset
  under the attacker's control. Only the database-backed account throttle
  survives reloads and fails closed.
