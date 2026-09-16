# TODOs

This list comes from a product review done on 2026-09-14, after v1.18.1, which looked at every role: guests, members, board moderators, admins, sysops, remote instances and contributors. Items marked **(confirmed)** were checked against the code, and "absent" claims were checked with grep.

Paths are relative to the repository root. `lib/baudrate_web/…` is shortened to `web/…` and `lib/baudrate/…` to `core/…`. Line numbers were correct as of v1.18.1.

Phase 0 (correctness bugs) shipped in v1.18.2. Every other open item is assigned to one of Phases 1–8 below, each with stages, acceptance criteria and the decisions it needs, or listed in the Backlog. Work phase by phase; within a phase, ship each stage as its own release.

Baudrate is already strong on security engineering, ADRs, accessibility plumbing and test coverage. At review time, the gaps were:
- **Broken promises:** the UI or docs say something happens and it doesn't.
- **Moderation reach:** tools exist but not for the right people.
- **Operability:** backups, observability, and an unclear single-node stance.
- **Federation reach:** our interactions don't reach remote authors.
- **Discovery and onboarding** for new visitors.

---

## Decisions (made 2026-09-14)

- **D1. Local post visibility.** Remove "Followers only" and "Direct" from local composers and keep Public and Unlisted.
  - Boards are public spaces whose audience is set by the board's view role, and direct messages are the private channel.
  - Implemented by B4.
- **D2. Scale target: one server.** Baudrate officially supports a single node. Implemented by 2B.
- **D3. Email: stay without email.** Recovery is covered by three additions instead: 4D.
- **D4. Data export and move gate: keep "TOTP enabled for ≥ 7 days"** (ADR 0023, ADR 0025), and improve the path for members: 6E.
  - Accepting WebAuthn in step-up re-authentication remains a separate possible feature.

---

## Roadmap

Each phase settles its decisions and gets its own implementation plan before work starts. Sizes: S ≈ a day, M ≈ a few days, L ≈ a week.

| Phase | Theme | Stages | Why |
|-------|-------|--------|-----|
| 1 | Trust and safety | 1A–1F | A public hub can't grow without moderation reach |
| 2 | Operability | 2A–2H | Data loss and blind operations are the biggest risks |
| 3 | Federation reach | 3A–3F | Threading, mentions, Lemmy groups and profile changes don't federate |
| 4 | Discovery and onboarding | 4A–4F | Turns visitors into members, and keeps them able to sign in |
| 5 | Anti-spam | 5A–5E | Growth from Phase 4 attracts spam |
| 6 | Member depth | 6A–6E | Retention |
| 7 | Admin and content tools | 7A–7E | Running the site without a shell |
| 8 | Contributor health | 8A–8D | Lowers the bus factor of one |

---

## Phase 1 — Trust and safety (scope)

**Goal.** Everyone who has to act on abuse can act, at the right level, and everyone affected by a decision is told about it.

**Done when:**
- a member can protect themselves without asking staff;
- a board moderator can handle reports about their board without the admin area;
- a global moderator can sanction a user short of a permanent ban;
- every sanction and report outcome is audited and reaches the people it concerns;
- the site publishes the rules those decisions rest on.

Work happens in five stages, each shipped and released on its own, in this order. Sizes are rough (S ≈ a day, M ≈ a few days, L ≈ a week).

### 1A — Member self-protection (S) — released in v1.19.0

Blocking semantics are recorded in [ADR 0026](adr/0026-blocks-stop-interaction-locally.md).

### 1B — A report queue that works, including for board moderators (L) — released in v1.20.0

