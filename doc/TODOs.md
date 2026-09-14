# TODOs

This list comes from a product review done on 2026-09-14, after v1.18.1, which looked at every role: guests, members, board moderators, admins, sysops, remote instances and contributors. Items marked **(confirmed)** were checked against the code, and "absent" claims were checked with grep.

Paths are relative to the repository root. `lib/baudrate_web/…` is shortened to `web/…` and `lib/baudrate/…` to `core/…`. Line numbers were correct as of v1.18.1.

Phase 0 (correctness bugs) shipped in v1.18.2. Phase 1 below is scoped, with its decisions P1-D1–P1-D9 still open; later phases are listed by role further down and get scoped when they start.

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
- **D2. Scale target: one server.** Baudrate officially supports a single node. See "Single-node stance" under Sysops.
- **D3. Email: stay without email.** Recovery is covered by three additions instead; see "Account recovery" under Registered members.
- **D4. Data export and move gate: keep "TOTP enabled for ≥ 7 days"** (ADR 0023, ADR 0025), and improve the path for members; see "Data export and move path" under Registered members.
  - Accepting WebAuthn in step-up re-authentication remains a separate possible feature.

---

## Roadmap

Each phase gets its own plan before work starts.

| Phase | Theme | Why |
|-------|-------|-----|
| 1 | Trust and safety | A public hub can't grow without moderation reach |
| 2 | Operability | Data loss and blind operations are the biggest risks |
| 3 | Federation reach | Threading, Lemmy groups and profile changes don't federate |
| 4 | Discovery and onboarding | Turns visitors into members |
| 5 | Member depth | Retention |
| 6 | Contributor health | Lowers the bus factor of one |

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

### 1A — Member self-protection (S)

- [ ] Block and unblock a local user from their profile page.
  - `Auth.block_user/2` and `unblock_user/2` already exist; they need a UI.
  - The `/profile` "Blocked" list shows local users and remote actors, each with an unblock control.
- [ ] Block or mute a remote actor from wherever it appears: feed items, remote comments and remote DM conversations.
  - Reuse `Auth.block_remote_actor/2` and the mute functions.
- [ ] Report a feed item, a received DM or a remote actor.
  - Record the remote author as `reports.remote_actor_id`, so "Send Flag" works.
  - A DM report includes that one message's text; nothing else from the conversation.
- [ ] Rate limits: reuse `check_mute_user/1` for blocks and `check_create_report/1` for reports.
- **Accepted when:** each control's action is enforced by the context, every list has an undo, and the README's blocking claim is true.

### 1B — A report queue that works, including for board moderators (L)

- [ ] **Queue basics.**
  - Paginate `Moderation.list_reports/1`.
  - Link each report to the reported content, account or actor.
  - Show the full reported text.
  - Show how many other reports the same target has.
  - A fixed reason category on every new report (P1-D9).
- [ ] **Scoped queue for board moderators.**
  - Board moderators (role `user`) get a queue of reports about articles and comments in the boards they moderate.
  - It is reachable from those boards, shows no admin navigation, and never shows reports about other boards, accounts or DMs.
- [ ] **Who hears about a new report.** Admins and global moderators are notified of every report. A board moderator is notified of reports about their boards.
- [ ] **Outcome notices (P1-D4).**
  - The reporter is told their report was reviewed.
  - The author of removed content is told it was removed, with the reason.
  - Neither is told about dismissed reports.
- [ ] **Cross-posted articles (P1-D5).**
  - A board moderator can remove an article from *their* board.
  - Pin, lock and delete on an article in several boards need moderation rights on every one of them (admins and global moderators excepted).
- [ ] **Moderator actions.**
  - Moderators are not held to the author delete limit of 20 per 5 minutes, but get their own, higher limit.
  - A deletion made from the queue records who deleted it.
- [ ] **Evidence retention (P1-D6).** Content deleted by a moderator stays readable to staff in the report for 90 days, then it is purged. An author deleting their own content still wipes it at once.
- **Accepted when:** a board moderator can resolve a report about their board end to end; a context-level test proves they cannot see or act on other boards' reports; every action is in the audit log.

### 1C — Sanctions short of a ban (M)

Needs an ADR (the sanctions model), based on P1-D2 and P1-D3.

- [ ] **Warn.** A notice to the user plus an audit entry. No restriction.
- [ ] **Silence.**
  - A silenced account can read, but cannot post or interact. It is enforced at the context boundary by generalising the moved-account gate (`AccountMigration.ensure_not_moved/1`, ADR 0025).
  - Optional end date.
  - Existing content stays up.
