# 0009 — Mandatory 2FA for privileged roles, plus admin sudo mode

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

An admin account on a Baudrate instance can read every private board, alter
moderation state, change federation policy and edit site settings. A stolen
admin password is a total compromise, and a long-lived admin session left open
in a browser tab is nearly as bad — anyone with access to that machine inherits
full authority for the life of the session.

## Decision

Two layers.

**1. Second factor is mandatory for privileged roles.**

- `admin` and `moderator` must enrol a second factor; the login flow routes
  them to TOTP setup if they have none.
- `user` may enrol; `guest` cannot.
- Two mechanisms are supported: **TOTP** (NimbleTOTP, QR via EQRCode) and
  **WebAuthn/FIDO2 hardware security keys** (`wax_`).
- TOTP secrets are encrypted at rest with AES-256-GCM (`Auth.TotpVault`) —
  see ADR 0010.
- One-time recovery codes exist for lost devices.

**2. Admin routes require re-verification — "sudo mode".**

The `:require_admin_totp` hook checks `admin_totp_verified_at` in the cookie
session; if absent or older than **10 minutes**, the admin is redirected to
`/admin/verify`, which accepts either TOTP or a WebAuthn key. Moderators pass
through. Five wrong attempts lock the verification, but the session is *not*
dropped.

`/admin/verify` deliberately lives in the `:authenticated` live_session, not
the `:admin` one, to avoid a redirect loop. The `:admin` live_session boundary
forces a full page load on entry so the cookie session is re-read for a fresh
timestamp; navigation *within* admin pages shares the socket without
re-prompting.

## Consequences

- Compromising an admin password is not sufficient; compromising a live admin
  session buys at most ten minutes of privileged action.
- Sysops must keep recovery codes — losing the second factor on the only admin
  account locks the instance.
- WebAuthn is origin-bound: `wax_`'s configured `origin` must match
  `window.location.origin` exactly (scheme + host + port) in every environment,
  or every WebAuthn operation fails client-side with `NotAllowedError`. This is
  set per environment in `runtime.exs` / `dev.exs` / `test.exs` (per-partition
  port).
- WebAuthn challenges are stored in ETS as the **full `Wax.Challenge` struct**,
  not a plain map — Wax needs `issued_at` and other fields during
  `register/3` / `authenticate/6`.
- Tests need `log_in_admin/2`, which sets `admin_totp_verified_at`.

## Alternatives considered

- **Optional 2FA for admins.** Rejected: the highest-value account should not
  have the weakest default.
- **Re-prompt for the password instead of the second factor.** Rejected: a
  password is exactly the credential most likely to already be compromised.
