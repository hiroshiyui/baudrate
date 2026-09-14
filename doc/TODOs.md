# TODOs

This list comes from a product review done on 2026-09-14, after v1.18.1, which looked at every role: guests, members, board moderators, admins, sysops, remote instances and contributors. Items marked **(confirmed)** were checked against the code, and "absent" claims were checked with grep.

Paths are relative to the repository root. `lib/baudrate_web/…` is shortened to `web/…` and `lib/baudrate/…` to `core/…`. Line numbers were correct as of v1.18.1.

Baudrate is already strong on security engineering, ADRs, accessibility plumbing and test coverage. The gaps are:
- **Broken promises:** the UI or docs say something happens and it doesn't.
- **Moderation reach:** tools exist but not for the right people.
- **Operability:** backups, observability, and an unclear single-node stance.
- **Federation reach:** our interactions don't reach remote authors.
- **Discovery and onboarding** for new visitors.

---

## Phase 0 — Correctness bugs (fix first)

Fix each bug in its own commit on `current`, with a regression test.

- [ ] **B1. Blocking a domain from the Federation dashboard doesn't take effect.** (confirmed)
  - `block_domain` and the audit "Add" / "Add All" buttons refresh `SettingsCache` but not `DomainBlockCache`. Inbox, delivery, DM and link-preview checks keep ignoring the block until settings are saved or the app restarts.
  - The instance-list block is also missing from the audit log.
  - The cache fails open (nothing blocked) before its first load.
  - Evidence: `web/live/admin/federation_live.ex:67-90`, `core/federation/domain_block_cache.ex`, `core/setup.ex:436`.
  - Test: enable the cache in a test and check `domain_blocked?/1` after `block_domain`.
- [ ] **B2. The audit log silently drops some actions.** (confirmed)
  - `pin_article`, `unpin_article`, `lock_article`, `unlock_article` and the six bot actions (`create/update/delete/toggle_bot`, `reset_bot_errors`, `refresh_bot_favicon`) are not in `@valid_actions`, so the insert fails and the error is ignored.
  - These are never logged at all: settings saves (including blocklist edits, so unblocks), board federation toggles, accept-policy changes, removing an article from a board, admin edits of other users' articles, and sending a Flag.
  - `doc/sysop.md` and `doc/development.md` claim every action is logged.
  - Evidence: `core/moderation/log.ex:15`, `web/live/article_live.ex:232,257`, `web/live/admin/bots_live.ex`.
  - Test: a guard that every action name passed to `Moderation.log_action` in `lib/` is valid.
- [ ] **B3. Reports from other servers (inbound `Flag`) are stored backwards.** (confirmed)
  - The *reporting* actor is saved in `remote_actor_id` and shown as "Reported Actor". "Send Flag" then sends a Flag back to the reporter.
  - The reported local user is never set in `reported_user_id`.
  - A Flag without `content` (Mastodon allows it) doesn't match the handler and is dropped.
  - There is no dedup and no rate limit.
  - Evidence: `core/federation/inbox_handler.ex:439,1856`, `web/live/admin/moderation_live.html.heex:205`, `core/moderation/report.ex`.
- [ ] **B4. "Followers only" and "Direct" don't restrict local posts.** (confirmed; approach set by D1)
  - The article, edit, comment and feed quick-post composers offer them, but they only change federation addressing (`core/federation/publisher.ex:38-45`). Guests can still read such posts on this site.
  - "Direct" is broken on top of that: it addresses nobody, and `article_addressing/2` still adds the post's boards as recipients, so a "Direct" board post reaches board followers.
  - Fix (D1): offer only Public and Unlisted in every local composer.
    - Enforce it at the context boundary: local `Article.changeset/2` and `Comment.changeset/2` accept only `public`/`unlisted`.
    - Remote rows keep their derived visibility.
  - Production had no local rows with either value on 2026-09-14 (all local articles and comments are `public`), so no data migration is needed.
  - Evidence: `web/live/article_new_live.html.heex:367`, `web/live/article_edit_live.html.heex:193`, `web/live/article_live.html.heex:584`, `web/live/feed_live.html.heex:336`.