- [x] **Queue basics** (2026-09-16): `Moderation.paginate_reports/1` (20 a page, status and page in the URL), links to the reported content, account or actor, the full reported text, `other_open_report_counts/1` next to each report, and a required reason category (P1-D9) on every report made on this site.
- [x] **Scoped queue for board moderators** (2026-09-16): `/moderation` (`ModerationLive`), scoped by `Content.moderated_board_ids/1`, linked from each board they moderate, with every action re-checking `Moderation.report_in_boards?/2` and the delete permission.
- [x] **Who hears about a new report** (2026-09-16): every admin and global moderator (`Setup.staff_user_ids/0`), plus the board moderators of the reported content's board.
- [x] **Outcome notices (P1-D4)** (2026-09-16): `report_reviewed` to the reporter on resolve, `content_removed` (always delivered) to the author with the report's reason category; dismissals notify nobody.
- [x] **Cross-posted articles (P1-D5)** (2026-09-16): `board_moderator_for_all?/2` gates delete, pin, lock and comment deletion; `can_remove_from_board?/3` lets a board moderator take the article out of their own board.
- [x] **Moderator actions** (2026-09-16): `RateLimits.check_moderator_delete/1` (100 per 5 minutes) for deleting other people's content, and `comments.deleted_by_id` records who deleted a comment, as articles already did.
- [x] **Evidence retention (P1-D6)** (2026-09-16): a removal from a queue copies the text into `reports.evidence_body`; `Moderation.purge_closed_report_evidence/0` (hourly) clears it and `message_body` 90 days after the report closed. Author deletions still wipe at once.
  - [ ] Articles an author deletes keep their body in the row (and in `article_revisions`); only comments are wiped. Worth revisiting with revision retention.
- **Accepted 2026-09-16:** a board moderator resolves, dismisses and deletes from `/moderation` end to end (`moderation_live_test.exs`); `moderation_test.exs` proves at the context level that another board's reports, account reports and DM reports are neither listed nor actionable; resolve, dismiss and both deletions are logged.

### 1C — Sanctions short of a ban (M) — done, unreleased

The model is [ADR 0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md) (accepted 2026-09-16): sanctions are rows in a `sanctions` table with an explicit end, active by the clock rather than by a sweep, and enforced by one gate (`Auth.ensure_can_interact/1`) that replaced `AccountMigration.ensure_not_moved/1` at every call site.

- [x] **The table and the gate.** `sanctions` rows (kind, reason, who, when, `expires_at`, `lifted_*`, optional `report_id`), and `Auth.ensure_can_interact/1` at every posting and interaction path, with an AST guard test that fails if the old gate is called anywhere but the two files that ask about the *followed* account. Follows are the one place the rules differ: a moved account may still follow (ADR 0025), so those paths pass `moved: :allow`.
- [x] **Warn.** A notice to the user plus an audit entry. No restriction, and no acknowledgement to demand.
- [x] **Silence.** Read-only, including the public parts of the profile; undo, self-delete, reporting abuse, account security and narrowing `dm_access` stay open. Optional end date, active by the clock. Existing content stays up.
- [x] **Suspend.** Refused in `authenticate_by_password/2`, re-checked in `AuthHooks` and `SessionController`, and treated as signed-out by `:optional_auth`. Sessions revoked, exports and moves cancelled; invite codes left alone. `SessionCleaner` only sends the "it has ended" notice.
- [x] **Reject pending registrations**, with a reason — a ban on an account that is still `pending`, logged as `reject_user`, which a global moderator may do — and notify staff of new pending registrations.
- [x] **User detail page** (`/admin/users/:id`): role, status, sanction history, reports both ways, recent content, inviter and invitees. IP addresses and sign-in attempts are admin-only.
- [x] **Role filter** on the users list, carried in the URL alongside the status filter and search.
- [x] **Enforce the defined permissions.** `moderator.sanction_user` added; `moderator.mute_user` and `admin.view_dashboard` removed; `admin.manage_roles` wired into `Auth.update_user_role/3`. A guard test fails if any catalogued permission is never checked.
- [x] Every sanction is audited, and the member is told what it is, why and until when — an always-delivered notice, the refusal message, and a page-wide banner.

### 1D — Instance-level federation moderation (M) — **done, unreleased**

[ADR 0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) (Accepted).

- [x] **Domain blocks moved from the comma-separated setting into a `domain_blocks` table:** domain, reason, public comment, who blocked it, when. Existing entries migrated and the setting deleted, so there is one authority; `DomainBlockCache` is still the only read path; allowlist mode unchanged.
- [x] **Block and unblock from the Federation dashboard,** both with a reason, both audited. The instance list prefills the form rather than blocking on one click.
- [x] **What a block does (P1-D7).**
  - Severs follows in both directions for every actor on the domain, sending nothing.
  - Hides the domain's existing articles, comments and feed items at query time, and stops serving them over AP, so an unblock restores them with no repair step.
  - Stops us reaching out too: actors, objects, reply chains and proxied images.