- [ ] **Suspend.**
  - A suspended account cannot sign in until a set date. Sessions are revoked and exports and moves cancelled, like a ban (`Auth.Sessions`, `cancel_active_exports/2`, `cancel_active_moves/2`).
  - Lifts automatically; the hourly `SessionCleaner` clears expired sanctions.
- [ ] **Reject pending registrations**, with a reason, and notify admins of new pending registrations.
- [ ] **User detail page** (`/admin/users/:id`).
  - Role, status and sanction history.
  - Reports against the user and reports the user filed.
  - Recent content, inviter and invitees (`invited_by_id`), recent login attempts.
- [ ] **Role filter** on the users list (the context already supports it).
- [ ] **Enforce the defined permissions.** Either check `moderator.mute_user`, `admin.manage_roles` and `admin.view_dashboard`, or remove them. Global moderators get the sanction tools P1-D3 grants them.
- [ ] Every sanction is audited, and the user is told what it is, why and until when (always delivered, like account security notices).
- **Accepted when:** a silenced or suspended user is refused on every posting or interaction path and on sign-in respectively (tests per path), and sanctions expire on schedule.

### 1D — Instance-level federation moderation (M)

Needs an ADR (domain blocks as rows), based on P1-D7.

- [ ] **Move the domain blocklist from the comma-separated setting into a `domain_blocks` table:** domain, reason, public comment, who blocked it, when.
  - Migrate existing entries.
  - Keep `DomainBlockCache` as the single read path.
  - Keep allowlist mode as it is.
- [ ] **Block and unblock from the Federation dashboard,** with a reason; both audited.
- [ ] **What a block does (P1-D7).**
  - Removes followers and follows with that domain.
  - Hides that domain's existing remote content (articles, comments, feed items) at query time, so an unblock restores it.
- [ ] **Instance-wide suspension of a single remote actor:** refuse its activities and hide its content, without blocking its whole domain.
- [ ] A read-only instance detail page: known actors, followers, content counts, delivery errors and block state.
- **Accepted when:** blocking a domain stops inbound and outbound traffic at once, removes its follows, and hides its content everywhere a guest or member can look; unblocking restores the content.

### 1E — Rules and terms (S)

- [ ] **Admin-editable Rules and Privacy pages,** next to the existing End User Agreement (`Setup.get_eua/0`).
  - Public at `/rules`, `/terms` and `/privacy`.
  - Linked from the footer, which is empty today.
- [ ] **Record acceptance.** Store `terms_accepted_at` and the terms version at registration; `terms_accepted` is only a virtual field today.
- [ ] **Publishing a new terms version (P1-D8).** Existing users see a banner and must accept before they post or interact again; reading is unaffected.
- [ ] Report categories can point to a rule (P1-D9).
- **Accepted when:** a guest can read all three pages, and every account has an acceptance record for the current version before it can post.

### Not in Phase 1

These stay in the role lists below:
- **Anti-spam:** CAPTCHA, trust levels, new-account limits, keyword filters, first-post approval, IP bans. A later phase of its own.
- **Content tools:** moving articles between boards, splitting or merging threads.
- **Admin surface:** an `/admin` dashboard with metrics, and a UI for admin announcements.
- **Federation:** silence and reject-media domain levels (only full blocks in 1D), outbound `Block` activities (P1-D1).
- **Legal:** takedown workflow, age gating, content warnings.

### Decisions needed before Phase 1 starts

Recommended answers in brackets.

