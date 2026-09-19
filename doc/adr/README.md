# Architecture Decision Records

This directory records the significant architectural decisions behind Baudrate:
what was decided, why, what was rejected, and what it costs to live with.

For the *what* rather than the *why* — every invariant with its enforcement
point and the test that proves it — see the conformance index at
[`doc/baudrate-spec.md`](../baudrate-spec.md).

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
| [0001](0001-elixir-phoenix-liveview-platform.md) | Elixir / Phoenix / LiveView on Bandit as the application platform | Accepted; `FeedWorker` renamed by [0041](0041-rss-and-atom-are-syndication.md) |
| [0002](0002-context-facades.md) | Context facades over focused sub-modules | Accepted; `Federation.Feed` renamed by [0039](0039-the-personal-stream-is-a-timeline.md) and [0041](0041-rss-and-atom-are-syndication.md); the no-sub-module rule amended by [0047](0047-the-facade-lists-every-way-a-context-changes-the-world.md) |
| [0003](0003-activitypub-federation.md) | Federate over ActivityPub, mapping boards to Group actors | Accepted |
| [0004](0004-federation-gate-for-non-public-boards.md) | A single federation gate for every inbound interaction | Accepted; the outbound half is [0043](0043-the-outbound-federation-gate-and-withdrawals.md) |
| [0005](0005-rust-nifs-for-untrusted-parsing.md) | Rust NIFs (Rustler) for sanitizing and parsing untrusted input | Accepted; the NIF table is a 2026-08-09 snapshot and is now incomplete |
| [0006](0006-media-proxy-no-third-party-subresources.md) | No third-party subresources: proxy all remote media | Accepted; click-to-load embeds refined by [0045](0045-the-video-player-loads-on-a-click.md) |
| [0007](0007-single-ssrf-safe-http-client.md) | One SSRF-safe, DNS-pinned HTTP client for all outbound requests | Accepted |
| [0008](0008-server-side-dual-token-sessions.md) | Server-side sessions with dual rotating tokens | Accepted |
| [0009](0009-mandatory-2fa-and-admin-sudo-mode.md) | Mandatory 2FA for privileged roles, plus admin sudo mode | Accepted |
| [0010](0010-encrypt-secrets-at-rest.md) | Encrypt TOTP secrets and federation private keys at rest | Accepted; amended by [0038](0038-encryption-keys-are-separate-and-rotatable.md); `send_accept`/`send_reject` queued by [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md) |
| [0011](0011-role-levels-for-board-authorization.md) | Ordered role levels plus per-board minimums for authorization | Accepted, except the configurable-capabilities half, superseded by [0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md) |
| [0012](0012-rate-limiting-behaviour-and-failure-modes.md) | Hammer/ETS rate limiting behind a behaviour, with explicit failure modes | Accepted |
| [0013](0013-database-backed-delivery-queue.md) | A database-backed delivery queue instead of a job framework | Accepted |
| [0014](0014-ets-caches-for-settings-and-boards.md) | ETS caches for settings, boards and domain blocks | Accepted |
| [0015](0015-soft-deletion.md) | Soft deletion via `deleted_at` | Accepted; tables renamed by [0039](0039-the-personal-stream-is-a-timeline.md); articles and comments purged after 90 days by [0040](0040-retention-deletes-what-nobody-touched.md), direct messages never |
| [0016](0016-authorization-at-the-context-boundary.md) | Enforce authorization at the context boundary, not in LiveViews | Accepted; tables renamed by [0039](0039-the-personal-stream-is-a-timeline.md) |
| [0017](0017-tailwind-daisyui-esbuild-asset-pipeline.md) | Tailwind + DaisyUI + esbuild, with no Node.js in the build | Accepted |
| [0018](0018-semantic-ids-and-classes-for-accessibility.md) | Every meaningful element carries a semantic `id` / `class` | Accepted |
| [0019](0019-gettext-i18n-no-bare-strings.md) | All user-visible text goes through Gettext | Accepted |
| [0020](0020-testing-strategy.md) | Deterministic, partitioned tests with a stubbable rate limiter | Accepted |
| [0021](0021-setup-wizard-and-installation-key-gate.md) | First-run setup wizard gated by `INSTALLATION_KEY` | Accepted |
| [0022](0022-step-up-reauthentication-for-second-factor-changes.md) | Changing an account's second factors requires step-up re-authentication | Accepted |
| [0023](0023-data-export-threat-model.md) | Self-service data export is designed against data leakage first | Accepted; names renamed by [0039](0039-the-personal-stream-is-a-timeline.md) |
| [0024](0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) | TOTP codes are single-use, with a one-period grace window | Accepted |
| [0025](0025-account-migration.md) | Account migration (ActivityPub Move) is gated, delayed and reversible | Accepted; tables renamed by [0039](0039-the-personal-stream-is-a-timeline.md) |
| [0026](0026-blocks-stop-interaction-locally.md) | A block stops interaction in both directions, enforced on this site only | Accepted; names renamed by [0039](0039-the-personal-stream-is-a-timeline.md) |
| [0027](0027-ci-runs-in-a-pinned-attested-image.md) | CI runs in a digest-pinned, attested image built from verified inputs | Accepted; amended by [0036](0036-production-runs-releases-built-and-attested-in-ci.md) |
| [0028](0028-backups-are-complete-folders-with-count-based-retention.md) | Backups are complete folders with count-based retention, pulled off-host | Accepted; amended by [0038](0038-encryption-keys-are-separate-and-rotatable.md) |
| [0029](0029-sanctions-are-rows-with-an-explicit-end.md) | Sanctions are rows with an explicit end, enforced by one gate | Accepted; names renamed by [0039](0039-the-personal-stream-is-a-timeline.md) |
| [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md) | Domain blocks are rows, and blocking hides content instead of deleting it | Accepted |
| [0031](0031-terms-acceptance-is-recorded-and-versioned.md) | Terms acceptance is recorded and versioned, and the pause runs through the interaction gate | Accepted |
| [0032](0032-rules-are-records-and-retired-not-deleted.md) | Site rules are records, retired rather than deleted, and a report may cite one | Accepted |
| [0033](0033-baudrate-runs-on-one-node.md) | Baudrate runs on one node | Accepted; `FeedWorker` renamed by [0041](0041-rss-and-atom-are-syndication.md) |
| [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md) | Federation work is committed before it is acknowledged | Accepted |
| [0035](0035-operational-visibility-stays-on-the-host.md) | Operational visibility stays on the host | Accepted, except decision 5 ("Baudrate does not notify"), amended by [0044](0044-the-instance-tells-its-admins-when-it-is-unwell.md) |
| [0036](0036-production-runs-releases-built-and-attested-in-ci.md) | Production runs releases built and attested in CI | Accepted; decision 3 superseded by [0037](0037-the-deploy-builds-on-the-server-again.md) |
| [0037](0037-the-deploy-builds-on-the-server-again.md) | The deploy builds on the server again | Accepted |
| [0038](0038-encryption-keys-are-separate-and-rotatable.md) | Encryption keys are separate, and rotatable | Accepted |
| [0039](0039-the-personal-stream-is-a-timeline.md) | The personal stream is a timeline, not a feed | Accepted, except the RSS carve-out, superseded by [0041](0041-rss-and-atom-are-syndication.md) |
| [0040](0040-retention-deletes-what-nobody-touched.md) | Retention deletes what nobody touched | Accepted; `bot_feed_items` renamed by [0041](0041-rss-and-atom-are-syndication.md) |
| [0041](0041-rss-and-atom-are-syndication.md) | RSS and Atom are syndication, not feeds | Accepted |
| [0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md) | Roles are ordered, and capabilities are not configurable | Accepted |
| [0043](0043-the-outbound-federation-gate-and-withdrawals.md) | The outbound federation gate, and the withdrawals it must not touch | Accepted |
| [0044](0044-the-instance-tells-its-admins-when-it-is-unwell.md) | The instance tells its admins when it is unwell | Accepted |
| [0045](0045-the-video-player-loads-on-a-click.md) | The video player loads on a click, and nothing else is embedded | Accepted |
| [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md) | Every identity claim is bound to the host that can prove it | Accepted |
| [0047](0047-the-facade-lists-every-way-a-context-changes-the-world.md) | The facade lists every way a context changes the world | Accepted |
| [0048](0048-a-poll-records-who-voted-and-nothing-reads-it-back.md) | A poll records who voted, and nothing reads it back | Accepted |
| [0049](0049-user-facing-changesets-are-allow-lists.md) | User-facing changesets are allow-lists | Accepted |
| [0050](0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) | A comment and a poll are objects with their own URI | Accepted |
| [0051](0051-a-mention-addresses-and-the-board-gate-still-decides.md) | A mention addresses, and the board gate still decides | Accepted |
| [0052](0052-a-content-warning-is-a-field-not-a-prefix.md) | A content warning is a field, not a prefix | Accepted |

