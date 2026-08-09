# 0021 — First-run setup wizard gated by `INSTALLATION_KEY`

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

A fresh Baudrate instance has no admin account. Whoever reaches `/setup` first
becomes the administrator of the instance. Between deployment and completed
setup there is therefore a race that an attacker on the public internet can win
— and the window is exactly when the sysop is least likely to be watching.

Seeding an admin via a mix task instead would work for hand-rolled deployments
but is hostile to the container and one-click-deploy audiences the wizard
exists for.

## Decision

Ship a first-run **setup wizard** (`SetupLive`, `:setup` layout, no navigation)
that seeds RBAC roles, the initial admin and core settings — and gate it in
production with a pre-shared **`INSTALLATION_KEY`**.

- `INSTALLATION_KEY` is **required in production until setup completes**.
- The `EnsureSetup` plug answers **503** on every browser route while setup is
  incomplete and no key is configured.
- `SetupLive.mount/3` carries the same gate, because a LiveView websocket does
  not traverse the router pipeline the same way; the plug alone is not enough.
- **Never move this check into a `raise` in `runtime.exs`.** That file runs
  before the Repo starts, so it cannot know whether setup already completed —
  and a boot-time raise turns a transient database outage into a bricked
  instance for a fully configured deployment.

## Consequences

- An unattended fresh instance cannot be claimed by a passer-by.
- Both the HTTP and websocket entry points must be kept in sync; adding a new
  entry point to setup means adding the gate there too.
- The failure mode for a sysop who forgets the variable is a clear 503, not a
  crash loop — deliberate, and documented in `doc/sysop.md`.
- After setup completes the key is irrelevant, so it need not be kept in the
  long-term configuration.

## Alternatives considered

- **Unprotected `/setup` that closes after first use.** Rejected: that is the
  race described above.
- **Admin seeded by a mix task only.** Rejected: no wizard for container and
  managed-hosting deployments, where running a task is awkward.
- **Bind setup to localhost.** Rejected: unusable for remote deployments, which
  is the normal case.