- [ ] **B5. Long DM conversations lose their newest messages.** (confirmed)
  - `Messaging.list_messages/2` sorts oldest first with `limit: 100`, and nothing loads more, so after 100 messages new ones never appear.
  - Evidence: `core/messaging.ex:410-418`, `web/live/conversation_live.ex:51,212`.
- [ ] **B6. Engagement on remote posts never reaches the remote author.** (confirmed)
  - `Delivery.enqueue_for_article/3` collects only local author followers and board followers.
  - Comments, likes, updates and deletes on a remote article skip the author's inbox.
  - Evidence: `core/federation/delivery.ex:266`, `core/federation/publisher.ex:514-600`.
- [ ] **B7. Comment authors can't delete their own comments.** (confirmed)
  - The template passes `can_delete={@is_board_mod}`, although `Permissions.can_delete_comment?/3` allows authors.
  - Deleting a parent comment also hides all its replies, because roots and descendants both filter `deleted_at` and there's no "[deleted]" placeholder.
  - Evidence: `web/live/article_live.html.heex:632`, `core/content/comments.ex:205,249`.
- [ ] **B8. The theme and font-size bootstrap script never runs.** (confirmed)
  - CSP `script-src 'self'` blocks the inline script in the root layout, so pages can flash the wrong theme or font size.
  - Move it to a static file, or allow it with a CSP hash.
  - Evidence: `web/components/layouts/root.html.heex:72`, `web/router.ex:74`.
- [ ] **B9. The documented backups don't work on Ansible installs.** (confirmed)
  - `mix backup` isn't in the release.
  - `Helper.uploads_dir/0` points inside the release instead of `/opt/baudrate/shared/uploads`, so a cron job would archive an almost empty directory with no error.
  - The files backup doesn't exclude `media_cache`, although `doc/sysop.md` says it does.
  - Evidence: `lib/mix/tasks/backup/helper.ex:54`, `doc/sysop.md:982`, `core/release.ex`.
- [ ] **B10. Notifications are never cleaned up.** (confirmed) `Notification.cleanup_old_notifications/1` exists and is tested, but nothing calls it; schedule it in `SessionCleaner`.
  - Evidence: `core/notification.ex:172`.
- [ ] **B11. Activity ids can repeat after a restart.**
  - They are built with `System.unique_integer/1` (34 places in the publisher), which restarts with the VM.
  - A reused id can match the delivery dedup index `(inbox_url, actor_uri, activity_id)` and be skipped, and receivers may treat it as a duplicate.
  - Use UUIDs.
  - Evidence: `core/federation/publisher.ex:74` and others.
- [ ] **B12. Local reports can't be sent to the remote author's server.** Article and comment reports store only the content id, never the remote author, so "Send Flag" never appears on local reports.
  - Evidence: `web/live/article_live.ex:727`.

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
| 3 | Federation reach | Interactions currently don't reach remote authors |
| 4 | Discovery and onboarding | Turns visitors into members |
| 5 | Member depth | Retention |
| 6 | Contributor health | Lowers the bus factor of one |

---

## Guests and first-time visitors

- [ ] **The home page is thin.** It shows top-level boards only: no latest, popular or unanswered posts, no board stats (posts, last activity), no site description, and no empty state when there are no boards (`web/live/home_live.html.heex`).
- [ ] **No "recent", "popular" or "unanswered" pages, and no tag index.** Only `/tags/:tag` exists. `Content.list_recent_public_articles` is used only by RSS.
- [ ] **Branding for guests.**
  - The guest welcome hardcodes "Baudrate" instead of `site_name` (`web/live/home_live.html.heex:14`).
  - Guests on mobile never see the site name: the logo is `hidden lg:block` and the hamburger menu is for signed-in users only (`web/components/layouts.ex:39,153`).
  - The footer is empty.
