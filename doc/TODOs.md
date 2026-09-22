# TODOs

From a product review on 2026-09-14 (after v1.18.1) that looked at every role:
guests, members, board moderators, admins, sysops, remote instances and
contributors. Items marked **(confirmed)** were checked against the code, and
"absent" claims with grep. Paths are relative to the repository root, with
`lib/baudrate_web/…` shortened to `web/…` and `lib/baudrate/…` to `core/…`;
line numbers were correct as of v1.18.1.

**Current state (v1.34.0, deployed 2026-09-21).** The review named five
gaps: broken promises (the UI or docs saying something happens when it does
not), moderation reach, operability, federation reach, and discovery and
onboarding. **All five are now closed** — Phase 0 in v1.18.2, Phase 1 in
v1.21.0, Phase 2 with the alerting item that followed v1.28.2, Phase 3 in
v1.31.0, and Phase 4 across v1.32.0–v1.34.0.

**Phase 5 is under way.** It was deferred on 2026-09-21 so that 6A could go
first — comment editing and image descriptions in v1.35.0, server-side drafts in
v1.36.0 — and planned on 2026-09-22 as three releases. The first, 5A + 5E, shipped
in v1.37.0; 5B shipped in v1.38.0; 5C + 5D are built and waiting to be
released as v1.39.0, which completes the phase. Its three decisions are
settled and recorded below.

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
- **D3. Email: stay without it.** Done (4D). Recovery codes stay the only
  self-service route, they can now be replaced, and past them recovery is
  anchored on an OpenPGP key verified out of band —
  [ADR 0058](adr/0058-account-recovery-is-anchored-outside-the-instance.md)
  records why that is better than adding a mailer, and what it costs.
- **D4. Data export and move gate: keep "TOTP enabled for ≥ 7 days"** ([ADR 0023](adr/0023-data-export-threat-model.md), [ADR 0025](adr/0025-account-migration.md)), and improve the path for members in 6E. Accepting WebAuthn in step-up re-authentication stays a separate possible feature.

---

## Roadmap

Each phase settles its decisions and gets its own implementation plan before work starts. Sizes: S ≈ a day, M ≈ a few days, L ≈ a week.

