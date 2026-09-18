# TODOs

From a product review on 2026-09-14 (after v1.18.1) that looked at every role:
guests, members, board moderators, admins, sysops, remote instances and
contributors. Items marked **(confirmed)** were checked against the code, and
"absent" claims with grep. Paths are relative to the repository root, with
`lib/baudrate_web/…` shortened to `web/…` and `lib/baudrate/…` to `core/…`;
line numbers were correct as of v1.18.1.

Every open item belongs to one of Phases 2–8 below, or to the Backlog. Work
phase by phase; within a phase, ship each stage as its own release. A completed
phase is summarised rather than listed — the detail lives in its ADRs and in
`CHANGELOG.md`.

The review found Baudrate already strong on security engineering, ADRs,
accessibility plumbing and test coverage, and named five gaps: broken promises
(the UI or docs saying something happens when it does not), moderation reach,
operability, federation reach, and discovery and onboarding. The first three
are closed — Phase 0 in v1.18.2, Phase 1 in v1.21.0, Phase 2 bar one 2A item
that needs a notifier. Phases 3–8 carry the rest.

---

## Decisions (made 2026-09-14)

- **D1. Local post visibility:** keep Public and Unlisted; drop "Followers only" and "Direct" from local composers, because boards are public spaces whose audience is set by the board's view role, and direct messages are the private channel. Done (B4).
- **D2. Scale target: one server.** Done (2B, [ADR 0033](adr/0033-baudrate-runs-on-one-node.md)).
- **D3. Email: stay without it.** Recovery is covered by 4D instead.
- **D4. Data export and move gate: keep "TOTP enabled for ≥ 7 days"** ([ADR 0023](adr/0023-data-export-threat-model.md), [ADR 0025](adr/0025-account-migration.md)), and improve the path for members in 6E. Accepting WebAuthn in step-up re-authentication stays a separate possible feature.

---

## Roadmap

Each phase settles its decisions and gets its own implementation plan before work starts. Sizes: S ≈ a day, M ≈ a few days, L ≈ a week.

| Phase | Theme | Stages | Why |
|-------|-------|--------|-----|
| ~~1~~ | ~~Trust and safety~~ | 1A–1F | **Complete** (v1.19.0 – v1.21.0) |
| ~~2~~ | ~~Operability~~ | 2A–2H | **Complete** (v1.23.0 – v1.28.0, pending release), bar one 2A item that needs a notifier |
| 3 | Federation reach | 3A–3F | Threading, mentions, Lemmy groups and profile changes don't federate |
| 4 | Discovery and onboarding | 4A–4F | Turns visitors into members, and keeps them able to sign in |
| 5 | Anti-spam | 5A–5E | Growth from Phase 4 attracts spam |
| 6 | Member depth | 6A–6E | Retention |
| 7 | Admin and content tools | 7A–7E | Running the site without a shell |
| 8 | Contributor health | 8A–8D | Lowers the bus factor of one |

---

## Phase 1 — Trust and safety — **complete**

Everyone who has to act on abuse can act at the right level, everyone affected
by a decision is told about it, and the site publishes the rules those
decisions rest on. The decisions behind it (P1-D1 … P1-D9, made 2026-09-14)
are all implemented; they live in the ADRs below, the `CLAUDE.md` invariants
and — for who hears about a report's outcome — `doc/development.md`.

| Stage | What | Released | Recorded in |
|-------|------|----------|-------------|
| 1A | Member self-protection: blocks stop interaction both ways, locally only | v1.19.0 | [ADR 0026](adr/0026-blocks-stop-interaction-locally.md) |
| 1B | A report queue board moderators can use, with reason categories and outcome notices | v1.20.0 | `doc/development.md` |
| 1C | Sanctions short of a ban: warn, silence, suspend — rows with an explicit end, one gate | v1.21.0 | [ADR 0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md) |
| 1D | Instance-level federation moderation: domain blocks as rows, reversible hiding, per-actor suspension | v1.21.0 | [ADR 0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) |
| 1E | Rules, terms and privacy pages; terms acceptance recorded and versioned | v1.21.0 | [ADR 0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md) |
| 1F | Rules as records, so a report can cite one | v1.21.0 | [ADR 0032](adr/0032-rules-are-records-and-retired-not-deleted.md) |