## Writing a new ADR

1. Copy the structure of an existing record; take the next free number.
2. Status starts at `Proposed`, becomes `Accepted` when merged.
3. To reverse a decision, write a **new** ADR and record the relationship in
   the old record's Status — never rewrite an accepted record. The Status
   keeps opening with `Accepted`: nothing here has ever been reversed whole,
   so a bare `Superseded by NNNN` would retire decisions that still hold, and
   `test/doc/adr_index_test.exs` fails a Status that opens with one. Rule 4
   has the form; *How records relate* below has the verbs.
4. When only part of a record is reversed, say which part, and leave the rest
   standing: [0036](0036-production-runs-releases-built-and-attested-in-ci.md)
   reads `Accepted, except decision 3 …, superseded by 0037`. Naming the
   decision matters more than the wording — a bare `Superseded by` would retire
   an ADR whose other decisions are still load-bearing.
5. Add a row to the index above. It may abbreviate a long Status line — the
   index is a table, and 0010's runs to six lines — but it must keep the
   relationship verb and **every ADR number the record's Status refers to**.
   The index is where a reader looks first; a row that drops the link to the
   record that changed this one sends them off with the superseded answer.
   `test/doc/adr_index_test.exs` enforces both halves.

## How records relate

Four verbs, used deliberately. The record's own Status line says which one
applies, and its index row repeats it:

| Verb | What it means |
|---|---|
| **superseded by** | the decision is reversed — [0011](0011-role-levels-for-board-authorization.md) → [0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md) |
| **amended by** | one decision inside it changed; the rest stands — [0035](0035-operational-visibility-stays-on-the-host.md) → [0044](0044-the-instance-tells-its-admins-when-it-is-unwell.md) |
| **refined by** | it stands, with a bounded exception — [0006](0006-media-proxy-no-third-party-subresources.md) → [0045](0045-the-video-player-loads-on-a-click.md) |
| **renamed by** | prose drift only: names used in the record predate a rename and the decision is untouched — [0040](0040-retention-deletes-what-nobody-touched.md) → [0041](0041-rss-and-atom-are-syndication.md) |

A record whose whole purpose is to change an older one also carries an
**Amends** / **Refines** header field naming it (see 0044 and 0045). That is
the forward pointer; the older record's Status line is the backward one, and
both have to be written — a reader arrives from either end.

Two statuses deliberately do **not** exist. Nothing is `Deprecated`: every
reversal here has a replacement, and a status value nothing ever takes is the
same false catalogue entry that
[0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md) is
about. Nothing is wholly `Superseded` either — all three supersessions are
partial, which is what rule 4 is defending.

That last point refines rule 1 of
[0000](0000-use-architecture-decision-records.md), which says to set a
superseded record's status to a bare `Superseded by NNNN`. Practice never did:
no record has ever carried that form, because each reversal left decisions
standing that a bare status would have retired. 0000 is accepted and not
rewritten, so this paragraph is where that lives.