- [x] **Instance-wide suspension of a single remote actor,** through the same predicate and the same inbox refusal.
- [x] An instance detail page (`/admin/federation/instances/:domain`): known accounts, block state, and per-account suspension. A remote-account report links to it.
- [x] `remote_actors.domain` normalized to lowercase on write and backfilled — the filter compares it with SQL equality where the ETS lookup used to downcase its key.
- **Accepted when:** blocking a domain stops inbound and outbound traffic at once, removes its follows, and hides its content everywhere a guest or member can look; unblocking restores the content. — met; `test/baudrate/federation/blocked_domain_hiding_test.exs` is the gate.

### 1E — Rules and terms (S) — **done, unreleased**

ADR 0031. Acceptance gate: `test/baudrate/auth/terms_gate_test.exs`.

- [x] **Admin-editable Rules and Privacy pages,** next to the existing End User Agreement (`Setup.get_eua/0`).
  - [x] Public at `/rules`, `/terms` and `/privacy`, in `live_session :public_browsable` — `:public` carries `:redirect_if_authenticated` and would bounce a member off the document they must accept.
  - [x] Linked from the footer, which was an empty element. Only documents that have actually been written are linked.
- [x] **Record acceptance.** `users.terms_accepted_at` and `users.terms_version`, written by `User.accept_terms/1` — validating the checkbox and recording it are one function, because they were two and that was the bug. Neither field is castable from params.
- [x] **Publishing a new terms version (P1-D8).** `settings.eua_version`, moved only by a deliberate "require every member to accept again" checkbox; the pause is `{:error, :terms_not_accepted}` from `Auth.ensure_can_interact/1`, so it reaches all 29 posting paths and inherits their exemptions. Reading, undo, self-delete, reporting abuse and account security stay open. **Bots are exempt inside the gate query** — they cannot sign in to accept, and their posts go through the same gate, so without it publishing terms would silently stop every RSS feed.
- [x] Report categories can point to a rule (P1-D9) — split out as 1F and done.
- **Accepted when:** a guest can read all three pages, and every account has an acceptance record for the current version before it can post. — met.

### 1F — Rules as records, so a report can cite one (S) — **done, unreleased**

ADR 0032. Acceptance gate: `test/baudrate/setup/rules_test.exs`.

- [x] Rules become records (`Setup.Rule`); the existing `rules` setting migrates into the first row. `position` is assigned by the context and swapped in a transaction, never cast from a form.
- [x] `/rules` renders them numbered, each with a stable `#rule-N` anchor; `/admin/rules` edits, reorders and retires them.
- [x] A `rule_violation` report can name which rule, and the queue shows it. **Retired, never deleted** — a report filed months ago still resolves to the rule its author meant.
- [x] Citing a rule is always optional: reporting abuse stays easy, as it does under a sanction (ADR 0029) or a terms pause (ADR 0031).
- **Accepted when:** a reporter choosing "Breaks a rule" picks the rule from the list, and the moderator sees which one. — met.

### Not in Phase 1

These are scheduled elsewhere:
- **Anti-spam:** CAPTCHA, trust levels, new-account limits, keyword filters, first-post approval, IP bans → Phase 5.
- **Content tools:** moving articles between boards → 7C; splitting or merging threads → Backlog.
- **Admin surface:** an `/admin` dashboard with metrics, and a UI for admin announcements → 7A, 7B.
- **Federation:** silence and reject-media domain levels (only full blocks in 1D) → Backlog; outbound `Block` activities were ruled out (P1-D1).
- **Legal:** takedown workflow, age gating → Backlog; content warnings → 3E.

### Decisions (made 2026-09-14)

- **P1-D1. Blocking a remote account is enforced locally only.** No ActivityPub `Block` is sent; the blocked person's server is never told.
- **P1-D2. Sanctions.**
  - Warn: a notice only.
  - Silence: read-only, with an optional end date.
  - Suspend: no sign-in until a date; lifts automatically.
  - Ban: permanent, unchanged.
  - Stored as a sanctions history table; `users.status` gets no new values.