- [ ] **No public About, Rules, Terms or Privacy pages.** The user agreement is shown only on `/register`.
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
- [ ] **Blocking and muting.**
  - No UI to block a user or remote actor, although `Auth.block_user/2` and `block_remote_actor/2` exist and the README advertises blocking.
  - Remote actors can't be muted from the UI; `/profile` only offers unmute.
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

- [ ] **No board moderator dashboard.** Users with the `user` role can't reach `/admin/moderation`, so board moderators get no report queue, notifications or audit log for their board.
- [ ] **Scope is too broad.**
  - `board_moderator_for_any?/2` lets a moderator of board A pin, lock or delete an article cross-posted to boards A and B.
  - Pin and lock are per article, not per board (`core/content/permissions.ex`).
- [ ] **Scope is too narrow.**
  - Board moderators can't remove an article from their own board; `remove_article_from_board` is author and admin only (`core/content/articles.ex:615`).
  - They can't edit board name, description or roles.

## Global moderators and admins

- [ ] **Report queue.**
  - No pagination (`list_reports/1` loads every row).
  - No assignment, no "in review" status and no reason categories.
  - No links to the reported content or user, and comments are cut to 200 characters.
  - No history per target.
- [ ] **Report notifications.** New reports notify admins only, not moderators (`core/notification/hooks.ex:252`), and neither the reporter nor the reported user hears the outcome.
- [ ] **User actions.** No warnings, temporary suspension, silencing or per-user rate limits. Pending users can't be rejected. Banning doesn't hide existing content.
- [ ] **No user detail page** (their content, reports, IP, inviter), and no role filter in the UI, although the context supports one (`core/auth/users.ex:230`). `invited_by_id` isn't shown anywhere.
- [ ] **Unenforced permissions.**
  - `moderator.mute_user`, `admin.manage_roles` and `admin.view_dashboard` are defined but never checked.
  - Global moderators have no ban or user tools.
  - Moderators are held to the author delete limit of 20 per 5 minutes (`web/live/article_live.ex:188`), which hurts during spam waves.
- [ ] **Deleting a comment destroys the evidence.** `soft_delete_comment` wipes the body, there's no restore, and deletions from the queue don't record who deleted.
- [ ] **Content tools.** No moving articles between boards, no split or merge of threads, and no tool to empty a board so it can be deleted (`core/content/boards.ex:184`).
- [ ] **Anti-spam.** None of: CAPTCHA or proof-of-work, trust levels, new-account or link limits, keyword filters, first-post approval, IP bans, or admin alerts for pending registrations.
- [ ] **Domain blocklist.**
  - It's a single comma-separated setting, with no severity, reason, date, public comment or unblock button.
  - Blocking doesn't remove existing follows or hide received content.
  - There's no silence or reject-media level, and no per-instance detail page.
- [ ] **Delivery dashboard** shows only 20 actionable jobs, with no domain filter and no bulk retry.
- [ ] **Users can't report feed items, DMs or remote actors.**
- [ ] **No `/admin` dashboard** with metrics (users, posts, growth, federation health).
- [ ] **Admin announcements have no UI**, although `Notification.create_admin_announcement/2` exists. Also missing: custom pages, and site description and contact settings.
- [ ] **Terms acceptance isn't recorded.** `terms_accepted` is a virtual field (`core/setup/user.ex:136`), there's no version or date, and users aren't asked again when the terms change.
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

- **Data portability.**
  - v1.17.0: account recovery prerequisites and self-service data export ([ADR 0023](adr/0023-data-export-threat-model.md)).
  - v1.18.0: account migration with ActivityPub `Move` ([ADR 0025](adr/0025-account-migration.md)).
  - Data import was dropped from the plan.
- **v1.18.1.**
  - Moved accounts no longer see post and interaction controls.
  - Data export downloads are rate limited per IP.
  - Admin sudo verification returns to the page that was asked for.
  - One shared password requirements component is used everywhere.
