# TODOs

From a product review on 2026-09-14 (after v1.18.1) that looked at every role:
guests, members, board moderators, admins, sysops, remote instances and
contributors. Items marked **(confirmed)** were checked against the code, and
"absent" claims with grep. Paths are relative to the repository root, with
`lib/baudrate_web/…` shortened to `web/…` and `lib/baudrate/…` to `core/…`;
line numbers were correct as of v1.18.1.

**Current state (v1.28.2).** The review named five gaps: broken promises (the
UI or docs saying something happens when it does not), moderation reach,
operability, federation reach, and discovery and onboarding. The first three
are closed — Phase 0 in v1.18.2, Phase 1 in v1.21.0, Phase 2 with the
alerting item that followed v1.28.2. **Phase 3 is next.**

Every open item belongs to one of Phases 3–8 below, or to the Backlog. Work
phase by phase; within a phase, ship each stage as its own release. A completed
phase is summarised rather than listed — the detail lives in its ADRs and in
`CHANGELOG.md`, and this file keeps only what is recorded nowhere else: the
numbered decisions, the open items, and the risks the operator accepted
knowingly.

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
| ~~2~~ | ~~Operability~~ | 2A–2H | **Complete** (v1.23.0 – v1.28.0, plus 2A's alerting item) |
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
decisions rest on. Shipped v1.19.0–v1.21.0: **1A** blocks
([0026](adr/0026-blocks-stop-interaction-locally.md)), **1B** the report queue
board moderators can use (`doc/development.md`), **1C** sanctions
([0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md)), **1D** domain
blocks and per-actor suspension
([0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md)), **1E**
terms acceptance ([0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md))
and **1F** rules as records
([0032](adr/0032-rules-are-records-and-retired-not-deleted.md)). The decisions
behind it (P1-D1 … P1-D9, made 2026-09-14) are all implemented and live in
those records and the `CLAUDE.md` invariants.

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

Every stage's reasoning is in its record; this is only the index, so that
"Phase 2D" in an ADR resolves to something.

| Stage | What | Released | Recorded in |
|-------|------|----------|-------------|
| 2A | Backups, recovery, and the alert when a check fails | v1.23.0; alerting after v1.28.2 | [0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md), [0044](adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md) |
| 2B | One node (D2) | v1.23.0 | [0033](adr/0033-baudrate-runs-on-one-node.md) |
| 2C | Federation work commits before it is acknowledged | v1.24.0 | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) |
| 2D | The loopback-only health report, and JSON logs | v1.25.0 | [0035](adr/0035-operational-visibility-stays-on-the-host.md) |
| 2E | Deploy safety: CI-built releases, rollback, per-server cookie | v1.26.0 | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md), [0037](adr/0037-the-deploy-builds-on-the-server-again.md) |
| 2F | Retention: the hourly purges | v1.28.0 | [0040](adr/0040-retention-deletes-what-nobody-touched.md) |
| 2G | Key separation, and every key rotatable | v1.27.0 | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) |
| 2H | Drift: CI runs production's PostgreSQL, server and client | v1.23.0 | `ci/image/README.md` |

### Only recorded here

Everything else about Phase 2 is in its ADRs. These are the facts that are not.

- **The rotation path is exercised, not theoretical.** Production separated its
  keys on 2026-09-18 and has since rotated them once, end to end: 117 stored
  secrets re-keyed with none left unreadable, the retired key dropped from
  configuration, `encryption_keys` reporting `ok`.
- **`SECRET_KEY_BASE` is still not rotatable,** because 130 recovery-code
  hashes ride the old derivation. A recovery code is a keyed HMAC and cannot be
  re-keyed without the code, so they move only as members regenerate theirs.
  `Baudrate.Release.key_census/0` says when that reaches zero.
- **Retention's first production pass** (2026-09-18) removed 717 timeline
  items, 93 announces, 48 articles, 287 comments and 14 files, then settled.
- **P2-D4 said "nobody has bookmarked or interacted with", but `bookmarks`
  only targets articles and comments** — a timeline item cannot be bookmarked —
  so the keep rule is likes, boosts and replies.
- **Never purge `bot_syndication_items`,** the `(bot_id, guid)` ledger of what
  each bot has posted: delete a row and that bot republishes the entry. It was
  one character from `feed_items` until
  [0039](adr/0039-the-personal-stream-is-a-timeline.md) and
  [0041](adr/0041-rss-and-atom-are-syndication.md) renamed both, and the
  near-miss is why the exclusion is written down rather than left to the names.