- **P1-D3. Who may do what.**
  - Board moderators: content in their boards only.
  - Global moderators: warn, silence, suspend for up to 30 days, reject pending registrations.
  - Admins: everything, plus ban and role changes.
- **P1-D4. Who hears about outcomes.**
  - The reporter is told the report was reviewed, with no details.
  - The affected author is told about content removal (with the reason) and about every sanction.
  - Nobody is told about dismissed reports.
- **P1-D5. Cross-posted articles.** A board moderator can remove the article from their own board. Deleting, pinning or locking it everywhere needs moderation rights on every board it is in; admins and global moderators are exempt.
- **P1-D6. Evidence.** Content a moderator deletes stays readable to staff for 90 days, then is purged. Content an author deletes is wiped at once.
- **P1-D7. Domain blocks.**
  - Remove follows both ways and hide the domain's existing content at query time.
  - Unblocking restores the content; follows have to be made again.
  - Full blocks only, with no silence or reject-media levels.
- **P1-D8. Changed terms.** A banner on every page, and posting and interacting pause until the member accepts. Reading never requires it.
- **P1-D9. Report categories.** Spam, harassment, illegal content, breaks a rule (choosing which rule from the Rules page), other. A free-text comment is optional for local reports.

---

## Phase 2 — Operability (scope)

**Goal.** No data loss goes unnoticed, the operator hears about problems before users do, and a bad deploy can be undone.

**Done when:**
- production takes verified backups on a schedule, and a restore has been rehearsed;
- a delivery or inbound backlog, a stalled worker or a full disk shows up in health checks and metrics;
- no federated activity is lost to a restart;
- the production host no longer compiles releases;
- a release can be rolled back with one command.

### 2A — Backups and recovery (M)

Scheduled backups, retention, the pre-deploy dump and restore commands are
built (ADR 0028: `Baudrate.Backup.Snapshots`, Ansible `backup` role).

- [x] **Enabled on production** 2026-09-16 (v1.19.5): timer at 04:44 Asia/Taipei, first backup 448 MB (45 MB dump), a second one added 47 MB with all 11,861 uploads hard-linked.
- [x] **Restore rehearsed** 2026-09-16 into a scratch database on the host; row counts, schema version, file count and sampled checksums all matched (`doc/sysop.md` → Restore). A rehearsal on a freshly provisioned host is still open.
- [x] **Off-host copies pulled** to the nanami workstation 2026-09-16: restricted `baudrate-pull` key (`rrsync -ro`), `scripts/pull-backups.sh` on a systemd user timer at 05:30, keeping 30 copies in `~/Backups/baudrate`. Copies only arrive while that machine runs; an always-on puller would be better.
- [ ] **Alert on a failed or stale backup** — today a failure only appears in the server's journal (see 2D).
- [ ] **Backup freshness in health checks:** the time of the last successful backup (see 2D).
- **Accepted when:** production has a backup less than 24 h old, and the rehearsal restored a working instance.

### 2B — Single-node stance, D2 (S)

- [ ] Remove `DNS_CLUSTER_QUERY` from `config/runtime.exs` and `doc/sysop.md`, and drop `DNSCluster` from `application.ex` and `mix.exs`.
- [ ] ADR: Baudrate runs on one node, so ETS caches, nonces, challenges, rate limits and local uploads are sound.
- [ ] Rewrite the scaling section of `doc/sysop.md` around a bigger host, Postgres tuning and a CDN for static assets.

### 2C — Delivery and inbound robustness (L)

- [ ] **Enqueue delivery jobs in the same transaction as the change that causes them.** Today a task inserts them after the commit (`core/federation.ex:367`), so a restart in between loses the activity.
- [ ] **Wake the delivery worker on enqueue** instead of waiting up to 60 s.
- [ ] **Per-domain circuit breaker:** after N consecutive failures a domain's jobs back off together instead of taking worker slots one by one.
- [ ] **Inbound queue.**
  - After signature verification, store the activity and answer `202`.
  - Process it with bounded concurrency outside the request.
  - Keep today's validation order, and reject oversized or duplicate activities before storing them.
- **Accepted when:** killing the node between a post and its delivery loses nothing (test), and a remote instance posting many activities cannot use up the web request pool.