| Phase | Theme | Stages | Why |
|-------|-------|--------|-----|
| ~~1~~ | ~~Trust and safety~~ | 1A–1F | **Complete** (v1.19.0 – v1.21.0) |
| ~~2~~ | ~~Operability~~ | 2A–2H | **Complete** (v1.23.0 – v1.28.0, plus 2A's alerting item) |
| ~~3~~ | ~~Federation reach~~ | 3A–3F | **Complete** (v1.31.0) |
| ~~4~~ | ~~Discovery and onboarding~~ | 4A–4F | **Complete** (v1.32.0 – v1.34.0) |
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

Everything else about Phase 2 is in its ADRs, in `CLAUDE.md` and in
`doc/sysop.md`. These are the facts that are not.

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
- **P2-D4 says "nobody has bookmarked or interacted with", but `bookmarks`
  only targets articles and comments** — a timeline item cannot be bookmarked —
  so the keep rule is likes, boosts and replies.
- **There is no `/admin/roles` screen, and adding one would not be a screen.**
  [0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md)
  settled that roles are a fixed ordered set of four and capabilities are not
  configurable. Revisiting it supersedes 0042 *and* needs a migration that
  backfills grants: gating `/admin/settings` on a permission an existing role
  row happens to lack locks an operator out of their own instance.
- **`Baudrate.Content.Feed` keeps its name** (operator's call, 2026-09-19). It
  is recent-content listings plus per-user statistics — a fifth sense of
  "feed" — but after [0041](adr/0041-rss-and-atom-are-syndication.md) it
  collides with nothing, and splitting it would be a cohesion change rather
  than a naming one.

### Accepted knowingly

Recorded so a later reader can tell a decision from an oversight.

- **Production allows SSH login as root** (key only), deferred by the operator.
  `/etc/ssh/sshd_config.d/00-disable-password-auth.conf` sets
  `PermitRootLogin yes`, and **sshd keeps the first value it reads**, so the
  `common` role's `PermitRootLogin no` has no effect (`sshd -T`, 2026-09-15).
  The fix would be for the role to manage the drop-ins and assert the
  effective value.
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

- **P2-D1. No metrics endpoint.** The loopback-only health report (2D) is the
  one place an operator polls; a metrics endpoint is more surface to secure
  for history this instance does not need yet.
- **P2-D2. No error reporting service.** Errors go to the logs. A third party
  would receive request data, and with no metrics endpoint there is no error
  counter either.
- **P2-D3. Releases are built in CI** on a project-owned image matching
  production, attested and attached to the GitHub release. **Amended by
  [0037](adr/0037-the-deploy-builds-on-the-server-again.md):** the deploy
  builds on the server instead, so the attestation now guards a manual install
  rather than the deploy.
- **P2-D4. Retention periods:** timeline items nobody interacted with, 90 days;
  announces, 180 days; soft-deleted rows, after the 90-day evidence window.

---

## Phase 3 — Federation reach — **complete** (v1.31.0)

**The aim it served:** conversations, mentions, profile changes and groups
behaving the way Mastodon and Lemmy users expect — so that what leaves this
instance arrives as the thing it is, rather than as something the receiving
server has to guess at.

All five goals are met **in code**: a reply threads under the comment it
answers; a mentioned remote user is notified; Lemmy community activity
arriving through a group appears here; profile and board edits reach
followers; content warnings survive in both directions. None of the five has
been seen working against a real peer, which is the phase's one open item
below.

### Done

Released as v1.31.0 and deployed 2026-09-20. v1.31.1 followed the same day
with a `sobelow_skip` annotation and nothing else (`CHANGELOG.md`). Each
stage's reasoning is in its record; this table is the index, so that "3C" in a
commit or an ADR resolves to something.

| Stage | What | Recorded in |
|-------|------|-------------|
| 3A | `inReplyTo` names the parent comment; `@user@domain` is its own syntax, resolved behind the board gate | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md), `mentions_test.exs` |
| 3B | Comments and polls are objects with their own URIs; every existing fragment id rewritten, `legacy_ap_id` keeping what peers already hold | [0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md), `object_identity_test.exs`, and [0060](adr/0060-an-edit-is-kept-and-the-history-is-public.md) for what an `Update` may name |
| 3C | A group's `Announce` is a carrier, unwrapped one level, and the group speaks only for its own host | [0053](adr/0053-a-group-announce-is-a-carrier.md), `group_announce_test.exs` |
| 3D | `Update(Person)`/`Update(Group)` on any rendered-document change; a closed poll announces its final counts once | no ADR; `CLAUDE.md` |
| 3E | `summary`/`sensitive` are fields, never a body prefix; video and audio are links | [0052](adr/0052-a-content-warning-is-a-field-not-a-prefix.md), `content_warning_test.exs` |
| 3F | NodeInfo counts honestly and serves 2.0 as well as 2.1; every `baudrate:` term is declared | no ADR; `protocol_hygiene_test.exs` |

Three decisions were taken and all three are now records, which hold the
reasoning: **P3-D1** — comment and poll ids were rewritten for **existing**
rows too, not only new ones as originally drafted; leaving the old ones would
have left every conversation this instance had already had permanently
unthreadable ([0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md)).
**P3-D2** — an unknown `@user@domain` resolves by WebFinger at post time, rate
limited per user, and one that does not resolve stays plain text, silently;
`@alice` with no domain is still a local mention.
**P3-D3** — a mention addresses and never widens the audience: it is a surface
*of* [0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md)'s
outbound gate rather than an exception to it, or typing a handle would be a
one-step way to get a private board's article to any instance. Both live in
[0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md).

### Only recorded here

Everything else is in those records, in `CHANGELOG.md`, `doc/api.md` and
`doc/sysop.md` — including the two refusals that were noted here while they
had nowhere else to live: a carried activity is never fetched when it is not
embedded ([0053](adr/0053-a-group-announce-is-a-carrier.md), decision 6), and
`Update(Person)` is never debounced (`CLAUDE.md`). Both read as obvious
improvements from outside, and both records say why they are not. These are
the facts that are still nowhere else.

- **Interop is unverified, and it is this phase's one open item.** Against a
  real Mastodon account and a real Lemmy community: thread a reply, send a
  mention, edit a display name, post with a content warning, follow a
  community. Only a peer can prove interop, so "met in code" is not "seen
  working". It has outlived Phase 4 and 6A's first half untouched — which is
  the signal, not a reproach: nothing has ever depended on it, so nothing will
  make it happen by itself.

- **The `ap_id` backfill has been run here** (2026-09-20: 47 comments, 0
  articles, 0 polls; a re-run reports `0/0`), so there is nothing left to do.
  Worth a line only because `doc/sysop.md` writes the procedure for an
  operator who still has to run it, and this one does not.

---

## Phase 4 — Discovery and onboarding — **complete**

**The aim it served:** a boring but friendly environment for online discussion
([ADR 0056](adr/0056-boring-but-friendly.md)). Discovery here means helping
someone find the board they want, never deciding what they should look at
today.

All four goals are met: a guest's first page shows the site's purpose and its
boards; search engines index public content without duplicates; a new member
is signed in and guided after registering; and a locked-out member has a
documented way back in.

### Done

| Stage | What | Released | Recorded in |
|-------|------|----------|-------------|
| 4A | Home and navigation: the boards-only home page, last activity on a board card, `site_description`, guest branding, footer feed links | empty state v1.32.0, rest v1.33.0 | [0054](adr/0054-attention-follows-the-board-not-a-ranking.md), [0055](adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md) |
| 4B | SEO and syndication feeds: `sitemap.xml`, a real `robots.txt`, canonical/description/`noindex`, 404 for a missing account, per-page and tag feeds | v1.33.0 | [0057](adr/0057-a-sitemap-invites-only-what-a-guest-sees.md) |
| 4C | Search: relevance or date sorting, a board and date filter, the same operators on the Comments tab, a paged Users tab capped at five pages | v1.33.0 | `doc/development.md` (Search), spec rows under [0054](adr/0054-attention-follows-the-board-not-a-ranking.md)/[0055](adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md)/[0057](adr/0057-a-sitemap-invites-only-what-a-guest-sees.md) |
| 4D | Onboarding and account recovery: sign-in on registering, `/welcome`, private pages that bring you back, replaceable recovery codes, OpenPGP recovery contacts, admin-issued reset links | v1.33.0 | [0058](adr/0058-account-recovery-is-anchored-outside-the-instance.md), `doc/sysop.md` (the operator's procedure) |
| 4E | Sharing and PWA: the service worker on every page with an offline fallback, a copy-link share fallback, follow-from-your-instance | v1.34.0 | [0059](adr/0059-the-service-worker-caches-the-shell-and-never-content.md), `doc/development.md` (the service worker; Follow from your instance) |
| 4F | Privacy and language: the footer language switcher and a one-year `locale` cookie | v1.32.0 | `doc/development.md` (resolution order, cookie inventory) |

Three decisions were taken and all three are now records, which hold the
reasoning and what is deliberately unaffected: **P4-D1** — the site ranks
nothing and rivers nothing ([0054](adr/0054-attention-follows-the-board-not-a-ranking.md),
narrowed by [0055](adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md),
premised on [0056](adr/0056-boring-but-friendly.md)); **P4-D2** — registering
signs you in, with the recovery codes still in front of the session;
**P4-D3** — an admin verifies an OpenPGP signature from a pre-registered
address before resetting an account ([0058](adr/0058-account-recovery-is-anchored-outside-the-instance.md)).
Reversing any of it needs a superseding record, not a patch.

### Only recorded here

Everything else lives in those records, in `CHANGELOG.md` and in the
moduledocs — including two lessons that started here and have since moved to
where the code is: why changing language on `/profile` used to render dead
HTML (`CLAUDE.md`, the locale gotcha) and why a board's last-activity time
shares the unread badge's filters (`Content.Boards.last_activity_by_board/1`).
These are the facts that are still nowhere else.

- **Reading a stage's list against the code changed the stage, every time.**
  Not once in six. 4F's YouTube item had already shipped and its translation
  item counted the PO header. 4B's items were right, but what "Unlisted"
  *means* was not among them. None of 4C's three described the real work:
  relevance ranking was written and thrown away on the next line, the Comments
  tab had been ordered oldest-first for its whole life, and
  `?q=after:2026-01-01` returned every article the viewer could see —
  `/recent` through the search box, which
  [0055](adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md) had refused
  through the router. Half of 4D's six were worse than written and one was not
  implemented at all: no way existed to mint recovery codes after account
  creation, so a member who spent all ten had lost the account, in a system
  with no email. 4E's three were all understated — registration was gated on a
  **VAPID key**, so an instance that never configured push could not be
  installed at all; the share button's "fallback" was two bugs, the second in
  the clipboard hook it would reuse; and the WebFinger lookup behind
  follow-from-your-instance was missing `refuse_blocked: true`, covered only
  by a downstream re-check that flow does not have.
  **The list is a prompt to go and read, never a specification.**

- **A fix drifts to wherever the rule is written twice.** 4E found
  `doc/examples/nginx.conf.example` still carrying both bugs the Ansible
  template had lost hours earlier, because the new gate watched one of the two
  files. A gate over one of two copies reports a rule that is half enforced.

- **A number in a TODO goes stale the next time anyone runs
  `gettext.extract`,** so the translation chore became a gate
  (`translation_coverage_test.exs`) rather than a recurring line here.

- **"An empty state when there are no boards" was the wrong question.** No
  boards cannot happen — setup seeds SysOp and `delete_board/1` refuses to
  remove it. **No board this *viewer* may see** can: nothing stops an admin
  raising SysOp's `min_role_to_view`, which empties the list for every guest,
  who was then told to "browse the boards below" with nothing below. The empty
  state never distinguishes "none exist" from "none for you", because that
  difference is what `min_role_to_view` is keeping.

- **4A added no new page.** `/recent` and `/popular` went with P4-D1;
  `/unanswered` and a `/tags` index with
  [0055](adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md). All four
  are in `@ranking_paths`, so mounting one fails the build. `/tags/:tag`
  already existed and is untouched — the reader named the tag.

---

## Phase 5 — Anti-spam (scope)

**Goal.** An instance with open registration survives a spam wave without an admin deleting posts one by one.

**Done when:** automated sign-ups are slowed down, new accounts cannot mass-post links, and moderators can stop a wave with filters and IP bans.

**Planned 2026-09-22, three releases:** 5A + 5E (the door), then 5B (trust),
then 5C + 5D — 5D's "hold for review" has nowhere to put a submission until 5C
exists. The first, 5A + 5E, shipped in v1.37.0; 5B in v1.38.0; 5C + 5D are
built for v1.39.0.

### 5A — Registration friction (S) — **shipped in v1.37.0**

The proof-of-work challenge and the invite-chain ban
([ADR 0063](adr/0063-the-door-is-defended-by-work-not-by-a-third-party.md),
which records the two things the plan got wrong: the difficulty, and "one solve,
one attempt" needing the success case too). Tried on a real phone after the
release: a Pixel 8a at 20 bits had its answer before its owner finished the
form. The default stays 18 for older phones; `Baudrate.Auth.Challenge`'s
moduledoc keeps the numbers.

### 5B — Limits for new accounts (M) — **shipped in v1.38.0**

Trust by age and posts still up, decided when asked
([ADR 0064](adr/0064-a-new-account-is-slowed-down-not-shut-out.md)). Five
things the plan did not say, all recorded there: the article edit page attached
uploads to the live post with **no check at all** (ADR 0029's included); a link
counter that read `href` as text missed `//host` and `/\host`, so
`extract_urls/2` resolves links as a browser does; the per-kind buckets became
**one** bucket taken at the context boundary; a signature, rendered under every
article, may gain no link or image; and a new account may also DM someone who
wrote first, or staff. Building the DM rule found that "Followers
only" admitted no local follower at all.

### 5C — Hold first posts (S) — **built for v1.39.0**

A held post is a row in `held_posts`, and approval replays creation as the
author with the row's delete as the first step of the same transaction
([ADR 0065](adr/0065-what-waits-for-review-is-not-content-yet.md)). Three
things the plan did not say, all recorded there: only a composer can hold, so
every composer now *submits* (`Content.submit_article/3` /
`submit_comment/2`) and a build check keeps it that way; one review page,
`/moderation/held`, for staff and board moderators alike, scoped to what each
could approve; and a held post passes every gate a published one must before
it is held, including a new account's hourly allowance. The orphan image
sweeps spare a pending post's uploads. Building it found that resuming a
draft with a board chosen had crashed the composer since v1.36.0.

### 5D — Keyword and link filters (M) — **built for v1.39.0**

Words, text anywhere and linked domains, never regular expressions, matched
in linear time over text as a reader sees it, at `/admin/filters` (ADR 0065).
What the plan did not say: an edit is judged by what it *adds*, as ADR 0064
judges links, and an edit a `hold` filter matches is refused, because it
cannot wait; remote content arrives by five routes and is screened on all of
them; **direct messages are never screened**; matches are recorded without
their text, in a table of their own rather than the moderation log. The browser
crawl caught the filter form crashing on its first keystroke — after it was
changed to read its error log *after* typing into forms rather than before.

### 5E — IP bans (S) — **shipped in v1.37.0**

Built with 5A, under the same record, with sign-in checked at
`establish_session/3` — the one function every sign-in path ends in — rather
than at `create/2` alone as planned.

### Decisions (made 2026-09-22)

- **P5-D1. Challenge type:** a self-hosted proof-of-work challenge, no external
  CAPTCHA ([ADR 0006](adr/0006-media-proxy-no-third-party-subresources.md)), in all three
  registration modes — `approval_required` still lets a bot mint pending
  accounts, and each one notifies every admin.
- **P5-D2. Trust thresholds:** 3 days old **and** 3 posts not removed. Admins
  and moderators are always trusted; an invite grants nothing, which is the case
  5A's second item exists for.
- **P5-D3. Filter actions:** block, hold for review, or flag; remote content can
  only be dropped or flagged.

---

## Phase 6 — Member depth (scope)

**Goal.** Members who stay find that the site keeps up with them: they can fix mistakes, follow what matters, and control their account.

**Done when:**
- comments can be edited;
- notifications lead straight to the comment they are about;
- members can watch boards and threads;
- DMs notify;
- members can delete their account and manage their sessions.

### 6A — Comments and composer (M) — **complete**

Comment editing with a public history
([ADR 0060](adr/0060-an-edit-is-kept-and-the-history-is-public.md)) and image
descriptions ([ADR 0061](adr/0061-an-image-description-is-not-a-form-field.md))
shipped in v1.35.0. Server-side drafts
([ADR 0062](adr/0062-a-draft-is-kept-in-two-places-on-purpose.md)) shipped in
v1.36.0: articles only, beside the localStorage autosave rather than
instead of it, because the two fail in opposite directions.

Two things this stage deliberately left standing:

- `/articles/:slug/history` still cannot show what the **most recent** edit
  changed, because a revision holds the state *before* a change.
  `CommentHistoryLive` renders the live text as a version to close that; the
  article page was left alone.
- The article **edit** composer has no server draft. An unsaved rewrite is
  still covered by the localStorage hook and the published text is never at
  risk, so this is deferred rather than refused — it needs a draft that
  belongs to an article, and a rule for what happens when that article is
  edited from elsewhere in between (ADR 0062's rejected alternatives).

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

- [x] **P6-D1. Editing comments.** Decided 2026-09-21: no time limit, every edit kept, **the history is public** (not just moderators — the reader who was replied to is who needs it), and **the author alone may edit** — an admin edit would rewrite attributed speech. [ADR 0060](adr/0060-an-edit-is-kept-and-the-history-is-public.md).
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