**Closed by 2F:** an article its author deletes used to keep its body in the
row and in `article_revisions` indefinitely; both are destroyed 90 days later
([ADR 0040](adr/0040-retention-deletes-what-nobody-touched.md)).

**Deliberately not in Phase 1:** anti-spam → Phase 5; moving articles between
boards → 7C; an `/admin` dashboard and announcement UI → 7A, 7B; content
warnings → 3E. Silence and reject-media domain levels, splitting threads,
takedown workflow and age gating are in the Backlog; outbound `Block` was ruled
out by P1-D1.

---

## Phase 2 — Operability — complete

**Goal.** No data loss goes unnoticed, the operator hears about problems before users do, and a bad deploy can be undone.

**Done when:** production takes verified backups on a schedule and a restore has been rehearsed; a delivery or inbound backlog, a stalled worker or a full disk shows up in the detailed health report; no federated activity is lost to a restart; a release can be rolled back with one command. One of the original five — "the production host no longer compiles releases" — was withdrawn by [ADR 0037](adr/0037-the-deploy-builds-on-the-server-again.md): moving the artifact cost more than compiling it.

### Done

| Stage | What | Released | Recorded in |
|-------|------|----------|-------------|
| 2B | One node (D2): cluster discovery removed, the scaling guide rewritten around a bigger host, PostgreSQL tuning and a CDN | v1.23.0 | [ADR 0033](adr/0033-baudrate-runs-on-one-node.md) |
| 2C | Federation work committed before it is acknowledged: delivery jobs inside the change's transaction, wake on commit, delivery deadlines, a per-domain circuit breaker, an inbound queue ordered per remote account | v1.24.0 | [ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) |
| 2D | Observability: a loopback-only detailed health report (queues, worker heartbeats, disk, backup age; 503 on failure) and optional JSON logs with a metadata allow-list | v1.25.0 | [ADR 0035](adr/0035-operational-visibility-stays-on-the-host.md) |
| 2E | Deploy safety: releases built on Debian 12 in CI, smoke-tested on every push and attested; a rollback playbook that refuses an incompatible schema; a per-server Erlang cookie with distribution on loopback; Sobelow and mix_audit in CI | v1.26.0 | [ADR 0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md), [ADR 0037](adr/0037-the-deploy-builds-on-the-server-again.md) |
| 2G | Key separation: an `:auth` and a `:signing` key read from the environment, retired keys kept for reading, stored values that name their key and are bound to their row, a resumable rotation task with a census, a health check for a key that is gone, and key ids in the backup manifest | v1.27.0 | [ADR 0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) |
| 2F | Retention: hourly purges of untouched timeline items (90 days), `announces` (180 days) and soft-deleted articles and comments (90 days past `deleted_at`, with their image files); nothing a report references is deleted; autovacuum guidance for the two tables emptied in bulk | v1.28.0 (pending) | [ADR 0040](adr/0040-retention-deletes-what-nobody-touched.md) |
| 2H | Drift: CI runs production's PostgreSQL 15, server and client, held together with Ansible by `verify-toolchain.sh`; the worker table, README clone URL and `INSTALLATION_KEY` fixed | v1.23.0 | `ci/image/README.md`, `doc/sysop.md` |

Production separated its keys on 2026-09-18, the day 2G shipped: 117 stored
secrets moved to the new keys, with none left unreadable. `SECRET_KEY_BASE` is
**not** rotatable yet — the 130 recovery-code hashes still ride the old
derivation and move only as members regenerate their codes, which is what
`Baudrate.Release.key_census/0` is for.

**Deferred by the operator, outside 2H:** production allows SSH login as root
(key only). `/etc/ssh/sshd_config.d/00-disable-password-auth.conf` sets
`PermitRootLogin yes`, and sshd keeps the first value it reads, so the `common`
role's `PermitRootLogin no` has no effect (`sshd -T`, found 2026-09-15). The fix
would be for the role to manage the drop-ins and assert the effective value.