### 2D — Observability (M)

- [ ] **Structured logs:** an optional JSON log format, off by default.
- [ ] **Metrics:** a Prometheus text endpoint on a localhost-only port (P2-D1). It exports request, LiveView, Repo, delivery queue, inbound queue, media cache and bot fetch metrics from the existing `BaudrateWeb.Telemetry` definitions.
- [ ] **Detailed health:** `/health` stays public and minimal, and a localhost-only detail view reports:
  - delivery backlog and the age of the oldest job;
  - inbound backlog;
  - worker liveness (`DeliveryWorker`, `SessionCleaner`, `FeedWorker`);
  - free disk space under `shared/uploads`;
  - the last successful backup.
- [ ] **Error reporting (P2-D2).**
- **Accepted when:** each detail check fails in a test when its condition is broken, and the sysop guide shows how to scrape and alert on it.

### 2E — Deploy safety (M)

- [ ] **Build releases in CI** on a Debian 12 image when a tag is pushed, and attach the tarball to the GitHub release (P2-D3).
- [ ] **Deploy the artifact.** The deploy playbook installs the attached release instead of compiling, and Rust, build-essential and git leave the production host.
- [ ] **Rollback playbook** that points `current` back at the previous release. It refuses when that release is older than the newest applied migration, unless forced, and documents why.
- [ ] **Security checks in CI:** Sobelow and `mix_audit` on every PR, and a release-build smoke test (start the release and hit `/health`).

### 2F — Retention (S)

- [ ] Purge on a schedule, with periods set by P2-D4:
  - old `feed_items` nobody has bookmarked or interacted with;
  - old `announces`;
  - soft-deleted articles and comments past the evidence window (P1-D6).
- [ ] Postgres guidance in `doc/sysop.md`: autovacuum, `shared_buffers` and connection pool sizing for a single host.

### 2G — Key separation (M)

Needs an ADR.

- [ ] Separate encryption keys for TOTP secrets and federation private keys, apart from `SECRET_KEY_BASE`. Today one secret derives every key and cannot be rotated.
- [ ] A release task that re-encrypts the stored secrets under a new key, so any key can be rotated.

### 2H — Drift (S)

- [ ] Run the same PostgreSQL major version in Ansible and CI (15 in Ansible, 17 in CI today).
- [ ] Update the worker table in `doc/sysop.md` (add `FeedWorker` and every `SessionCleaner` job).
- [ ] Fix the README clone URL and add `INSTALLATION_KEY` to its production environment list.
- [ ] Remove the two link-preview images committed under `priv/static/uploads`.
- [ ] **Production allows SSH login as root (key only).** `/etc/ssh/sshd_config.d/00-disable-password-auth.conf` sets `PermitRootLogin yes`; sshd reads drop-ins first and keeps the first value, so the `common` role's `PermitRootLogin no` in `sshd_config` has no effect (`sshd -T` shows `permitrootlogin yes`, found 2026-09-15). Make the role manage the drop-ins and assert the effective value with `sshd -T`.

### Decisions needed

- [ ] **P2-D1. Metrics stack.** [A Prometheus text endpoint with no third-party service, scraped by whatever the operator runs.]
- [ ] **P2-D2. Error reporting.** [None built in; errors go to logs and metrics. Sending errors to a third party would leak request data.]
- [ ] **P2-D3. Where releases are built.** [In GitHub Actions on a Debian 12 image matching production; deploy the artifact.]
- [ ] **P2-D4. Retention periods.** [Uninteracted feed items 90 days; announces 180 days; soft-deleted rows after the 90-day evidence window.]

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

- [ ] **Inbound:** store `summary` and `sensitive` in their own fields on articles, comments and feed items, and render the content collapsed behind its warning. Today they are merged into the body (`core/federation/inbox_handler.ex:1219`).
- [ ] **Outbound:** an optional content warning in the local composer (articles, comments, feed replies), sent as `summary` and `sensitive`.
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
- [ ] **Large lists:** keyset pagination for the outbox and feeds, where `core/pagination.ex:88-93` runs a full count every page.
- [ ] **LiveView streams** for the feed, board, notification and conversation lists.
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