- **The health alert cannot live inside the backup task.** That can only report
  a run that failed, never one that never happened — a masked timer, a disabled
  unit, a host down at the hour — and those are the silent cases 2A was about.
- **It still cannot tell you the server is down,** because it runs inside the
  server. That half stays with an external monitor, which `doc/sysop.md`
  documents and nobody has to build until they want it.

### Accepted knowingly

Recorded so a later reader can tell a decision from an oversight.

- **Production allows SSH login as root** (key only), deferred by the operator.
  `/etc/ssh/sshd_config.d/00-disable-password-auth.conf` sets
  `PermitRootLogin yes`, and sshd keeps the first value it reads, so the
  `common` role's `PermitRootLogin no` has no effect (`sshd -T`, 2026-09-15).
  The fix would be for the role to manage the drop-ins and assert the effective
  value.
- **No restore rehearsal onto a fresh host, and no always-on puller** (declined
  2026-09-18). The rehearsal that was done restored into a scratch database on
  the same machine, so rebuilding the host from nothing is untested — and since
  2G that also means the key set a restore needs
  ([0038](adr/0038-encryption-keys-are-separate-and-rotatable.md)) has never
  been exercised anywhere but the machine that holds it. Off-host copies arrive
  only while the workstation is running.
- **Publishing the release to a registry** is left open by
  [0037](adr/0037-the-deploy-builds-on-the-server-again.md), so the operator's
  machine could verify a digest and the server pull the bytes over its own
  link. Only worth doing if the artifact ever has to reach the server again.

### Decisions (made 2026-09-17)

- **P2-D1. No metrics endpoint.** The localhost-only detailed health view (2D) is the one place an operator polls. A metrics endpoint was declined: it is more surface to secure for history this instance does not yet need.
- **P2-D2. No error reporting service.** Errors go to the logs. Sending them to a third party would leak request data, and with no metrics endpoint there is no error counter either.
- **P2-D3. Releases are built in CI** on a project-owned Debian 12 image matching production, and attached to the GitHub release with a provenance attestation. **Amended by ADR 0037:** the deploy no longer installs that tarball — it builds the tag on the server — so the attestation now guards a manual install rather than the deploy.
- **P2-D4. Retention periods:** timeline items nobody interacted with, 90 days; announces, 180 days; soft-deleted rows, after the 90-day evidence window.

### Settled — the permission catalogue is documentation (ADR 0042)

Investigated 2026-09-18. The answer was *neither wire the unenforced
permissions nor delete them*:
[ADR 0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md)
records that roles are a fixed, totally ordered set of four and that
capabilities are not configurable — the matrix has no write path, there is no
roles screen, and only four of eleven permissions are consulted anywhere. Two
authorization defects the audit turned up were fixed in v1.28.1 and v1.28.2 (a
ban checked neither the permission nor the rank rule; article visibility had
four implementations, three of them missing the remote refusals — the edit
history page was the fourth and was found only after the first fix claimed
three).

The two follow-on questions are closed, not open:

- **No `/admin/roles` screen.** ADR 0042 stands. If it is ever revisited it
  supersedes 0042 and needs a migration that backfills grants, not just a
  check: gating `/admin/settings` on a permission an existing role row happens
  to lack locks an operator out of their own instance.