**Left open by ADR 0037:** publishing the release to a registry, so the
operator's machine verifies a digest and the server pulls the bytes over its
own link. Only worth doing if the built artifact ever has to reach the server
again.

### 2A — Backups and recovery (M)

Scheduled backups, retention, the pre-deploy dump, restore commands, per-file
checksums verified off-host, and backup age in the health report are all built
and running on production since 2026-09-16 (ADR 0028, `doc/sysop.md`). One
item is left:

- [ ] **Alert on a failed or stale backup.** The health report fails on a stale backup and the puller exits non-zero on a bad checksum, a failed pull or a stale copy, but neither tells a person: for 2D the operator chose to document polling rather than ship a notifier (ADR 0035).
- **Accepted when:** production has a backup less than 24 h old, and a restore has put the data back. Both hold.

**Declined by the operator, 2026-09-18:** a restore rehearsal onto a freshly
provisioned host, and an always-on puller. What the rehearsal proved is that
the dump reads and the data comes back; it restored into a scratch database on
the same machine, so rebuilding the host from nothing is untested — and since
2G that also means the key set a restore needs
([ADR 0038](adr/0038-encryption-keys-are-separate-and-rotatable.md)) has never
been exercised anywhere but the machine that holds it. Off-host copies arrive
only while the workstation is running. Both are accepted risks for one small
instance, recorded so a later reader can tell a decision from an oversight.

### 2F — Retention — done

Purges run hourly from `SessionCleaner`
([ADR 0040](adr/0040-retention-deletes-what-nobody-touched.md)): timeline items
older than 90 days with no like, boost or reply; `announces` older than 180
days; and articles and comments hard-deleted 90 days after `deleted_at`, with
their image files unlinked. Nothing a report points at is deleted at any age.
Autovacuum guidance for the two tables the purges empty in bulk is in
`doc/sysop.md`.

P2-D4 said "nobody has bookmarked or interacted with", but `bookmarks` only
targets articles and comments — a timeline item cannot be bookmarked — so the
keep rule is likes, boosts and replies.
**Still never purge `bot_syndication_items`, or the articles a bot created.** The
ledger holds the `(bot_id, guid)` record of what each bot has posted; delete a
row and that bot republishes the entry. The two tables were `feed_items` and
`bot_feed_items`, one character apart, until
[ADR 0039](adr/0039-the-personal-stream-is-a-timeline.md) renamed the first to
`timeline_items` and [ADR 0041](adr/0041-rss-and-atom-are-syndication.md) the
second to `bot_syndication_items`. The near-miss is why this is written in the
ADRs and in the retention module, not left to the names.

### Decisions (made 2026-09-17)

- **P2-D1. No metrics endpoint.** The localhost-only detailed health view (2D) is the one place an operator polls. A metrics endpoint was declined: it is more surface to secure for history this instance does not yet need.
- **P2-D2. No error reporting service.** Errors go to the logs. Sending them to a third party would leak request data, and with no metrics endpoint there is no error counter either.
- **P2-D3. Releases are built in CI** on a project-owned Debian 12 image matching production, and attached to the GitHub release with a provenance attestation. **Amended by ADR 0037:** the deploy no longer installs that tarball — it builds the tag on the server — so the attestation now guards a manual install rather than the deploy.
- **P2-D4. Retention periods:** timeline items nobody interacted with, 90 days; announces, 180 days; soft-deleted rows, after the 90-day evidence window.

### Open — five permissions that enforce nothing

`Setup.default_permissions/0` grants `admin.manage_settings`,
`moderator.manage_comments`, `moderator.view_reports`,
`user.edit_own_content` and `user.manage_profile`, and no code consults any of
them. Each capability *is* guarded — by the route's role hook and an
authorship or role check in the context — so none is an open door; the
permission row simply is not what closes it. But ADR 0029 says a permission
that enforces nothing is a false statement to the operator about who can do
what: revoking `moderator.view_reports` from the moderator role changes
nothing, and nothing says so.