- [ ] **P1-D1. Should blocking a remote actor send an ActivityPub `Block` to its instance?** [No: enforce locally only. A `Block` tells the blocked person's server about the block, and a public hub gains little from it.]
- [ ] **P1-D2. Sanctions model.** [Warn (notice only); silence (read-only, optional end date); suspend (no sign-in until a date, lifts automatically); ban (permanent, unchanged). Stored as a sanctions history table, not new `status` values, like moves never overloaded `status`.]
- [ ] **P1-D3. Who may do what.** [Board moderators: content in their boards only. Global moderators: warn, silence, suspend for up to 30 days, reject pending registrations. Admins: everything, plus ban and role changes.]
- [ ] **P1-D4. Who hears about outcomes.** [The reporter: "reviewed", no details. The affected author: content removal with the reason, and every sanction. Dismissed reports: nobody.]
- [ ] **P1-D5. Cross-posted articles.** [A board moderator removes the article from their board. Deleting or pinning it everywhere needs rights on every board it is in.]
- [ ] **P1-D6. Evidence retention.** [Moderator deletions stay readable to staff for 90 days, then are purged. Author deletions are wiped at once.]
- [ ] **P1-D7. What a domain block does.** [Remove follows both ways and hide existing content at query time, reversible by unblocking. No silence or reject-media levels yet.]
- [ ] **P1-D8. Changed terms.** [Existing users see a banner and must accept before posting or interacting. Reading never requires it.]
- [ ] **P1-D9. Report reason categories.** [Spam, harassment, illegal content, breaks a rule (pick one), other. A free-text comment stays optional for local reports.]

---

## Guests and first-time visitors

Public Rules, Terms and Privacy pages are in Phase 1 (1E).

- [ ] **The home page is thin.** It shows top-level boards only: no latest, popular or unanswered posts, no board stats (posts, last activity), no site description, and no empty state when there are no boards (`web/live/home_live.html.heex`).
- [ ] **No "recent", "popular" or "unanswered" pages, and no tag index.** Only `/tags/:tag` exists. `Content.list_recent_public_articles` is used only by RSS.
- [ ] **Branding for guests.**
  - The guest welcome hardcodes "Baudrate" instead of `site_name` (`web/live/home_live.html.heex:14`).
  - Guests on mobile never see the site name: the logo is `hidden lg:block` and the hamburger menu is for signed-in users only (`web/components/layouts.ex:39,153`).
  - The footer is empty.
- [ ] **SEO.**
  - No sitemap, no canonical `<link>` for `?page=N`, and no `<meta name="description">`.
  - No `noindex` on search and login pages, and `robots.txt` is the stock file.
  - `site_description` (read in `web/open_graph.ex:151`) has no admin setting.
  - An unknown user redirects to `/` instead of returning 404 (`web/live/user_profile_live.ex:28-37`).
- [ ] **Feeds aren't discoverable.** No RSS link or icon anywhere in the UI, user feeds aren't advertised in `<head>`, and there are no tag feeds.
- [ ] **Search.** No sort (relevance or date) and no board or date filter UI. The Users tab is capped at 20 with no pagination (`web/live/search_live.ex:398`). Operators don't work on the Comments tab.
- [ ] **Sharing.**
  - The share button hides itself when `navigator.share` is missing, with no copy-link fallback (`assets/js/web_share_hook.js:15`).
  - Fediverse visitors have no "follow from your instance" flow.
- [ ] **PWA.**
  - The service worker is registered only by `PushManagerHook` on `/profile`, and only when VAPID and PushManager are available. Install and share-target are therefore unreliable.
  - There's no offline page.
- [ ] **YouTube embeds contact Google for every reader** (`web/components/core_components.ex:1011`). Use a click-to-load placeholder, in line with the no-third-party rule.
- [ ] **No guest language switcher** (Accept-Language only), no RTL support, and no `hreflang`.

## Registered members

Blocking and muting are in Phase 1 (1A).

- [ ] **Account recovery (D3: no email).** Today there's no email, recovery codes are issued only at registration and setup, and admins can't reset a password, so losing both the password and the codes loses the account. Add:
  - [ ] **Regenerate recovery codes** from `/profile`.
    - Behind step-up re-authentication (`Auth.verify_reauthentication/5`, ADR 0022).
    - Old codes stop working.
    - Sends an always-delivered security notice.
  - [ ] **Admin-assisted reset.**
    - An admin creates a single-use reset link (24 h expiry) and hands it over through another channel.
    - Using it sets a new password, revokes all sessions (`Auth.Sessions`), and runs `cancel_active_exports/2` and `cancel_active_moves/2`.
    - It sends a security notice and is written to the audit log.
    - Needs an ADR covering social-engineering risk and what happens to the account's TOTP and security keys.
  - [ ] **Nudges:** remind users to store recovery codes and to add a second factor or security key (registration, `/profile`).
- [ ] **Onboarding.**
  - After registering, users are sent to `/login` instead of being signed in (`web/live/register_live.ex:88`).
  - No welcome or profile-setup step, and display name isn't asked at signup.
  - No notification when an account is approved (`core/auth/users.ex:140`).
  - Hitting a private page gives no explanation, and there's no return to that page after sign-in.
- [ ] **Comments.**
  - Authors can't edit their own comments; only remote comment updates exist.
  - Replies stop at depth 5 (`web/components/comment_components.ex:154`).
- [ ] **Composer.**
  - No alt-text field for images; alt text is always generic "Image N" (`core/content/article_image.ex`).
  - No content-warning or spoiler option, and images can't be placed inline.
  - Drafts are stored only in the browser (localStorage).
- [ ] **Reading.**
  - No per-comment "new since last visit" and no jump-to-unread.
  - The comments heading counts only the current page (`web/live/article_live.html.heex:536`).
  - Guests get no "sign in to comment" prompt.
  - Board lists re-render under the reader when a new post arrives, with no "N new posts" banner.
- [ ] **Notifications.**
  - They open the top of the article instead of the comment (`web/live/notifications_live.ex:117`).
  - No grouping ("5 people liked") and no filter by type.
  - No notifications for approval, report outcome, watched boards or a poll closing.
- [ ] **No way to watch or subscribe to a board or thread.** Also no followers list, follower count or remove-follower.
- [ ] **Direct messages.**
  - A new DM sends no web push, because DMs aren't a notification type (`core/notification.ex:334`).
  - No attachments, search, group conversations or read receipts for the sender.
- [ ] **Timestamps** use the site time zone with no label and no per-user setting (`web/helpers.ex:28`).
- [ ] **Account.**
  - No self-service account deletion.
  - No list of sessions or devices; only "sign out everywhere else".
- [ ] **Data export and move path (D4: keep the gate).** On `/profile/export` and `/profile/move`:
  - Explain why TOTP for 7 days is required.
  - Link straight to TOTP setup, and show the date the member becomes eligible.
  - Document that the operator can fulfil an export offline with `Release.export_user_data/3` (already audited) for members who can't use TOTP.
- [ ] **`/profile` is one 887-line page** with a separate save button per section; split it into tabs or sub-pages.
- [ ] **Privacy controls.** Only `dm_access` exists: no discoverability or indexing opt-out, no manual follower approval, no domain mute and no keyword filter.
- [ ] **Translations.** Fill the 5 empty strings in each of zh_TW and ja_JP.

## Board moderators

All board moderator items are in Phase 1 (1B).

## Global moderators and admins

The report queue, notifications, sanctions, user detail page, permissions, evidence retention, domain blocks and terms acceptance are in Phase 1. What remains here is outside it.

- [ ] **Content tools.** No moving articles between boards, no split or merge of threads, and no tool to empty a board so it can be deleted (`core/content/boards.ex:184`).
- [ ] **Anti-spam.** None of: CAPTCHA or proof-of-work, trust levels, new-account or link limits, keyword filters, first-post approval, or IP bans. (Admin alerts for pending registrations are in 1C.)
- [ ] **Delivery dashboard** shows only 20 actionable jobs, with no domain filter and no bulk retry.
- [ ] **No `/admin` dashboard** with metrics (users, posts, growth, federation health).
- [ ] **Admin announcements have no UI**, although `Notification.create_admin_announcement/2` exists. Also missing: custom pages, and site description and contact settings.
- [ ] **No takedown or legal-request workflow, and no age gating.**
- [ ] **Board ordering** is a number field; there's no drag-and-drop.
- [ ] **Bots.**
  - No display of the next fetch time, no post counts, no "fetch now" that isn't also a reset, and no dry-run preview.
  - No include or exclude filters.
  - The first fetch posts the whole backlog (`core/bots/feed_worker.ex:118`).
  - Bots aren't auto-disabled after repeated failures.
  - No conditional GET (ETag or If-Modified-Since).

## Sysops and operators

- [ ] **Backups** (beyond B9).
  - No Ansible backup role, and no `pg_dump` before migrations run during deploy.
  - No documented, tested restore on a fresh host.
- [ ] **Deploy.**
  - Releases are built on the production host (Rust toolchain on prod, CPU load while serving).
  - Rollback is manual (`ansible/README.md:150-178`), and migrations are never reversed.
  - No release artifact is built in CI.
- [ ] **Observability.**
  - Telemetry feeds only the dev LiveDashboard.
  - No Prometheus or OpenTelemetry export, no error tracking, and plain-text logs rather than JSON.
- [ ] **`/health` only runs `SELECT 1`.** Include delivery backlog, worker liveness and free disk space.
- [ ] **Single-node stance (D2).** `DNS_CLUSTER_QUERY` and `DNSCluster` suggest clustering is supported, but nothing else is multi-node safe:
  - `DeliveryWorker` has no `SKIP LOCKED`;
  - settings, board and domain-block caches refresh only on the local node;
  - WebAuthn challenges, download nonces, rate limits, uploads and the media cache are all per node.

  To do:
  - Remove `DNS_CLUSTER_QUERY` from `doc/sysop.md` and `config/runtime.exs`, and drop `DNSCluster` from the supervision tree and `mix.exs`.
  - Record the single-node assumption in an ADR.
  - Rewrite the scaling section around vertical scaling, Postgres tuning and a CDN.
- [ ] **Delivery.**
  - Activities are enqueued in a task after the transaction commits, so a restart in between loses them (`core/federation.ex:367`).
  - Throughput is 50 jobs every 60 s at concurrency 10.
  - Nothing is delivered immediately on enqueue, and there's no per-domain circuit breaker.
- [ ] **Inbound activities are processed inside the HTTP request**, including remote fetches, competing for the default pool of 10 DB connections. There's no inbound queue.
- [ ] **Retention.**
  - Nothing ages out `feed_items`, announces, soft-deleted rows or remote content.
  - No Postgres tuning or vacuum guidance.
- [ ] **Storage.** Local disk only: no S3-compatible storage and no CDN guidance.
- [ ] **One secret for everything.** `SECRET_KEY_BASE` derives the session, TOTP and federation key encryption keys and can't be rotated.
- [ ] **Drift.**
  - Ansible installs Postgres 15 while CI uses 17.
  - The worker table in `doc/sysop.md` omits `FeedWorker` and most `SessionCleaner` jobs.
  - The README clone URL is a placeholder and its production env list omits `INSTALLATION_KEY`.
  - Two link-preview images are committed under `priv/static/uploads`.

## Remote fediverse users and instances

- [ ] **Reply threading and mentions.**
  - Outbound comments always set `inReplyTo` to the article, even when replying to a comment (`core/federation/publisher.ex:186`).
  - No `Mention` tags outside DMs, so mentioned remote users aren't notified.
- [ ] **Lemmy groups (FEP-1b12).** An `Announce` that wraps `Create`, `Update`, `Delete` or `Like` is dropped; only bare Note, Article or Page objects are accepted (`core/federation/inbox_handler.ex:948`).
- [ ] **Comments can't be fetched by URL.** Their ids are `/ap/users/:name#note-N`, so fetching one returns the actor document. Polls and DMs aren't served as objects either.
- [ ] **Missing outbound activities.**
  - No `Update(Person)` when a profile changes (avatar, display name, bio, profile fields).
  - No `Update(Group)` when a board is edited.
  - No `Delete(Person)` and no poll result `Update`.
- [ ] **Content warnings and attachments.**
  - Inbound content warnings are merged into the body as `[CW: …]` (`core/federation/inbox_handler.ex:1219`).
  - Outbound posts never set `summary` or `sensitive`.
  - Only image attachments are accepted, so video and audio are dropped.
- [ ] **NodeInfo counts are wrong.** `localPosts` includes remote articles, user totals include bots and banned users, and there are no active-user counts (`core/federation/discovery.ex:85-100`).
- [ ] **Namespaces and caching.** The `baudrate:*` extension fields have no JSON-LD namespace in `@context`, and actor documents are served with `no-store`.
- [ ] **Absent:** custom emoji, relays, backfilling remote outboxes or threads, the `featured` (pinned) collection, `Add`/`Remove`, `contentMap`, RFC 9421 signatures and a NodeInfo 2.0 link.

## Developers and contributors

- [ ] **CI checks.** Add Sobelow, Dialyzer, `mix_audit` on PRs, coverage, a check that gettext translations are up to date, `cargo clippy` and tests for the NIF crates, a release-build smoke test, and ansible-lint. The Wallaby feature tests never run in CI.
- [ ] **Repository files.** Add CONTRIBUTING, SECURITY.md, a code of conduct, and issue and PR templates.
- [ ] **Local setup.** Every contributor needs Rust and libvips. Consider `rustler_precompiled` for the NIFs.
- [ ] **Unimplemented design doc.** `doc/door-apps-development.md` describes a plugin system with no code; mark it as a proposal or remove it.
- [ ] **No API or extension points:** no REST, Mastodon-client or OAuth API, and no webhooks.
- [ ] **Performance.**
  - Outbox and collection pages run per-item preloads and counts, about 160 queries per page (`core/federation/collections.ex:49,218`).
  - Offset pagination runs a full count on every page (`core/pagination.ex:88-93`).
  - No LiveView streams are used.
  - Cropper.js is bundled for every page instead of only the avatar editor.

---

## Recently completed

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