- **Phase 1F — rules as records, so a report can cite one (unreleased).**
  The `rule_violation` category could only say *that* a rule was broken, never
  which, because the rules were one markdown blob with no addressable parts.
  They are now numbered records with stable anchors, edited at `/admin/rules`
  ([ADR 0032](adr/0032-rules-are-records-and-retired-not-deleted.md)). Rules are
  retired rather than deleted, so a report filed months ago still names the rule
  its author meant, and citing one is always optional so reporting stays easy.

- **A gettext interpolation guard (unreleased).**
  A fuzzy merge rendered "Move %{title} up" as "将 %{locale} 上移" in both
  locales — a translation referencing a binding that does not exist, which is a
  runtime fault rather than merely a bad string. `gettext_interpolation_test.exs`
  now fails on any translation using a placeholder its msgid does not provide.

- **Phase 1E — rules and terms, minus the rule picker (unreleased).**
  The terms, the site rules and a privacy policy are public pages linked from
  a footer that used to be an empty element, and acceptance is recorded and
  versioned instead of validated and discarded
  ([ADR 0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md)).
  Publishing a new version pauses posting through the same gate that carries
  sanctions, so it reaches every posting path and keeps every exemption —
  reading, undo, self-delete, reporting abuse and account security all stay
  open, and bots are exempt so RSS feeds keep running. P1-D9 split out as 1F.

- **A composer that named the wrong reason (unreleased).**
  `/articles/new` told every member it turned away "Your account is pending
  approval", whichever of the three conditions in `can_create_content?/1`
  actually stood — so a silenced member waited for staff who were not coming.
  Found by the browser crawl while adding the terms pause. It now uses the
  gate's own message.

- **Phase 1D — instance-level federation moderation (unreleased).**
  Domain blocks are rows with a reason and an author, blocked and unblocked
  from the Federation dashboard ([ADR 0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md)).
  A block severs follows both ways, hides the domain's existing content at
  query time — reversibly, since nothing is deleted or stamped — and stops us
  fetching from it. One remote account can be suspended instead, through the
  same predicate, from the new instance detail page.

- **Two federation bugs found while mapping 1D (unreleased).**
  `StaleActorCleaner` decided an actor was unreferenced from six hand-written
  queries against nineteen foreign keys, silently deleting followers' follows
  and feed items and aborting the sweep on a conversation; it now reads the
  catalog. And no listing query filtered non-public remote articles, so a
  followers-only remote post was listed with its title and re-published to the
  fediverse through the board outbox stamped `as#Public`.

- **Phase 1A — member self-protection (unreleased).**
  - A block now stops replies, likes, boosts, forwards, follows and DMs in both
    directions, locally and for inbound federation, and removes follows both
    ways without sending `Block` ([ADR 0026](adr/0026-blocks-stop-interaction-locally.md)).
  - Block and unblock on user profiles; a Blocked Accounts list on `/profile`;
    remote actors in the blocked and muted lists shown as `@user@domain`.
  - Mute, block and report remote accounts from feed items, remote comments
    and remote conversations; report feed items and received DMs (a DM report
    copies only that message).

- **v1.18.2 — Phase 0 correctness bugs (B1–B12 of the 2026-09-14 review).**
  Domain blocks from the Federation dashboard apply at once; the audit log no
  longer drops entries and covers settings, federation and bot actions;
  inbound `Flag` records reporter and target correctly; local composers offer
  only Public/Unlisted (D1); long DM conversations show their newest messages;
  interactions reach remote authors; comment authors can delete their comments
  and replies to deleted comments stay visible; the theme bootstrap script runs
  under the CSP; activity and follow ids are UUIDs; old notifications are
  purged; reports about remote posts can be forwarded; backups work from a
  release. See CHANGELOG.md.

- **Data portability.**
  - v1.17.0: account recovery prerequisites and self-service data export ([ADR 0023](adr/0023-data-export-threat-model.md)).
  - v1.18.0: account migration with ActivityPub `Move` ([ADR 0025](adr/0025-account-migration.md)).
  - Data import was dropped from the plan.
- **v1.18.1.**
  - Moved accounts no longer see post and interaction controls.
  - Data export downloads are rate limited per IP.
  - Admin sudo verification returns to the page that was asked for.
  - One shared password requirements component is used everywhere.