Its acceptance gate (`test/baudrate/setup/permissions_are_enforced_test.exs`)
was a tautology — it searched `lib/**/*.ex`, which includes the file that
*defines* the catalogue, so every permission was always "found". The gate now
excludes that file, has an anti-vacuity test, and names these five
explicitly, so a sixth fails the build.

Each needs a decision: wire it to a real `Setup.has_permission?/2` check, or
remove it from the catalogue. Wiring is the riskier half — gating
`/admin/settings` on a permission an existing role row happens to lack would
lock an operator out of their own instance — so it wants a migration that
backfills the grants, not just a check.

---

## Phase 3 — Federation reach (scope)

**Goal.** Conversations, mentions, profile changes and groups work the way Mastodon and Lemmy users expect.

**Done when:**
- a reply to a comment threads under that comment on Mastodon;
- a mentioned remote user is notified;
- Lemmy community activity arriving through a group appears here;
- profile and board edits reach followers;
- content warnings survive in both directions.

### 3A — Threading and mentions (M)

- [ ] **`inReplyTo` names the parent comment** when replying to a comment (`core/federation/publisher.ex:186`).
- [ ] **`Mention` tags.** `@user@domain` mentions in local articles and comments become `Mention` tags plus `cc` addressing, delivered to the mentioned actors.
  - Unknown handles are resolved via WebFinger, rate limited (P3-D2).

### 3B — Fetchable objects (M)

- [ ] **New local comments get a fetchable id,** `/ap/comments/:id`, served with the same visibility and federation gates as articles.
  - Today their ids are `/ap/users/:name#note-N`, which returns the actor document when fetched.
  - Existing comments keep their stored ids (P3-D1).
- [ ] **Polls are fetchable** as `Question` objects.

### 3C — Lemmy groups, FEP-1b12 (M)

- [ ] **Accept an `Announce` from a group that wraps `Create`, `Update`, `Delete`, `Like` or `Undo`** (`core/federation/inbox_handler.ex:948` drops them).
  - Each wrapped activity passes the same origin checks as a direct delivery, and is fetched by id when it is not embedded.
- [ ] **Interop tests** with recorded Lemmy fixtures, both for a Lemmy community a board follows and for a Lemmy user who follows a board.

### 3D — Profile, board and poll updates (S)

- [ ] **`Update(Person)`** when avatar, display name, bio or profile fields change, debounced.
- [ ] **`Update(Group)`** when a board's name, description or avatar changes.
- [ ] **`Update(Question)`** with final counts when a poll closes.
- [ ] **`Delete(Person)`** ships with self-service account deletion (6E).

### 3E — Content warnings and media (M)

- [ ] **Inbound:** store `summary` and `sensitive` in their own fields on articles, comments and timeline items, and render the content collapsed behind its warning. Today they are merged into the body (`core/federation/inbox_handler.ex:1219`).
- [ ] **Outbound:** an optional content warning in the local composer (articles, comments, timeline replies), sent as `summary` and `sensitive`.
- [ ] **Video and audio attachments** render as a link card to the original, never embedded, following the no-third-party rule. They are dropped today.

### 3F — Protocol hygiene (S)

- [ ] **NodeInfo:**
  - `localPosts` counts only local articles;
  - user totals exclude bots and banned users;
  - add active-user counts for one month and half a year (`core/federation/discovery.ex:85-100`).
  - Advertise NodeInfo 2.0 as well.
- [ ] Declare a JSON-LD namespace for the `baudrate:*` extension fields.
- [ ] Actor documents get a short cache lifetime instead of `no-store`.
- [ ] A `Follow` of a local user that arrives through the shared inbox creates no `new_follower` notification: `InboxHandler.notify_follow_target/2` only notifies for the `{:user, user}` target. Resolve the user from the `object` URI, as the block check (`follow_blocked_by_target?/2`) already does. Found while building 1A.

### Decisions needed