- **`Baudrate.Content.Feed` keeps its name** (operator's call, 2026-09-19).
  It is recent-content listings plus per-user statistics — a fifth sense of
  "feed" — but after ADR 0041 it collides with nothing, and splitting it would
  be a cohesion change, not a naming one.

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

### ~~3B — Fetchable objects~~ — **done** (unreleased)

Comments are served at `/ap/comments/:id` and polls at `/ap/polls/:id`, gated
by the owning article. Every existing row was rewritten from its fragment id
(P3-D1 as decided: the backfill, not the conservative option), with
`legacy_ap_id` keeping the identity peers already hold — matched on every
inbound path, and named alongside the new id in a withdrawal.
[ADR 0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md),
gate `test/baudrate/federation/object_identity_test.exs`.

Operators must run `Baudrate.Release.backfill_ap_ids()` once after the upgrade
(`doc/sysop.md`, "Data Repair: `ap_id` Backfill").

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
- ~~A `Follow` of a local user that arrives through the shared inbox creates no `new_follower` notification.~~ **Already fixed** while building 1A — `InboxHandler.notify_follow_target/2` resolves the user from the Follow's own target URI, as the block check always did. Struck 2026-09-19 after checking the code.

### Decisions (made 2026-09-19)

- **P3-D1. Comment and poll ids: rewrite them all.** Every local comment and poll moves to a dereferenceable path, existing rows included — not just new ones, which was the option originally drafted here. Leaving old ids in place would have left every conversation this instance has already had permanently unthreadable. The cost of rewriting a public identity is covered by `legacy_ap_id`: inbound matches either id, and a withdrawal names both. [ADR 0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md).
- **P3-D2. Resolving mentions of unknown handles: WebFinger at post time, rate limited per user.** A handle that does not resolve stays plain text, silently. `@alice` with no domain remains a local mention.
- **P3-D3. A mention addresses; it never widens the audience.** Not previously recorded. [ADR 0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md)'s gate decides whether content leaves, and a `Mention` becomes a surface *of* that gate rather than an exception to it: in a private or AP-disabled board a remote mention produces no tag, no `cc` and no delivery. Otherwise typing a handle would be a one-step way to exfiltrate a private board's article to any instance.

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
  - The footer (1E) also links the syndication feeds.
- [ ] **New pages:** `/recent`, `/popular` (P4-D1) and `/unanswered`, plus a tag index at `/tags`.

### 4B — SEO and syndication feeds (S)

- [ ] **`sitemap.xml`** for public boards and articles, paginated.
- [ ] **Canonical links and metadata.**
  - Canonical `<link>` on paginated pages.
  - `<meta name="description">`.
  - `noindex` on search, login and registration pages.
  - A real `robots.txt`.
- [ ] **Unknown users** return 404 instead of redirecting (`web/live/user_profile_live.ex:28-37`).
- [ ] **Syndication feed links** (`SyndicationFeedController` already serves
  site, board and user RSS and Atom; this is about finding them).
  - Visible links on the home, board, user and tag pages.
  - User feeds advertised in `<head>`.
  - Tag feeds, which do not exist yet.

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
- [ ] **What a bot posts:** include and exclude filters on title and content. The first fetch posts only the latest N entries, not the whole backlog (`core/bots/syndication_feed_worker.ex`).
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

## Closed by the ADR audit (2026-09-19)

A record-by-record check of all 46 ADRs against the code. Most held; seven did
not, and all seven are now closed. Kept as a short index because each left
something behind that is not obvious from the record it fixed.

- **Origin binding had no ADR** → [0046](adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md).
  Sixteen call sites, seven distinct attacks, one rule. Writing it turned up a
  second, divergent `same_host?/2` private to `InboxHandler` that accepted two
  hostless URIs as same-origin where the Validator's rejects them — and it was
  the copy guarding the fetched-Announce object id and the `attributedTo`
  binding. It now delegates.
- **ADR 0016's invariant did not hold for article moderation** → fixed by
  taking the actor into `toggle_pin_article/2`, `toggle_lock_article/2`,
  `soft_delete_article/2` and `soft_delete_comment/2`, which reload it.
  Reloading is not incidental: `can_delete_article?` matches on
  `%{role: %{name: "admin"}}`, so an admin passed in with `:role` unloaded
  would have fallen to the board-moderator branch and been silently denied.
  A delete must now name its actor or say `remote: true`.
- **ADR 0002's facade rule was stricter than the code** →
  [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md)
  narrows it to the operations that change the world and names the five exempt
  categories; `Federation` gains the five mutating moderation delegates the
  admin LiveViews were bypassing it for. Deliberately no acceptance gate —
  "changes the world" is a judgement, and the record says so.
- **Poll anonymity had no ADR** →
  [0048](adr/0048-a-poll-records-who-voted-and-nothing-reads-it-back.md), with
  `test/baudrate/content/poll_anonymity_test.exs` as the gate. The record is
  explicit that this is anonymity from other members, not from the operator.
- **Changeset allow-lists had no ADR** →
  [0049](adr/0049-user-facing-changesets-are-allow-lists.md). It is the local
  half of 0046: that record stops a remote host minting our URIs, this stops a
  member minting theirs, and the unique `ap_id` column needs both.
- **ADR 0036 decision 1 lost its third enforcer** → the deploy asserts the
  host's Debian release again. What it defends changed with
  [0037](adr/0037-the-deploy-builds-on-the-server-again.md) and got stronger:
  the release is built here now, so a drifted host silently becomes the system
  the binary is built against, and `debian_version` also fixes the PostgreSQL
  client major — a 17+ `pg_dump` against the 15 server breaks the pre-deploy
  dump and the nightly backups rather than the deploy.
- **ADR 0018 was violated by `app.css`** → the three `.card:has(> .card-body >
  .stretched-link)` rule sets now hang off a `tappable-card` semantic class on
  the five cards that are pressable as a whole. The pressed selector keeps two
  branches on purpose: an article card holds independently clickable links and
  `:active` propagates to ancestors, so a bare `:active` would flash the card
  when you press the author.
- **ADR 0024 §6** → `totp_setup_live.html.heex` carries the single-use hint,
  and `test/baudrate_web/totp_code_hint_test.exs` is the gate that notices the
  next one. Eight templates had it and nothing checked the ninth.

**Settled, not open: the Aqua themes keep their `.card > .card-body`
selectors** (`aquaosx.css:235,245`, `aquaosx-dark.css:217,222`; operator's
call, 2026-09-19). The audit listed them with the `app.css` rule sets, and
that was an overreach. They are imported into `app.css`, so the file-scope
reading does not save them — but their subject does: `[data-theme="aquaosx"]
.card > .card-body:has(> .card-title)` normalises padding for **any** card
carrying an Aqua title bar, so that the full-bleed bar below it meets the
border flush whether the card uses `p-4` or daisyUI's default. The rule is
about the component's shape, and naming a specific element is what would
break it. ADR 0018's concern is custom CSS hooked onto structure *in place
of* a semantic handle the element could have had; there is no such handle
here, and adding one per card body would touch dozens of templates while the
theme still had to target the component. Do not re-file this.

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

`CHANGELOG.md` has the detail and each ADR has the reasoning; this is only the
shape of where the project has been.

| Release | What | Recorded in |
|---|---|---|
| v1.28.2 | What a documentation audit found by reading the guides against the code: a fourth copy of the article visibility check on the edit-history page, and a periodic worker the health report could not see | [0035](adr/0035-operational-visibility-stays-on-the-host.md) |
| v1.28.1 | Two authorization fixes from the RBAC investigation: a ban checked neither the permission nor the rank rule; article visibility had four implementations, three missing the remote refusals (the fourth was found in v1.28.2) | [0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md), [0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md) |
| v1.28.0 | Phase 2F retention; the personal stream became the timeline and RSS/Atom became syndication; the outbound board gate completed at five surfaces; a security audit, an a11y sweep and a code review | [0039](adr/0039-the-personal-stream-is-a-timeline.md), [0040](adr/0040-retention-deletes-what-nobody-touched.md), [0041](adr/0041-rss-and-atom-are-syndication.md) |
| v1.27.0 | Phase 2G: secrets at rest keyed per class and every key rotatable. `SECRET_KEY_BASE` had keyed all four at-rest secrets and could never be changed; two were written down nowhere — the recovery-code hashes, which made the documented remedy for a lost TOTP secret circular, and the Web Push key | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) |
| v1.26.0 | Phase 2E: releases built, smoke-tested and attested in CI on production's Debian. Closed a live hole — the co-hosted account could read the Erlang cookie while distribution listened on every interface. Installing the tarball then cost 13 minutes against 2 for an incremental build, so the deploy compiles on the server again | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md), [0037](adr/0037-the-deploy-builds-on-the-server-again.md) |
| v1.25.0 | Phase 2D: a loopback-only detailed health report, and optional JSON logs with a metadata allow-list | [0035](adr/0035-operational-visibility-stays-on-the-host.md) |
| v1.24.0 | Phase 2C: a change and its outgoing activities commit together, so a restart no longer drops them; deliveries wake on commit, a per-domain circuit breaker, an inbound queue ordered per remote account | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) |
| v1.23.0 | Phase 2B and 2H: one node officially — the old guide called running several "idempotent" when it would have delivered every job twice; CI tests production's PostgreSQL 15, server and client | [0033](adr/0033-baudrate-runs-on-one-node.md) |
| v1.22.x | Backups that prove they are intact (per-file checksums verified off-host); bilingual privacy policy and EUA; two ways the accept card failed silently, including an id ad blockers hid because `#policy-accept` looks like a cookie bar | [0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md) |
| v1.19.x–v1.21.0 | Phase 1, trust and safety: blocks that stop interaction both ways, a report queue board moderators can use, sanctions with an explicit end, domain blocks as reversible rows, public terms and rules with versioned acceptance. Production backups started in v1.19.5 | [0026](adr/0026-blocks-stop-interaction-locally.md), [0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md)–[0032](adr/0032-rules-are-records-and-retired-not-deleted.md) |
| v1.17.0–v1.18.2 | Data portability (self-service export and account migration; import was dropped) and Phase 0, the twelve correctness bugs from the 2026-09-14 review | [0023](adr/0023-data-export-threat-model.md), [0025](adr/0025-account-migration.md) |
