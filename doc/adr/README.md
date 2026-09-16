# Architecture Decision Records

This directory records the significant architectural decisions behind Baudrate:
what was decided, why, what was rejected, and what it costs to live with.

`doc/development.md` documents **what** the system does. These ADRs document
**why** it does it that way — which is the part that is expensive to
reconstruct and easy to "simplify" away by accident.

See [ADR 0000](0000-use-architecture-decision-records.md) for the process,
template and conventions. ADRs 0001–0021 were written retroactively on
2026-08-09 from the code as of v1.12.0.

## Index

| # | Decision | Status |
|---|---|---|
| [0000](0000-use-architecture-decision-records.md) | Use Architecture Decision Records | Accepted |
| [0001](0001-elixir-phoenix-liveview-platform.md) | Elixir / Phoenix / LiveView on Bandit as the application platform | Accepted |
| [0002](0002-context-facades.md) | Context facades over focused sub-modules | Accepted |
| [0003](0003-activitypub-federation.md) | Federate over ActivityPub, mapping boards to Group actors | Accepted |
| [0004](0004-federation-gate-for-non-public-boards.md) | A single federation gate for every inbound interaction | Accepted |
| [0005](0005-rust-nifs-for-untrusted-parsing.md) | Rust NIFs (Rustler) for sanitizing and parsing untrusted input | Accepted |
| [0006](0006-media-proxy-no-third-party-subresources.md) | No third-party subresources: proxy all remote media | Accepted |
| [0007](0007-single-ssrf-safe-http-client.md) | One SSRF-safe, DNS-pinned HTTP client for all outbound requests | Accepted |
| [0008](0008-server-side-dual-token-sessions.md) | Server-side sessions with dual rotating tokens | Accepted |
| [0009](0009-mandatory-2fa-and-admin-sudo-mode.md) | Mandatory 2FA for privileged roles, plus admin sudo mode | Accepted |
| [0010](0010-encrypt-secrets-at-rest.md) | Encrypt TOTP secrets and federation private keys at rest | Accepted |
| [0011](0011-role-levels-for-board-authorization.md) | Ordered role levels plus per-board minimums for authorization | Accepted |
| [0012](0012-rate-limiting-behaviour-and-failure-modes.md) | Hammer/ETS rate limiting behind a behaviour, with explicit failure modes | Accepted |
| [0013](0013-database-backed-delivery-queue.md) | A database-backed delivery queue instead of a job framework | Accepted |
| [0014](0014-ets-caches-for-settings-and-boards.md) | ETS caches for settings, boards and domain blocks | Accepted |
| [0015](0015-soft-deletion.md) | Soft deletion via `deleted_at` | Accepted |
| [0016](0016-authorization-at-the-context-boundary.md) | Enforce authorization at the context boundary, not in LiveViews | Accepted |
| [0017](0017-tailwind-daisyui-esbuild-asset-pipeline.md) | Tailwind + DaisyUI + esbuild, with no Node.js in the build | Accepted |
| [0018](0018-semantic-ids-and-classes-for-accessibility.md) | Every meaningful element carries a semantic `id` / `class` | Accepted |
| [0019](0019-gettext-i18n-no-bare-strings.md) | All user-visible text goes through Gettext | Accepted |
| [0020](0020-testing-strategy.md) | Deterministic, partitioned tests with a stubbable rate limiter | Accepted |
| [0021](0021-setup-wizard-and-installation-key-gate.md) | First-run setup wizard gated by `INSTALLATION_KEY` | Accepted |
| [0022](0022-step-up-reauthentication-for-second-factor-changes.md) | Changing an account's second factors requires step-up re-authentication | Accepted |
| [0023](0023-data-export-threat-model.md) | Self-service data export is designed against data leakage first | Accepted |
| [0024](0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) | TOTP codes are single-use, with a one-period grace window | Accepted |
| [0025](0025-account-migration.md) | Account migration (ActivityPub Move) is gated, delayed and reversible | Accepted |
| [0026](0026-blocks-stop-interaction-locally.md) | A block stops interaction in both directions, enforced on this site only | Accepted |
| [0027](0027-ci-runs-in-a-pinned-attested-image.md) | CI runs in a digest-pinned, attested image built from verified inputs | Accepted |
| [0028](0028-backups-are-complete-folders-with-count-based-retention.md) | Backups are complete folders with count-based retention, pulled off-host | Accepted |
| [0029](0029-sanctions-are-rows-with-an-explicit-end.md) | Sanctions are rows with an explicit end, enforced by one gate | Proposed |

## Writing a new ADR

1. Copy the structure of an existing record; take the next free number.
2. Status starts at `Proposed`, becomes `Accepted` when merged.
3. To reverse a decision, write a **new** ADR and mark the old one
   `Superseded by NNNN` — never rewrite an accepted record.
4. Add a row to the index above.