- [ ] **P3-D1. Comment ids.** [New comments use `/ap/comments/:id`; existing rows keep their stored `ap_id`, because other servers already know them.]
- [ ] **P3-D2. Resolving mentions of unknown handles.** [Resolve at post time with WebFinger, rate limited per user; leave the mention as plain text if it doesn't resolve.]

---

## Phase 4 — Discovery and onboarding (scope)

**Goal.** A first-time visitor understands what the site is and finds something to read; a new member gets to a first post without a dead end, and can always get back into the account.

**Done when:**
- a guest's first page shows recent content and the site's purpose;
- search engines index public content without duplicates;
- a new member is signed in and guided after registering;
- a locked-out member has a documented way back in (D3).

### 4A — Home and navigation (M)

- [ ] **Home page.**
  - Latest articles from public boards.
  - Board cards with post counts and last activity.
  - A site description, from a new admin setting `site_description`, which `web/open_graph.ex:151` already reads.
  - An empty state when there are no boards.
- [ ] **Branding for guests.**
  - The welcome text uses `site_name` instead of the hardcoded "Baudrate" (`web/live/home_live.html.heex:14`).
  - Guests on mobile see the site name.
  - The footer (1E) also links feeds.
- [ ] **New pages:** `/recent`, `/popular` (P4-D1) and `/unanswered`, plus a tag index at `/tags`.

### 4B — SEO and feeds (S)

- [ ] **`sitemap.xml`** for public boards and articles, paginated.
- [ ] **Canonical links and metadata.**
  - Canonical `<link>` on paginated pages.
  - `<meta name="description">`.
  - `noindex` on search, login and registration pages.
  - A real `robots.txt`.
- [ ] **Unknown users** return 404 instead of redirecting (`web/live/user_profile_live.ex:28-37`).
- [ ] **Feed links.**
  - Visible feed links on the home, board, user and tag pages.
  - User feeds advertised in `<head>`.
  - Tag feeds.

### 4C — Search (S)

- [ ] Sort by relevance or date, and filter by board and date.
- [ ] Page through users past the first 20 (`web/live/search_live.ex:398`).
- [ ] Search operators on the Comments tab.

### 4D — Onboarding and account recovery, D3 (M)

- [ ] **Signing in after registering (P4-D2).** Open mode signs the new member in, instead of sending them to `/login` (`web/live/register_live.ex:88`). A first-visit step asks for a display name and avatar.
- [ ] **Approval mode.** The pending page explains what happens next, and approval sends a notice (`core/auth/users.ex:140`).
- [ ] **Private pages** explain that signing in is needed, and bring the user back after sign-in.
- [ ] **Regenerate recovery codes** from `/profile`.
  - Behind step-up re-authentication (ADR 0022).
  - Old codes stop working.
  - Sends an always-delivered security notice.
- [ ] **Admin-assisted reset** (needs an ADR).
  - A single-use link that expires in 24 h, handed over through another channel.
  - Using it sets a new password, revokes sessions, and cancels exports and moves.
  - Sends a security notice and writes an audit entry.
  - The ADR decides what happens to TOTP and security keys, and covers the risk of an admin being talked into it.
- [ ] **Nudges** to store recovery codes and add a second factor.

### 4E — Sharing and PWA (S)

- [ ] **Service worker on every page,** independent of push (`assets/js/push_manager_hook.js:28-34`), with an offline fallback page.
- [ ] **Copy-link fallback** when `navigator.share` is missing (`assets/js/web_share_hook.js:15`).
- [ ] **"Follow from your instance":** a visitor enters their instance and is sent to its remote-follow page for a user or board.

### 4F — Privacy and language (S)

- [ ] **YouTube embeds** load only after a click (`web/components/core_components.ex:1011`).
- [ ] **Language switcher** for guests, kept in a cookie.
- [ ] **Translations:** fill the 5 empty strings in each of zh_TW and ja_JP.

### Decisions needed

- [ ] **P4-D1. What "popular" means.** [Likes, boosts and comments in the last 7 days, public boards only.]
- [ ] **P4-D2. Signing in after registering.** [Open mode: sign in at once. Approval mode: sign in as pending, which can read and edit the profile, as today after login. Invite mode: like open mode.]

---

## Phase 5 — Anti-spam (scope)

**Goal.** An instance with open registration survives a spam wave without an admin deleting posts one by one.

**Done when:** automated sign-ups are slowed down, new accounts cannot mass-post links, and moderators can stop a wave with filters and IP bans.

### 5A — Registration friction (S)

- [ ] **A self-hosted proof-of-work challenge** on registration (P5-D1). No third-party CAPTCHA, in line with the no-third-party rule.
- [ ] **Ban an account and the accounts it invited** in one audited action, using the invite chain (`invited_by_id`).

### 5B — Limits for new accounts (M)

- [ ] **A trust level, earned by age and approved activity (P5-D2).** Until a member earns it, they have lower rate limits, at most one link per post, no DMs to non-followers, and fewer images.

### 5C — Hold first posts (S)

- [ ] **An optional setting** that holds a new account's first post (or first N) in the Phase 1 moderation queue until a moderator approves it.

### 5D — Keyword and link filters (M)

- [ ] **Admin-managed filters** on words, patterns and domains.
  - Each filter blocks, holds for review, or flags (P5-D3).
  - Applied when local content is created and when remote content arrives.
  - Every match is audited.

### 5E — IP bans (S)

- [ ] **IP and CIDR bans** for registration and sign-in, with a reason and an optional expiry, audited.
  - Resolve addresses through `RealIp` only.

### Decisions needed

- [ ] **P5-D1. Challenge type.** [A self-hosted proof-of-work challenge; no external CAPTCHA.]
- [ ] **P5-D2. Trust thresholds.** [3 days old and 3 posts not removed; admins and moderators are always trusted.]
- [ ] **P5-D3. Filter actions.** [Block, hold for review, or flag; remote content can only be dropped or flagged.]

---

## Phase 6 — Member depth (scope)

**Goal.** Members who stay find that the site keeps up with them: they can fix mistakes, follow what matters, and control their account.

**Done when:**
- comments can be edited;
- notifications lead straight to the comment they are about;
- members can watch boards and threads;
- DMs notify;
- members can delete their account and manage their sessions.

### 6A — Comments and composer (M)

- [ ] **Edit your own comments,** with revision history like articles, federated as `Update(Note)` (P6-D1).
- [ ] **Alt text** on article, comment and reply images, federated as the attachment `name`. Today alt text is always "Image N".
- [ ] **Drafts on the server,** with a drafts list, next to the local autosave.

### 6B — Reading and notifications (M)

- [ ] **Per-comment "new since your last visit"** and a jump to the first unread comment.
- [ ] **The comments heading shows the total count,** not this page's (`web/live/article_live.html.heex:536`).
- [ ] **Guests see a "sign in to comment" prompt.**
- [ ] **Board lists show an "N new posts" banner** instead of re-rendering under the reader (`web/live/board_live.ex:162`).
- [ ] **Notifications link to the comment's anchor and page** (`web/live/notifications_live.ex:117`).
  - Group similar notifications ("5 people liked…").
  - Filter by type.
  - Notify when a poll you voted in closes.

### 6C — Watching and followers (M)

- [ ] **Watch a board or a thread,** and get notified of new posts or replies.
- [ ] **Your followers:** a list, a count, and a way to remove a follower (sends `Reject`).

### 6D — Direct messages (M)

- [ ] **Web push for new DMs.**
- [ ] **Image attachments in DMs,** reusing the upload pipeline.
- [ ] **Search your own conversations.**

### 6E — Account and privacy (L)

- [ ] **Self-service account deletion** (needs an ADR, P6-D2).
  - Cooling-off period and step-up re-authentication.
  - `Delete(Person)` to followers.
- [ ] **Session list:** browser family and last seen for each session, each with its own sign-out.
- [ ] **Time zones:** a per-user time zone, and a time-zone label on timestamps (`web/helpers.ex:28`).
- [ ] **Privacy settings:**
  - opt out of search and indexing (`noindex`, left out of search);
  - approve followers manually;
  - mute a domain;
  - mute keywords.
- [ ] **Data export and move pages (D4).**
  - Explain the TOTP rule and link to TOTP setup.
  - Show the date the member becomes eligible.
  - Say that the operator can run an export offline.
- [ ] **Split `/profile`** (887 lines, one save button per section) into sub-pages.

### Decisions needed

- [ ] **P6-D1. Editing comments.** [No time limit; every edit is kept in history, and moderators see all revisions.]
- [ ] **P6-D2. What account deletion removes.** [Profile, DMs and keys are deleted. Articles and comments are anonymized ("deleted user") by default, or deleted if the member chooses.]

---

## Phase 7 — Admin and content tools (scope)

**Goal.** Running the site doesn't need a shell or SQL.

**Done when:**
- an admin sees the site's state on one page;
- an admin can announce, reorganise content and fix bots from the UI.

### 7A — Admin dashboard (M)

- [ ] **`/admin`** shows members and growth, pending registrations, open reports, federation health, delivery backlog, disk space and the last backup (reusing the 2D checks).
- [ ] **Check `admin.view_dashboard`,** which is defined but unused.

### 7B — Announcements and site settings (S)

- [ ] **Admin announcements UI:** a notification plus a site-wide banner that can be dismissed. `Notification.create_admin_announcement/2` already exists.
- [ ] **A contact setting** (shown on the About and Rules pages).

### 7C — Content tools (M)

- [ ] **Move an article to another board,** audited and federated.
- [ ] **Move every article out of a board,** so the board can be deleted (`core/content/boards.ex:184`).
- [ ] **Keyboard-accessible board ordering** (move up and down) instead of a number field.

### 7D — Bots (M)

- [ ] **Bots list:** show the next fetch time and post counts.
  - A "fetch now" separate from "reset errors".
  - A dry-run preview of the next fetch.
- [ ] **What a bot posts:** include and exclude filters on title and content. The first fetch posts only the latest N entries, not the whole backlog (`core/bots/feed_worker.ex:118`).
- [ ] **Failures:** a bot is disabled automatically after N failed fetches, with an admin notice.
- [ ] **Conditional GET** (ETag and Last-Modified).

### 7E — Delivery dashboard (S)

- [ ] **Page through actionable jobs** (only 20 are shown today), filter by domain, and retry or abandon in bulk per domain.
- [ ] **Show open delivery circuits** (`DeliveryCircuits.list_tripped/0`) with their next probe time, and let an admin close one after fixing a problem on our side.

---

## Phase 8 — Contributor health (scope)

**Goal.** Someone other than the maintainer can set up, test and contribute safely.

**Done when:** a new contributor can go from clone to passing tests without installing Rust, and CI catches what reviews would.

### 8A — CI (M)

- [ ] **Static checks:** Dialyzer, a coverage report, and a check that gettext translations are extracted and up to date.
- [ ] **NIF crates:** `cargo clippy` and `cargo test` for the three NIF crates (they have no `#[test]` today).
- [ ] **Ansible:** `ansible-lint` on the playbooks.

### 8B — Repository files (S)

- [ ] CONTRIBUTING, SECURITY.md (how to report vulnerabilities), a code of conduct, and issue and PR templates.

### 8C — Local setup (M)

- [ ] **Precompiled NIFs** (`rustler_precompiled`) published with each release, so contributors don't need Rust.
- [ ] **Development database credentials** from the environment, with today's values as defaults (`config/dev.exs`).
- [ ] **`doc/door-apps-development.md`:** mark it as a proposal or remove it; no code backs it.

### 8D — Performance (M)

- [ ] **Outbox and collection pages:** batch the per-item preloads and counts (about 160 queries per page today; `core/federation/collections.ex:49,218`).
- [ ] **Large lists:** keyset pagination for the outbox and the long listings, where `core/pagination.ex:88-93` runs a full count every page.
- [ ] **LiveView streams** for the timeline, board, notification and conversation lists.
- [ ] **Cropper.js** loads only on the avatar editor.

---

## Backlog (not planned)

Kept so the review is complete. None of these are scheduled; propose moving one into a phase before working on it.

- **Scale and storage:** multi-node clustering (ruled out by D2), S3-compatible storage, CDN integration.
- **APIs:** a Mastodon-compatible client API, OAuth, a REST API, webhooks, plugins or themes.
- **Federation extras:**
  - custom emoji and quote posts;
  - relays and backfilling remote outboxes or threads;
  - the `featured` collection, `Add`/`Remove` and `contentMap`;
  - RFC 9421 signatures;
  - silence and reject-media domain levels;
  - outbound `Block` (ruled out by P1-D1).
- **Members:** group DMs, read receipts, emoji reactions, inline image placement, reply depth beyond 5, RTL layout, `hreflang` links.
- **Content tools:** splitting and merging threads, custom pages beyond Rules, Terms and Privacy.
- **Legal:** a takedown and legal-request workflow, age gating.
- **Email:** ruled out by D3.

---

## Recently completed

Full detail is in `CHANGELOG.md`; this is the short version of where the
project has been.

- **v1.27.0 — Phase 2G.** Secrets at rest are keyed per class, and every key
  can be rotated
  ([ADR 0038](adr/0038-encryption-keys-are-separate-and-rotatable.md)).
  `SECRET_KEY_BASE` had keyed all four at-rest secrets and could never be
  changed; two of the four were written down nowhere — the recovery-code
  hashes, which made the documented remedy for a lost TOTP secret circular,
  and the Web Push key. Stored values now name the key that wrote them and are
  bound to their row, so a ciphertext copied onto another account no longer
  decrypts.
- **v1.26.0 — Phase 2E.** Releases are built, smoke-tested and attested in CI
  on production's Debian release
  ([ADR 0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md)),
  with a rollback playbook that refuses a release the database has outgrown. It
  also closed a live hole: the co-hosted account could read Baudrate's Erlang
  cookie while distribution listened on every interface, which was code
  execution as the service account for any other account on the host — the
  firewall kept it off the internet, not off the machine. Installing the tarball then turned out to
  cost 13 minutes against 2 for an incremental build, so
  [ADR 0037](adr/0037-the-deploy-builds-on-the-server-again.md) reversed that
  one decision and the deploy compiles on the server again.
- **v1.25.0 — Phase 2D.** A detailed health report on a loopback-only listener
  ([ADR 0035](adr/0035-operational-visibility-stays-on-the-host.md)) — queues,
  worker heartbeats, disk and backup age, 503 when a check fails — and optional
  JSON logs with a metadata allow-list.
- **v1.24.0 — Phase 2C.** A change and its outgoing activities commit together
  ([ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)),
  so a restart no longer drops them; deliveries wake on commit, a server that is
  down pauses behind a per-domain circuit breaker, and the inbox stores an
  activity and answers at once while a worker processes it, one per remote
  account in order.
- **v1.23.0 — Phase 2B and 2H.** Baudrate officially runs on one node
  ([ADR 0033](adr/0033-baudrate-runs-on-one-node.md)); the old guide had called
  running several "idempotent" when it would have delivered every job twice
  and applied a domain block on one node only. CI tests production's
  PostgreSQL 15, server and client. The backup puller verifies one older copy
  per run, and no longer pulls a backup still being built.
- **v1.22.x — backups that prove they are intact, and policy documents.**
  Per-file checksums verified off-host; bilingual privacy policy and end user
  agreement written from the code; plus two ways the accept card failed
  silently — a re-accept checkbox that took two clicks, and an id ad blockers
  hid because `#policy-accept` looks like a cookie-consent bar.
- **v1.19.x – v1.21.0 — Phase 1**, trust and safety: blocks that stop
  interaction both ways, a report queue board moderators can use, sanctions
  with an explicit end, domain blocks as reversible rows with per-actor
  suspension, and public terms and rules with recorded, versioned acceptance
  (ADRs [0026](adr/0026-blocks-stop-interaction-locally.md),
  [0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md)–[0032](adr/0032-rules-are-records-and-retired-not-deleted.md)).
  Production backups started in v1.19.5.
- **v1.17.0 – v1.18.2 — data portability** (self-service export,
  [ADR 0023](adr/0023-data-export-threat-model.md), and account migration,
  [ADR 0025](adr/0025-account-migration.md); import was dropped) and **Phase
  0**, the twelve correctness bugs from the 2026-09-14 review.
