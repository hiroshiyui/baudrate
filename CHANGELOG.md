# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older releases: [1.2.x](CHANGELOG-1.2.md) | [1.1.x](CHANGELOG-1.1.md) | [1.0.x](CHANGELOG-1.0.md)

## [Unreleased]

Phase 8, contributor health: 8B, the repository files a contributor looks
for; 8C, local setup; 8A, what CI checks; and 8D, performance.

**For other servers:** the ActivityPub outboxes, followers, following and
replies collections now link `?page=true` and continue with `max_id` (replies:
`min_id`). The numbered `?page=N` links are still answered.

### Added

- `CONTRIBUTING.md`: setting up (the dev container, or your own toolchain),
  running the tests and the browser suite, and the conventions a change
  follows.
- `SECURITY.md`: vulnerabilities are reported privately by email to
  hiroshi@ghostsinthelab.org, optionally encrypted with the OpenPGP key in
  `doc/security-contact.asc` (fingerprint
  `37A4 5B21 B45E A42E BE6C  E74C 9F35 3471 AF05 D276`), with the response
  to expect and what is in scope.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1).
- Issue forms for bugs and feature requests (the feature form asks how the
  idea fits ADR 0056, and security reports are pointed to `SECURITY.md`), and
  a pull request checklist.
- **A dev container** (`.devcontainer/`): the image CI tests in, pinned by
  the same digest, with PostgreSQL 15 beside it. Build output stays in
  volumes, so the container and a host build never overwrite each other.
  `verify-toolchain.sh` fails when its digests drift from CI's, and the CI
  image workflow updates it with every image bump.

- **CI's Static checks job** (8A): translations must be extracted from the
  code, Dialyzer must report nothing outside a reviewed baseline, the three
  NIF crates must pass `clippy -D warnings` and their own unit tests, and the
  Ansible playbooks must pass `ansible-lint` at its strictest profile. A
  **Coverage** job merges the four test partitions into one report,
  published as a CI artifact, with no threshold. The CI image gains clippy
  and ansible-lint.
- **Rust unit tests** for the sanitizer (what federated and Markdown HTML may
  keep, and that image sources stay within what the media proxy rewrites),
  the link extractor that the limits on new accounts and the filters rely on,
  and the feed parser. Each NIF is now a one-line wrapper around a plain
  function the tests call.
- A test that every locale's `.po` file holds exactly the messages of its
  template, which `translation_coverage_test.exs` could not see before: a
  message missing from a locale entirely rendered in English with no failure.

### Changed

- **ActivityPub collections page by row id** (8D): `first` is `?page=true`,
  and `next` is `?page=true&max_id=<id>`, so a page costs the same at any
  depth and never skips or repeats an item when the collection changes between
  two requests. The older `?page=N` is still answered.
  - The **replies** collection is paged too (oldest first, `min_id`); it used
    to return every comment in one document.
  - A user's **following** collection is one query; it loaded every follow
    the account had and paged them in memory.
- **A page of Articles costs a fixed number of queries** (8D):
  `ObjectBuilder.article_objects/1` preloads, counts comments and likes and
  checks for edits for the whole page at once. A 20-item user outbox page
  went from 104 queries to 6, and an `/ap/search` page from 101 to 9.
- **Cropper.js loads only on the avatar editor** (8D). It was 108 KB of every
  page's `app.js`; it is now `/assets/js/cropper.js`, which the avatar hook
  fetches when a crop is first needed.
- **The timeline, board, notification and conversation lists are keyed**
  (`:key`), so loading older messages, a new arrival or a regrouped
  notification sends only what changed. LiveView streams were considered and
  not used: every one of these lists is bounded (decision P8-D6).
- Server provisioning downloads `rustup-init` pinned by version and SHA-256,
  like the CI image, instead of piping `https://sh.rustup.rs` into a shell.
- Dialyzer's first run reported 404 warnings. 344 were specs naming a
  schema's `t/0` type that did not exist; the 28 schemas now define it.
- The development and test database settings read `PGUSER`, `PGPASSWORD`,
  `PGHOST` and `PGPORT` (and `PGDATABASE` in development), with the old
  values as defaults.
- **Erlang/OTP 29 and Elixir 1.20** (29.1.1 and 1.20.4), from 28 and 1.19.
  Operators do nothing by hand: **the deploy now installs the Erlang and
  Elixir the release pins when the server lacks them** (compiling Erlang
  takes several minutes, once) and refuses to build on anything else, so
  production runs exactly what CI tested. Development, the CI images, the
  dev container and the Ansible pins are checked to be one version.
- Elixir 1.20's type checker found 34 places where the code guarded against
  something that cannot happen: fallback clauses no caller can reach,
  `nil` checks inside a condition that already rules `nil` out, and unused
  requires. They were removed rather than silenced, so a value that later
  goes unhandled fails the build instead of falling into a silent default.
- daisyUI 5.7.46 (from 5.7.37), bug fixes only (dependency drift report
  #18). In themes other than the Aqua pair, a pressed toggle (like, boost,
  bookmark, watch) and the current page's link in the header now carry the
  button's active background; the Aqua themes keep their transparent
  toolbar buttons.

### Fixed

- **A member's ActivityPub outbox listed their oldest posts first**, while
  claiming newest first. Its query paired `distinct` with an `order_by`, and
  Ecto's `DISTINCT ON` put the article id first in the order, replacing the
  requested one. The same defect CLAUDE.md records for comment search.
- Specs that left out an error the function returns: verifying a recovery
  contact can refuse with `:no_live_challenge`, and the delivery queue's page
  carries `per_page`. A spec for object-origin validation was so narrow that
  a correct guard in the inbox looked impossible.
- The feed parser removed only *adjacent* repeated categories, so `a, b, a`
  kept both `a`s (the Elixir side removed them again, so no post showed a
  duplicate tag).
- The invite pages handled an `:account_too_new` refusal that invite
  generation stopped returning in March; the dead branch and its message are
  gone.
- Test setup no longer times out under load: about twenty async test files
  seeded the roles table, each waiting on the previous test's uncommitted
  insert. The roles are now seeded once, committed, before the suite.
- **A very large `?page=` answered 500** on every listing and on the
  ActivityPub collections' numbered pages: the offset overflowed
  PostgreSQL's bigint and could not be sent. Page numbers are capped at
  1,000,000, and a page past the end is empty. The personal timeline no
  longer reads every row the viewer can see to show an empty page past its
  end.

### Removed

- `doc/door-apps-development.md`, a design for WASM plug-ins that no code
  implemented; the idea is one line in the Backlog.

### Security

- **Signing in said which accounts exist, by how long it took.** A wrong
  password for a real account ran bcrypt twice and an unknown name once, so
  timing the answer enumerated accounts, including those that appear in no
  byline. Resetting a password with a recovery code leaked the same the other
  way round: an unknown name cost a bcrypt, a wrong code for a real account
  none. Every path now costs exactly one, and a test counts them.
- **A rejected new password spent a recovery code.** Resetting a password
  consumed the code before checking the new password, so a member who typed
  one the policy refused lost one of the codes that are their only
  self-service way back in. The password is checked first, and the code and
  the new password are now written together or not at all. The reset page
  also shows the policy's errors in the reader's language, and the username
  is matched without regard to case, as at sign-in.
- **The runtime's own security fixes** (dependency drift report #18). The
  new Erlang/OTP 29.1.1 and Elixir 1.20.4 (see Changed) include fixes for
  two flaws that reach an instance through the TLS connections it opens to
  other servers: CVE-2026-89422 (the client accepted an unsolicited TLS 1.3
  pre-shared key) and CVE-2026-65634 (a certificate with oversized OID
  components could exhaust resources). Elixir fixes CVE-2026-75758
  (unbounded recursion on an invalid charlist).
- An avatar id is stored only in the shape the server generates, and
  deleting an avatar refuses any other value, since it removes a directory.
  The feed bots' favicon fetcher names its temporary file randomly.

## [1.45.0] — 2026-09-24

Phase 7's last release, 7D: bots, which completes Phase 7. One migration
adds the filter, first-fetch and validator columns to `bots`.

### Added

- **Bots list** (`/admin/bots`) shows each bot's next fetch and how many
  articles it has posted, and has **Fetch now**, which makes a bot fetch
  within a minute without clearing its errors (that is still **Reset &
  Retry**). Logged as `fetch_bot_now`.
- **Dry run.** Shows what the next fetch would do with every entry the feed
  lists — post it, or skip it as already posted, excluded, not included or
  part of the first fetch's backlog — without posting or recording anything.
- **What a bot posts.** Include and exclude patterns, one per line, matched
  against an entry's title and text with the admin content filters' own
  matcher (a whole word or phrase, or `*` for part of a word).
- **The first fetch posts only the newest entries** (5 by default, 0–100 per
  bot); the rest of a feed's backlog is recorded and never posted. A new
  feed URL starts over.
- **A failing bot is switched off** after 10 failed fetches in a row and
  every admin gets an always-delivered notice; it shows as *Stopped after
  failures*, and activating it again clears the count.
- **Conditional GET.** Feeds are asked for with an `Accept` header naming the
  feed types and with the last answer's `ETag` / `Last-Modified`, so an
  unchanged feed answers 304.

### Changed

- An entry skipped by a bot's patterns or left in the first fetch's backlog
  is recorded in the ledger like a posted one, so it is judged once:
  changing the patterns later affects new entries only.

## [1.44.0] — 2026-09-24

Phase 7's second release: 7B, site announcements and a contact line, and
7C, moving articles between boards, emptying a board and ordering boards.
One new record,
[ADR 0075](doc/adr/0075-moving-an-article-arrives-and-withdraws-only-what-changed.md).
One migration: the `announcements` and `announcement_dismissals` tables.

### Added

- **Site announcements** (7B). An admin posts a short notice at
  `/admin/announcements` that every page shows, to guests and members, for
  1, 3, 7 or 30 days or until ended, and can also send it as a notification.
  Anyone can close it for themselves — a member once for every device, a
  guest in their browser — and it does not come back. Posting and ending one
  are logged.
- **Moving articles between boards** (7C,
  [ADR 0075](doc/adr/0075-moving-an-article-arrives-and-withdraws-only-what-changed.md)).
  An admin, a global moderator, or a moderator of both boards can move an
  article from its menu. Into a federated board it is announced like a
  forwarded one; a local article that stops being public is withdrawn from
  other servers; remote articles are only relinked here.
- **Emptying a board** (7C): **Move articles** on `/admin/boards` moves every
  article of a board to another, so the board can be deleted.
- **Board order with Move up and Move down** (7C), instead of typing a
  position; a new board goes after its siblings. Moves and reordering are
  logged.
- **A contact line** (7B): one line of plain text on `/admin/settings`,
  shown in the footer and on the rules, terms and privacy pages.

### Fixed

- **Translations that had drifted from the settled terms** (audit before
  release): eight Japanese strings called a board 板 rather than 掲示板
  (forwarding, board search, removing from a board, posting permission),
  one called a report モデレーション報告 rather than 通報, and zh_TW used
  聯盟 for federation and 傳送 for delivery in four strings, where the rest
  of the site says 聯邦 and 遞送.
- **Accessibility of this release's new controls** (audit before release):
  the announcement's close button is named for the word it shows (WCAG
  2.5.3); a refused announcement marks its text box invalid and linked to
  the error, not only the flash; cancelling **Move articles**, and opening
  the move panel with nowhere to move to, no longer leave focus on the page
  body; each **End now** names the announcement it ends; and **Close
  circuit** and **Move articles** are named for the words they show.
- Boards that shared a position could be listed in a different order from
  one page load to the next; every listing now breaks the tie by id.
- The announcement notification went to every account row, bots, pending,
  banned and deleted accounts included; it goes to active members only.

## [1.43.0] — 2026-09-24

Phase 7's first stages: 7A, the admin dashboard, and 7E, the delivery queue
page, with the fixes from a project-wide code review. One new record,
[ADR 0074](doc/adr/0074-the-dashboard-reads-the-health-checks-behind-the-admin-session.md).
No migrations.

### Security

- **A peer could claim a local comment's identity.** The fallback that
  threads a reply addressed to a pre-v1.31.0 comment id
  (`<actor>#note-N`) accepted any URI that merely *began* with this site's
  base URL — `https://our.host.evil.example/…#note-42` included — and then
  stored that URI as the comment's `ap_id`. It now matches only the exact id
  the comment was minted under and writes nothing (ADR 0046, ADR 0050).
- **Approving a registration could unban an account.** The account id comes
  from the client, and approval set any account `active` — a banned one
  included, with its ban fields still set, skipping the unban's rank check,
  log line and notice. Only a pending account can be approved now, in one
  conditional update.

### Added

- **`/admin`, the dashboard.** What is waiting for review (open reports,
  held posts, pending registrations) for admins and moderators; for admins
  also the members (total, active in 30 days, joined in 7 and 30 days, the
  same accounts NodeInfo counts), failed deliveries, blocked servers,
  suspended remote accounts, and each health check's status with a few
  figures. It is the Admin menu's first entry and where sudo mode returns to.
- **`/admin/federation/delivery`, the delivery queue page.** Every pending
  and failed job, 50 to a page, filtered by server; retry and abandon one
  job, or every job for the filtered server; and the open circuits with
  their next probe and a **Close circuit** button. Abandoning a server's jobs
  and closing a circuit are recorded in the moderation log.

### Changed

- `/admin/federation` shows the delivery counts and links to the delivery
  page instead of listing twenty jobs.
- The moderation log names every action it records; sixteen (IP bans,
  recovery contacts and reset links, remote account suspensions, held posts
  and content filters among them) were listed by their internal identifier
  in every language.

### Fixed

- **A closed report could be closed again**, overwriting who decided it and
  when, restarting its 90-day evidence purge and telling the reporter a
  second time. Resolving and dismissing now apply only to an open report.
- The admin account page showed a report's status untranslated, and the
  moderation log its targets' internal kind (`timeline_reply#12`).
- A test deadlocked now and then: it took two unique keys in the opposite
  order from every other test.

- **Per-server delivery actions matched a substring of the inbox URL**, so
  acting on `example.com` would also have retried or abandoned the jobs of
  `notexample.com` and `example.com.evil`. They match the job's stored
  domain exactly.
- **Retrying a delivery job could send it twice**: any job, including a
  delivered one, could be put back in the queue. Retry now applies only to a
  failed job and abandon only to a waiting one, each as one conditional
  update.

## [1.42.1] — 2026-09-24

A security patch found while planning Phase 7: an article taken out of its
last board became public. No migrations.

### Security

- **Taking an article out of its last board no longer publishes it.** An
  article in no board is public to everyone and federates to its author's
  followers, so when the author, an admin or that board's moderator removed
  an article from the only board it was in, a private board's article became
  readable by guests at its permalink and fetchable at `/ap/articles/:slug`.
  The last board may now be removed only when it is itself federated (public
  and ActivityPub-enabled), which is the case where nothing becomes more
  visible; any other is refused with a message pointing to deletion, and
  neither the article page nor the edit form offers the control. The check
  runs with the article row locked, so two removals cannot race past it.
- **Deleting a board checks for articles with the board row locked.** The
  count used to run before the delete, so an article linked in between lost
  the board to the cascade and could be left in none.

## [1.42.0] — 2026-09-24

Stage 6E, which completes Phase 6: 6E-1, the account controls; 6E-2,
deleting your own account; and 6E-3, privacy settings. Two new records,
[ADR 0072](doc/adr/0072-a-deleted-account-leaves-a-tombstone.md) and
[ADR 0073](doc/adr/0073-privacy-settings-shape-what-a-member-sees-and-who-finds-them.md).
Six migrations: `users.time_zone`, `users.deleted_at`, the
`account_deletions` table, the `user_domain_mutes` table, three privacy
columns on `users`, and a backfill of `followers.accepted_at`.

**Operators:** members can now delete their own accounts, so the sample
terms (`doc/eua.md`) and privacy policy no longer send them to you. If your
published terms or policy were copied from them, update the termination and
deletion clauses; nothing else needs doing.

### Added

- **Mute a whole server**, from `/profile/privacy`: everything from it leaves
  your own views — boards, comments, search, the timeline, notifications —
  and nobody is told. You can still reply to or message its accounts.
- **Mute words.** Other people's posts containing them are folded away behind
  "Hidden by your muted words — show", never removed, so every list keeps its
  place and count. Matching works like the admin filters: whole words or text
  anywhere, fullwidth and case folded. Your own posts and direct messages are
  never folded, and the fold never says which word matched.
- **Approve new followers yourself.** A follow request — from here or another
  server — waits on `/followers` until you approve or decline it, and is no
  follower anywhere until then: your posts are not delivered to it and it
  does not count for who may message you. Turning the setting off approves
  everyone waiting. Other servers see your account as locked.
- **Opt out of search engines and the member search.** Your profile, articles
  and feeds ask not to be indexed, the sitemap leaves them out, and the
  `/search` Users tab does not list you. Your pages stay public, and people
  who know your name can still mention or message you.

- **Delete your own account**, from `/profile/account`, with your password
  (and TOTP code if you use one). It happens seven days later, and signing in
  before then cancels it — you are told so, and so is anyone who signed in
  as you. Your profile, sign-in methods, sessions, drafts and the text of your
  direct messages are removed; your username stays reserved so nobody can
  take it. Your posts and comments stay, shown as "deleted account", so the
  discussions you were part of still make sense — unless you choose to
  withdraw them too. Other servers are told the account is gone, and most of
  them then remove what it posted there. The account is never deleted as a
  row: that would have deleted other members' replies with it.

- **Your sessions, listed** on `/profile/security`: the browser and system
  each one signed in with, when, and when it was last active. After you
  confirm your identity — the same five-minute unlock as security keys — it
  also shows the address each came from and lets you sign one out. Neither
  is open to a stolen cookie alone: it must not learn your other locations,
  nor sign you out and keep itself.
- **Your own time zone.** Choose it on `/profile/account`, or take it from
  the device you are on; timestamps everywhere are then shown in it, and the
  footer says which zone that is. Unset, you see the site's zone as before.
- **The data export and account move pages give the date** two-factor
  authentication will have been on for a week, not only the number of days,
  and say why the rule exists. The export page adds that the operator can
  prepare an export if you cannot wait.

### Changed

- **A banned account is no longer described to other servers.** Its
  ActivityPub actor carries only its name on this server and its key — no
  display name, bio, avatar or profile fields — and its outbox is empty, as
  its profile page here already refused. It is not marked deleted, because a
  ban can be lifted.
- **`/profile` is five pages**: profile, security, notifications, privacy and
  account, with a menu between them. It had grown to one page of over 2,000
  lines. Security notices, TOTP setup, security-key registration and the
  password change now lead to `/profile/security`.
- **Every `<time datetime>` is now UTC**, ending in `Z`. It was the site's
  local time with no offset, which anything reading the page could only take
  for UTC — off by the site's offset for everyone.

### Security

- **Replies from other servers on your threads in the timeline** now get the
  filters every other list applies. A reply addressed only to its author's
  followers, or sent directly, was shown there, and so were replies from
  blocked servers and from accounts you had blocked or muted.
- **Site search no longer lists unlisted articles** — only their author finds
  them — so `/ap/search` does not either. Unlisted already meant "not in the
  sitemap, not indexed".

### Fixed

- **The profile page no longer logs an error for every message or
  notification that arrives while it is open.** It had no catch-all for the
  events forwarded to every signed-in page.

## [1.41.1] — 2026-09-23

A maintenance release: the HTML sanitizer's library, and two fixes to CI.

### Changed

- **The HTML sanitizer uses ammonia 4.2.0** (from 4.1.4), with html5ever
  0.40 and cssparser 0.38 underneath. Only 3.3, 4.1 and 4.2 receive
  security fixes upstream. It needs Rust 1.85 or newer to build.
- **CI runs on refreshed images** (`ci-image` 20260920-9980ca9), rebuilt
  from the same Dockerfile.

### Fixed

- **CI test jobs no longer fail after their tests pass.** The cache key
  searched every file in the checkout for `mix.lock`, and since v1.41.0
  the tests leave a directory the runner cannot read, so the step that
  saves the cache failed every job. It now hashes the one `mix.lock`.

## [1.41.0] — 2026-09-23

Stages 6B, reading and notifications; 6C, watching and followers; and 6D,
direct messages. Three new records:
[ADR 0069](doc/adr/0069-a-voter-is-told-the-poll-closed-and-that-is-the-only-reader.md),
which amends ADR 0048,
[ADR 0070](doc/adr/0070-a-member-hears-about-what-they-chose.md) and
[ADR 0071](doc/adr/0071-a-direct-message-stays-between-the-two-people-in-it.md).
Three migrations: the `watches` and `dm_images` tables, and a search index on
direct messages.

**Operators:** re-apply the nginx role once (`setup-server.yml --tags nginx`,
with its output redirected to a file) so nginx refuses `/uploads/dm_images/`.
A deploy does not run that role. The directory is created 0700 by the deploy,
so the images are unreadable to nginx in the meantime; see `doc/sysop.md`.

### Added

- **Comments that are new since your last visit are marked "New"**, and a
  link under the comments heading jumps to the first of them — on whatever
  page it is. "New" means after your last visit to the article, or after a
  "mark all as read" in its board, whichever is later; your own comments are
  never marked.
- **A board offers new posts instead of reloading under you.** While a board
  is open, a post by someone else shows a "N new posts. Show them" button
  above the list, and the list stays where it was until you press it. It
  counts only posts the list would show you.
- **Guests are told how to join in.** Where the comment form would be, a
  guest sees "Sign in to comment" (which brings them back to the article
  afterwards), and a link to create an account unless registration is by
  invitation. It is not shown on a locked thread, or where only staff may
  post.
- **Likes and boosts of the same article or comment are one notification**:
  "Alice, Bob and 3 others liked your article". The unread badge counts them
  the same way, and marking one read marks the group.
- **Notifications can be filtered**: replies and mentions, likes and boosts,
  follows, moderation and site, or account.
- **When a poll closes, its author and everyone here who voted in it are
  told**, once. The notice says only that the poll closed; it carries no
  result and nothing about anyone's vote. It can be turned off in the
  notification settings. ADR 0069 records why this is the one other thing
  allowed to read who voted.
- **`/comments/:id`**, a permanent address for a comment that opens the page
  it is on. New comments publish it as their `url`.
- **Watch a board or a thread.** A "Watch" button on every board tells you
  about its new threads; one on every article tells you about its new
  comments. Nothing is ever watched for you — not when you post, reply or
  bookmark — and `/watching` lists what you watch, with a way to stop. A
  comment that already reached you as a reply or a mention is not announced
  twice, and a board or thread you can no longer open tells you nothing.
- **Your followers, at `/followers`.** Who follows you, here and on other
  servers, with a way to remove any of them: an account elsewhere is sent a
  `Reject(Follow)`, and nobody is told. The count is shown to you only.
- **Your data export includes the boards and threads you watch.**
- **A push when a direct message arrives**, if you have push notifications
  on. It says who the message is from and never what it says, because a
  phone shows it on the lock screen. A direct message adds nothing to
  `/notifications`; the Messages badge is still where you find it. It can be
  turned off on its own in the notification settings.
- **Images in direct messages**, up to four per message, with descriptions,
  and a message may be just a picture. They are shown only to the two people
  in the conversation — and to a moderator if one of you reports that message
  — never by a public link, and they cannot be sent to accounts on other
  servers. Uploading is limited to 20 an hour and 60 a day (3 an hour for a
  new account).
- **Search your own messages** from `/messages`. A result opens the
  conversation on the message it found, however far back it is.

### Fixed

- **A link to a comment opens the page the comment is on.** Comments are
  paged 20 threads at a time, and every link to one — from a notification,
  from another instance's "view original", from the moderation queue and
  from the edit history — pointed at page 1, where a comment in a longer
  thread is not.
- **A second reply from the same account on another server is no longer
  dropped from your notifications.** A remote reply was stored without its
  comment, so the duplicate check took the second one for the first.
- **The comments heading shows the article's total**, not the number on the
  current page.
- **A thread cross-posted into a board by another server now shows up** in
  the board's "N new posts" offer. It used to be linked in silently.
- **Turning a notification type off in the site no longer turns its push
  notifications back on.** The in-app switch on `/profile` replaced that
  type's settings instead of changing one of them.
- **Deleting a direct message now removes its link preview too,** not only
  its text.
- **Unsent images from the timeline reply box are deleted from disk again.**
  The hourly cleanup looked for them at the path they had when uploaded,
  which a deploy removes, so after any deploy it deleted the rows and left
  the files.

## [1.40.1] — 2026-09-23

Two layout fixes. Nothing an instance stores or federates has changed, and
there is no migration.

### Fixed

- **The RSS and Atom links sit on one line again**, on every profile and
  board page. The RSS link starts with an icon, and a flex box whose first
  child has no text takes its baseline from its bottom edge, so "RSS" sat a
  pixel above "Atom". The links are now items of a flex container instead of
  inline boxes on a line, and a browser test measures the two.
- **The action cells on `/admin/boards`, `/admin/users` and
  `/admin/federation` are table cells again.** Each was itself a flex box,
  which stops a `<td>` being a cell: the row wrapped it in an anonymous one,
  its labels sat 1.35px off from the rest of the row, and it dropped out of
  the table's column sizing. The flex now sits inside the cell.

A sweep of every public page and 32 member and admin pages found no other
case of either.

## [1.40.0] — 2026-09-23

Account recovery stops depending on what anybody remembered to type. The
instance now issues the one-line challenge a member signs, with a mail ready
to paste, and a confirmed key shows on the member's profile as exactly what
was checked
([ADR 0067](doc/adr/0067-the-instance-issues-the-challenge-the-admin-still-verifies-it.md),
[ADR 0068](doc/adr/0068-a-profile-says-what-was-checked-not-that-someone-is-verified.md)).
Baudrate still parses no OpenPGP and verifies no signature: it asks the
question, and the admin's own client answers it.

### Upgrading

- **One migration** adds the `recovery_challenges` table. Nothing else
  changes, and no setting needs touching.
- **Verifying a recovery contact and issuing a reset link now need a
  challenge.** Both refuse until one has been issued for that contact, so the
  SysOp procedure gained a step it always described (`doc/sysop.md`).
- Contacts verified before this release stay verified.

### Added

- **Baudrate issues the challenge a member signs to recover an account**
  ([ADR 0067](doc/adr/0067-the-instance-issues-the-challenge-the-admin-still-verifies-it.md)).
  `/admin/users/:id` shows a one-line phrase naming the instance, the account
  and the date, with a random nonce; an admin sends it, checks the signature
  over it in their own client as before, and only then marks the contact
  verified or issues a reset link. Both actions now refuse unless a challenge
  is waiting, and each spends it.
- **An OpenPGP key confirmed badge on a member's profile**
  ([ADR 0068](doc/adr/0068-a-profile-says-what-was-checked-not-that-someone-is-verified.md)),
  dated in its title, once an admin has confirmed the account controls the key
  it registered. It states what was checked rather than saying "verified",
  which would claim an identity check this instance never performs, and it
  goes away by itself when the member changes the address or the key.
- **A mail subject and message ready to paste**, beside the challenge on
  `/admin/users/:id`, carrying the phrase, how to sign it and the warning
  never to send a private key. It is written in the member's own language when
  they have asked for one, and the page says which language that is.

### Security

- **A recovery request can no longer be answered with an old signature.** The
  phrase was previously whatever the member or the admin composed — the SysOp
  guide asked for `openssl rand -hex 16` by hand — so a signed message anyone
  had once seen could be presented again. A challenge now works once, expires
  after 72 hours, and re-issuing supersedes the one before it.
- The moderation log records each challenge with the phrase that was asked, so
  a disputed recovery can be reconstructed.
- **Baudrate still parses no OpenPGP and verifies no signature.** Automating
  the check was considered and refused; ADR 0067 records the reasoning.

## [1.39.1] — 2026-09-22

A documentation release: nothing an instance runs has changed since v1.39.0.
It records what the security audit before v1.39.0 changed in how posts are
screened, which the record written for that release did not yet say.

### Documentation

- [ADR 0066](doc/adr/0066-a-filter-reads-what-is-stored-not-what-the-object-claims.md)
  records what the security audit before v1.39.0 changed in screening, and
  amends decisions 8 and 13 of
  [ADR 0065](doc/adr/0065-what-waits-for-review-is-not-content-yet.md), which
  named less than the code screens: a filter reads everything a post stores
  and shows, an exemption follows what the handler writes rather than what
  the incoming object claims, and a post imported by its URL is screened like
  one delivered. Two more regression cases hold the fields the audit had left
  untested — a remote poll's `anyOf` options and a comment upload's
  description.
- The NodeInfo sample and the manual-install and build examples name this
  release; they had named v1.34.0.

## [1.39.0] — 2026-09-22

Phase 5's third release, which completes it: posts can wait for a moderator,
and an admin can write filters on words, text and linked domains in the middle
of a wave ([ADR 0065](doc/adr/0065-what-waits-for-review-is-not-content-yet.md)).
A held post is a submission of its own, not a hidden article, so no listing
can leak it; approving publishes it as its author, once. Filters are never
regular expressions, and an edit is screened like a new post.

### Upgrading

- **Nothing changes until an admin turns it on.** Holding first posts is off
  (`hold_first_posts` = 0) and there are no filters. Two migrations add the
  `held_posts`, `content_filters` and `content_filter_matches` tables and a
  column on `reports`.

### Added

- **Holding first posts** (Phase 5C). A new setting, **First posts held for
  review**, makes an account's first articles and comments — as many as it
  says, counted as posts still up, like trust — wait for a moderator before
  anyone else can see them. Admins, moderators and bots are never held. The
  member is told, finds the post under **Drafts → Waiting for review** and can
  withdraw it, and is notified when it is approved or declined (with the
  moderator's note).
- **`/moderation/held`**, one review page for admins, moderators and board
  moderators, each seeing only what they could approve — a board moderator an
  article whose boards they all moderate, or a comment on one. Approving
  publishes the post as its author; declining keeps the text for 90 days. Both
  report queues and the admin menu link to it with the count, and reviewers
  are notified when a post arrives.
- **Content filters** (Phase 5D) at `/admin/filters`: a word or phrase, text
  anywhere (with `*` inside a word), or a linked domain, set to refuse, hold
  for review, or publish and report. They apply to articles, comments and
  timeline replies when written and when edited, and to what arrives from
  other servers, which can only be dropped or reported. Each filter shows how
  often it matched in the last 30 days, and can be switched off without being
  deleted.
- A report a filter opened says so and names the pattern; a reported timeline
  reply keeps a copy of its text, since it has no page here.

### Changed

- **Every composer now submits rather than creates**
  (`Content.submit_article/3`, `submit_comment/2`), which is what lets a post
  be held. A build check fails if a page calls the creating functions
  directly.

### Fixed

- **Resuming a draft that had a board chosen crashed the composer.** The board
  lookup returns `{:ok, board}`, and the resume treated the whole tuple as the
  board. No test resumed a draft with a board, so it shipped in v1.36.0.

### Security

- **An edit is screened like a new post, and judged by what it adds**, so
  posting clean and editing dirty does not get past a filter — while a post
  that already contained a word, or that a moderator approved, can still have
  its typos fixed.
- **Filters are matched without regular expressions**, in time proportional
  to the text whatever the pattern, so no pattern an admin writes can hang the
  instance. Fullwidth letters, zero-width characters, HTML entities and empty
  tags inside a word do not hide it, and links are resolved as a browser
  resolves them.
- **A refusal never says which filter or word caught the post**, so it cannot
  be used to rephrase until something passes. Matches are recorded without the
  text.
- **Direct messages are never screened**, in either direction.
- Approving a held post re-checks what can have changed since it was
  submitted — the author's standing, their boards, the thread, blocks — and two
  moderators approving at once publish it once.
- **A security audit before this release** closed five gaps, each with a
  regression test that fails when the hole is put back:
  - A remote `Update` addressed like a direct message skipped the filters,
    while the handler still rewrote the public comment it named — so a peer
    could post a clean reply and edit refused text into it. Updates are now
    screened whatever their addressing.
  - Remote text carried only in `source.content`, and attachment and poll
    option names, were stored and shown but never screened; so were a local
    post's poll options and image descriptions. All are screened now.
  - **An image description could be changed on a published post by a
    silenced member**, and nothing screened it. Changing a published image's
    description now passes the sanction gate and the filters, as an edit
    ([ADR 0029](doc/adr/0029-sanctions-are-rows-with-an-explicit-end.md)).
  - Importing a remote post by its URL from `/search` bypassed the filters,
    and was not rate limited although each import makes the server fetch an
    address the member chose. It is screened and limited to 10 per 5 minutes.
  - A held post's poll was stored with however many options of whatever
    length the client sent; it is now held to a published poll's bounds.

### Documentation

- [ADR 0065](doc/adr/0065-what-waits-for-review-is-not-content-yet.md), with
  twenty-one rows in the conformance index. The SysOp guide covers holding
  first posts, writing filters and what to do during a wave; the
  troubleshooting guide covers a post that "disappeared" and one refused by a
  filter; the AP reference says what a filter does to inbound activities.
- The pre-release audit brought `Setup`'s description of its settings up to
  date — it still named a domain blocklist that has been rows of its own
  since ADR 0030 — and `TODOs.md`'s current-state line, which said v1.34.0.
- The browser crawl read its error log before typing into each page's forms,
  so a view that crashed on a keystroke went unreported. It reads it
  afterwards now — which is how the filter form's crash was caught before
  release — and the admin crawl and layout checks now include `/admin/ip-bans`,
  `/admin/filters` and `/moderation/held`.

## [1.38.0] — 2026-09-22

Phase 5's second release: an account that gets through the door is slowed
down until it has been here a few days and written a few posts that stayed
up — one link and one image a post, ten posts an hour, nothing added to its
signature, and messages only where they are not unsolicited
([ADR 0064](doc/adr/0064-a-new-account-is-slowed-down-not-shut-out.md)). Nothing
about it is stored: the site asks the clock and the post count every time,
so the limits lift on their own, and come back if the posts that lifted them
are removed.

Building it found three ways round rules that already existed: the article
edit page published uploads with no check at all, a link counter that read
links as text, and a "Followers only" DM setting that admitted no follower on
this instance.

### Upgrading

- **The limits apply from the moment of deploy to every account that has not
  met both numbers** — including long-standing members who have posted fewer
  than three times. They lift on their own as soon as both are met. If that
  is not what you want, set both **Days before a new account is trusted** and
  **Posts before a new account is trusted** to 0 at `/admin/settings` right
  after deploying, and raise them when you are ready. Admins, moderators and
  bots are never limited. No migrations.

### Added

- **Limits on new accounts** (Phase 5B,
  [ADR 0064](doc/adr/0064-a-new-account-is-slowed-down-not-shut-out.md)).
  Until an account is three days old *and* has three articles or comments that
  have not been removed, it may put one external link and one image in a
  post, post ten times an hour (articles, comments and timeline replies
  together), add no link or image to its signature — which appears under
  every article it posts — and send direct messages only to people who follow
  it, people who have written to it first, and staff. Bots, admins and
  moderators are never limited, and an invite confers nothing. The site works this out every
  time from the account's age and post count, so the limits lift the moment
  both are met — and come back if a moderator removes the posts that earned
  it.
- Two settings at `/admin/settings`: **Days before a new account is trusted**
  and **Posts before a new account is trusted** (3 and 3; up to 30 and 20;
  0 and 0 turns the limits off). Raise them during a wave.
- A member who runs into a limit is told which one, and what is left for them:
  a date, a number of posts, or both.

### Changed

- **Edits are held to the same limits as new posts.** An edit may not add a
  link or an image past a new account's limit; it never has to remove what was
  already there, so a post written before the limits existed can still have
  its typo fixed.
- Links are now counted the way a browser follows them: every `href` is
  resolved against the site's address and compared by host. The HTML parser
  gained `extract_urls/2` and `count_images/1`, and the link-preview extractor
  now takes the first of the same list. It depends on the `url` crate, locked
  at the version the sanitizer already uses.
- A refused article keeps what was written in the composer, on the new-post
  page and the timeline composer alike, rather than depending on the page
  having seen the text typed.

### Fixed

- **A silenced or suspended member's profile page crashed** when they saved
  their display name, bio or signature: the refusal was handed to the form as
  if it were a validation error. Every profile save now shows why it was
  refused, including profile fields and avatars, which used to say only that
  something failed.
- **A refused avatar change deleted the avatar anyway.** The old files were
  removed before the update that a sanction then refused, leaving the account
  pointing at an image that no longer existed. Files now go only after the
  change is saved, and a refused new upload is removed instead.
- **"Followers only" direct messages admitted no follower on this instance.**
  The check asked the table of *remote* followers, so a member here who
  followed you could never message you under that setting. It now asks both.
- A link to a host that merely begins with this site's name
  (`https://example.org.spam.example/`) was treated as a link to this site, so
  it was never given a link preview. Same-site is now a host comparison.

### Security

- **The article edit page attached an uploaded image to the published article
  with no check at all.** The upload landed on the live post before anything
  was submitted, so a silenced or suspended member could still add pictures to
  their own article, and nothing looked at how many. It now goes through
  `Content.authorize_article_image/2` — the member must be able to edit the
  article and to act at all, and a new account may not pass its image limit —
  before the file is even processed, and again as it attaches.
- Link counting cannot be walked round with `//host`, `/\host` or `http:host`,
  which a browser follows off the site and a prefix check did not count.

### Documentation

- [ADR 0064](doc/adr/0064-a-new-account-is-slowed-down-not-shut-out.md), with
  its rows in the conformance index; a section on the limits in
  `doc/development.md` and `doc/sysop.md`, and the new bucket in both rate
  limit tables.
- `doc/troubleshooting.md`: a member who cannot post a second link or send a
  message, how to read an account's standing from the console, and what only
  looks like the limit.

## [1.37.0] — 2026-09-22

Phase 5's first release, "the door": an instance with open registration can
now make every sign-up cost something, refuse a network outright, and ban an
account together with the accounts it invited — the tools for a spam wave
that arrive at the registration form rather than in the boards
([ADR 0063](doc/adr/0063-the-door-is-defended-by-work-not-by-a-third-party.md)).

**Nothing here is a third party.** The obvious tool for automated sign-ups is
a CAPTCHA, and it is a subresource from somebody else's host on the one page
every new member must load, handing them every registrant's address. The
challenge here is self-hosted proof-of-work instead: the browser does a little
arithmetic, the server checks one hash.

### Added

- **A registration challenge.** Each registration makes the browser find a
  number whose SHA-256 with a server-issued nonce begins with a set number of
  zero bits; the server checks the one hash. It applies in all three
  registration modes, stores nothing about the visitor, and is replaced after
  every attempt — success included, so one answer can never be spent on more
  than one account. The difficulty is a setting (**Registration challenge
  difficulty**, `/admin/settings`): 18 bits by default, estimated at about two
  seconds on a phone; raise it during a wave, `0` switches it off.
- The solver runs in a Web Worker off the page's main thread, falls back to
  the main thread if a worker cannot start, and never disables the submit
  button: a submit that arrives before the answer is held by the server and
  completed when the answer lands, with a line saying what is happening.
- **IP and CIDR bans** at `/admin/ip-bans`, admin-only, with a reason and an
  optional expiry. A banned address cannot register or sign in; reading the
  site is never affected. The page says how many addresses a range covers
  before it is submitted, and every row of the login-attempt log with an
  address has a link that opens the form filled in.
- **Ban with invitees**, on a member's detail page: the whole invite chain is
  listed with each account's post count and join date, and nothing is ticked —
  an account a spammer invited is sometimes a real member, so each one is
  chosen by somebody who looked.

### Changed

- The challenge's default is **18 bits, not the 20 the plan proposed**, and the
  cap 22 rather than 24. Measured, the solver manages about 1.2 million hashes
  a second in a desktop browser; taking a phone to be eight times slower — an
  estimate, not yet timed on a real one — 20 bits is about seven seconds there
  and 24 nearly two minutes: long enough to look broken, and long enough to
  close the door.

### Security

- Sign-in from a banned address is refused **before the password is
  tested**, so it learns nothing about any account and adds nothing to the
  login-attempt log — and again in `establish_session/3`, the one function
  every sign-in path ends in, so a sign-in path added later cannot route
  around the ban.
- A ban is refused for a **private or loopback range** — what every visitor
  looks like when the reverse proxy's trust is misconfigured, so banning it
  bans the whole site — for anything broader than a `/8` or a `/16`, and for a
  range containing the admin's own address. A range broader than a `/16`
  (IPv4) or `/32` (IPv6) needs a second, deliberate tick.
- An IP ban's expiry is decided by the clock when the ban is read. There is no
  job that lifts it, and the cache keeps expired rows so it cannot enforce a
  ban past its end.
- A chain ban acts only on accounts in a tree the server recomputes — an id
  edited into the page is dropped, not banned — authorizes every account
  separately, so an invitee who is staff is refused while the rest are banned,
  and skips an account already banned rather than overwrite the reason its
  original ban was given.

### Documentation

- The SysOp Guide covers tuning the challenge, banning an invite chain, and
  IP bans, including how to lift one from the server console when an admin's
  own address has moved into a banned range. Troubleshooting covers a
  registration that never finishes and a visitor refused by a ban — a refused
  sign-in is not in the login-attempt log, and the entry says where the
  address is logged instead.

### Records

- **[ADR 0063](doc/adr/0063-the-door-is-defended-by-work-not-by-a-third-party.md)
  — the door is defended by work, not by a third party.** Why the challenge is
  proof-of-work and applies in every mode, why one solve buys one attempt, why
  the numbers are 18 and 22, and what an IP ban may and may not name. Also what
  none of it does: native code computes SHA-256 far faster than a browser, so a
  determined attacker pays milliseconds. The challenge is a price, not a wall.

## [1.36.0] — 2026-09-22

Phase 6A's second half, and with it 6A is complete: an unfinished article is
now saved to your account as you write, so a post begun on a phone can be
finished on a laptop.

**The browser's autosave stays, and that is the decision**
([ADR 0062](doc/adr/0062-a-draft-is-kept-in-two-places-on-purpose.md)). The
tidy version of this feature deletes the `localStorage` hook and keeps only
the server — and it makes the feature worse in the case that actually
happens. The hook is the only half that works when the connection is gone,
which is exactly when a tab gets lost; the server row is the only half that
crosses devices. Losing a draft now takes both failures at once.

**The one worth an operator's attention is a fix, not the feature.** Checking
the live site right after v1.35.0 deployed turned up comments that had never
been edited telling the fediverse they had been — 47 of them here, every one
the v1.31.0 `ap_id` backfill had touched. It is cosmetic, peers showed an
"edited" badge and nothing else, and it is corrected below. Nothing needs
doing to the database.

### Added

- **Drafts on the server**, at `/drafts`, with a link in the account menu.
  The composer saves as you type, a fresh composer picks up where you left
  off, and posting deletes the draft it came from. Articles only: a comment
  draft is the right size for the browser-side one, which is unchanged.
- A draft holds the **whole composer** — the content warning, the visibility,
  the forwardable flag, the selected boards, the uploaded images and the poll
  — where the browser hook could only ever reach the title and the body,
  because those are the only two inputs with a `name` attribute.
- Drafts are included in a member's data export.

### Changed

- The composer refuses to restore a draft in three cases, each of which would
  otherwise put the wrong text in front of somebody: a composer opened from
  the **PWA share target** (the post you just shared would be buried), one
  opened **from a board** (a draft addressed to other boards is a
  non-sequitur), and an **empty** draft, which is the residue of opening the
  composer and closing it again.
- A draft's boards and images are re-checked when it is resumed rather than
  trusted from the row: a board can be deleted, or your right to post in it
  withdrawn, while a draft is sitting there.
- Drafts untouched for 90 days are removed by the hourly cleaner, and a member
  keeps at most 20. The limit applies to *starting* a draft, never to typing
  into one you already have open, and the composer says so when you reach it.

### Fixed

- **Comments that were never edited told the fediverse they had been.** Found
  by checking the live site right after v1.35.0 deployed. The federated
  `updated` field was derived from `updated_at` being more than five seconds
  past `inserted_at` — a proxy for "was this edited", and the proxy broke:
  the v1.31.0 `ap_id` backfill rewrote rows with an ordinary changeset months
  after they were written, so every comment it touched began telling peers it
  had been edited on the day of that backfill. Mastodon shows an "edited"
  badge whenever `updated` differs from `published`, and this instance's own
  history page — which counts revisions — correctly said the same comments had
  never been edited. Two surfaces disagreeing about one comment.

  The field now asks the revision table, which is the fact rather than a
  proxy for it, so no future housekeeping write can recreate this. The
  backfill also no longer moves `updated_at`: a repair pass is the one write
  that most wants to be invisible to "when did this last change". No data
  repair was needed — once the field stops reading that timestamp, the
  already-bumped rows simply stop claiming an edit.
- **An image held by a draft is no longer swept as an orphan.** An upload
  belongs to no article until the post is submitted — which is exactly the
  state a draft preserves — so without this a post drafted overnight would be
  resumed with its pictures already unlinked from disk.

### Security

- Every read of a draft is scoped to its owner **in the query**, never fetched
  and then checked, and another member's draft id answers exactly as one that
  never existed. A refusal that can be told apart from a miss would report how
  many drafts an account has.
- `user_id` is not castable on the draft changeset, so an autosave cannot name
  somebody else as the owner of what is being typed.
- Draft autosave is rate-limited per member, and the body carries the same
  64 KB ceiling as an article, so a draft cannot hold something that would
  then refuse to publish.

### Records

- **[ADR 0062](doc/adr/0062-a-draft-is-kept-in-two-places-on-purpose.md) — a
  draft is kept in two places, on purpose.** Why both halves stay, why a draft
  is not content, why the cap is counted rather than stored, and why the
  orphan image sweep had to learn about drafts.

## [1.35.0] — 2026-09-22

Phase 6A's first half: a comment can be edited, and what it used to say stays
readable. Plus a description for every uploaded image — until now each one
announced itself as "Image 2", which is a position rather than a description
and tells a screen-reader user nothing about what is in the picture.

**Six defects fixed on the way, all of which predate this work.** A local
comment body had **no length limit at all**, where articles cap at 64 KB and
inbound federation is held to the same ceiling. The draft autosave key was
**shared between accounts**: it was a constant string, and localStorage is
scoped to the origin rather than the session, so on a shared browser one
member's unsent post was restored into the next member's composer. Six
**English strings were rendering another string's text** — the one worth an
operator's attention, because it was visible on every page that used them and
nothing in the test suite could see it.

The last three came out of the pre-release audit and are collected under
**Accessibility** and **Security** below: an image with no description
**announced itself as decorative**, so a screen reader passed over it in
silence; a peer's image description reached the database **with no length
bound**, alone among remote strings; and eleven render sites — the article
body among them — **never went through the render passes at all**, which
would have left that first fix working on comments and silently absent from
articles.

### Added

- **Edit your own comment**, with a revision per edit kept for ever and a
  public history at `/comments/:id/history` showing a diff between versions
  ([ADR 0060](doc/adr/0060-an-edit-is-kept-and-the-history-is-public.md)).
  There is no grace window: a reply can arrive inside one, and then what it
  answered could be un-said underneath it. **The author alone may edit** — not
  admins, deliberately narrower than article editing, because editing somebody
  else's words under their name is indistinguishable from their own and
  deletion is already the moderation tool. An "edited" marker on the comment
  links to the history.
- Edits federate as `Update(Note)`, carrying `updated` so peers show the
  comment as edited rather than as a new reply. Published under the comment's
  current `ap_id` only — never re-sent under a pre-ADR-0050 `legacy_ap_id`, as
  a `Delete` is, because an `Update` invites the receiver to dereference the
  id and a fragment URI resolves to the wrong object.
- **A description for every uploaded image**, on article, comment and timeline
  reply composers, federated as the attachment `name` — what Mastodon and
  other clients render as alt text. A description a peer sent us is now stored
  and shown too; it was already being fetched and then discarded.
- Comment revisions are included in a member's data export, alongside article
  revisions (ADR 0023).

### Changed

- Article revisions now snapshot the **content warning** as well as the title
  and body. Removing a warning re-exposes what it hid, which makes it the edit
  most worth recording, and it previously left no trace. Rows written before
  this keep no value: it is unknown, not known to have been absent.
- A gallery image's description is announced **once**, by the link that wraps
  it, with the image itself marked decorative. Both carried text before, so a
  screen reader read "Image 2 (opens in new tab)" and then "Image 2".
- The draft autosave no longer discards a draft when the server rejects the
  submit; it writes it back if the form is still on the page.

### Fixed

- **A local comment body is bounded at 64 KB**, on both the local and the
  remote changeset, matching articles and the ceiling inbound federation
  already enforced.
- **The draft autosave key is per account.** On a shared browser, one member's
  unsent article or comment could be restored into another member's composer.
- **Six English strings were showing somebody else's sentence.** `Published`
  rendered as "Push", `Remote actor not found.` as "Remote actor", a
  notification about a liked comment said "liked your article", and "N earlier
  messages loaded" said "N unread messages". `mix gettext.extract --merge`
  fuzzy-matches into the `en` catalogue like any other locale and Gettext
  serves the result, but the translation-coverage check exempted `en` on the
  assumption its entries stay empty. Three of the six were not even flagged as
  fuzzy. The catalogue now falls back to the source text, and the check covers
  `en` too.

### Security

- `Content.update_comment/3` authorizes at the context boundary rather than in
  the LiveView, and casts only `body`, `summary` and `sensitive` — an edit
  cannot move a comment to another article or thread, or change its
  visibility or `ap_id`.
- A comment's edit history answers 404 for a **soft-deleted** comment. Its
  revisions still hold every earlier draft, so serving them would make
  withdrawing a comment a way of publishing what it used to say.
- An image description supplied by a remote instance is tag-stripped and
  length-bounded at ingest, with a changeset backstop.
- **The inline-attachment path was the exception, and no longer is.** Images
  on an inbound comment or DM go into the stored HTML rather than into rows,
  and that path used a bare tag-strip with no length limit — where every other
  remote string reaching a column is truncated. `body_html` has no length
  validation of its own, so up to four attachment names could carry
  attacker-chosen text as far as the 256 KB payload cap allows. It now goes
  through `ImageAlt.from_remote/1`, as the article-image path already did.

### Accessibility

- **An undescribed image inside a post is now announced instead of skipped.**
  `alt=""` is not a blank: in HTML it is a positive claim that the image is
  decorative, and a screen reader honours it by passing over the picture
  without a word. Images on an inbound comment or DM are appended to the
  stored HTML as inline `<img>` tags, and they carried `alt=""` whenever the
  sending instance supplied no description — so the reader was not even told
  a picture was there. `BaudrateWeb.ImageAltFallback` fills it in at render
  time, which covers every comment already stored and lets the fallback be
  translated; a string chosen at ingest would have frozen whichever locale
  that request ran in into the row for good.
- **Every rendered page gets the fix, not just the ones that were checked.**
  Eleven render sites — the article body among them — turned a Markdown column
  into HTML with a bare `raw/1` rather than going through
  `BaudrateWeb.SafeHTML`. Nothing hotlinked, because the Markdown renderer
  carries the media-proxy rewrite itself, but it cannot carry a *translated*
  fallback, so the fix above would have reached comments and direct messages
  and stopped there. All eleven now go through `SafeHTML`, and the build now
  holds an allow-list of every remaining `raw/1` call with a reason for each,
  because the eleventh was split across two files and no search for a single
  spelling would have found it.
- **A sixth composer cannot ship without a description field.** All five that
  accept image uploads render one today, and nothing but review stopped the
  next one from forgetting — a failure that leaves every test green and is
  noticed only by the people who cannot see the picture. It is now a build
  gate, with avatars the one named exemption, since an avatar's accessible
  name is the account's display name.

### Records

- **[ADR 0061](doc/adr/0061-an-image-description-is-not-a-form-field.md) — an
  image description is not a form field.** The image row exists before the
  composer is submitted, because uploads are `auto_upload: true`, so the
  control writes to that row directly: no `name` attribute, inside a
  `phx-update="ignore"` container. As a form field it would be patched back to
  the server's value on every re-render, which is the trap that has erased a
  typed password, a recovery code, a bio and a poll's options in this codebase
  already. The record also settles why an empty description is `nil` and never
  `""` — `alt=""` means *decorative, announce nothing*, which for a photograph
  somebody chose to post is false and, once stored, indistinguishable from a
  deliberate choice.
- It also records the shape the fix had to take, which was not obvious until
  it was attempted: remote images arrive by **two different routes and only
  one of them is a row.** An image on a remote article is fetched and stored
  as an `article_images` row with `alt`; an image on a remote comment or DM is
  appended to `body_html` as inline HTML. The second route cannot use the
  gallery's `Image N` fallback and cannot choose any fallback at ingest, which
  is what pushed the repair to render time — and from there to the discovery
  that the article body was not going through the render passes at all.

### Tests

- The image-description control now has a gate for the two properties that
  make it work at all: it carries no `name`, and it sits in an ignored
  container. Both were load-bearing, documented, and untested.
- The **third** of the three attachment builders — the one for timeline item
  replies — had no test of its own; a description now proves it travels, and
  an undescribed image proves the field is absent rather than empty.

### Documentation

- Eleven modules were missing from `doc/development.md`'s project tree,
  including `sitemap.ex`, `crawlers.ex`, `http_caching.ex` and
  `not_found_error.ex` — the machinery behind ADR 0057, absent since v1.32.0 —
  as well as `content_warning.ex` from v1.31.0 and this release's three.
- The rate-limit table listed article updates but not comment updates, and the
  PubSub table listed `:comment_created` and `:comment_deleted` but not
  `:comment_updated`.

## [1.34.0] — 2026-09-21

Phase 4E, and with it Phase 4 is complete. Three features that were each
already half-claimed by the UI, plus the proxy fixes found while checking
them against a deployed site.

The one worth an operator's attention is that **the app was never installable
on an instance without Web Push.** The service worker was registered by the
push settings section on `/profile`, and only when a VAPID key was configured,
so an instance that had not set push up had no service worker anywhere — and
nothing connected the two. It is now registered on every page, and serves an
offline page when a navigation cannot reach the server.

**What it caches is a decision, not an implementation detail.** The offline
page and the fingerprinted CSS/JS, and nothing else. No article, comment,
direct message or board page is written to a reader's disk, so there is no
offline reading and no cache to purge when someone signs out on a shared
machine ([ADR 0059](doc/adr/0059-the-service-worker-caches-the-shell-and-never-content.md),
which also records why "add offline reading" is refused rather than deferred).

**Upgrading:** no migrations and nothing to configure. **If you run your own
nginx**, check two things — `curl -sI https://your.host/robots.txt` should be
200 from Baudrate rather than a 404 from nginx, and
`curl -s -o /dev/null -w '%{content_type}' https://your.host/site.webmanifest`
should say `application/manifest+json`. `doc/examples/nginx.conf.example` has
the corrected rules and `doc/troubleshooting.md` explains both symptoms.

### Added

- **An offline page.** A navigation that cannot reach the server now shows
  Baudrate's own page, translated and themed, rather than the browser's error.
  The service worker re-fetches it after each successful navigation, so the
  cached copy follows the language the reader actually uses.
- **The share button works on the desktop.** Where `navigator.share` does not
  exist it copies the link and relabels itself to say so, instead of hiding
  itself and leaving no way to share at all. It also carries the page's
  canonical URL, so a share is the article's own address rather than whatever
  tracking parameters the reader arrived with.
- **Follow from your instance.** A fediverse visitor on a profile or a
  federated board can enter their own handle and be handed a link to their own
  server's follow page, discovered from its WebFinger subscribe template
  rather than guessed — so it works with Mastodon, Akkoma, Misskey and
  GoToSocial. The handle is always there to copy as well, and boards had no
  follow control at all before this. A `<details>` and a plain form post, so
  both halves work with scripting switched off.

### Changed

- The service worker is registered from `app.js` on every page rather than by
  the push hook on `/profile`. Push availability and installability are
  unrelated questions.
- Its `fetch` handler now covers navigations and `/assets/` only. It used to
  answer *every* request with a bare pass-through — added to satisfy Firefox's
  installability check — which routed the whole site through the worker and
  cached nothing.
- It gained an `install`/`activate` lifecycle. Without one, an updated worker
  waited for every tab of the site to close, which on a site people keep open
  is indistinguishable from the update never shipping.
- `priv/static/service_worker.js` is no longer tracked in git. It is an
  esbuild bundle — the only build output that was — so the file browsers
  actually run could drift from its source silently. `mix assets.build` and
  `mix assets.deploy` produce it.

### Fixed

- **`/robots.txt` answered nginx's 404, not Baudrate's directives.** It became
  a route in 1.33.0 and `priv/static/robots.txt` was deleted with it, but the
  shipped nginx rules still matched it and served from disk — so the instance
  advertised no sitemap and no `Disallow` for `/ap/`, `/api/` or `/exports/`
  at all, and nothing in the application could tell. Found by curling the
  deployed site, which is the only place it was visible.
- **The web app manifest was served as `application/octet-stream`**, which
  stops browsers treating the site as installable. Debian's nginx
  `mime.types` has no `webmanifest` entry; it now has a `location` of its own
  with an explicit `default_type`.
- **`doc/examples/nginx.conf.example` carried both of the above** after the
  Ansible template had been fixed, because the new gate read one of the two
  files a rule is written in. It reads every nginx config the repository
  ships now.
- **The Ansible nginx role could leave a config nginx cannot start from.** It
  templated and reloaded with nothing checking in between, so a bad render
  failed the reload while nginx kept serving from memory — the only symptom
  arriving at the next restart. It now runs `nginx -t`, restores the previous
  file and fails the play without reloading.
- **The clipboard hook gave no feedback when it could not copy.** It called
  `navigator.clipboard.writeText` with no `.catch()` and no feature test, so
  outside a secure context it threw inside the click listener and a denied
  permission rejected a promise nothing caught.
- A WebFinger lookup could reach a blocked domain. `refuse_blocked: true` was
  missing from the client and covered only because the one caller re-checked
  downstream; it is now applied where the fetch happens, which the new
  remote-follow path depends on.

### Security

- The remote-follow lookup refuses any subscribe template that is not HTTPS on
  the domain the visitor typed, and refuses a blocked domain outright. Without
  the host check a hostile server could answer WebFinger with a link to
  anywhere and have this site render it. Two rate limits apply — per visitor
  IP, and per target domain so many visitors cannot combine against one
  server — and the form carries a kind and a name rather than an actor URI, so
  a submission cannot name a board whose page would never have offered it.

## [1.33.1] — 2026-09-21

Test-only. The application code is identical to 1.33.0; this exists so the
released tag has a green CI run rather than one everybody has to be told to
ignore.

**Upgrading:** nothing to do, and nothing to gain if you are already on
1.33.0.

### Fixed

- Two browser tests that 1.33.0's own CI caught after the tag was cut. One
  still asserted that acknowledging your recovery codes lands you on `/login`,
  which this release series replaced — acknowledging is what completes the
  sign-in. The other timed out at ExUnit's 60-second default: that crawl types
  into every `phx-change` field on every page it visits, and 1.33.0 added a
  filter row to `/search` and a recovery-contact form to `/profile`.
- The release checklist ran `mix test --partitions 4`, which excludes every
  `:feature`-tagged test — so the documented "full test suite" had never once
  run a browser test. It now runs `test/baudrate_web/features/` as well, which
  is what would have caught both before the tag.

## [1.33.0] — 2026-09-21

The rest of Phase 4: discovery from outside (4A, 4B), search worth using (4C),
and a way back into an account (4D).

The one that changes the most for an operator is **account recovery**. This
instance sends no email, so recovery codes were the only way back — and until
now there was no way to mint new ones after registration, which meant a member
who spent all ten had lost the account. Codes can be replaced, and past them
recovery is anchored on an OpenPGP key the member registers here and signs
with elsewhere; an admin verifies a signed message in their own mail client
and issues a single-use link. Baudrate sends no mail, verifies no signature
and fetches no key ([ADR 0058](doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md),
and `doc/sysop.md` holds the procedure, because no code enforces it).

**Upgrading:** four migrations run on deploy — two new tables
(`recovery_contacts`, `account_resets`), two columns on `users`, and a trigram
index for the member search. Nothing to configure.

**One thing to check:** `priv/static/robots.txt` no longer exists. It is a
route now, because its `Sitemap:` directive needs an absolute URL that a file
cannot know for an arbitrary host. **If you customised that file, your edits
are gone** — the served version blocks `/ap/`, `/api/` and `/exports/` and
names the sitemap. Pages that should not be indexed carry `noindex`
themselves, which is deliberate and not interchangeable with `Disallow`: a
blocked page can still be indexed URL-only from its inbound links, and its
`noindex` is never read because the crawler never fetches it.

### Added

- **Account recovery anchored outside the instance.** A member registers one
  or more email addresses and an armored OpenPGP public key at `/profile`,
  behind step-up re-authentication. It arrives unverified; an admin confirms,
  out of band, that a signed message from that address checks out against that
  key, and can then issue a reset link that works once and expires in 24
  hours. Four rules hold it up and each looks like a restriction that could be
  relaxed: a reset needs a **verified** contact, changing the address or the
  key drops it back to pending, nobody resets an account at or above their own
  role, and clearing someone's TOTP and security keys is a separate tick with
  its own audit line. The member registers the anchor; an admin can only ever
  confirm one ([ADR 0058](doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md)).
- **Recovery codes can be replaced** from `/profile`, behind the same step-up
  unlock. The page shows how many are unused, never the codes.
- **Registering signs you in.** All three modes; approval mode signs in as
  pending, which can browse and set up a profile. The ten recovery codes are
  shown *before* the session starts and acknowledging them is what completes
  the sign-in, so nobody is carried past the only time they are shown. A
  one-time step at `/welcome` then asks for a display name and a picture —
  skipping counts as answering.
- **Approval is no longer silent.** An approved member is told; staff are told
  about a new pending registration. Neither notice can be switched off.
- **A private page says what it needs and brings you back.** `:require_auth`
  carries the refused path through sign-in, sanitised on the way in and again
  on the way out by the one open-redirect guard.
- **A notice for an account with no way back in** — no unused codes and no
  verified contact. Dismissible, remembered, no count and no badge.
- **`sitemap.xml`, and a `robots.txt` that is a route.** Boards, articles
  (5,000 per page) and tag pages, listing only what a guest can already see —
  local, public, not deleted, in a guest-readable board. Unlisted articles are
  out of it *and* carry `noindex, follow`, because the word in the composer
  promises that and leaving them out of a sitemap alone promises nothing. Member
  profiles stay crawlable through every byline and are never enumerated
  ([ADR 0057](doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md)).
- **Every page names itself.** A self-referencing canonical URL keeping only
  `?page`, one `<meta name="description">` per page, and `noindex` on search
  and the sign-in flow. A `noindex` page gets no canonical — the two
  contradict.
- **Feeds you can find.** Board, profile and tag pages each carry and
  advertise their own RSS and Atom pair; tag feeds are new.
- **Search you can steer.** Sort by relevance or date, filter by board and
  date range, and the same `author:` / `board:` / `tag:` / `has:` /
  `before:` / `after:` operators on the Comments tab as on Articles. The
  controls write operators into the query string rather than carrying
  parameters of their own, so the box stays the one description of a search.
- **The Users tab pages** past the first twenty, capped at five pages.
- **Board cards say when a board was last active,** and a guest's first page
  says what the site is and what it is called.

### Changed

- **Search defaults to relevance** rather than newest. The weighted tsvector
  behind it has been stored on every article since February and never read:
  the ranking clause was built and discarded on the next line. `/ap/search`
  is pinned to newest-first rather than inheriting the default, because an
  `OrderedCollection` is reverse-chronological by contract.
- **A search has to name something to search within** — words, or an
  `author:`, `board:` or `tag:`. `?q=after:2026-01-01` used to return every
  article the viewer could see, newest first, which is
  [ADR 0055](doc/adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md)'s
  own description of `/recent` reachable from the search box.
- **`robots.txt` is a route**, and `priv/static/robots.txt` is deleted. See
  the upgrade note above.
- **An unknown or banned account answers 404** at `/users/:name`,
  `/users/:name/articles` and `/@handle`, instead of redirecting to `/`. A
  redirect tells a crawler the page moved, so it keeps asking and `/`
  collects the authority of every mistyped handle. Banned and absent stay
  indistinguishable. `/@handle` now redirects 301.

### Fixed

- **Recovery codes could not be regenerated at all.**
  `/profile/recovery-codes` read a session key nothing in the codebase ever
  wrote, and `RecoveryCode`'s own documentation claimed a TOTP reset re-issued
  them — it never touched the table.
- **The recovery-code password reset sent no security notice,** while changing
  a password while signed in always had. The flow most likely to be somebody
  else was the only silent one. Its username lookup was also case-sensitive
  while the throttle downcases, so registering `Alice` and typing `alice` gave
  a generic refusal *and* burned a throttle slot.
- **The Comments tab had been ordered oldest-first since it was written.**
  `distinct: c.id` compiles to `DISTINCT ON`, PostgreSQL requires those
  expressions to lead the `ORDER BY`, and Ecto therefore prepends them — so
  the newest-first the code asked for never had any effect.
- **A mistyped date returned the whole site.** `before:not-a-date` parsed to
  no operator and no search term, and that was read as "match everything".
- **Staff could mute the approval queue.** `pending_registration` is
  always-delivered now, like the other operational notices.

### Security

- **`mint` 1.10.0 → 1.10.1** (CVE-2026-82672 / GHSA-rj5m-69wp-cxq9, MEDIUM):
  unvalidated chunk-size line tail enabling response smuggling against strict
  intermediaries on pooled connections. A production dependency, reached by
  every federation fetch, feed poll, link preview and media-proxy request.
- **Recovery addresses are encrypted at rest** under the `:auth` keyring and
  bound to their owner, like TOTP secrets. On a pseudonymous forum that column
  is the one thing linking an account to a real-world identity. It is the
  first secret column that does not live in its owner's own row, so key
  rotation now tracks the owning column explicitly.
- **A reset link is stored only as a SHA-256**, is claimed with a single
  conditional `UPDATE` so two simultaneous redemptions cannot both win, and
  answers every failure identically — unknown, expired, spent, revoked or a
  since-banned account — so the page cannot be used to discover whether a link
  ever existed. It carries `noindex` and no canonical, because the token is in
  its path.
- **An always-delivered notice when a reset link is *issued*,** not only when
  it is used. The member who asked cannot read it; the one who did not ask is
  exactly who needs to see it while it is still outstanding.
- A crash on `/welcome` for an account the interaction gate refused, a
  five-per-hour limit on recovery-code regeneration, and a
  `translation_coverage_test` gate that fails the build when a translation
  interpolates a binding its message never passes.

## [1.32.0] — 2026-09-20

Phase 4F (privacy and language), and the first pieces of 4A.

Anyone can now change the site's language from the footer, signed in or not.
Before this a guest could not change it at all — the answer came from
`Accept-Language` and nothing else — and a member could only reorder a list on
`/profile`.

**Upgrading:** nothing to do. No migration, no release task, no setting an
operator has to add. Visitors get one new cookie, `locale`, and only if they
use the switcher.

### Added

- **A language switcher in the footer.** A `<details>` dropdown holding a
  plain form. Both halves are deliberate: `<details>` is the one disclosure
  widget the browser implements itself, so opening it needs no JavaScript and
  no `aria-*` bookkeeping of ours to get wrong; and the form posts to a
  controller because writing a cookie and the session is a controller's job.
  A language control has to keep working when scripting has gone wrong — it is
  what a reader reaches for when the page already makes no sense to them.

  The choice lives in a named one-year `locale` cookie rather than in the
  session, because the session is dropped at sign-out and a preference that
  resets itself reads as a bug rather than as privacy. A member's click also
  moves that language to the head of their preferred languages, so the footer
  and `/profile` cannot disagree and the choice follows them to another
  device. **Match my browser** deletes the cookie: a switcher with no way back
  to automatic is a one-way door.

  An unknown value is ignored — never handed to Gettext, never echoed back —
  and the page it returns to comes from a CSRF-protected form field, with the
  query string restored from a same-origin `Referer` only when it agrees with
  that path, so a search or a page number survives the switch.

- **An empty state on the home page.** "No boards" cannot happen — setup
  seeds the SysOp board and `delete_board/1` refuses to remove it — but "no
  board *this viewer* may see" can, and nothing stops an admin raising SysOp's
  `min_role_to_view`. A guest then got a page whose welcome text said "Browse
  the boards below" with nothing below it. The empty state never distinguishes
  "none exist" from "none for you", because that difference is exactly what
  `min_role_to_view` is keeping.

- **A translation coverage gate.** `translation_coverage_test.exs` fails the
  build on an empty `msgstr` in zh_TW or ja_JP. `en` is exempt: its `msgid`s
  *are* the source text Gettext falls back to. A string whose translation
  really is the English — an example value in a placeholder — is written out
  in full with a translator comment, because an empty entry cannot be told
  from an oversight.

### Changed

- **Nothing here is ranked by engagement, and it is now a record.**
  [ADR 0054](doc/adr/0054-attention-follows-the-board-not-a-ranking.md): no
  `/popular`, `/trending`, `/hot`, `/recent` or `/top`; the home page lists
  boards, not the articles inside them; board cards carry no post count; the
  order is the admin's, never activity. A ranking is a feedback loop rather
  than a measurement — what it surfaces gets read, which keeps it surfaced —
  and engagement cannot tell an argument from a conversation, so ranking on
  activity promotes a flame war to the front page. Chronological order within
  a board, search, tag pages, the feeds, the personal timeline, unread markers
  and `/unanswered` are deliberately unaffected: none of them is the site
  choosing for a reader. `no_content_ranking_test.exs` gates the four
  falsifiable shapes; whether some *new* surface is a ranking is a judgement
  review has to make.

- **Locale resolution order.** The `locale` cookie, then the member's
  preferred languages as cached at login, then `Accept-Language`, then `en`.
  The cookie is first because it is the only one of these a person said out
  loud.

- **One definition of "is this a safe local path".**
  `BaudrateWeb.Helpers.local_path/2`, extracted from `SessionController`.
  An open-redirect guard kept in two places is one that gets fixed in one.

### Fixed

- **A member who changed their language kept being shown the old one.**
  `SetLocale` reads a member's language from the session copy of their
  preferred languages, which is written at login and nowhere else, and a
  LiveView cannot write the session — so changing it on `/profile` reached the
  database and stopped. Every later full page load rendered its dead HTML,
  including `lang=` on `<html>`, in the language they had just left, and kept
  doing so until they signed in again: a screen reader was told the wrong
  language on every load. `/profile` now posts the change to the same
  controller the switcher uses, and only when the *effective* language moved —
  reordering the entries below the first changes nothing anyone reads.

- **The zh_TW language is named 台灣漢語.** It read 正體中文, in the switcher
  built to display it. Both 繁體中文 and 正體中文 name a *script* and frame
  the variety as a typographic variant of something else. The site's own
  governing-language clauses in `doc/eua.md` and `doc/privacy-policy.md`
  already said 台灣漢語, so the switcher was offering a reader a different
  thing from the one the terms are written in.

- **`layout_test.exs` covers `<details>` menus.** It found menu triggers by
  `aria-haspopup`, which a `<summary>` correctly does not carry — a disclosure
  is not a menu widget, and labelling one as a pop-up so a test could find it
  would be a lie told to screen readers. Its sandbox ownership timeout was
  also tighter than the timeout those tests set for themselves, so an overrun
  surfaced as a bewildering assertion about a missing theme attribute rather
  than as a timeout.

### Documentation

- **The cookie inventory.** `doc/development.md` lists both cookies this
  instance sets, with lifetimes and attributes, and `doc/sysop.md` points at
  it from the section an operator sits in while writing the privacy policy
  that has to describe them. Theme and text size are `localStorage` and never
  reach the server.
- `doc/troubleshooting.md` gains "A member says the site is in the wrong
  language" — a year-long cookie that outranks `Accept-Language` is a new way
  for the site to look broken while working as designed.

## [1.31.1] — 2026-09-20

A lint annotation. No behaviour change, and nothing to do on upgrade beyond
what v1.31.0 already asks for.

### Fixed

- **The Security checks job passes again.** v1.31.0 extracted an existing
  `raw(Markdown.to_html(...))` call out of a template and into a named
  function (`CommentComponents.comment_body/1`), so that the warned and
  unwarned branches of a comment could not render different things. Sobelow
  does not see the call inside a template but does see it inside a function,
  so it reported `XSS.Raw` and failed CI on an unchanged expression.

  It is a false positive: `Content.Markdown.to_html/1` ends with the Ammonia
  sanitizer and the media-proxy rewrite, which is precisely why `raw/1` is
  correct there and is stated in that module's own documentation. Marked with
  `# sobelow_skip ["XSS.Raw"]` where it lives, per `.sobelow-conf` — skip
  means "someone checked this function", so a new function is checked again.

  v1.31.0's own CI keeps the red job; the tag was already published and
  nothing about the release artifact was wrong, so it was left alone rather
  than rewritten.

## [1.31.0] — 2026-09-20

Phase 3 (federation reach), complete: stages 3A–3F.

Federation that stopped at the instance boundary. None of it was a bug in
something that worked — a reply that did not thread, a mention that named the
wrong person, a Lemmy community whose posts were discarded, a profile edit
nobody heard about. All of it was invisible from here and visible only from
another server, which is why it lasted.

**Upgrading:** four migrations, and **one release task that must be run**:
`bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"` (see
`doc/sysop.md`, "Data Repair: `ap_id` Backfill"). Until it runs, comments
created before the upgrade keep their old IDs and stay unthreadable from other
instances; nothing breaks either way, and the task is idempotent and resumable.

### Added

- **Lemmy communities work**
  ([ADR 0053](doc/adr/0053-a-group-announce-is-a-carrier.md)). A community is a
  hub rather than a booster: members send activities *to* it and it announces
  them on, so its `Announce` wraps an **activity** where a Mastodon boost wraps
  an object. The handler accepted only `Note`/`Article`/`Page` objects and
  returned `:ok` for everything else, so **every post in every followed Lemmy
  community was silently discarded** — the board followed the community, the
  activities arrived, and nothing appeared.

  A carried `Create` now goes to the announced-content path, which verifies
  the object through its own origin and routes it to the boards following the
  **group** rather than the author's (nobody here need follow the author at
  all). `Update`, `Delete`, `Like` and `Undo` are honoured only when their
  actor is on the group's own host: the signature on the Announce is the
  group's and the inner activity carries none, so that host is the whole of
  what the group can prove. A community relaying another instance's `Delete`
  is asking to be taken at its word about somebody else's actor, and taking it
  would let any community delete any post anywhere.

- **Content warnings, in both directions**
  ([ADR 0052](doc/adr/0052-a-content-warning-is-a-field-not-a-prefix.md)).
  Every composer — article, article edit, comment, timeline reply — offers an
  optional warning, published as `summary` + `sensitive`. Warned content
  renders collapsed behind a `<details>` element the reader opens: not a
  JavaScript toggle, because a warning has to hold when scripting has gone
  wrong, and with class names that no cosmetic-filter list targets, because a
  warning hidden by a content blocker shows the content it was standing in
  front of.

- **Video and audio attachments arrive as a link** to the original instead of
  being dropped. They cannot go through the media proxy — that would mean this
  instance downloading and re-serving arbitrarily large files — and embedding
  them would be the hotlink the proxy exists to prevent, so a link is the
  honest form: it contacts nobody until the reader follows it, like the
  click-to-load video player (ADR 0045). A post whose whole point was a video
  used to arrive looking empty.

- **NodeInfo is served at 2.0 as well as 2.1**, and reports
  `usage.users.activeMonth`, `usage.users.activeHalfyear` and
  `usage.localComments`. The 2.0 document omits `software.repository`, which
  its schema has no place for. `metadata.nodeDescription` is included when the
  `site_description` setting is set.

- **`Baudrate.Federation.Context` declares the `baudrate:` extension terms.**
  `baudrate:pinned`, `:locked`, `:commentCount`, `:likeCount`,
  `:parentBoard` and `:subBoards` were published without appearing in any
  `@context`, which makes them undefined terms in JSON-LD — dropped by any
  consumer that expands the document rather than reading it as plain JSON.
  One module now owns every context this instance publishes, where four each
  held their own copy of the ActivityStreams URI. The namespace identifies the
  software, not the instance, so the terms mean the same thing on every
  Baudrate. Documented in `doc/api.md`.

- **A profile or board edit reaches followers.** Changing a display name, bio,
  avatar or profile field now sends `Update(Person)`; changing a board's name,
  description or avatar sends `Update(Group)`. Both were silent before, so a
  remote instance kept whatever it first saw until it happened to refresh the
  actor.

  The test is the **rendered actor document**, not a list of fields: the
  activity goes out when the `Person`/`Group` JSON differs before and after,
  and otherwise nothing is sent. So a field added to `ActorRenderer` tomorrow
  federates with nothing to remember, and a change the document does not carry
  — a signature, a notification preference, a narrowed `dm_access`, a board's
  `min_role_to_post` — costs no fan-out at all. The publish commits with the
  change, so a restart cannot save a new name and drop the activity announcing
  it.

  There is deliberately **no debouncing**. `/profile` saves each section
  separately, so editing four of them sends four `Update`s; coalescing them
  would mean holding an activity in memory, which is the one thing ADR 0034
  says publishing must not do. Profile edits are rare enough that the trade
  goes the other way. An instance that ever sees queue pressure from this
  should coalesce in the delivery queue, where the jobs are durable.

- **A closed poll publishes its final counts**, once, from a new hourly
  `announce_closed_polls` step. A poll has no stored "closed" state — it
  closes by the clock, like a sanction expires — so this is the one place that
  treats closing as an event, and a new `polls.final_update_sent_at` is what
  makes it happen exactly once rather than every hour or, on a missed run,
  never. Gated like any other publication: a poll in a private board announces
  nothing (but is still marked, because deciding not to announce is a way of
  having handled it).

- **A reply threads where it belongs.** A comment's `inReplyTo` names its
  **parent comment** rather than the article, so a Mastodon user sees who is
  answering whom instead of a flat list. One definition
  (`ObjectBuilder.reply_target_uri/2`) is shared by the published
  `Create(Note)`, the object at `/ap/comments/:id` and the replies collection.
  A reply to a *remote* comment names that comment's own URI, threading it
  back into the conversation on the instance it started from. This was not a
  regression: until comments had a dereferenceable id (above) there was
  nothing `inReplyTo` could have named.

- **`@user@domain` mentions reach the person they name**
  ([ADR 0051](doc/adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md)).
  Resolved remote handles become `Mention` tags plus `cc` addressing on
  articles and comments, and the object is delivered to them. Unknown handles
  are looked up once, when the content is written, via WebFinger.

- **Comments and polls are fetchable objects** — `GET /ap/comments/:id` returns
  the comment as a `Note`, `GET /ap/polls/:id` returns the poll as a standalone
  `Question`. Both are content-negotiated: a browser is redirected to the
  article. Documented in `doc/api.md`.

### Fixed

- **An inbound content warning no longer becomes the content.** A `sensitive`
  object had its `summary` glued onto the front of the body as `[CW: …]`.
  That is a one-way conversion, and it loses the only thing that matters: once
  the warning is inside the body it is the first line of the text it was
  supposed to stand in front of. Nothing could render the post collapsed,
  nothing could publish the warning back out — and **the reader was shown the
  content anyway**, with a label above it.

  `summary` and `sensitive` are now columns on articles, comments, timeline
  items and timeline replies, with one module
  (`Baudrate.Content.ContentWarning`) holding the rules for all four: an empty
  warning is `nil` rather than `""`, text implies the flag (a peer that sends
  a `summary` and forgets `sensitive` meant to warn somebody), and the text is
  bounded. **Rows written before this keep their `[CW: …]` prefix** — parsing
  it back out would be guessing where the warning ends.

- **Articles no longer arrive on Mastodon hidden behind their own first
  paragraph.** `summary` carried a 500-character excerpt of the body, which is
  a defensible reading of ActivityStreams for an `Article` and wrong in
  practice: Mastodon maps `summary` to `spoiler_text` for every object type it
  ingests. It now carries the content warning and nothing else. The excerpt is
  gone rather than moved — `name` already carries the title and `content` the
  body.

- **NodeInfo counted things it should not have.** `usage.users.total` counted
  feed bots and banned accounts, so every instance-size comparison this
  document exists for was inflated. `usage.localPosts` counted *every* article
  row, including ones mirrored from other instances — so an instance that
  followed a busy community reported that community's output as its own — and
  included soft-deleted articles.

  Active-user counts are new rather than fixed, and needed a durable column:
  `users.last_active_on`, stamped on sign-in and session refresh. They could
  not come from `user_sessions`, where a session lives 14 days and is then
  purged. It is a **date, not a timestamp**, deliberately — the question is
  which month somebody was last here, and a timestamp would record what time
  of day they read the site, every day, for six months. It appears in the
  member's own data export.

- **A mention of a remote person no longer links to a local stranger.**
  `Content.Markdown`'s mention pattern treated `@` as a word boundary, so
  `@alice@mastodon.social` matched `@alice` and linkified it to the **local**
  `/users/alice`. Whoever happened to hold that name here got the link, the
  remote person was told nothing, and the published object carried no mention
  at all. `@user@domain` is now a pattern of its own, and links to this site's
  own search, which resolves the actor and offers a follow — not to
  `https://domain/@user`, which is a guess at another server's URL scheme.
  An ordinary email address is still autolinked as `mailto:` and is never
  mistaken for a handle.

- **A comment's ActivityPub ID no longer resolves to the wrong object**
  ([ADR 0050](doc/adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md)).
  Local comments were stamped `https://host/ap/users/alice#note-42` and polls
  `https://host/ap/articles/some-slug#poll`. Both are URI *fragments*, and a
  fragment is never sent to the server: dereferencing the first returned the
  author's Person document and the second returned the Article. So the ID this
  instance published for an object reliably resolved to a **different object**,
  and had done since comments first federated.

  Everything that needs to dereference a comment therefore could not. A
  Mastodon user replying to a comment sends `inReplyTo: <that comment's id>`;
  the receiving instance fetched it, got an actor back, gave up, and threaded
  the reply flat under the article. A `Question` embedded in an Article carried
  no `id` at all, so a remote client had nothing to address a vote to. Nothing
  was wrong locally, which is why it lasted: the IDs are unique, they round-trip
  through our own inbox, and every test passed. The failure was only ever
  visible from another server.

  Both now use paths, minted by `Federation.actor_uri/2` like every other URI
  this instance builds, and `Baudrate.Release.backfill_ap_ids/1` rewrites the
  existing rows.

- **The rewritten IDs do not orphan what peers already know.** An `ap_id` is a
  public identity and ActivityPub has no way to announce that one has changed
  (`Move` is for actors), so the old value is kept in a new `legacy_ap_id`
  column and is load-bearing in both directions: `Content.get_comment_by_ap_id/1`
  and `get_poll_by_ap_id/1` match either column — the single lookups all seven
  inbound call sites go through — a poll vote may address the article or the
  poll, and `Publisher.publish_comment_deleted/2` publishes the deletion under
  **both** IDs. Without that last one, deleting a pre-upgrade comment would
  have left it standing on every instance that had it. `legacy_ap_id` is
  matched, never asserted, and never castable from params (ADR 0049).

- **`Baudrate.Release.backfill_ap_ids/1` derives its base URL from the running
  endpoint when there is one.** It kept its own derivation from static config
  because release tasks run with only the repo started — correct, but it meant
  two definitions of this instance's own URL. That was tolerable while the task
  only healed the occasional `nil`; now that it rewrites in bulk and publishes
  the result, a disagreement would stamp a host the site does not answer on.
  The static derivation remains as the fallback for `bin/baudrate eval`.

- **The article replies collection no longer invents an ID for a local comment
  that has none** — the fallback was a fragment of the collection's own URI,
  which a peer following it could not resolve either.

### Security

- **A mention cannot carry a post out of a board that does not federate.**
  A mention is the only place a *member* picks an outbound recipient, by
  typing, so it is a sixth surface **of** ADR 0043's board gate rather than an
  exception to it. The gate is applied at four points: the `Mention` tag, the
  `cc`, the delivery job, and the **lookup** — resolving an unknown handle is
  itself an outbound request, and doing it for a private-board article would
  tell that server a member here typed the handle.

- **Mention resolution is bounded four ways**, because the handles come from
  text the author chose and each unknown one costs another server two
  requests: 30 lookups per hour per user, 8 unknown handles per post, a
  3-second deadline per lookup and a 5-second budget for the whole step.
  `HTTPClient.get/2`, `ActorResolver.resolve/2` and
  `Discovery.lookup_remote_actor/2` gained an optional `:timeout` for this; it
  can only **shorten** the configured ceiling, never extend it. Bots never
  resolve mentions — a feed body is not the bot's writing, and an RSS item
  containing an address would otherwise make this instance fetch from whatever
  domain it named, on a schedule. An actor on a blocked domain is never
  addressed, though blocking deletes nothing and its row still exists.

### Changed

- **Actor documents are cached for 180 seconds** instead of `no-store`, which
  takes real load off both sides of a federation link — a verifier fetches the
  actor on every signature check. `no-store` stays on every 404 and HTML
  redirect, because a cached wrong answer there breaks signature verification
  for everyone, and `public` is used **only while authorized fetch is off**:
  with it on, the same URL answers 401 unsigned and the document signed, so a
  shared cache holding it would defeat the setting.

- `Baudrate.Federation.Visibility` now owns both directions of the `to`/`cc`
  mapping (`to_addressing/2` beside `from_addressing/1`), and `Publisher`
  delegates to it. The comment object needs the same addressing the publisher
  builds, and two copies of that mapping would have drifted.
- `Publisher.publish_comment_deleted/2` returns `:ok` rather than
  `{:ok, count}`: it may now enqueue two activities, so a single job count no
  longer describes it.
- `Publisher.build_create_comment/2` preloads the article's `:boards`. It did
  not, and `Delivery.article_boards_federated?/1` fails closed on an unloaded
  association — so every comment mention was silently dropped. Found by the
  ADR 0051 gate, which is the argument for having one.
- `Notification.Hooks` reads local mentions through `Mentions.extract/1`, so a
  member named in the long form `@alice@this.host` is notified like `@alice`.
- `Publisher.build_create_comment/2` builds its Note through
  `ObjectBuilder.comment_object/1` rather than assembling its own copy. The
  duplicate is what made mention tags, and then content warnings, a thing to
  remember twice.
- `Publisher.publish_key_rotation/2` is now `publish_actor_updated/2`. A new
  public key and a new display name are the same activity carrying the same
  document, and two names for it would be two things to remember when a field
  is added.

## [1.30.0] — 2026-09-19

Things this instance told the fediverse, its members or its own records were
true, and were not. A record-by-record audit of the 46 ADRs then on file,
against the code, drove most of it: the site actor advertised three endpoints
that answered 404, a YouTube link put a Google iframe on the page, article
moderation was authorized at mount rather than at the act, and the rule
binding every identity claim to its host had sixteen call sites and no record
at all.

**Upgrading:** no migrations and no configuration changes.

**Operators:** the deploy refuses a host whose Debian release or architecture
disagrees with `debian_version` (ADR 0036 decision 1, restored). Production is
Debian 12 on x86_64 and is unaffected; a host that drifted will now be told
so, which is the point.

### Added

- **The site actor serves the three endpoints it advertises.** `/ap/site`
  published `outbox`, `followers` and `inbox` URIs, and all three returned 404.
  Mastodon fetches an actor's collections when it first sees it, so the
  instance actor failed discovery — and a peer that posted a `Follow` to the
  advertised inbox was told nothing at all. `/ap/site/outbox` and
  `/ap/site/followers` are now served (empty collections: the site actor signs
  instance-level activities and publishes nothing of its own), and
  `POST /ap/site/inbox` routes to the same handler as `/ap/inbox`, which
  resolves the target from the activity's addressing either way.

### Changed

- **The YouTube player loads on a click**
  ([ADR 0045](doc/adr/0045-the-video-player-loads-on-a-click.md)). The server
  renders a poster frame — the thumbnail the link-preview fetcher had already
  stored locally — and a play button that says the player comes from YouTube;
  a hook builds the `<iframe>` when the reader presses it. One extra click to
  watch a video, and that is the whole cost.
- **`Federation` names the instance moderation operations**
  ([ADR 0047](doc/adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md)).
  Blocking a domain and suspending a remote actor were reached by the admin
  LiveViews directly, so nothing on the facade said this instance could do
  either. They are now `Federation.block_domain/3`, `unblock_domain/1`,
  `suspend_remote_actor/3`, `unsuspend_remote_actor/1` and `deliver_flag/2`.
  No check is gained or lost: authorization stays in the sub-module that
  performs the operation (ADR 0016), precisely so the facade can be bypassed
  without bypassing it.
- **The deploy checks the host's Debian release again** (ADR 0036 decision 1).
  The assert went with the move back to building on the server, but that made
  it matter more, not less: the release no longer arrives pre-linked, so a
  drifted host silently becomes the system the binary is built against while
  CI keeps testing on the other one. `debian_version` also fixes the
  PostgreSQL client major, so the first thing a mismatch breaks is the
  pre-deploy dump and the nightly backups (ADR 0028), not the deploy.
- **Card tap feedback hangs off a semantic class**
  ([ADR 0018](doc/adr/0018-semantic-ids-and-classes-for-accessibility.md)).
  Three rule sets targeted `.card:has(> .card-body > .stretched-link)` — the
  structural chain the record names as the anti-pattern. They now use
  `tappable-card`. Behaviour is unchanged, deliberately: the pressed selector
  keeps two branches so pressing an author link inside an article card does
  not flash the whole card.

### Fixed

- **A follow through the shared inbox told nobody.** A `Follow` addressed to a
  local user and delivered to `/ap/inbox` — which is where Mastodon sends it —
  was accepted and recorded, and the user was never notified. Only the
  per-user inbox route notified. Both paths now resolve the target the same
  way.
- **The TOTP enrolment form never said the code is single-use**
  ([ADR 0024](doc/adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md)
  decision 6). Eight forms carried the hint; enrolment did not, and enrolment
  *consumes* the code — so an admin who enabled TOTP and went straight to
  `/admin/verify` inside the same 30 seconds was refused with nothing having
  warned them.
- **Reference documentation for the above.** `doc/api.md` gains the three site
  actor endpoints and `doc/development.md` the followers and following routes
  it had never listed, the eight places origin binding is applied, and four
  Federation sub-modules missing from its table.

### Security

- **Article moderation is authorized at the act, not at mount**
  ([ADR 0016](doc/adr/0016-authorization-at-the-context-boundary.md)).
  `toggle_pin_article/1` and `toggle_lock_article/1` took no actor at all,
  `soft_delete_article/2` checked nothing, and `ArticleLive` computed
  `can_pin`/`can_lock`/`can_delete` once in `mount/3` and read them on events
  that could arrive an hour later. Losing a *role* revokes sessions, so a
  demoted admin was already stopped; losing a **board moderator** grant does
  not, so they kept pin, lock and delete on any article page left open. All
  four now authorize inside the context against a freshly reloaded actor, and
  a delete must name its actor or declare itself remote.
- **One definition of same-origin**
  ([ADR 0046](doc/adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)).
  Writing the record for origin binding turned up a second, divergent
  `same_host?/2` private to `InboxHandler` that accepted two hostless URIs as
  same-origin where the shared one rejects them — and it was the copy guarding
  the fetched-Announce object id and the `attributedTo` binding. It now
  delegates. A security primitive with two definitions is one definition and
  one liability.
- **No page contacts a third party on render** (ADR 0045, refining
  [ADR 0006](doc/adr/0006-media-proxy-no-third-party-subresources.md)). A
  YouTube link preview embedded a Google-hosted `<iframe>` on article, comment
  and DM pages, disclosing every reader's IP address and User-Agent simply for
  opening a thread. The acceptance gate could not see it: it matched `<img>`
  and nothing else, so it was blind to `<iframe>`, `<script>`, `<video>`,
  `<link rel=stylesheet>` and `url()` in CSS. The gate now covers every
  subresource element, and asserts `frame-src` admits exactly one origin, so a
  second embed fails the build.

### Records

Five new ADRs, and the audit that asked for them. **0045** the click-to-load
player; **0046** that every identity claim is bound to the host that can prove
it — sixteen call sites, seven distinct spoofing attacks, and the largest
undocumented decision in the codebase; **0047** what the facade rule actually
governs, amending 0002, whose "never reach into a sub-module" had never been
what the code does; **0048** why `poll_votes` carries a `user_id` when votes
are anonymous, and that this is anonymity from other members, not from the
operator; **0049** that user-facing changesets are allow-lists — the local
half of 0046, since the unique `ap_id` column is squattable from both sides.

`doc/adr/README.md` now names the relationship verbs (*superseded by*,
*amended by*, *refined by*, *renamed by*) and `test/doc/adr_index_test.exs`
fails when an index row drops an ADR number or a verb its record's Status line
uses. Two claims that were no longer true were corrected in the process.

## [1.29.0] — 2026-09-19

The instance now tells its admins when something is wrong with it, which
closes the last open item of Phase 2 — the phase whose goal was that no data
loss goes unnoticed.

**Upgrading:** no migrations and no configuration changes. Admins will start
receiving `health_alert` notifications; there is nothing to switch on.

**If you build from source,** `mix.exs` now requires Elixir 1.19 (see Fixed).

### Added

- **A failing health check now reaches a person** ([ADR 0044](doc/adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md)).
  `Baudrate.Health` has always known when a backup went stale, a queue stuck, a
  worker died, the disk filled or an encryption key went missing. Nothing told
  anyone: the report answered `503` and `scripts/pull-backups.sh` exited
  non-zero, and both waited for a monitor the operator had to build.
  `Baudrate.Health.Alerts` runs hourly from `SessionCleaner` and notifies every
  admin — in-app, and by Web Push for admins who subscribed — naming the checks
  that are failing.

  The alert is deliberately driven by a periodic check of the report rather
  than by the backup itself. A backup can only report a run that *failed*; it
  can never report one that **never happened** — a masked timer, a disabled
  unit, a host that was down at the scheduled hour — and those are the silent
  cases this exists for.

  It watches all seven checks, not only the backup: a full disk and an
  encryption key this instance no longer has were equally silent.

  Restraint is part of the design, not tuning. A failing set must survive two
  consecutive polls before anything is sent, the same set then repeats once a
  day rather than hourly, and recovery is announced once. Whether something has
  already been said is answered by querying the notification rows, so a restart
  cannot re-announce a week-old problem. `health_alert` and `health_recovered`
  bypass notification preferences, like the account-security notices: the
  person who would mute them is the person who has to act on them.

  It cannot report that the instance is **down**, because it runs inside the
  instance. `doc/sysop.md` still documents an external monitor, which is now
  the only part an operator has to build.

### Fixed

- **`mix.exs` declared an Elixir floor that nothing had built or tested.** It
  asked for `~> 1.17` while `.tool-versions`, the CI image and the Ansible
  inventory all install 1.19.5 — and the project block uses `listeners:`, a
  `Mix.Project` key that does not exist before 1.18, so on the declared minimum
  `Phoenix.CodeReloader` was silently never registered. Now `~> 1.19`, the
  version everything actually uses. This project pins PostgreSQL to
  production's major precisely so "passes here, fails in CI" cannot happen; a
  language floor two versions below anything that runs was the same class of
  claim.
- **Three controls the guides described that do not exist.** A 7-day
  account-age gate on invite generation, documented in four places including
  two moduledocs — removed from the code on 2026-03-15 and never removed from
  the docs; an instance federation kill switch on `/admin/federation`, which
  only toggles boards; and an "Abandon all for domain" admin action, which is a
  console function no UI calls. Same pattern as the `/admin/roles` finding in
  v1.28.1.
- **`doc/api.md` misdescribed hashtags twice** — the pattern as ASCII when it
  is `\p{L}` (so `#日本語` federates), and the output as case-preserving when
  every tag is downcased — and credited the `published` clamp with 60 seconds
  of clock-skew slack it does not have. Also corrected: the 202 response body
  for a blocked domain, the optionality of `updated`, and where a Person actor
  redirects under HTML content negotiation.
- **`doc/troubleshooting.md` gave a fix that cannot be carried out** ("upload a
  bot avatar by hand on `/admin/bots`" — there is no upload, and the bot's
  account has a locked password), and put the feed-bot backoff cap one failure
  early.
- **Three accepted ADRs named things ADR 0041 renamed** (`bot_feed_items`,
  `FeedWorker`). Their Status lines now carry the caveat six other records
  already had; the bodies are untouched.

### Changed

- `doc/TODOs.md` is shorter and better shaped: the completed phases are an
  index plus the two lists that earn their place — what only that file knows,
  and what the operator accepted knowingly.
- ADR 0035's decision 5 ("Baudrate does not notify") is amended by 0044. Its
  stated grounds included "no push channel", which was not true when it was
  written: Web Push shipped in February 2026 and every notification has gone
  through it since. The notifier was not waiting on a missing capability.

## [1.28.2] — 2026-09-19

Two defects a documentation audit turned up by reading the guides against the
code, plus the corrections that found them.

**Upgrading:** no migrations, no configuration changes, no behaviour changes.

**If you monitor the detailed health report**, its `workers` check gains a
fifth key, `stale_actor_cleaner`. Nothing else moves.

### Security

- **The edit-history page had a fourth copy of the article visibility check,
  and it was the weak one.** v1.28.1 consolidated "may this user see this
  article?" and reported three implementations; there were four.
  `ArticleHistoryLive` tested board view roles only — no refusal for a remote
  row ingested as followers-only or direct, and none for an author whose domain
  is blocked or whose actor is suspended. `/articles/:slug/history` shares the
  public route scope with `/articles/:slug`, so the leak that release set out to
  close was still open one URL away: the article page refused such a row while
  the history page rendered it, exposing the title through `page_title` even
  when the revision list was empty. The local copy is deleted rather than
  patched, so there is one definition again instead of two that agree.

### Fixed

- **The stale-actor cleaner was invisible to the health report's `workers`
  check.** It never called `Health.Heartbeat.beat/1` and had no entry in the
  worker list, so the check could not tell whether it had run this year — while
  `doc/sysop.md` documented it as a worker in two places. The report was
  quietly narrower than its own documentation, which is the failure
  [ADR 0035](doc/adr/0035-operational-visibility-stays-on-the-host.md) exists to
  prevent. It runs daily, so its staleness threshold is 72 hours.
- **`doc/api.md` carried three statements the last two releases made false**, and
  a federating peer would have been misled by all three: Board Following was
  documented as ignoring `?page` and always answering the root (it paginates like
  every other collection); `/ap/search` as covering "articles in public boards"
  (it is federated boards — this doc line is what found that leak in 1.28.0);
  and the WebFinger 404 rule named only private boards, omitting AP-disabled
  ones.
- **`doc/sysop.md` gave a manual-backup command that cannot run.**
  `Release.backup("/root/manual-backup")` executes as the `baudrate` user and
  starts with `File.mkdir_p!`, but `/root` is `drwx------ root root` — the only
  copy-pasteable command in either guide that simply fails. It also claimed
  every `/admin` page needs sudo mode, which is false for precisely the page it
  must not cover (`/admin/verify` is where you go to satisfy it), documented
  three `wax_` settings that appear in no config file, gave the `mix.exs`
  version floor as though it were what a build host needs, and named one
  renamed table in v1.28.0 when that release renamed two.
- **`doc/development.md`** still pointed at four file paths ADR 0041's rename
  swept past, never linked ADR 0043, listed four of the outbound gate's five
  surfaces, and documented none of v1.28.1's changes.
- New in `doc/troubleshooting.md`: a **Syndication bots** section. "The feeds
  stopped" is a routine question that had no entry, and the answer is that
  failures back off to a day, so a failing bot looks idle rather than broken.

### Changed

- `doc/TODOs.md` is 48 lines shorter and more current: the completed phases
  point at their ADRs instead of restating them, and the roadmap now keeps only
  what is recorded nowhere else — the numbered decisions, the open items, and
  the risks the operator accepted knowingly.

## [1.28.1] — 2026-09-18

Two authorization fixes found by an investigation into the permission system,
plus the decision records that investigation produced.

**Upgrading:** no migrations, no configuration changes. One behaviour change,
below.

**An admin can no longer ban another admin.** ADR 0029 has always said nobody
sanctions an account at or above their own role level, and every other sanction
applied it; a ban did not. It does now, so removing a peer admin is
demote-then-ban — two deliberate acts instead of one. That is also what stops a
single compromised admin session removing the other admins. Unban is
deliberately *not* rank-checked, so a banned account is always restorable.

### Security

- **A ban checked neither the permission nor the rank rule.** A ban is the
  harshest thing this system does to an account — permanent, revokes every
  session, cancels active data exports and account moves, revokes invite codes
  — and `Auth.ban_user/3` guarded only against banning yourself, against an
  admin id it never loaded. So the sanction ladder ADR 0029 built was gated at
  every rung except the top: a moderator could not silence a peer for an hour,
  while this function would permanently ban an admin for any caller that
  reached it. Authorization now runs at the context boundary
  (`Sanctions.authorize_ban/2`), in the module that already owns the rank rule,
  rather than relying on the route hook in front of it — which is what ADR 0016
  asks for and why the route hook was never enough on its own.
- **"May this user see this article?" had three implementations, and two were
  wrong.** The canonical one lived in the web layer and refused a remote row
  ingested as followers-only or direct, and an author whose domain is blocked
  or whose actor is suspended. The context's copy checked neither, and kept its
  own hand-written copy of the role hierarchy; the article-history page had a
  third. Since the interaction paths use the context's copy, a remote
  followers-only article in a guest-readable board was refused by
  `/articles/:slug` and **accepted by like, boost, bookmark and both forward
  paths** — and `can_forward_article?/2` gave admins a clause that returned
  before any visibility test, so an admin could forward such a row into a board
  whose outbox then re-publishes it stamped `as:Public`. Re-publishing someone
  else's followers-only post is not a trust question, which is why ADR 0030 and
  the invariants file both say these rows are refused to everyone including
  admins. There is now one definition,
  `Content.Interactions.remote_servable?/1`, in the context.
- An article id that resolved to nothing counted as **visible**, because the
  board count came back zero — which is also how a legitimate board-less quick
  post looks.

### Changed

- The acceptance gate for the permission catalogue had a second hole beneath
  the one closed in 1.28.0: it searched raw file text, so two permissions looked
  enforced on the strength of a moduledoc quoting them as examples. It now
  strips every heredoc and `@doc` before searching — the class rather than the
  two instances — and names **seven** unenforced permissions, not five.

### Added

- **[ADR 0042](doc/adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md)**
  — roles are a fixed, totally ordered set of four, and capabilities are not
  configurable. An audit of the whole authorization surface found that the
  permission matrix has no write path (nothing outside first-run seeding writes
  it, and there is no roles screen), so `has_permission?/2` is a constant
  function of a compile-time map; that only four of eleven permissions are
  consulted anywhere; that the dominant mechanism is the role name, in 29
  authorization decisions; and that the documented "higher roles inherit
  lower-role permissions" was never implemented. The record accepts that state
  rather than leaving it as an unexplained gap, and supersedes only the
  capabilities half of [ADR 0011](doc/adr/0011-role-levels-for-board-authorization.md).
- **[ADR 0043](doc/adr/0043-the-outbound-federation-gate-and-withdrawals.md)**
  — the outbound federation gate, and the withdrawals it must not touch.
  [ADR 0004](doc/adr/0004-federation-gate-for-non-public-boards.md) recorded the
  inbound half and its reasoning assumed an outbound half that no record ever
  described. It names all five surfaces that leaked in 1.28.0 and, more
  importantly, why gating a `Delete` is the wrong instinct: the gate exists to
  stop content leaving, a withdrawal carries no content, so refusing one cannot
  protect anything and can only strand a retracted post on every follower's
  server. That is the mistake closing the leak made first, and the one someone
  will reach for again.

### Fixed

- The operator guide still promised permission inheritance, and the SysOp guide
  is where that belief would be acted on. It now says what is true, including
  the practical consequence: editing the role/permission tables by hand does
  not change authority — change the account's role.
- `Content.Feed`'s docstring described its queries as "public timeline
  queries", which after 1.28.0's rename named a different subsystem entirely.
  The module keeps its name, deliberately, and now says why.

## [1.28.0] — 2026-09-18

Phase 2, stage 2F: Baudrate now deletes what it has agreed not to keep. Until
this release nothing was ever removed — a post its author deleted kept its body
in the database indefinitely, and two federation tables only grew. See
[ADR 0040](doc/adr/0040-retention-deletes-what-nobody-touched.md).

It also settles a piece of vocabulary, in two steps. "Feed" named four
different things here — the RSS and Atom the bots read, the syndication we
publish, a feed bot's dedup ledger, and the personal fediverse stream. The last
is now a **timeline**, in the URL, the code and the database
([ADR 0039](doc/adr/0039-the-personal-stream-is-a-timeline.md)); the first two
are now **syndication**
([ADR 0041](doc/adr/0041-rss-and-atom-are-syndication.md)), because leaving them
was not enough — the rename sweep itself mistook one for the other, on the one
table whose loss would make every bot re-publish its back catalogue.

The rest is hardening: a security audit, an accessibility sweep, a dependency
review, a code review and a documentation audit, run back to back before the
tag. The last of those found four code defects, all fixed here.

**Upgrading:** five migrations. Three are quick and additive; the other two are
renames — one moves five tables and their indexes, the other moves one more —
and both are reversible. One of the additive ones
(`unique_username_case_insensitively`) can **rename an existing account** — if
two usernames differ only in case, the older keeps its name and the newer gets
a numeric suffix. Nothing on this instance's scale should notice, but check
`users` afterwards if you have ever allowed mixed-case registrations. A
username is a fediverse handle, and nothing in the UI can change it back.

**Retention starts deleting on the first hourly run after this deploy**, and it
deletes permanently. Timeline items older than 90 days that nobody liked,
boosted or replied to; `announces` older than 180 days; and articles and
comments whose `deleted_at` passed 90 days ago, together with their revisions
and image files. Nothing a moderation report points at is touched, whatever its
age. The periods are in `doc/sysop.md` and in the privacy policy. Run
`Baudrate.Retention.run(dry_run: true)` first if you want to see the counts
before anything goes.

**If you monitor the detailed health report**, `workers.feed_worker` is now
`workers.syndication_feed_worker`. There is no compatibility alias: two names
for one worker is the ambiguity this release is removing.

**If you installed by hand from `doc/examples/nginx.conf.example`**, add the
`/uploads/media_cache/` deny rule it was missing — see Security below. The
Ansible deploy already had it.

**Elixir 1.17 is now the minimum.** It already was in practice — a non-optional
dependency requires it — but `mix.exs` said 1.15, so nobody on 1.15 could build
and the error did not say why.

### Added

- **Retention** (`Baudrate.Retention`, hourly from `SessionCleaner`): three
  purges, a `dry_run` mode that counts without deleting, and per-pass counts in
  the log. Autovacuum guidance for the two tables emptied in bulk is in the
  sysop guide.
- `scripts/check-keyring.py` validates `BAUDRATE_AUTH_KEYS` /
  `BAUDRATE_SIGNING_KEYS` **without disclosing them** — it reports each key's
  id, that it decodes to 32 bytes, and a truncated fingerprint, and nothing
  else. Checking a key set with `grep` over `sops --decrypt` prints the keys
  themselves, and the only remedy for that is rotating them. The fingerprints
  also prove a rotation replaced a key rather than relisting the same one under
  a new id, which looks correct in the file and in the key census. The rotation
  procedure now runs it before the deploy, where a malformed key is a typo
  rather than a boot refusal on a live instance.
- Usernames are unique without regard to case, and the timeline announces where
  you are in it to a screen reader (`aria-posinset`/`aria-setsize`).

### Changed

- **The personal stream is a timeline.** `/feed` is now `/timeline` and answers
  the old path with a 301, so bookmarks keep working. `feed_items` and its four
  satellite tables became `timeline_items…`, `Federation.Feed` became
  `Federation.Timeline`, and `FeedLive` became `TimelineLive`.
- **RSS and Atom are syndication.** `Bots.FeedParser`, `FeedParserNative`,
  `FeedWorker` and `BotFeedItem` became `Bots.SyndicationFeedParser`,
  `SyndicationFeedParserNative`, `SyndicationFeedWorker` and
  `BotSyndicationItem`; `FeedController` and `FeedXML` became
  `SyndicationFeedController` and `SyndicationFeedXML`; `bot_feed_items` became
  `bot_syndication_items`. The public URLs `/feeds/rss`, `/feeds/atom` and the
  rest are **unchanged** — every subscriber has one saved, and an RSS URL saying
  "feed" is not ambiguous to begin with. The WAI-ARIA `role="feed"` and a bot's
  `feed_url` column keep the word too.
- **An article in a guest-readable but AP-disabled board is no longer served
  over ActivityPub** and no longer appears in its author's outbox. The
  documented gate has always been "guest-viewable **and** `ap_enabled`"; five
  surfaces were testing only the first half, so turning federation off for a
  board did less than it said.
- Elixir `~> 1.17`; phoenix 1.8.14, phoenix_live_view 1.2.12, tz 0.28.4.
- The syndication-parser NIF no longer links a TLS stack it never calls (234
  crates down to 114).

### Security

- **Articles in private and AP-disabled boards were federated to their author's
  remote followers**, as `Create(Article)` addressed `as:Public`. One
  unsolicited Follow was the whole attack: after that, every post its author
  wrote in a staff-only board arrived on the follower's instance. The gate now
  applies to the author's own followers, to user boosts (an `Announce` names the
  article's URI, and the slug is derived from its title), and to the
  `cc`/`audience` of the AP object itself — which three unauthenticated
  endpoints serve verbatim, so a private board's name leaked through them too.
- **`/ap/search` was the fifth surface, and it was missed until the
  documentation audit read the API reference against the code.** The query
  filtered the viewer's role and not `ap_enabled`, and every result was rendered
  as a full Article object — title, body, attachments, stamped `as:Public` — to
  anonymous callers, while the same article's own permalink answered 404. The
  gate is opt-in per caller, because the site's own search must keep listing
  content in boards whose federation is off, and it is a clause in the query
  rather than a filter over the results, so the collection's `totalItems` cannot
  advertise a count its pages are unable to fill.
- **A withdrawal is never gated.** Closing the leak above initially dropped
  `Delete(Tombstone)` as well, so an article that had left its last federated
  board could no longer be withdrawn — moderation removing a post meant the
  author's later delete never reached the servers that held it.
- **The shipped nginx example did not deny `/uploads/media_cache/`.** Only the
  Ansible template did, while `doc/sysop.md` told a manual installer to copy the
  example and then asserted that "the shipped config" denied it. Anyone who
  followed the guide had the HMAC-signed `/media/` route bypassable and every
  cached third-party image readable by guessing a path — the one thing
  [ADR 0006](doc/adr/0006-media-proxy-no-third-party-subresources.md) needs nginx to
  enforce, because systemd's `ReadWritePaths` forces that cache under
  `uploads/`.
- **Retention could empty a moderation record and orphan image files.** A report
  on a comment was silently blanked when its article was purged, and files
  belonging to cascaded comments were never unlinked. Found and fixed before the
  feature shipped.
- **Image deletion did not work at all, in three places.** Each used a stored
  absolute path into the release directory current at upload time, which the
  deploy deletes — so the unlink silently did nothing while the row naming the
  file was destroyed, leaving the image served forever with no way to find it.
  Retention was the worst case (every file it purged); the orphan sweeps and
  `ArticleImageStorage.delete_image/1` had the same defect in narrower windows,
  and a deploy is exactly the event that lands inside them. All three rebuild
  the path from the filename, confined under the uploads root, and log a missing
  file instead of swallowing it — swallowing it is what hid all three.
- **Usernames were case-sensitive**, so `Admin` could be registered alongside
  `admin`. That is a distinct fediverse actor for impersonation, and it made the
  mention lookup return two rows — a permanent crash for anyone who wrote
  `@admin` in a post.
- **Admin sudo mode was only checked at mount.** A socket opened inside the
  ten-minute window kept accepting admin events for as long as it stayed
  connected; it is now re-checked on every event. A role change revokes the
  account's sessions, so a demoted admin's open tabs stop acting with authority
  they no longer have.
- **A domain block now stops us reaching out on every hop.** Two fetch paths
  still reached a blocked instance: the actor resolver's signed retry, which a
  redirect could steer, and the fetch behind an `Announce`, whose URI a verified
  sender chooses freely. Signature and authorization headers are dropped on
  every redirect.
- **The personal timeline showed posts nobody had addressed to its viewers.** It
  had no visibility filter, and for a boost the follow proves nothing about the
  author — so a hostile instance could put a victim's followers-only post in
  front of everyone who followed the booster. Direct posts never appear.
- **A locked thread accepted replies from the fediverse**, and a peer could pin
  its own post to the top of every follower's timeline indefinitely with a
  `published` date in the future. Both refused now.
- **A key named `legacy` silently destroyed what it encrypted.** That id is
  reserved for the `SECRET_KEY_BASE` fallback, and nothing reserved it: a key
  configured under that name was written with one key and read back with
  another, so every TOTP secret enrolled afterwards became unreadable — while
  the health check that exists to catch exactly this reported no problem. The id
  is refused at boot, and two further defects in the same check are fixed: it
  could report a lockout for a perfectly readable row (and crash the health
  endpoint doing so), and it loaded every ciphertext in the database on each
  scrape.
- Poll voter counts collapsed a local member and a remote actor that happened to
  share an id, under-reporting the count to every reader and to the fediverse.
  An unauthenticated request could crash the `/feed` redirect with a crafted
  query string. SSRF deny-list coverage for three further ranges
  (`64:ff9b:1::/48`, `fec0::/10`, `192.88.99.0/24`).

### Fixed

- **A board's ActivityPub following collection discarded `?page`** — the only
  collection action that did not thread its params through — so the `first` link
  it advertises answered with the root collection again and a peer could never
  walk it. Its documentation also still claimed the collection is always empty;
  a board follows remote actors, and that is how remote content reaches it.
- **Accessibility**: the "Remove from board" control, and four other places,
  used a colour at 1.89:1 against its background in the default light theme;
  fifteen more text elements sat at 3.22:1. Two breadcrumb landmarks had no
  accessible name. Loading older direct messages read the whole conversation
  aloud, because the live region was the entire list.
- The privacy policy said deleted posts were kept indefinitely, which had
  stopped being true; the retention periods and the report exemption are now
  written down in both languages.
- Three fuzzy mistranslations the gettext merge introduced ("Timeline" as
  "Timezone" in two locales, among others), and a batch of missing translations.
- **Two acceptance gates were not testing anything.** The permissions gate
  searched the file that defines the permissions, so it could never fail — five
  permissions had gone unenforced behind it. The LIKE-sanitization test asserted
  only that a list came back. Both now fail when the behaviour they guard is
  removed.
- An hourly purge of soft-deleted content scanned `articles` and `comments`
  whole, because the existing index on `deleted_at` covers only the rows the
  purge never wants.
- **The documentation audit corrected what a reader would have been told**, not
  only what was missing: the ActivityPub reference predated both federation-gate
  commits and never mentioned that the inbox answers 202 — the primary response
  a federating peer gets; the NodeInfo, WebFinger and actor samples had drifted
  from what we emit; the SSRF range list was missing seven entries; the
  rate-limit table was missing thirteen live buckets; user actor keypairs were
  documented as rotatable from `/admin/federation`, where no such control
  renders; and the feed-bot subsystem had no entry in the operator guide at all.
  Three docstrings in `lib/` had gone outright false, including one that
  contradicted a comment five lines below it.

## [1.27.0] — 2026-09-18

Phase 2, stage 2G: every secret Baudrate keeps at rest gets a key of its own,
and any of those keys can be rotated. Until now all of them were derived from
`SECRET_KEY_BASE`, which therefore could never be changed. See
[ADR 0038](doc/adr/0038-encryption-keys-are-separate-and-rotatable.md).

**Upgrading:** one migration (`recovery_codes.key_id`), additive and quick.
**Nothing to configure, and nothing changes on disk:** with no keys set the app
derives today's keys from `SECRET_KEY_BASE` exactly as before *and keeps writing
the old format*, so this release can be rolled back. Setting the keys is a
separate, deliberate change after the deploy has settled — values written
afterwards carry a key id that an older release knows nothing about. Both steps
are in the sysop guide ("Encryption keys", "Rotating an encryption key"). A boot
log line and the detailed health report say which classes are still on the
fallback.

### Security

- **`SECRET_KEY_BASE` could never be rotated, and four stored secrets depended
  on it.** If it ever leaked — a copied env file, a log line, an operator's old
  laptop, a backup left somewhere — there was nothing to be done about it. Two
  of those dependencies were not written down anywhere: the **recovery-code
  hashes**, which made the documented remedy circular (a member locked out of
  TOTP is told to use a recovery code, which the same rotation invalidated), and
  the **Web Push key**. Stored secrets now sit under an `:auth` key (TOTP
  secrets, recovery-code hashes) or a `:signing` key (user, board and site actor
  private keys, the Web Push key), each rotatable on its own; `SECRET_KEY_BASE`
  becomes rotatable once nothing is left on the old derivation.
- **A stored secret was portable between rows.** The ciphertext was bound only
  to its vault, so anyone able to write one row — SQL injection, a selective
  restore, a careless support script — could transplant a member's second factor
  onto another account, or an actor's private key onto another actor. Each value
  is now bound to the row it belongs to, by that row's immutable id, and no
  longer decrypts anywhere else.
- Every failure here is fail-closed: a wrong or missing key refuses the right
  person and never admits the wrong one, and no key problem raises inside a
  request.

### Added

- **Two keyrings, read from the environment.** `BAUDRATE_AUTH_KEYS` and
  `BAUDRATE_SIGNING_KEYS`, each a list of `id:key` entries with the current key
  first and retired keys after it, kept in SOPS like `SECRET_KEY_BASE`. A
  malformed entry stops the boot, naming the problem and the command that
  generates a key, and never echoing key material. Ansible renders them when
  they are set and — unlike `secret_key_base` — never generates one: a key the
  operator did not save would encrypt secrets on one deploy and be gone on the
  next, and what was written in between would be unrecoverable.
- **A rotation task.** `Baudrate.Release.rotate_keys/1` re-encrypts whatever is
  not on the current key, in batches, with `dry_run: true` to see the work
  first. What is left is read from the data rather than a bookmark, so it
  resumes by being run again and running it twice changes nothing. Each write
  lands only if the row still holds what was read, so a member enrolling TOTP
  mid-run keeps their new secret. A value it cannot decrypt is counted and
  logged, never written and never raised.
- **A key census.** `Baudrate.Release.key_census/0`, and the end of every
  rotation, lists how many values sit under each key id, per column — so a
  retired key is dropped only once nothing needs it.
- **A health check for a key that is gone.** The detailed report's
  `encryption_keys` check fails when a stored value names a key that is not
  configured, which means rows nobody can read, and stays quiet about an
  instance still on the fallback.
- **Key ids in the backup manifest.** `MANIFEST.json` records the ids that were
  current, never key material, so restoring a dump against the wrong key set is
  diagnosable instead of looking like everyone's second factor broke at once.
- **[ADR 0038](doc/adr/0038-encryption-keys-are-separate-and-rotatable.md)**,
  sysop guide sections on the key set and how to rotate one, and a
  troubleshooting section on the keys that protect stored secrets.

### Changed

- **Recovery codes record which key hashed them.** Only the member's own code
  can produce its hash, so a rotation cannot move it: verification now tries
  every configured key, and codes issued under a retired key keep working until
  the member generates new ones. The rotation deliberately does not regenerate
  anyone's codes — that would void a printed sheet without telling them.
- **Stored values say which key wrote them**, in a self-describing format that
  also authenticates the key id and the row. Values in the old format are still
  read, permanently.
- **The deploy builds the release on the server again**
  ([ADR 0037](doc/adr/0037-the-deploy-builds-on-the-server-again.md)), reversing
  one decision from 1.26.0: installing the CI tarball moved 46 MB down from
  GitHub and 46 MB back up to the server, and took 13 minutes against 2 for an
  incremental build. CI still builds, smoke-tests and attests the tarball on
  every push and every release — it is the gate that catches a release that
  cannot start, and it is what a manual install uses.
- Key derivation is cached, taking 1,000 PBKDF2 rounds off every TOTP
  verification, every outbound signature and every push delivery.

### Fixed

- `mix backfill_remote_urls` read a setting name that has never existed, so it
  could never decrypt the site's signing key and silently fetched nothing. It
  now goes through the one function that knows how that key is stored.

## [1.26.0] — 2026-09-18

Phase 2, stage 2E: a deploy installs a release that CI built, tested and
attested, instead of compiling one on the server, and a bad deploy can be undone
with one command. See
[ADR 0036](doc/adr/0036-production-runs-releases-built-and-attested-in-ci.md).

**Upgrading:** no migrations. This is the first release built by CI, and the
first the Ansible deploy installs as a tarball:

- **Wait for the tarball.** Publishing the GitHub release starts the Release
  workflow, which attaches `baudrate-1.26.0-debian12-x86_64.tar.gz`. The deploy
  fails until it has.
- **On the control machine:** sign in the GitHub CLI (`gh auth login`) and fetch
  the tag (`git fetch --tags`). The playbook's `git_repo` prompt is now
  `release_repo` (`owner/name`).
- **On the server:** the deploy generates the server's own Erlang cookie. A
  manual install must set `RELEASE_COOKIE`, or the release refuses to start.
  The node is now named `baudrate@127.0.0.1`, and `bin/baudrate remote` and
  `rpc` need the environment file sourced (see the sysop guide).
- **Releases before this one have no tarball**, so the deploy cannot install
  them; a release still on the server can be rolled back to.

### Security

- **Another local account could run code inside Baudrate.** A release built
  with `mix release` keeps its Erlang cookie in `releases/COOKIE`, readable by
  every local user, and the node listened for Erlang distribution on all
  interfaces. On a server that also runs other software under another account,
  that account could connect to Baudrate's node and read its database
  credentials and `SECRET_KEY_BASE`. The firewall kept this off the internet,
  not off the host. Each server now has its own cookie, generated once and
  readable only by the service account. The release refuses to start, or open
  a console, with the cookie it ships with or with none, and distribution
  listens on `127.0.0.1` only.
- **Nothing is compiled on the production server any more.** Building there
  ran every dependency's compile-time code and build scripts on the host that
  holds the site's secrets, from a toolchain installed without checksums.
- **The deploy verifies where a release came from.** On the control machine,
  before anything reaches the server, `gh attestation verify` requires that the
  tarball was built by this repository's Release workflow, on a GitHub-hosted
  runner, from the tag's commit as it is in the operator's own clone. A tarball
  from another workflow or commit, or for a tag moved on GitHub, is refused.
  The server then checks the file's SHA-256.
- The data export's statement timeout is passed as a query parameter instead of
  being interpolated into SQL, and remote actor documents with a missing field
  are refused with literal error atoms instead of atoms built from the field
  name. Neither was reachable from request input.

### Added

- **Releases built in CI.** Publishing a GitHub release builds the release in
  a project image running Debian 12, like production. It then starts the
  release the way production does and checks the cookie guard, migrations,
  `/health`, the detailed report, `rpc`, and that nothing but the web port
  listens beyond loopback. Only then does a separate job, which runs no
  third-party code, attest the tarball and attach it with its Sigstore bundle.
  The same build and smoke test run on every push.
- **A rollback playbook.** `rollback-baudrate.yml` switches back to a release
  still on the server (the previous one, or `rollback_to=<tag>`), restarts,
  and waits for `/health`. It refuses when the database has migrations that
  release does not contain, since rolling back code does not roll back the
  schema, unless `force=true`. `--check` reports the target and the verdict
  without changing anything.
- **Security checks in CI.** Sobelow fails the build on any finding; each
  reviewed false positive is marked where it occurs. mix_audit checks
  `mix.lock` against an advisory list built into the CI image, fetching nothing
  at run time.
- **[ADR 0036](doc/adr/0036-production-runs-releases-built-and-attested-in-ci.md)**,
  sysop guide sections on release artifacts, the Erlang cookie and remote
  console, and rolling back a deploy, and troubleshooting entries for each.

### Changed

- **CI runs on Debian 12**, production's release, in two images built from one
  Dockerfile: one builds releases, the other runs the tests. A release carries
  its own Erlang runtime and NIFs, linked against the system that built it, so
  it must be built on the system it runs on. The PostgreSQL 15 client now comes
  from Debian itself.
- **The deploy refuses a host** that is not Debian 12 on x86-64.
- The build toolchains stay installed on servers that have them: deploys no
  longer use them, and the Ansible README explains what can be removed by hand.

## [1.25.0] — 2026-09-17

Phase 2, stage 2D: an operator can find out that something is wrong before the
members do. A detailed health report on the host's loopback interface says
whether the site actually works (queues moving, workers running, disk space,
a recent backup), and logs can be written as JSON. See
[ADR 0035](doc/adr/0035-operational-visibility-stays-on-the-host.md).

**Upgrading:** no migrations. The report is served only when
`HEALTH_DETAIL_PORT` is set; Ansible sets it to `4001`, and sets
`BAUDRATE_BACKUP_DIR` to the nightly backup folder. Nothing is opened in the
firewall or proxied by nginx. On a manual install, set both yourself (see the
sysop guide), then poll `curl -s http://127.0.0.1:4001/health`.

### Added

- **A detailed health report.** `GET /health` on its own listener, bound to
  `127.0.0.1` in code so no configuration can expose it, answers `200` when
  every check passes and `503` when one fails, with a JSON report either way:
  - **database:** it answers;
  - **delivery queue:** no delivery has been due for more than 15 minutes
    (deliveries held by an open circuit are waiting on purpose and do not
    count);
  - **inbound queue:** no inbox activity has waited more than 10 minutes;
  - **workers:** the delivery, inbound, feed and cleanup workers have each
    completed a run within three of their intervals;
  - **disk:** free space under the uploads directory is above 1 GiB and 10%,
    the floor backups keep;
  - **backup:** the newest complete backup is under 26 hours old.

  Each check has 5 seconds; one that hangs or raises fails with a fixed reason
  instead of hanging the report or leaking the error. The report holds counts,
  ages and statuses only, with no content, account names or remote domains.
  The public `/health` is unchanged. Before this, a stopped queue, a worker
  crashing on every run, a filling disk or a backup that had not run for days
  all answered `ok`.
- **Worker liveness means a completed run.** Periodic workers record a
  heartbeat at the end of each successful run. A worker that crashes on every
  run and is restarted has a live process almost all the time, but never beats.
- **JSON logs.** `LOG_FORMAT=json` (Ansible: `log_format: json`) writes one
  JSON object per line with the time, level, message, request id and the
  calling module and function, and no other metadata. A newline in a message
  cannot forge a second entry, invalid UTF-8 is replaced, and the formatter
  never raises, since a formatter that raises silently ends all logging.
- **[ADR 0035](doc/adr/0035-operational-visibility-stays-on-the-host.md)**, a
  sysop guide section on polling the report and alerting from a systemd timer
  or a host monitor (Baudrate sends no alerts itself), and a troubleshooting
  entry for each failing check.

## [1.24.0] — 2026-09-17

Phase 2, stage 2C: federation work is saved before it is acknowledged. A post
and its outgoing activities are committed together, deliveries start as soon as
they are saved, a server that is down no longer holds up everyone else's, and
the inbox stores an activity and answers at once instead of making the sender
wait while it is processed. See
[ADR 0034](doc/adr/0034-federation-work-is-committed-before-it-is-acknowledged.md).

**Upgrading:** two migrations (`delivery_circuits`, and `inbound_activities`),
both additive and quick. Baudrate now holds one database connection beyond
`POOL_SIZE`, for `LISTEN`; connect it to PostgreSQL directly, since a pooler in
transaction mode (PgBouncer) cannot carry `LISTEN` and deliveries would fall
back to the one-minute poll. `delivery_batch_size` is no longer read.

### Added

- **An inbound queue.** The inbox checks an activity in the same order as
  before (well-formed, domain not blocked, account not suspended, signed by the
  actor it names), stores it and answers `202`; a redelivery is recognised and
  not stored again. A worker then processes stored activities, 4 at a time and
  one at a time per remote account in the order they arrived, so a `Create`
  never runs after the `Delete` that followed it, and it repeats the domain and
  suspension checks, so a block applies to activities already waiting. A
  refused activity is recorded with its reason; one that crashes or runs past
  5 minutes is retried, up to 3 attempts. Processing used to happen while the
  sender's request waited, holding a web process and database connections
  through actor lookups and reply-chain fetches, so a busy remote instance
  could slow the site for everyone.
- **A per-instance circuit breaker for deliveries.** After 5 consecutive
  failures that say a server is unreachable (connection errors, timeouts, 5xx,
  429), its deliveries pause together, and one is sent at a time as a probe,
  with waits growing from 5 minutes to 24 hours. The first response showing the
  server is up releases the rest. Deliveries held for 7 days are abandoned.
  Before, every job for a dead server waited out its own timeout while
  deliveries to healthy servers queued behind them.
- **[ADR 0034](doc/adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)**,
  and sysop and troubleshooting entries for open circuits, missed wake-ups and
  inbound activities that did not take effect.

### Changed

- **A change and its outgoing activities are saved together.** Posts, edits,
  deletions, comments, likes, boosts, forwards, poll votes, follows, direct
  messages, account moves and key rotations write their delivery jobs in the
  same database transaction as the change. They used to be queued by a
  background task started afterwards, so a restart or deploy at the wrong
  moment saved the post and silently dropped its activities. If building an
  activity fails, the change now fails with it instead of saving unfederated. A
  test runs every kind of change with all background work discarded, and fails
  on any code that sends activities from a background task.
- **Deliveries start within moments.** Saving a change sends a PostgreSQL
  notification, delivered only when the transaction commits, and the delivery
  worker wakes on it instead of waiting up to a minute for its next poll. It
  keeps up to 10 deliveries in flight and starts the next as soon as one ends.
- **Answers to follow requests are queued.** `Accept` and `Reject` were sent
  once from a background task; a failed request left the remote side's follow
  pending for good. They are now retried like any other delivery.
- **A final error response ends a delivery at once.** A `4xx` other than
  `401`, `408` and `429` means a retry cannot succeed, so the job is abandoned
  instead of being tried five more times over fifteen hours, as Mastodon does.

### Fixed

- **A slow server's delivery was retried every minute, forever.** A delivery
  task was stopped after 45 seconds, shorter than the 60-second request
  deadline, and a stopped task left its job untouched, so the job never used up
  its attempts. Deliveries now get the request deadline plus 15 seconds, and a
  stopped or crashed one counts as a failed attempt.
- **Forwarding a local comment into a board sent its `Create` and `Announce`
  twice**, under different activity ids.
- **An activity or object id over 2048 bytes caused a server error on every
  retry** instead of a refusal: the id goes into a unique index, which
  PostgreSQL cannot hold past about 2.7 KB. Such ids are now refused.
- The retry schedule in the sysop and troubleshooting guides listed a 24-hour
  sixth retry that never happens: a job is abandoned when its sixth attempt
  fails. The development guide said reply chains are followed 10 hops; the
  limit is 5.

## [1.23.0] — 2026-09-17

The first of Phase 2, operability: Baudrate officially runs on one node, CI
tests the PostgreSQL version production actually runs, and the backup puller
checks older copies, not only the newest.

**Upgrading:** no migrations. `DNS_CLUSTER_QUERY` is no longer read; remove it
from the environment if it is set. A machine that pulls backups runs
`scripts/pull-backups.sh` from a checkout, so update that checkout; its first
run starts recording verification stamps in `<dest>/.verified`.

### Added

- **Each backup pull also verifies one older copy.** The puller checked only
  the newest backup, and every database dump belongs to one copy only, so a
  dump was verified once, on the day it was newest, and rot in a three-week-old
  backup would have waited to be discovered at restore time. Each run now also
  checks the copy that has gone longest without a successful check,
  never-checked copies first; with 30 copies, each is re-checked about once a
  month. The summary line names it (`also verified …`), and a failure names the
  copy that failed.
- **[ADR 0033](doc/adr/0033-baudrate-runs-on-one-node.md): Baudrate runs on one
  node**, recording what depends on it — in-memory caches, security-key
  challenges, download tokens, rate limits, and every background job running
  exactly once.
- **A Scaling section in the sysop guide** — a bigger host, PostgreSQL starting
  points, and what a CDN must respect if one is used (it must front the whole
  site, since the Content Security Policy allows assets only from the site
  itself) — and a troubleshooting entry for recognising and removing an
  accidental second node.
- **Tests for the backup puller**, run against backups written by the real
  backup code, so both ends of the checksum contract are exercised.

### Changed

- **CI tests against PostgreSQL 15, server and client**, the version
  production runs. CI had a 17 server and client and development machines run
  newer still, so SQL needing a newer server could pass every check and fail on
  deploy. The client matters as much as the server: `pg_dump`/`pg_restore` 17
  and later write `SET transaction_timeout`, which a 15 server rejects. The CI
  image takes that one package from the PostgreSQL project's repository —
  trusting the signing key Debian itself ships, and pinned below Debian so
  nothing else comes from there — and CI fails whenever Ansible, the image and
  the workflow disagree on the version.
- **The test suite can target another PostgreSQL server** with `PGHOST` and
  `PGPORT`. `PGPORT` set only in the environment reached some connections but
  not the Repo, so such a run silently split across two servers.
- **The sysop guide's worker table is complete:** all four workers, and each of
  `SessionCleaner`'s fourteen jobs with the period the code actually uses.

### Fixed

- **A backup pull could copy a backup that was still being built.** The server
  builds each one under `.incomplete-…` and renames it when complete; a pull
  that overlapped (a workstation catching up after being off, say) brought the
  half-built folder along, and because pulls never delete, it stayed for good
  and was counted as a backup. Such folders are no longer pulled, and any left
  behind are removed.
- **The sysop guide said running several nodes was safe.** It described workers
  on every node as "idempotent (safe but slightly redundant)"; in fact two nodes
  would deliver every federation job twice, apply a domain block or a settings
  change on one node only, and fail security-key sign-ins at random.
- The README's clone URL was a placeholder, and it omitted `INSTALLATION_KEY`,
  without which every page answers 503 until setup completes.
- Two link-preview images committed to the repository by accident are no
  longer tracked.

### Removed

- **`DNSCluster` and the `DNS_CLUSTER_QUERY` variable.** Nothing supported more
  than one node, so the switch could only turn on a broken mode. Production
  never set it, and nothing changes at runtime.

## [1.22.2] — 2026-09-17

### Fixed

- **Members running an ad blocker could not accept the terms.** The accept card
  on `/terms` used the id `policy-accept`, which appears in the cosmetic-filter
  lists shipped with uBlock Origin and similar extensions — alongside
  cookie-consent and advertising selectors, because "policy…accept" is what a
  consent bar looks like. The card was hidden with `display: none`, so a member
  whose posting was paused had no way to clear it and nothing explaining why.
  Nothing was wrong with the page itself, which is why no test caught it.
- **Other notices could have been hidden the same way**, and two of them matter:
  a hidden account-move notice would deny someone whose account was taken over
  the warning that lets them cancel the move, and a hidden terms notice leaves a
  member unable to see why posting stopped. Every affected control was renamed
  away from words these lists target.

### Changed

- The interface now uses 您 rather than 你 throughout Taiwanese Mandarin
  translations, matching the published policy documents.

## [1.22.1] — 2026-09-16

### Fixed

- **Publishing a new version of the terms could silently do nothing.** The
  "require every member to accept again" checkbox took two clicks to tick: the
  first re-rendered the form, which patched the box back to unchecked. An admin
  who ticked once, saw it clear and saved anyway published nothing — the terms
  text changed, no new version was issued, nobody was asked to accept, and no
  error said so. The checkbox now keeps its state, so one click is enough.
- **The same checkbox stayed ticked after saving**, so the next ordinary edit —
  a typo fix — would have published another version and asked every member to
  accept again for nothing. The form is reset after a save.

## [1.22.0] — 2026-09-16

Backups that can prove they are intact, and two policy documents written from
what the code actually does.

**Upgrading:** no migrations. The first backup after upgrading writes a
`CHECKSUMS.sha256` alongside the dump; backups taken before this are still
verified, but only their database dump, and the puller says so.

### Added

- **A checksum for every file in a backup.** Each backup now carries
  `CHECKSUMS.sha256` covering the database dump and every stored upload, in the
  format `sha256sum -c` reads — so a copy can be verified anywhere with one
  standard command and no knowledge of this project. Previously only the dump
  had a checksum; the uploads, which are most of a backup, had none at all, and
  `rsync` exiting 0 was the only assurance they had arrived intact.
- **Off-host verification of the whole backup.** `scripts/pull-backups.sh` now
  checks the newest copy against that list — the dump *and* every upload — so
  corruption in transit, or bit rot on either disk, fails the nightly run
  instead of being discovered at restore time. It verifies the list against its
  own hash in `MANIFEST.json` first, because `sha256sum -c` on a truncated list
  exits 0 and would otherwise certify a backup missing most of its files.
- **A privacy policy and an end user agreement**, in `doc/`, bilingual
  (台灣漢語 and English) and written from the code rather than from a template:
  what federates and cannot be recalled, what the data export omits, which
  third parties a visitor's browser reaches, and what each retention period
  actually is. Both are templates, with the site name, operator, contact,
  source URL and jurisdiction as placeholders.

### Changed

- **Registration no longer promises a year of logs.** The notice said activity
  "will be logged for at least 1 year"; nothing implemented that, and the
  database is the other way round — sign-in attempts are purged after 7 days,
  while moderation records are kept indefinitely. It now says activities are
  recorded, without a period the software does not keep.
- A hard-linked file in a backup keeps the checksum the previous backup
  recorded rather than being hashed again. This is cheaper, but the reason it is
  correct is stronger: re-hashing would read the bytes as they are now and
  certify them, so a file that had rotted on disk would be marked intact by
  every later backup.

## [1.21.0] — 2026-09-16

The rest of roadmap phase 1: moderation levers between "nothing" and "a
permanent ban", federation blocks that actually take effect, and the published
rules and terms those decisions rest on.

**Upgrading:** six migrations run, all automatic. Two settings become tables —
`ap_domain_blocklist` moves into `domain_blocks` and `rules` becomes the first
row of a `rules` table — and both settings are deleted, so there is one
authority for each. Existing accounts are recorded as having accepted the terms
as they stood, so nobody is prompted by the upgrade itself; the first time you
tick "require every member to accept again", everyone is. No operator action is
required.

### Added

- **Sanctions short of a ban.** Warn, silence (read-only, optional end date)
  and suspend (no sign-in until a date, lifting by itself) sit alongside the
  permanent ban. They are rows with an explicit end, active by the clock rather
  than by a background job, so a missed run can never hold someone past their
  time. Global moderators may sanction up to 30 days; admins are uncapped.
  Nobody can sanction themselves or anyone at or above their own role level.
  Every sanction reaches the member — a notice, the refusal message, and a
  banner saying what stands and until when.
- **A user detail page** at `/admin/users/:id`: role, status, sanction history,
  reports in both directions, recent content, who invited them and whom they
  invited. IP addresses and sign-in attempts stay admin-only.
- **Refusing a pending registration**, with a reason, and staff are now told
  when someone is waiting.
- **Instance-level federation moderation.** Blocked domains are rows carrying a
  reason, a public comment and the admin who decided, blocked *and unblocked*
  from the Federation dashboard. A block now severs follows in both directions,
  hides everything the domain has already sent, and stops this instance
  reaching out to it. Nothing is deleted, so unblocking restores the content by
  itself.
- **Suspending one remote account** instance-wide, from a new instance page at
  `/admin/federation/instances/:domain` — the lever between telling someone to
  block an account personally and blocking its whole instance. A report about a
  remote account links straight there.
- **Public terms, rules and privacy pages** at `/terms`, `/rules` and
  `/privacy`, linked from a footer that was previously empty. Only documents an
  admin has actually written are linked.
- **Terms acceptance is recorded and versioned.** Registration now stores when
  a member accepted and which version; previously the checkbox was validated
  and the answer discarded, so editing the terms silently changed what everyone
  had agreed to. Ticking "require every member to accept again" publishes a new
  version: members see a banner and posting pauses until they accept. Reading
  is never affected, and neither are undoing a like, deleting your own content,
  reporting abuse, or anything about account security. Bot accounts are exempt,
  so RSS feeds keep running.
- **Site rules are a numbered list** edited at `/admin/rules`, each with a
  stable anchor, and a report can now say *which* rule it means — "Breaks a
  rule" could previously only say that one was broken. Rules are retired rather
  than deleted, so a report filed months ago still names the rule its author
  meant. Citing a rule is always optional.

### Security

- **A followers-only or direct post from a remote instance was listed
  publicly.** No listing query filtered non-public remote content, so such a
  post appeared with its title and digest on board pages, search, tags,
  bookmarks and feeds — and `/ap/boards/:slug/outbox` re-published it to the
  fediverse stamped as public. Every listing now filters it, and
  `test/baudrate/content/remote_visibility_test.exs` is the gate.
- **A blocked domain still received requests from this instance.** The check
  ran only on what a domain sent us, so actor lookups, object fetches, reply
  chains and the media proxy went on contacting instances we had decided not to
  federate with — disclosing readers' IP addresses and reading times to them.
- **The stale-actor sweep deleted rows it was still referenced by.** It decided
  an actor was unreferenced from six hand-written queries against nineteen
  foreign keys, so sweeping an account quiet for 30 days could delete its
  followers' follows and every feed item it had posted, and crash the run on
  the first one with a conversation. It now reads the foreign keys from the
  database catalog.

### Changed

- **A permission that enforces nothing is now a test failure.**
  `moderator.mute_user` and `admin.view_dashboard` were defined and never
  checked; both are gone, `admin.manage_roles` is wired up, and
  `moderator.sanction_user` is new.
- **`remote_actors.domain` is stored lowercase.** It is written from a
  peer-supplied URI, and the domain-block filter compares it with SQL equality,
  so an actor recorded as `Example.COM` would have stayed visible under a block
  on `example.com`. Existing rows are backfilled.
- **A role filter on the admin users list**, carried in the URL next to the
  status filter and search.
- **CI no longer runs where it proves nothing:** documentation-only pushes,
  pushes to `main` (which only ever fast-forwards from `current`), and runs
  superseded by a newer push.

### Fixed

- **The composer named the wrong reason when it turned someone away.**
  `/articles/new` said "Your account is pending approval" whichever condition
  actually stood, so a silenced member waited for staff who were not coming.
- **A translation that referenced a variable that does not exist.** A fuzzy
  gettext merge rendered "Move %{title} up" as "将 %{locale} 上移" in both
  locales — a render-time fault rather than merely a bad string. A new test
  fails on any translation interpolating a binding its source string does not
  provide.
- **The report detail view loaded fewer associations than the queue**, from a
  second hand-written preload list that had drifted from the first.

## [1.20.0] — 2026-09-16

A report queue board moderators can actually use, reason categories on
reports, and notices telling people what happened to what they reported or
posted (roadmap phase 1B).

**Upgrading:** three migrations run (`reports.category`,
`comments.deleted_by_id`, `reports.evidence_body` / `evidence_taken_at`).
Existing reports keep an empty category and still show in the queue.

### Added

- **A moderation queue for board moderators** at `/moderation`, outside the
  admin area. It lists only reports about articles in the boards they
  moderate and comments on those articles — never accounts, messages, feed
  items or another board's content. Resolving, dismissing and deleting are
  re-checked on the server against the moderator's boards, so a report id
  from the client grants nothing. Admins and global moderators see every
  board here too, and each board page links its moderators to the queue.
- **A reason category on every report** — spam, harassment, illegal content,
  breaks a rule, or other — chosen when reporting and shown in both queues.
- **Notices about outcomes:** resolving a report tells the reporter it was
  reviewed, with no detail; removing content tells its author, with the
  report's reason category. Removal notices cannot be switched off in
  preferences, since they are about the member's own content.
- **New reports now notify global moderators** as well as admins, plus the
  board moderators of the board the content is in.
- **Kept evidence:** removing reported content copies its text into the
  report, so a closed report still explains itself. The copy is cleared 90
  days after the report closes; an open report keeps it.
- **Off-host backup copies:** `scripts/pull-backups.sh` pulls the nightly
  backups to another machine over the read-only key from 1.19.5, verifies
  each manifest's checksums and the dump, keeps the newest 30 and exits
  non-zero when the newest copy is stale.

### Changed

- **The report queue shows the whole reported text** instead of a
  200-character preview, links to the article, the comment at its place on
  the article, the account or the original remote post, and says how many
  other open reports share the same target. Both queues page 20 at a time.
- **What happens to a cross-posted article needs rights on every board it is
  in.** Deleting, pinning or locking it, and deleting a comment on it, now
  require moderator rights on all of its boards; a moderator of one board
  can instead take the article out of their own board. Authors, admins and
  global moderators are unaffected.
- **Moderator deletions are recorded** for comments as well as articles, and
  moderators get their own delete limit of 100 per 5 minutes instead of the
  author limit of 20.

### Fixed

- **Backup file permissions no longer depend on the caller's umask** — dumps
  and snapshots are written `0640` in directories `0750` however the backup
  was started.

## [1.19.5] — 2026-09-16

Scheduled backups for Ansible installs, sized for a small server (ADR 0028).

**Upgrading (Ansible):** the deploy applies a new `backup` role, which
creates `/var/backups/baudrate` and a nightly `baudrate-backup.timer`, and
takes a database dump before migrations. Settings are the `backup_*`
variables in `inventory/group_vars/all.yml`. Remove any backup cron job set
up from earlier versions of the SysOp guide.

### Added

- **Nightly backups** (`Baudrate.Release.snapshot_backup/2`), each a folder
  with a database dump checked by `pg_restore --list`, a snapshot of the
  uploads and a manifest. Uploads unchanged since the previous backup are
  hard-linked, so a week of backups stores the images about once.
- **Safe retention:** the newest 7 backups are kept, and older ones are
  removed only after a new backup succeeded, so failed runs never delete the
  last good copies. A backup refuses to start when it would leave less than
  1 GiB or 10% of the disk free, and a half-written backup never counts.
- **A database dump before every deploy's migrations,** keeping the last 3;
  a failed dump stops the deploy before the database changes.
- **Restore commands:** `Release.restore_snapshot/1` for a nightly backup
  and `Release.restore_db/1` for a dump.
- **Read-only pull access for off-host copies** (`backup_pull_public_key`):
  a key that may only run a read-only rsync of the backup directory.

## [1.19.4] — 2026-09-15

Fixes forms that erased what was typed, including password reset, password
change and polls, and layout problems on narrow screens. Browser tests now
cover account security, moderation, member features and layout.

### Fixed

- **Password reset works when the form is filled in order.** Typing the new
  password erased the username and recovery code, so the reset failed. This
  is the only way back into an account without email.
- **Password change no longer erases the current password.** Typing the new
  password cleared it, so the change failed with "Invalid credentials" and
  the attempt counted towards the sign-in throttle.
- **Polls can be created again.** In the article composer and the feed's
  quick post, typing a poll option erased the others, and typing the title
  erased them all.
- **A bio typed in the admin bot form is kept** when another field changes.
- **Long titles no longer widen the page.** An article title with a long
  unbreakable token (a URL-like RSS or federated title) made the article and
  edit history pages scroll sideways at every width.
- **Member profiles fit narrow phones.** The header with the name, handle and
  Message/Follow/Mute/More buttons did not wrap, and the More actions menu
  opened partly off-screen.
- **Menus near the end of a page clear the mobile dock.** Their last items,
  such as "Report account" on the last feed post, sat under the bottom
  navigation where they could not be tapped.

### Changed

- **Browser tests cover much more** (77, up from 55), in CI: TOTP enrollment
  and sign-in, recovery codes, password change and reset, sign out
  everywhere, security keys, data export download, the moderation queue,
  block/mute/report menus, the composer (preview, drafts, polls, image
  upload), direct messages and invites.
- **The page crawl catches forms that erase typed input,** by filling every
  live-validated form field by field.
- **A layout test checks every member and admin page** in the Aqua light and
  dark themes at narrow and desktop width, for sideways scrolling and for
  menu items that are clipped or covered.

## [1.19.3] — 2026-09-15

Paging returns you to the list on every paginated page. CI now runs in the
project's own verified image and runs the browser tests too.

### Fixed

- **Changing pages brings you back to the list.** Only board and search pages
  scrolled back after paging. The feed, article comments, tags, bookmarks,
  notifications, a user's content pages and the admin lists left you at the
  bottom of the new page. Every paginated page now scrolls to its list (on an
  article, to the comments) and moves keyboard focus into it, and a test fails
  when a paginated page is added without this.

### Security

- **CI no longer runs third-party code to install its tools** (ADR 0027).
  Jobs run in a Debian image built in this repository from checksum-pinned
  inputs and published with a build provenance attestation. CI uses it only by
  a reviewed digest, after verifying that attestation. Actions are GitHub's
  own, pinned to commit SHAs, and the PostgreSQL service is pinned by digest.
- **GeckoDriver is built from source.** Its 0.37.x release binaries are signed
  only by a Mozilla signing subkey that Mozilla revoked on 2026-08-06 as
  compromised. The CI image and `mix selenium.setup` build 0.37.1 from its
  crates.io crate, with a pinned checksum and the `Cargo.lock` it ships.
- **The browser tests start Selenium Server on loopback only.** It listened on
  every interface, so anyone on a developer's network could drive a browser on
  that machine.

### Changed

- **CI runs the browser tests** (Wallaby with headless Firefox ESR), the only
  tests that run the JavaScript hooks. The page crawl signs an admin in with
  TOTP, covers every admin page, and fails when a page redirects instead of
  rendering.
- `mix selenium.setup` installs Selenium Server 4.49.0 (was 4.27.0) and
  GeckoDriver 0.37.1 (was 0.36.0), checking both against pinned SHA-256s. The
  CI image uses Rust 1.98.1. Dependabot and the weekly drift report also watch
  the CI image's base image and tools.

## [1.19.2] — 2026-09-15

Fixes two bugs found by auditing recent accessibility changes; one of them
v1.19.1 exposed.

### Fixed

- **Typing `#` or `@` no longer crashes `/profile` and `/admin/settings`.**
  Hashtag and mention suggestions work again since v1.19.1, but only the
  article and feed pages answered their requests, so typing in the profile
  signature or the End User Agreement field crashed the page and lost unsaved
  input. Suggestions are now answered on every signed-in page.
- **Direct message conversations open at the newest messages.** The
  conversation page named a script that did not exist, so it never scrolled
  to the bottom, and the scroll position kept when loading older messages
  (v1.18.2) never worked.

## [1.19.1] — 2026-09-15

Fixes for the feed pager, hashtag and mention autocomplete, menus in the Aqua
themes, and the hourly cleanup job.

### Fixed

- **The feed pager switches pages again, and #hashtag / @mention autocomplete
  works.** The autocomplete script on Markdown text boxes called a method
  renamed in v1.14.1, so it failed as it loaded. Suggestions never appeared,
  and on `/feed` the failure stopped page updates: the pager changed the URL
  but not the page.
- **Menus inside cards are no longer cut off in the Aqua themes.** The themes
  clip everything that sticks out of a card, which hid most of the "More
  actions" menu on feed items, as well as other menus inside cards. A card
  stops clipping while a menu inside it is open.
- **The hourly cleanup job no longer stops partway.** Refreshing a stale link
  preview crashed when the fetch timed out, which skipped every later step of
  that run: the data export and account move sweeps, the orphan preview and
  media cache purges, and notification cleanup. The failure is now recorded
  on the preview, and each cleanup step runs on its own, so one failure is
  logged and the rest still run.

## [1.19.0] — 2026-09-14

Members can protect themselves without asking staff: blocking now actually
stops interaction, and remote accounts, feed posts and received messages can
be muted, blocked or reported where they appear (Phase 1A).

**Upgrading:**

- One migration: `reports.feed_item_id`, `reports.message_id` and
  `reports.message_body`.
- Blocks created before this release (there was no control for them, so
  normally none exist) are not revisited: their follows stay until the block is
  removed and made again. New interactions between the accounts are refused
  from now on.

### Added

- **Block and unblock users from their profile** ("More actions" menu). While
  blocked, Follow and Message are hidden.
- **Blocked Accounts list on `/profile`**, with an unblock control per account.
  Remote accounts in the blocked and muted lists show as `@user@domain`.
- **Mute, block and report remote accounts** from the menu of remote feed
  items and remote comments, and from the header of a conversation with a
  remote account.
- **Report feed posts and received direct messages.** A message report keeps a
  copy of that one message for moderators, who never see the rest of the
  conversation; the copy survives the sender deleting the message. The
  moderation queue shows both, and "Send Flag" includes the reported objects.

### Changed

- **A block stops interaction in both directions** ([ADR 0026](doc/adr/0026-blocks-stop-interaction-locally.md)).
  Neither account can reply to, like, boost, forward or follow the other, or
  message it; undoing an earlier like or boost still works. Blocking removes
  follows both ways (`Undo(Follow)` and `Reject(Follow)` for remote accounts).
  A blocked remote account's follow is rejected and its likes, boosts and
  replies on the blocker's posts are dropped. No `Block` activity is sent.
- A duplicate report now means the same exact target: reporting one of an
  account's posts no longer prevents reporting the account.

### Removed

- The unused builders for outbound `Block` / `Undo(Block)` activities. The
  documentation claimed they were sent; they never were.

## [1.18.2] — 2026-09-14

Fixes from a product review: domain blocks, the audit log, reports from other
instances, post visibility, long DM conversations, federated interactions,
comment deletion, backups and more.

**Upgrading:**

- One migration: `reports.reporter_remote_actor_id`. Reports that arrived from
  other instances before this release stored the reporting actor as the
  reported actor; the migration moves them.
- **Backups:** `mix backup` is not part of a release, and on an Ansible install
  it archived an almost empty uploads directory without error. Use
  `bin/baudrate eval 'Baudrate.Release.backup("/var/backups/baudrate")'`
  instead (see "Backup & Restore" in `doc/sysop.md`), replace any cron job
  built from the old guide, and check the new archive's size.
- The composers no longer offer "Followers only" or "Direct" for articles and
  comments. Existing rows are untouched.

### Fixed

- **Domain blocks from the Federation dashboard take effect at once.** The
  instance list and blocklist audit buttons saved the blocklist without
  reloading the cache the federation checks read, so the block was ignored
  until the next settings save or restart.
- **The audit log no longer drops entries.** Pin, lock and every bot action
  used names the log refused. Settings saves (with the domains added to and
  removed from the blocklist and allowlist), End User Agreement edits, push key
  generation, board federation and accept policy changes, removing an article
  from a board, admins editing others' articles, and sent Flags are now
  recorded too.
- **Reports from other instances are recorded correctly.** An inbound `Flag`
  stored its reporter as the reported actor and never recorded the reported
  local account; Flags without a comment were dropped. Duplicates are now
  skipped, Flags naming nothing local are ignored, and each instance may file
  10 per hour.
- **Reports about remote posts can be forwarded.** Reporting a remote article
  or comment records its author, so "Send Flag" is available.
- **"Followers only" and "Direct" no longer promise privacy the site did not
  enforce.** Local articles and comments stayed readable by guests, and a
  "Direct" board post still went to board followers. Local posts now accept
  only Public or Unlisted.
- **Long DM conversations show their newest messages.** Past 100 messages, new
  ones never appeared. Older messages load on request.
- **Replies, likes and boosts reach remote authors.** Interactions with remote
  articles and comments went only to followers, so the author's instance never
  saw them.
- **Comment authors can delete their own comments**, and replies to a deleted
  comment stay visible under a placeholder instead of disappearing.
- **No wrong-theme flash on page load.** The content security policy blocked
  the theme bootstrap script; it is now allowed by its hash.
- **Activity and follow ids stay unique across restarts.** They ended in a
  counter that restarts with the VM, so an id could repeat: a new activity
  could be skipped as a duplicate delivery, and a new follow or feed reply
  could collide with an existing one and fail.
- **Old notifications are purged.** Notifications older than 90 days are now
  deleted hourly.

## [1.18.1] — 2026-09-14

Fixes for moved accounts and admin sudo mode, plus a rate limit on data export
downloads.

**Upgrading:**

- No migrations, no configuration changes.

### Fixed

- **Admin verification returns to the page you asked for.** Opening an admin
  page (e.g. `/admin/bots`) in a new page load while sudo mode had expired
  always landed on `/admin/settings` after verifying. It now returns to the
  requested page, including its query string.
- **Moved accounts no longer see controls that only fail.** Like and boost
  show the count (a toggle stays only to undo an existing like or boost),
  polls show results instead of the vote form, and forward and reply are
  hidden on articles, boards, feeds and comments.

### Security

- **Data export downloads are rate limited per IP**: 10 per 15 minutes on
  `POST /exports/:id/download`, checked before any session or database work.

### Changed

- Registration, password reset and setup use the shared password requirements
  component.

## [1.18.0] — 2026-09-14

Account migration with ActivityPub `Move`, and a fix for federation
deliveries that were silently dropped.

**Upgrading:**

- **Three migrations** run on deploy: `users.also_known_as`, `moved_to` and
  `moved_at` plus `remote_actors.moved_to_ap_id` and `moved_at`; the
  `account_moves` table; and `delivery_jobs.activity_id`, backfilled from
  queued jobs, with a new dedup index.
- No configuration or nginx changes.
- Users who follow a remote account that moves now send a real `Follow` to
  the new account. Its posts appear once that account accepts.

### Added

- **Account migration** at `/profile/move` (ADR 0025):
  - **Aliases** (`alsoKnownAs`), entered as `@user@domain` or an `https://`
    URI, behind password and TOTP confirmation, with a notice for every
    change. They are published on the actor document.
  - **Moving to another server** needs TOTP enabled for 7 days, no admin,
    moderator or board moderator role, and a destination that already lists
    this account as an alias. The `Move` is sent 24 hours after the request,
    after checking everything again. Until then every page shows a warning
    banner with Cancel. A password change, TOTP reset, sign out everywhere or
    a ban cancels it. One move per 30 days.
  - **After a move:** remote followers get the `Move`, and local followers
    are moved to the new account for them and notified. The old account
    stays able to sign in, read, follow and export, but cannot post,
    comment, send DMs, like, boost, vote or create invites; this is enforced
    in the application core, not only hidden in pages. Its profile points to
    the new account. "Remove redirect" restores posting; followers who
    already moved stay moved.
- **Notices** for alias changes, move requests, cancellations, failures,
  completed moves and removed redirects, which cannot be turned off, plus
  "moved to a new account" for followers and a notice for admins when a
  remote account followed by boards moves.

### Fixed

- **Federation deliveries were silently dropped.** Pending delivery jobs
  were deduplicated by inbox and sender only. While one job for an inbox was
  waiting or retrying, later activities from the same account to that inbox
  were discarded, for example a boost right after a like, two quick posts in
  a federated board, or everything sent to a server while it was down. Jobs
  are now deduplicated per activity.
- **Following an account that moved stopped delivering its posts.** An
  inbound `Move` switched local follows to the new account without sending
  it a `Follow`, so it never delivered anything. Followers now unfollow the
  old account and send a real `Follow` to the new one. A `Move` must name
  the signer as its object, a destination that has itself moved is ignored,
  at most one `Move` per remote account is processed every 30 days, and
  board follows are never switched automatically.

## [1.17.0] — 2026-09-14

Users can export their own data, change their password and sign out
everywhere else. TOTP codes are now single-use and tolerate a code rolling
over while it is typed.

**Upgrading:**

- **Four migrations** run on deploy: `users.totp_enabled_at` (existing TOTP
  users are stamped with the migration time), `articles.deleted_by_id`,
  the `export_requests` table, and `users.totp_last_used_step` plus
  `login_attempts.factor`. None rewrites existing rows beyond that stamp.
- **Re-run the nginx role** (`setup-server.yml --tags nginx`), or add the
  `location /exports/` block from `doc/examples/nginx.conf.example` by hand.
  Without it nginx may buffer export archives to disk. The deploy playbook
  does not update nginx.
- Self-service export needs TOTP enabled for at least 7 days, so users who
  already have TOTP can export 7 days after the upgrade.
- Each TOTP code now works once. Signing in on two devices, or confirming two
  actions, within the same 30 seconds needs two codes. Every code field says
  so.

### Added

- **Data export** at `/profile/export` (ADR 0023). It is designed against
  leakage first:
  - It needs TOTP enabled for at least 7 days, and the password plus a TOTP
    code both to request and to download.
  - A request can be downloaded 24 hours later, for 48 hours, at most 3 times.
    At most 2 requests per 7 days.
  - While a request is waiting or ready, every page shows a warning banner
    naming the requesting browser, with "Cancel" and "Cancel and sign out
    everywhere else". A password change, TOTP reset, sign out everywhere or
    ban cancels it. Every step sends a notice that cannot be turned off.
  - No archive is ever stored: the ZIP is built at download time into a
    private temporary file and deleted after sending.
  - It contains only what the user wrote and can still see, from explicit
    field lists. DMs contain only the user's own messages. Content removed by
    moderators and content in boards the user lost access to are excluded.
  - Downloads accept only a same-origin page navigation with a 60-second
    single-use token bound to the session. Every other failure is the same
    404.
  - A canary test fails the build if any secret column or other people's data
    appears in an archive.
- **SysOp export** for banned users or accounts without TOTP:
  `bin/baudrate eval "Baudrate.Release.export_user_data(...)"`. It requires an
  operator and a reason, writes a `0600` file to an owner-only directory
  outside the web roots, is audited, and notifies the user. `doc/sysop.md`
  describes identity verification.
- **`/admin/data-exports`:** a read-only, admin-only history of export
  requests. There is no way to export another user's data from the web UI.
- **Change password** at `/profile/password`, behind password plus TOTP. It
  signs out every other session and sends a `password_changed` notice.
- **Sign out everywhere else** from `/profile` → Sessions, behind the same
  check, with a `signed_out_everywhere` notice.
- **A `totp_login_failed` notice** when the correct password is entered but the
  TOTP code fails 3 times within an hour at login, pointing the user to change
  their password.
- **`/admin/login-attempts` shows what each attempt was for:** password,
  two-factor code, or re-authentication. Failed two-factor codes follow a
  correct password.

### Changed

- **TOTP accepts the previous 30-second period too**, so a code that rolls
  over while the user types it still works (ADR 0024). Codes from a device
  clock running ahead are still refused.
- The password policy messages ("must contain a digit", ...) are now
  translated.

### Security

- **TOTP replay protection never worked.** The login step checked a session
  key that was never set, so login, admin sudo and step-up re-authentication
  all accepted an already used code again for the rest of its 30 seconds.
  Codes are now consumed per account with one conditional update, which also
  holds under concurrent requests.
- **Failed TOTP codes at login were not limited per account.** Anyone with the
  password was bounded only per IP and per resettable cookie. They now count
  toward the per-account login throttle.
- **Revoking a session did not close its open pages.** Logout, bans, password
  resets, eviction and expiry deleted the session row, but an already-open
  LiveView page (including a banned user's) kept acting until it reconnected.
  Every revocation now disconnects the session's sockets.
- `token`, `code` and `secret` parameters are now redacted from logs along
  with `password`.

### Documentation

- HTTP Signatures accept a `Date` header within ±300 seconds; the SysOp guide,
  troubleshooting guide and API reference said ±30.
- The SysOp guide claimed ±30 seconds of TOTP clock-skew tolerance, which was
  never true. It now describes the actual window.

## [1.16.0] — 2026-09-14

Users are now told whenever their second factors change, plus fixes to
notification preferences and push notifications.

**Upgrading:**

- No migrations, no configuration changes.
- Users start receiving account security notices for second-factor changes
  made after the upgrade. They cannot be turned off.
- Push notification titles are now localized, and some wording changed to
  match the in-app notification list (e.g. "forwarded your article" instead
  of "shared your article").

### Added

- **Account security notices.** A user is notified when a security key is
  added to or removed from their account (with the key's label), and when
  TOTP two-factor authentication is set up or turned off.
  - The notices are sent from the functions that make the change, so no path
    can skip them.
  - They are always delivered, in-app and by push, whatever the notification
    preferences say.
  - Each notice links to `/profile` and says what to do if the user did not
    make the change.
  - This lets someone notice a change they did not make (see ADR 0022).

### Fixed

- **Some notification preferences could not be switched off.** Turning off
  "liked your comment", "boosted your article" or "boosted your comment" on
  `/profile` failed with "Failed to update notification preferences." The page
  and the validation now share one list of notification types.
- **Push notification icons never loaded.** They pointed at an avatar path
  that does not exist; they now use the stored 120 px avatar.
- **Push notification titles were English-only, and some types had no
  title.** Comment likes and boosts showed "New notification". Titles now use
  the same translated text as the in-app notification list, in the
  recipient's preferred language.

### Documentation

- **The Ansible README explains rollback after an old Erlang/Elixir version
  is uninstalled.** Re-deploying such a tag needs that version reinstalled.
  The immediate alternative is to repoint the `current` and `static` symlinks
  at a kept release and restart.

## [1.15.0] — 2026-09-14

Real client IPs behind a same-host reverse proxy, and version information in
the admin panel.

**Upgrading:**

- **Per-IP rate limits and IP logging now see real client addresses** on the
  default deployment (Nginx on the same host). Before this release every
  request was attributed to the proxy, so all visitors shared one bucket for
  the login, TOTP, password-reset, search and LiveView-mount limits. That
  meant one abusive client could lock everyone out. After upgrading, `ip=`
  fields in the log should show real addresses instead of `::ffff:127.0.0.1`.
- IP addresses recorded before the upgrade (login attempts, sessions, log
  lines) remain the proxy's and cannot be recovered.
- No migrations, no configuration changes.

### Added

- **System Information on `/admin/settings`:** the running Baudrate version
  plus the Elixir, Erlang/OTP and ERTS versions, read from the running node.

### Security

- **The reverse proxy was never trusted on a dual-stack bind.** The production
  endpoint listens on the IPv6 any-address, so Nginx connecting from
  `127.0.0.1` arrived as the IPv4-mapped `::ffff:127.0.0.1`. That never
  matched the `127.0.0.1` trusted-proxy entry, so `X-Forwarded-For` was
  ignored, over plain HTTP and LiveView sockets alike.
  - IPv4-mapped addresses are now unmapped before trust matching and before
    they are stored.
  - Only the `::ffff:0:0/96` prefix is unmapped. NAT64 and 6to4 addresses are
    different hosts and stay untrusted.
  - The LiveView path now resolves client IPs through the same function as the
    plug, and no longer uses an unparseable header value verbatim.

## [1.14.4] — 2026-09-14

A security release. **All instances should upgrade.** A stolen admin session
cookie could get past admin sudo mode without the admin's password or second
factor.

**Upgrading:**

- **Managing security keys now asks for your password first** (plus the
  current TOTP code if TOTP is enabled). On `/profile`, confirming unlocks
  "Register New Key" and "Remove" for 5 minutes.
- **After upgrading, review the security keys registered on admin accounts**
  (`/profile` → Security Keys, or the `webauthn_credentials` table). Look for
  keys you don't recognise, and check the logs for
  `auth.webauthn_register_success` lines for admin users. Remove any unknown
  key and reset that admin's password and TOTP.
- The Ansible systemd unit no longer uses `ExecStop`. It is installed with the
  next deploy, and that deploy's restart already uses it.
- No migrations, no configuration changes.

### Security

- **Admin sudo mode could be bypassed with a stolen session.** Registering a
  WebAuthn security key required only a logged-in session, and sudo mode
  accepts any key registered on the account. Someone holding an admin's
  session cookie could enrol their own key and use it to pass `/admin/verify`,
  and could also remove the admin's real keys.
  - Registering or removing a key now requires step-up re-authentication.
  - WebAuthn challenges are bound to their purpose, so a sudo-verification
    challenge can no longer be used to register a key.
  - See ADR 0022.
- **The TOTP reset page did not throttle password guesses durably.** Its
  lockout reset on page reload, and failures were not counted against the
  account. A stolen session could use it to guess the account password
  without hitting the login throttle. Re-authentication failures now feed the
  per-account login throttle, behind a per-user rate limit shared by every
  re-authentication form. Recovery codes are never accepted for
  re-authentication.

### Fixed

- **Deleting a security key with a malformed id crashed the profile page.**
  The id is now parsed safely.
- **The service stop command failed after every deploy.** `ExecStop` ran
  `bin/baudrate stop` through the already-swapped `current` symlink. Each
  release build has its own cookie, so the old node rejected the connection
  and systemd fell back to SIGTERM, logging "Invalid challenge reply" on every
  deploy. The unit now relies on SIGTERM directly, which the VM turns into
  the same orderly shutdown.

## [1.14.3] — 2026-09-14

A deployment fix. After an Erlang/OTP or Elixir version bump, the Ansible
deploy role now rebuilds from scratch on its own.

**Upgrading:**

- Upgrading from v1.14.1 or earlier: install OTP 28.5.0.6 first with
  `ansible-playbook playbooks/setup-server.yml --tags elixir`, then deploy
  v1.14.3. You no longer need to delete `_build/prod` by hand.
- The first deploy with this version always does one full rebuild, because
  no toolchain stamp exists yet.
- No migrations, no configuration changes.

### Fixed

- **Deploys reused build artifacts from the previous toolchain.** The deploy
  role only removed `_build/prod/rel`, so after a `.tool-versions` bump a
  release could include dependency BEAM files and Rust NIFs compiled by the
  old Erlang/Elixir. The role now records `.tool-versions` in
  `_build/prod/.tool-versions.stamp` after each successful compile. When the
  deployed tag pins a different toolchain, or no stamp exists, it wipes
  `_build/prod` before building. Builds on an unchanged toolchain stay
  incremental.

## [1.14.2] — 2026-09-14

A maintenance release. It updates the runtime and vendored front-end
dependencies flagged by the weekly dependency drift report.

**Upgrading:**

- **Erlang/OTP 28.5.0.6 is now the pinned runtime.** Install it (e.g.
  `asdf install` from `.tool-versions`) and rebuild from a clean `_build`,
  because compiled BEAM files and Rust NIFs are tied to the OTP build. The
  Ansible `erlang_version` has been bumped to match, so re-run the `elixir`
  role on deployment hosts.
- No migrations, no configuration changes.

### Changed

- **Erlang/OTP 28.3.1 → 28.5.0.6.** Same-major maintenance and security
  patches. OTP 29 and Elixir 1.20 are deliberately held for a separate review.
- **topbar 3.0.0 → 3.0.1.** The page-loading bar hides with the `hidden`
  attribute and is marked `role="presentation"`, so assistive technology
  ignores it.
- **Cropper.js 1.6.2 → 1.6.3** (avatar cropping). Fixes unanchored
  action/tag-name regexes, guards event listener helpers against invalid
  targets, and prevents `NaN` in zoom-ratio calculations. Cropper.js 2.x is a
  rewrite and is held.
- **Development workflow.** All development now happens on the `current`
  branch. `main` only advances by fast-forward when a release is cut. CI now
  runs on `current` as well as `main`, and Dependabot version-update PRs target
  `current`.

## [1.14.1] — 2026-09-13

An accessibility release: a project-wide WCAG 2.2 AA / WAI-ARIA sweep of the
web layer fixing every critical and nearly every major finding — keyboard
barriers, unlabelled fields, silent or over-verbose live updates, theme
contrast and focus visibility — plus CI and dependency-monitoring fixes.

**Upgrading:**

- **Admin → Users role changes now need an explicit Save.** The per-user role
  dropdown no longer applies on change; this prevents keyboard users from
  changing a role on every arrow-key press.
- The Mac OS X (Aqua) themes use slightly darker accent, info, success, error
  and primary-button colours (and lighter primary/error in the dark theme) to
  meet AA contrast.
- No migrations, no configuration changes.

### Fixed

- **Keyboard access** — comment and article image uploads were unreachable by
  keyboard (`display:none` file inputs); they now use focusable `sr-only`
  inputs with a visible focus ring. Image remove buttons, the scroll-to-top
  button and dropdown menus are visible and operable on focus, and Escape
  closes dropdowns and returns focus to their trigger.
- **Accessible names** — Markdown composers no longer wrap the toolbar and
  preview in the textarea's `<label>` (screen readers read the toolbar as the
  field name); the comment reply box and the profile display name, bio and
  signature fields now have real labels. Repeated row actions (Ban, Delete,
  Revoke, …) name their subject, and buttons no longer carry `aria-label`s
  that contradict their visible text.
- **DM composer** — the compose form's id changed with every message, so an
  incoming message wiped in-progress text and dropped focus. The id is now
  stable.
- **Admin role select** — saved on every change event (see Upgrading).
- **Focus management** — focus moves to the section heading after destructive
  admin actions (ban, delete, revoke, resolve, dismiss, abandon) and to each
  setup wizard step, instead of falling to `<body>`.
- **Live updates** — new comments, feed items, notifications and DMs are
  announced as short status summaries; the comment tree, feed and admin table
  bodies are no longer live regions that re-read everything on each update.
  Draft autosave, copy-to-clipboard and Markdown preview now announce their
  results, and the DM list no longer jumps to the bottom while reading history.
- **State and structure** — like, boost, bookmark and admin filter toggles
  expose `aria-pressed`; admin filters no longer claim an unimplemented tab
  pattern; board, forward and recipient pickers are plain labelled result
  lists with an announced count; the hashtag/emoji autocomplete uses valid
  textbox ARIA with an announced suggestion count; polls use a fieldset and
  announce your vote; comments, recovery codes and setup steps have list
  semantics; headings on the profile, poll and setup pages are correctly
  nested.
- **Colour and contrast** — Aqua light and dark themes meet 4.5:1 for buttons,
  alerts, badges and error text; the default dark theme was missing from the
  `dark:` variant; the link focus ring is 2px, ≥3:1 in every theme and visible
  under Windows forced-colors; unread, muted, diff and selected-revision states
  no longer rely on colour alone; `prefers-reduced-motion` is honoured.
- **Page titles** — 404 and 500 pages now have localized titles; unread counts
  are included in the navigation link names.
- **CI Cargo cache** — keyed on and caching all three Rust NIF crates instead
  of only `baudrate_sanitizer`.

### Added

- **Dependency drift workflow** (`.github/workflows/dependency-drift.yml`) —
  weekly check of pins Dependabot cannot read (esbuild/Tailwind binary
  versions, vendored daisyUI/topbar/Cropper.js, `.tool-versions`) plus
  `mix hex.audit`, reported in one rolling issue.
- zh_TW and ja_JP translations for all new accessible names and announcements.

### Changed

- GitHub Actions bumped: `actions/checkout` 4 → 7, `actions/cache` 3 → 6;
  Dependabot PRs are assigned to the maintainer.
- Documented the focus, live-region and ARIA conventions in
  `doc/development.md` and `CLAUDE.md`; added the `a11y-engineering` skill.

## [1.14.0] — 2026-09-13

A security release closing the findings of a project-wide audit — eleven fixes
across the federation trust boundary, outbound HTTP, content authorization and
admin authentication — plus a dark companion to the Mac OS X (Aqua) theme,
which becomes the default theme pair, and a sweep of dependency updates that
clears every open `mix hex.audit` advisory.

**Upgrading:**

- **The default theme changes.** Theme choices are stored only when an admin
  saves *Admin → Settings*. An instance whose admin has never saved that page
  will switch to the Mac OS X (Aqua) themes after upgrading. To keep the
  previous look, select "Light" and "Dark" there and save.
- **Followers-only and direct remote content is now hidden from public
  pages.** Existing rows are kept, only their display changes. A peer that
  sends replies without any `to`/`cc` addressing will see them hidden, as the
  ActivityPub spec treats unaddressed objects as non-public.
- **New optional config key** `http_request_timeout` (default 60 000 ms) under
  `config :baudrate, Baudrate.Federation` bounds every outbound request.
- No migrations.

### Added

- **Mac OS X (Aqua) Dark theme** — a dark-scheme sibling of the Mac OS X (Aqua)
  light theme (`aquaosxdark`, labelled "Mac OS X (Aqua) Dark"), selectable under
  *Admin → Settings → Theme (dark)*. Same glossy-gel buttons, Aqua-blue default
  button and focus glow, hairline windows and blue-gel scrollbars, on graphite
  windows with dark input wells. Lives in `assets/css/themes/aquaosx-dark.css`,
  mirroring `aquaosx.css` rule for rule.

### Security

- **Federated objects and activities are bound to their sender's origin.** An
  activity `id` must share the actor's host, and a `Create`/`Update` object `id`
  must share the signer's host. Previously any instance could publish content
  under another instance's URIs, squatting them so the genuine post was later
  dropped as a duplicate. User-triggered remote import applies the same rules
  to the fetched document and its author.
- **`Accept`/`Reject(Follow)` only affect follows addressed to the signer.**
  Any verified remote actor could accept or reject another user's follow of a
  third party by naming its (non-secret) follow id.
- **Announce can no longer pull private or foreign articles into public
  boards.** An embedded Announce naming one of this instance's article URIs is
  refused, and an existing article is linked into the booster's following
  boards only when it belongs to the announced author.
- **Followers-only and direct remote content is kept off public surfaces.**
  Such replies and articles were shown on article pages, in board-less article
  pages, and re-served as public ActivityPub objects. They are now excluded
  from those surfaces. The addressing parser also recognizes the compact
  `as:Public` / `Public` forms and no longer crashes on non-string entries.
- **Outbound HTTP bodies are capped while streaming and requests have a total
  deadline.** The federation HTTP client checked the body size only after Req
  had buffered the whole response, so a remote actor, feed, link-preview
  target or media URL could make the instance allocate a multi-gigabyte body
  per fetch; POST responses (inbox deliveries, Web Push) had no cap at all.
  A streaming collector now halts the connection as soon as the received
  bytes or a declared `content-length` exceed the cap, on GET and POST alike.
  A whole-request `request_timeout` (60 s, `http_request_timeout`) joins the
  per-read `receive_timeout`, so a server trickling one byte every 29 seconds
  can no longer hold a delivery job or media request open indefinitely.
- **Article and comment changesets no longer cast server-owned fields.** Any
  authenticated user could submit `ap_id`, `url` or `published_at` with a new
  article (and `ap_id`/`parent_id` with a comment) — pre-squatting a remote
  object's URI so the genuine post is later dropped as a duplicate and the
  local one is served in its place, planting an arbitrary "View original"
  link, backdating a post, or threading a comment under (and notifying the
  author of) a comment in a board they cannot see. User changesets are now
  allow-lists, bots use `Content.create_article/3` with `trusted: true`, and
  the LiveViews set `parent_id` only from the server-side reply target.
- **Remote object `url` must be https.** A federated Note/Article whose `url`
  was `javascript:` or `data:` was stored verbatim and rendered as the "View
  original" href, held back only by CSP. Non-https values are dropped at
  ingest with a changeset backstop.
- **User profile pages and the personal feed no longer leak private-board
  content.** `/users/:name`, `/users/:name/articles|comments` and the
  followed-user section of `/feed` listed article titles, board names and
  comment bodies from boards the viewer (including guests) cannot open. All
  user-page listings now take the viewer and apply the board view gate; the
  feed applies it to followed users' local articles.
- **Admin sudo lockout is now per user and survives a discarded cookie.** The
  5-attempt lockout on `/auth/admin-totp-verify` and `/auth/admin-webauthn-verify`
  lived only in the session cookie and was cleared on lockout, so the next POST
  started again at zero. Anyone holding a hijacked admin session could
  brute-force the 6-digit TOTP bounded only by the per-IP limit. A per-user
  `admin_sudo:<id>` bucket (5 attempts / 15 min) is now hit before the code is
  checked; the cookie counter remains as defense in depth.
- **WebAuthn cloned-authenticator detection.** The signature counter returned
  by the authenticator was stored but never compared, so a cloned security key
  would authenticate indefinitely. Assertions whose counter does not advance
  past the stored value are now refused with `:sign_count_regressed` and
  logged as `auth.webauthn_clone_suspected`; authenticators that never
  implement a counter (both sides `0`) are exempt, as the spec allows.

### Changed

- **Mac OS X (Aqua) is now the default theme pair** — a fresh instance renders
  `aquaosx` in light mode and `aquaosxdark` in dark mode. The former defaults
  ("Light" and "Dark") remain selectable under *Admin → Settings → Theme*, and
  instances that already saved a theme choice are unaffected.
- **Dependencies** — bandit 1.12.5, mint 1.10.0, phoenix 1.8.13,
  phoenix_live_view 1.2.11, phoenix_pubsub 2.3.0 (clears five `mix hex.audit`
  advisories: two HTTP/2 DoS issues in Bandit, two HTTP/1 parsing DoS issues in
  Mint, and a low-severity open redirect in LiveView's local-URL check); req
  0.7.4, hammer 7.5.0, telemetry_metrics 1.2.0, ecto 3.14.2; dns_cluster 0.3.0
  and phoenix_live_dashboard 0.9.1 (constraints raised); feedparser-rs crate
  0.7.0 (the crate's new built-in HTML sanitizer is disabled so Ammonia stays the
  single sanitizer of record); vendored daisyUI 5.7.37.

### Fixed

- **Flaky media cache test under parallel partitions** — the media cache
  directory is now configurable (`media_cache_dir`) and the test config gives
  each `MIX_TEST_PARTITION` its own, so one partition's cache-wiping setup can no
  longer delete a file another partition had just warmed.

## [1.13.0] — 2026-08-09

A hardening release closing the findings of a project-wide audit: four fixes on
the federation-ingest and authorization boundaries, plus a data-loss fix in
inbound account migration. Also backfills the Architecture Decision Records, so
the load-bearing constraints now carry their rationale.

**Upgrading:** no action required. One behaviour change is visible only in
unusual network topologies — the SSRF deny-list now refuses hosts that resolve
into the IPv4 benchmarking range (`198.18.0.0/15`), the IETF/TEST-NET ranges, or
through a 6to4 or Teredo tunnel. No legitimate fediverse peer lives there, but a
lab or test instance addressed that way will stop federating.

### Added

- **Bookmark comments from the thread** — comment bookmarking existed in the
  context and rendered on `/bookmarks`, but no UI could create one. Each comment
  now carries a bookmark toggle in its action row.
- **Architecture Decision Records** in [`doc/adr/`](doc/adr/README.md) — 22
  records reconstructing the decisions already embodied in the code as of
  v1.12.0 (federation gate, media proxy, fail-closed proxy trust,
  context-boundary authorization, and so on), each with the alternatives that
  were rejected and the consequences we now live with. `README.md`,
  `CLAUDE.md`, and `doc/development.md` link into the index, and the
  `docs-engineering` skill now audits them.

### Changed

- esbuild 0.28.1 → 0.28.2, vendored daisyUI → 5.7.16, and `regex` 1.12.3 →
  1.13.1 in the sanitizer crate. The daisyUI bump changes three component rules
  (`.input`/`.select` focus isolation, `.sr-only` cascade position,
  `.menu-horizontal` alignment) and no theme variables, so the `light`, `dark`,
  and `aquaosx` palettes are unchanged.

### Fixed

- **An inbound `Move` no longer erases the moved actor's feed history.** Feed
  membership is a query-time join on `user_follows`, and the Move handler
  migrated the follow but left `feed_items` pointing at the old actor — so every
  item that actor had already published vanished from its followers' feeds and
  failed `feed_item_accessible?/2`, becoming impossible to like, boost, reply
  to, or forward. `Federation.migrate_feed_items/2` now repoints both
  `remote_actor_id` and `boosted_by_actor_id` alongside the follow. Articles and
  comments deliberately keep their original attribution.
- **Long CJK titles no longer drop inbound articles.**
  `Content.TitleDeriver.truncate_title/2` appended its ellipsis *on top of*
  `max_len`, so a 255-grapheme CJK title became 256 characters and failed the
  `:title` length validation — silently discarding the federated object.
  `max_len` is now a hard ceiling.
- LiveView forms with `phx-change` but no `id` (article/comment/feed
  forward-to-board search, feed reply, both setup wizard steps) could not
  perform form recovery after a reconnect. All now carry stable, semantic ids.
- `/articles/:slug/history` gained the `data-focus-target` marker so keyboard
  and screen-reader users land on the revision list after navigation.
- `BaudrateWeb.Plugs.ArticleApContentNeg` documented that its two-segment path
  match kept `/articles/new` from being content-negotiated, but that path *is*
  two segments — only router scope order was keeping it away from the plug. The
  guarantee is now local to the plug (`@reserved_slugs`) rather than dependent
  on a declaration order in another file. No behaviour change in the assembled
  router.
- `doc/api.md` omitted the signed media proxy from its list of first-party
  endpoints outside the AP surface, and the setup prerequisites in `README.md`
  and `CLAUDE.md` named only two of the three Rust NIFs a build actually
  compiles.
- The media proxy cache directory (`priv/static/uploads/media_cache/`, added in
  v1.12.0) was not gitignored, so running a dev server left untracked files.

### Security

- **Remote `preferredUsername` is now sanitized.** The username is the actor's
  identity anchor — the UI renders it as `@username@domain` and falls back to it
  as the display name when the actor publishes no `name` — but it was stored
  verbatim from the actor document. A hostile instance could embed Unicode
  bidirectional overrides to make one handle render as another's, or park an
  unbounded string in the column. `Federation.Sanitizer.sanitize_username/1`
  strips tags, control characters, and bidi overrides, and truncates to 64
  characters; `ActorResolver` falls back to deriving the handle from the actor
  `id` when nothing survives.
- Display-name sanitization now also strips Unicode bidirectional overrides and
  zero-width spaces (U+200B/FEFF), which the previous C0/C1 control-character
  pass let through. Zero-width joiners are deliberately preserved — they are
  load-bearing in emoji sequences and in Indic and Persian scripts.
- **Bounded the remaining unbounded remote strings.** A feed item's `title` is
  the remote object's `name` verbatim and, unlike `content`, never passes
  through `Validator.validate_content_size/1` — a remote actor could store a
  payload-sized string and have it rendered on every follower's `/feed`. Titles
  are now truncated at ingest with a 255-character `validate_length` backstop on
  `Federation.FeedItem`. Remote actor profile-field values are capped at 1000
  characters and `alsoKnownAs` at 20 entries.
- **Widened the SSRF deny-list.** `HTTPClient.private_ip?/1` decoded the embedded
  IPv4 of IPv4-mapped, NAT64, and IPv4-compatible addresses but not of 6to4
  (`2002::/16`), so `2002:7f00:1::` could reach `127.0.0.1` through a 6to4 relay.
  6to4 now decodes and re-checks like the others, and Teredo (`2001::/32`) —
  which obfuscates its embedded address rather than carrying it plainly — is
  refused outright. Also added the non-routable IPv4 special-purpose ranges
  (`192.0.0.0/24`, `192.0.2.0/24`, `198.18.0.0/15`, `198.51.100.0/24`,
  `203.0.113.0/24`) and the IPv6 documentation and discard prefixes
  (`2001:db8::/32`, `100::/64`).
- **Bookmarking is authorized at the context boundary.**
  `Content.toggle_article_bookmark/2` and `toggle_comment_bookmark/2` take a
  client-supplied ID and now require the target to exist, not be soft-deleted,
  and be visible to the user. Without the check a user could bookmark a guessed
  ID in a board they cannot view and read its title and body excerpt back off
  `/bookmarks`. Removing an existing bookmark is always permitted, so raising a
  board's `min_role_to_view` cannot strand a row on someone's list.

## [1.12.0] — 2026-08-08

A security-hardening release closing every finding from a project-wide audit,
plus a new media proxy that stops federated content from disclosing visitors'
IP addresses to remote instances.

**Upgrading:** no action is required for a set-up instance behind a loopback
reverse proxy. Two changes are visible: peers using RSA keys below 2048 bits
will stop federating (see Security), and a reverse proxy that does *not* run on
the same host now needs `BAUDRATE_TRUSTED_PROXIES` set.

### Added

- **Media proxy** — remote images are served from a locally re-encoded WebP copy
  via a signed `/media/:sig/:encoded` route (`Baudrate.Media.Proxy`,
  `BaudrateWeb.MediaController`) instead of being hotlinked. Fetches go through
  the SSRF-guarded `Federation.HTTPClient`, are magic-byte validated, and are
  re-encoded with libvips; SVG is never served. Failures fall back to a
  same-origin placeholder and are negative-cached for an hour. The cache lives
  at `uploads/media_cache/`, is bounded by a 30-day TTL and a 2 GB ceiling
  evicted by `SessionCleaner`, and is safe to delete at any time.
- **`BAUDRATE_TRUSTED_PROXIES` and `BAUDRATE_REAL_IP_HEADER`** — runtime
  configuration for reverse proxies that do not run on the application host.
  Both were referenced in comments but had never been implemented, leaving
  operators with a non-loopback proxy no way to widen trust without rebuilding.

### Security

- **Setup wizard installation-key bypass (critical)** — `SetupLive`'s
  `complete_setup` event had no server-side check that the `INSTALLATION_KEY`
  step had been passed; the gate existed only in which step was *rendered*. A
  LiveView client can push any event regardless of the displayed step, so any
  visitor reaching a freshly deployed instance could claim the admin account
  without ever knowing the key. The handler now requires a verified key, and
  `Setup.complete_setup/2` refuses to run once setup is complete.
- **`INSTALLATION_KEY` is now required until setup completes** — in production,
  an instance with an incomplete setup and no configured key answers 503 on all
  browser routes rather than serving an unguarded wizard. Enforcement is in
  `EnsureSetup` and `SetupLive.mount/3`, not a boot-time `raise`, so a transient
  database outage cannot brick a restart. Removing the key after setup remains
  supported.
- **Inbound replies and poll votes now honour the federation gate** — `Like` and
  `Announce` checked `article_federated?/1` but `Create(Note)` replies and
  Mastodon-style poll-vote Notes did not, so a remote actor could guess a slug
  and inject a comment (plus an author notification) or a vote into an article
  living only in a private or AP-disabled board. Federated poll votes are also
  now refused after `closes_at`, matching the local `cast_vote/3` path.
- **No third-party image hotlinking** — previously, viewing federated content
  disclosed each visitor's IP address, User-Agent, and reading times to every
  remote instance whose content appeared on the page. Five separate paths
  emitted third-party `<img>`: user Markdown, RSS/bot article bodies, AP
  attachment images, feed-item attachments, and remote actor avatars. All now
  route through the media proxy.
- **Minimum RSA key size on inbound actor keys** — remote actor public keys must
  be RSA ≥ 2048 bits, enforced both at `ActorResolver` ingest and at signature
  verification (so keys cached before this change are rejected too). A short
  modulus makes an instance's signatures forgeable by a third party, who could
  then impersonate that actor to this instance. Non-RSA keys are rejected
  explicitly. **A remote instance still using a 1024-bit key will stop
  federating until it rotates** — see `doc/troubleshooting.md`.
- **`RealIp` fails closed** — an unconfigured `trusted_proxies` no longer means
  "trust every peer", and `[]` no longer means the opposite of what it says; the
  default is now loopback only. Previously, wherever a header was configured but
  the allow-list was not, any client could spoof `x-forwarded-for` and defeat
  every per-IP rate limit (login, TOTP, AP inbox, feeds, search) while poisoning
  the persisted `ip_address` audit trail.
- **Reply-chain amplification bounded** — a fabricated `inReplyTo` could drive up
  to 10 outbound fetches per inbound activity, roughly 600/min per hostile
  domain against a target of the attacker's choosing. Now capped at 5 hops
  across at most 3 distinct hosts, with a visited-URI cycle guard and rate
  limits keyed on both the target host (10/min, so many hostile domains cannot
  combine against one victim) and the sending domain (20/min).
- **Protocol-relative image sources are stripped** — the Ammonia markdown
  allowlist now constrains `img[src]`. `url_relative(PassThrough)` treated
  `<img src="//evil.example/x.png">` as *relative*, so it survived scheme-based
  filtering and would still have hotlinked under the tightened CSP.
- **`postgrex` 0.22.3 → 0.22.4** — EEF-CVE-2026-66838 / GHSA-3gww-3f36-2388,
  SQL injection via the `:comment` option in `Postgrex.stream/4`. Not reachable
  from this codebase, but shipped.

### Changed

- CSP `img-src` tightened from `'self' https: data: blob:` to
  `'self' data: blob:`. No page issues a third-party subresource request any
  more, so the `https:` allowance for federated avatars is no longer needed.
- nginx now denies `/uploads/media_cache/` directly, so cached remote images are
  reachable only through the signed `/media/` route.

### Fixed

- `Plug.Crypto.secure_compare/2` is guarded on two binaries, so pushing the
  `verify_key` event with no installation key configured — or with a malformed
  payload — crashed the setup wizard with a `FunctionClauseError`.

## [1.11.0] — 2026-08-03

### Security

- **Forwarding no longer resurrects deleted content** — `forward_article_to_board/3`,
  `forward_comment_to_board/3`, and `forward_feed_item_to_board/3` now return
  `{:error, :not_found}` for a source record with a non-nil `deleted_at`. The
  LiveView handlers resolve the source from a client-supplied ID via a bare
  `Repo.get/2`, which does not filter soft deletes, so a comment removed by a
  moderator or a feed item withdrawn by its remote author via `Delete` could
  previously be republished as a permanent board article — defeating the
  moderation or withdrawal decision.
- **Article forwarding is source-board view-gated** — `forward_article_to_board/3`
  now checks `Interactions.article_visible_to_user?/2` at the context boundary
  instead of relying on its caller passing a mount-time view-gated article. Local
  articles default to `visibility: "public"` regardless of the board's
  `min_role_to_view`, so the visibility check alone did not stop a user from
  guessing an article ID in a private board and republishing it publicly. This
  brings the article path in line with the comment path.
- **Feed-item interactions are reachability-gated** — `feed_items` rows are global
  (feed membership is a query-time JOIN on `user_follows`), so every entry point
  that resolves one from a client-supplied ID must verify reachability.
  `create_feed_item_reply/4` had no check at all and would federate a
  `Create(Note)` to an arbitrary remote actor's inbox; `can_forward_feed_item?/2`
  had none either. Both now go through the shared
  `Federation.feed_item_accessible?/2` predicate.
- **Hex dependencies updated for 12 advisories** — Phoenix 1.8.9
  (CVE-2026-56811 channel-join DoS, CVE-2026-56812), Phoenix LiveView 1.2.8
  (CVE-2026-58228, `<.link>` scheme-validation bypass leading to XSS), Bandit
  1.12.4 (CVE-2026-65623, quadratic CPU blow-up on fragmented WebSocket frames),
  Mint 1.9.3 (CVE-2026-58229, CVE-2026-56810, CVE-2026-59246, CVE-2026-59249),
  hpax 1.0.4 (CVE-2026-58226, HPACK decoding DoS), Plug 1.20.3 (CVE-2026-56814,
  CVE-2026-56813), Postgrex 0.22.3 (CVE-2026-58225). No `mix.exs` constraint
  edits were required — every fix version was already reachable.
- **Ammonia updated to 4.1.4** (RUSTSEC-2026-0213, mutation XSS via SVG `animate`
  and `set` tags) in both the sanitizer and feed-parser NIFs. The advisory appears
  unreachable as configured — `federation_tags/0` is a strict allowlist with no
  `svg`, and `svg`/`math` are in `clean_content_tags/0` — but the closely related
  RUSTSEC-2025-0071 was a bug in that removal path itself, so the version is not
  worth leaning on. Ammonia sits on the federation XSS boundary.

### Changed

- **Replying to or forwarding a feed item now requires following its source
  actor.** Previously any authenticated user could reply to or forward any feed
  item in the database, including from actors they do not follow. This aligns
  those two actions with likes and boosts, which were already scoped this way.
  Admins keep their existing bypass of the follow requirement when forwarding.
- **The 429 rate-limit response is localized** — the HTML branch of
  `Plugs.RateLimit` sent a bare English sentence as a naked `text/html` body. It
  now renders a minimal valid HTML document with a `gettext`-backed title and
  message, a `lang` attribute from the active locale, and semantic `id`/`class`
  hooks; translations are HTML-escaped. `SetLocale` moved ahead of `RateLimit` in
  the `:share_target` pipeline so that route's 429 is localized too. The JSON
  branch keeps the untranslated `"Too Many Requests"` status phrase for remote AP
  instances and the push worker.
- **Tailwind 4.3.3 and daisyUI 5.7.14** (from 4.3.2 / 5.6.10). Verified against
  the full Wallaby/Selenium browser suite; the custom `light`/`dark`/`aquaosx`
  themes are intact.
- Req 0.7.2 (from 0.6.2), image 0.72.0 (from 0.69.0), MDEx 0.13.5, and
  feedparser-rs 0.5.6. Req 0.7 carries breaking changes upstream (the
  `run_finch`/`run_plug` steps became the `Req.Finch`/`Req.Plug` adapter modules,
  `current_request_steps` was removed, GET with a body now converts to POST);
  Baudrate is unaffected, as `HTTPClient` uses only `Req.get/1`, `Req.post/1`, and
  `:connect_options` for DNS pinning.

### Fixed

- **Liking or boosting a boosted feed item silently failed.** The internal
  reachability predicate always matched on `remote_actor_id`, but for an
  `Announce` that field holds the *original author* while feed membership comes
  from `boosted_by_actor_id` (the booster). An item that legitimately appeared in
  a user's feed via a followed booster was rejected as `:not_found` on like and
  boost. `Federation.feed_item_accessible?/2` now mirrors the membership
  conditions of `list_feed_items/2` exactly.

### Removed

- Dead `register` entry from the `Plugs.RateLimit` limit table. No route used it —
  registration and password reset submit over the LiveView channel and check their
  own buckets in `RegisterLive` / `PasswordResetLive`. The moduledoc now documents
  that split instead of implying the plug enforces it.

## [1.10.3] — 2026-07-03

### Changed

- **Notification-preference switches now use a consistent color** — the *Push*
  column toggles in `/profile` were `toggle-secondary` (gray) while the *In-App*
  column was `toggle-primary` (blue); both now use `toggle-primary` so the two
  columns read identically across every theme.
- **Checked toggles in the Mac OS X (Aqua) theme now have a white gel knob** on
  the blue track, like a real macOS switch — previously the knob inherited the
  primary color, leaving a barely-visible blue dot on the blue track.
- **Mac OS X (Aqua) theme extracted to a standalone file** — both the `aquaosx`
  DaisyUI palette registration and the `[data-theme="aquaosx"]` glossy-chrome
  overrides moved out of `assets/css/app.css` into `assets/css/themes/aquaosx.css`,
  imported back near the end of `app.css`. Tailwind v4 inlines local `@import`s in
  place, so the chrome overrides stay late in the cascade exactly as before — the
  compiled stylesheet is byte-for-byte equivalent (verified against a pre-refactor
  build). Purely an organizational change; no visual difference.

## [1.10.2] — 2026-07-03

### Added

- **Semantic `id`/`class` on every meaningful element** — a top-priority
  accessibility initiative so any element in any page template is precisely
  locatable (for assistive tooling, automated testing, and styling). All 43 page
  templates and the shared UI components (`core_components`, `comment_components`,
  layout chrome) now carry stable, page-prefixed kebab-case semantic `id`/`class`
  on region containers, interactive controls, loop-rendered list/table/card items,
  and key content nodes. Loop items derive a dynamic id from their record plus a
  shared class (e.g. `id={"muted-user-#{id}"} class="muted-user"`). Changes are
  purely additive — no existing Tailwind utility, `phx-*`, `aria-*`, `:if`/`:for`,
  or `gettext` binding was altered. The principle and its full convention (naming,
  id-uniqueness, and the rule that custom stylesheet selectors must hook onto the
  semantic id/class rather than fragile structural selectors) are documented in
  `CLAUDE.md` and `doc/development.md`.

### Changed

- **Site name in the navbar and mobile menu renders in Roboto Slab across all
  themes** — a `.site-name` class pins the brand to Roboto Slab even under themes
  (e.g. Aqua) that override `--font-sans` to a different stack, matching how the
  stock daisyUI themes present it.

### Fixed

- **Aqua title bar was gapped from the border on default-padding cards** (e.g. the
  profile heading) — the full-bleed title bar's `-1rem` margin only matched `p-4`
  cards; card bodies carrying a title bar are now normalized to `1rem` padding so
  the bar meets the border flush regardless of the card's utility padding.
- **Aqua badges looked like clickable buttons** — the glossy gel treatment is now
  reserved for interactive controls; badges are flattened (no gradient/inset
  highlight) so they read as status labels.
- **Badge labels could wrap onto multiple lines** — badges now use
  `white-space: nowrap`.

## [1.10.1] — 2026-07-03

### Fixed

- **Flash messages were invisible in the Mac OS X (Aqua) theme** — the theme's
  white-window rule included `.alert`, forcing a white background while daisyUI's
  `.alert-info`/`.alert-error` kept a light content text colour meant for their own
  coloured background, so flash text rendered white-on-white. `.alert` is now
  excluded from that rule and keeps daisyUI's properly-contrasted colouring.

## [1.10.0] — 2026-07-03

This release is a broad dependency-modernization and security pass: every
production security advisory reported by `mix hex.audit` is resolved and the
whole dependency tree (Hex, Rust NIF crates, and the JS/CSS toolchain) is
current, with the full unit and browser test suites green.

### Security

- **Migrated the Markdown renderer from Earmark to MDEx** — Earmark is retired
  (unmaintained) and carried an unpatched stored-XSS advisory (EEF-CVE-2026-48591)
  with no fix in its 1.4.x line. `Content.Markdown.to_html/1` now renders via
  MDEx (comrak, CommonMark + GFM) with `render: [unsafe: true]` so stored/feed
  HTML still passes through to the Ammonia sanitizer — the render-then-sanitize
  security model is unchanged.
- **Updated Req to 0.6.2** — patches a HIGH `form_multipart` header-injection
  advisory (EEF-CVE-2026-49755) and a decompression-bomb DoS. Reviewed against
  the SSRF guard (`Federation.HTTPClient`): unaffected — it uses no multipart and
  already sets `decode_body: false`, so it was never exposed to either.
- **Updated Ecto to 3.14 and Decimal to 3.x** — Decimal 2.x carried a MEDIUM
  unauthenticated-DoS advisory (EEF-CVE-2026-32686, unbounded exponent); Decimal 3
  makes the mitigation the default. The fix is coupled to Ecto 3.14.
- **Cleared the remaining test-only advisories** by updating wallaby to 0.31
  (pulling hackney/tesla to patched majors). These were never shipped (test tooling
  only). `mix hex.audit` now reports no retired or advisory packages.

### Changed

- **Migrated rate limiting to Hammer 7** — replaced the v6 global backend with a
  `use Hammer` store (`BaudrateWeb.RateLimit`) started in the supervision tree; all
  rate checks route through the `BaudrateWeb.RateLimiter` behaviour.
- **Updated Phoenix to 1.8.8**, and the Rust NIF stack: rustler 0.38 (Elixir + all
  three native crates, in lockstep), ammonia 4.1.3, scraper 0.27, feedparser-rs 0.5.4,
  image 0.69.
- **Updated the frontend toolchain**: Tailwind CLI 4.3.2, daisyUI 5.6.10,
  esbuild 0.28.1.
- Routine patch/minor bumps across bandit, postgrex, jason, cbor, tz, credo, and
  their transitive dependencies.

### Fixed

- **Aqua theme card titlebars** are now full-bleed and vertically centered, meeting
  the window border like a real Mac OS X title bar instead of leaving an inset gap.
- **`button/1` component** declares `type` as an allowed global attribute, fixing a
  Phoenix 1.8.8 `--warnings-as-errors` failure.
- **Four browser feature tests** (article editing, comments, search ×2) — corrected
  pre-existing bugs (wrong form-field ids, wrong assertion text, an over-broad button
  selector). The full feature suite (48) is green.

### Added

- **`check-updates` and expanded `security-audit` skills** — a three-ecosystem
  dependency update-check workflow, and a dedicated dependency-vulnerability step
  (OWASP A06) in the security audit.

## [1.9.0] — 2026-07-02

### Added

- **Mac OS X (Aqua) light theme** — a new selectable light theme (`aquaosx`, labelled "Mac OS X (Aqua)") reproducing the Aqua look: glossy gel buttons, the iconic blue default button with a soft focus glow, hairline white "windows" (cards/modals/dropdowns) with soft drop shadows, a gradient header bar, rounded segmented toolbar pills, and rounded blue-gel WebKit scrollbars. It uses the native Apple UI font stack (no bundled webfont). Select it under *Admin → Settings → Theme (light)*.
- **Two-column board listing on the home page** — the board list at `/` now renders in two columns on viewports ≥768px (single column below), making better use of horizontal space. Uses `minmax(0,1fr)` grid tracks so long board names/descriptions can't blow out the layout.
- **`security-audit` project skill** — a dedicated project-wide security-audit workflow (injection, SSRF, federation trust boundaries, auth, secrets, uploads, rate limiting) mapped to the OWASP Top 10, runnable independently of the broader `code-review` skill.

### Security

- **Announced-object authorship bound to its own origin** — a followed remote booster could send an `Announce` whose embedded or fetched object claimed `attributedTo` a victim actor on a *different* instance. The victim resolved legitimately, so attacker-chosen content (with an attacker-chosen `ap_id` able to shadow the victim's future genuine posts) was materialized into boards and feeds attributed to the victim. `InboxHandler` now requires an object's `attributedTo` host to match the object `id` host, and in the fetched path the object `id` host to match the URL it was fetched from; a missing `attributedTo` still falls back to the booster (the verified Announce signer). Legitimate Mastodon/Lemmy boosts are unaffected.
- **Comment forwarding gated on source-board visibility** — `Content.forward_comment_to_board/3` only checked `comment.visibility`, which defaults to `"public"` for local comments regardless of the source board's `min_role_to_view`. An authenticated user could guess a comment ID in a private board they cannot view and forward its body into a public board, exfiltrating restricted content. Forwarding now rejects when the acting user cannot view the comment's source board.
- **JSON-LD `<script>` embedding hardened against the double-escape state** — the previous `</` escape stopped the classic `</script>` breakout but not the `<!--<script` script-data double-escaped state, which an attacker-controlled title could use to swallow the page's `<link>`/`<script>` head markup and break rendering for all visitors (page-integrity, not XSS). JSON-LD is now encoded with Jason's `:html_safe` mode, which escapes every `<` and `>`.

## [1.8.8] — 2026-06-18

### Security

- **SSRF deny-set now decodes NAT64 and IPv4-compatible IPv6** — `Federation.HTTPClient.private_ip?/1` rejected IPv4-mapped IPv6 (`::ffff:x.y.z.w`) but not the NAT64 prefix (`64:ff9b::/96`, RFC 6052) nor the deprecated IPv4-compatible form (`::a.b.c.d`). On a host with a NAT64 gateway, a name resolving to e.g. `64:ff9b::7f00:1` could reach `127.0.0.1`. Both forms now extract and re-check the embedded IPv4 before allowing the fetch.

### Fixed

- **Authenticated LiveViews no longer crash when a DM or notification arrives** — `article_live`, `board_live`, `search_live`, and `board_follows_live` defined only guarded `handle_info/2` clauses. The unread DM/notification count hooks (attached on `:require_auth`/`:optional_auth`) forward `:dm_received`/`:notification_created`/etc. into the underlying LiveView via `{:cont, socket}`, so an arriving DM or notification raised `FunctionClauseError` and crashed the view (remount, lost state) for any logged-in user on those pages. Each now has a catch-all `handle_info/2`.
- **Federation reply-chain ingest no longer crashes on a remote-article insert failure** — `Federation.ObjectResolver` matched only `{:error, _}` from `Content.create_remote_article/3`, but that function surfaces failures as a raw `Ecto.Multi` 4-tuple (e.g. an `ap_id`/slug `unique_constraint` collision), raising `CaseClauseError`. The 4-tuple is now normalized to `{:error, reason}`.
- **Long unbreakable content no longer breaks page width** — feed and user-profile layouts used arbitrary CSS grid tracks with a bare `1fr` (= `minmax(auto, 1fr)`, min `min-content`), so a long URL/token in real federated/RSS content forced the track past its container and broke the page width (not reproducible with short dev content). Tracks now use `minmax(0,1fr)` with `min-w-0`, and feed titles/bodies, DM plain-text bodies, and moderation report reasons wrap via `break-words`.

### Added

- **zh_TW and ja_JP translations** for three flash messages that were wrapped in `gettext()` but never extracted (`"Feed item not found."`, `"You are not allowed to comment on this article."`, `"Invalid reply target."`), which previously rendered as raw English.
- **Negative-path test coverage** for several security invariants that were enforced but unasserted: bot-account login rejection, oversized-payload (413) handling, expired/missing/malformed HTTP-Signature dates, `dm_access: "followers"` and remote block/domain-block paths in `create_message/3`, the 64 KB inbound content cap, and the new IPv6 SSRF deny-set entries.

## [1.8.7] — 2026-06-05

### Security

- **Actor key-confusion / forgery and cache poisoning closed** — `Federation.ActorResolver` took the cached `ap_id` blindly from a fetched actor document's `id`. Because HTTP-Signature verification fetches the actor from the request's `keyId` host, a host controlling any HTTPS endpoint could serve a document whose `id` claimed a victim actor on another domain (with the attacker's own public key) — forging the victim **and** overwriting the genuine cached `remote_actors` row's key (an instance-wide hijack until the next TTL refresh). The resolver now rejects a document whose `id` host differs from the URL it was fetched from (`{:error, :actor_id_origin_mismatch}`) before any upsert.
- **Inbound `Move` now requires `alsoKnownAs` authorization** — the Move handler verified only the signer, so any remote actor could redirect its local followers onto an arbitrary, non-consenting target account. It now force-refreshes the target (`ActorResolver.refresh/1`) and migrates follows only when the target's `alsoKnownAs` claims the moving actor, rejecting with `{:error, :move_not_authorized}` otherwise. A new `also_known_as` column on `remote_actors` (migration `20260605000000`) stores the captured aliases.
- **Direct-message authorization is enforced on every send** — `Messaging.create_message/3` previously performed no authorization; `can_send_dm?` was only checked when *starting* a conversation, so a user could keep messaging into an existing conversation after being blocked or after the recipient set `dm_access` to `nobody`/`followers`. The check now runs at the context boundary on every message (local recipient → `can_send_dm?`; remote → block/domain-block check), returning `{:error, :not_allowed}`.
- **Expanded SSRF deny-set** — `Federation.HTTPClient.private_ip?/1` now also rejects CGNAT/shared address space (`100.64.0.0/10`, RFC 6598) and multicast/reserved ranges (`224.0.0.0/4`, `240.0.0.0/4`) in addition to the existing private/loopback/link-local ranges.

### Fixed

- **Federation delivery no longer crash-loops on a keyless local actor** — a user-signed activity (e.g. a Like on an article in a federated board) is delivered to the *board's* remote followers, who never fetched the user's actor, so a new user's keypair was never lazily generated. `Delivery.do_deliver/1` then hit the bare `:error` from `KeyStore.decrypt_private_key/1`, which its `case` did not match, crashing the delivery `Task` with `CaseClauseError` and re-running the stuck `pending` job every worker cycle. `Delivery.get_private_key/1` (the signing chokepoint for `send_accept`/`send_reject`/queued delivery) now lazily generates a keypair for any existing local user/board/site actor that lacks one and normalizes the missing-key case to `{:error, :no_private_key}`.
- **RSS/Atom bots no longer crash-loop on article-slug collisions** — `Content.create_article/3` surfaces `Ecto.Multi` failures as a 4-tuple `{:error, op, value, changes}`, but `Bots.FeedWorker.post_entry/2` only matched the 2-tuple, raising `CaseClauseError` on a slug `unique_constraint` collision. The crash skipped `record_feed_item` and the fetch cursor, so the bot was re-selected and crashed again every poll. `post_entry/2` now normalizes any error shape, records the item, and continues; the misleading `create_article/3` `@spec` is corrected.
- **`FeedLive` gained a defensive catch-all `handle_info/2`** so an unexpected message (late task reply, monitor `:DOWN`) cannot crash the LiveView.
- **Deterministic ordering for the federation delivery dashboard** — `DeliveryStats.list_actionable_jobs/1` now includes a `desc: id` tiebreaker.

## [1.8.6] — 2026-05-11

### Security

- **Web Push delivery now goes through the SSRF-validated, DNS-pinned HTTP client** — `Baudrate.Notification.WebPush` previously validated the subscription endpoint with `Federation.HTTPClient` but then issued the actual `Req.post` against the raw URL, leaving a DNS-rebinding window where a hostname could resolve to a public IP at validation time and to a private/loopback IP at request time. A new `HTTPClient.post_raw/3` reuses the existing SSRF guard and pinned-host transport so push delivery cannot be redirected to internal addresses.

### Fixed

- **`DomainBlockCache` no longer leaks state across concurrent tests** — the cache stored federation mode and domain sets in a process-wide ETS table that survived Ecto sandbox rollback, so tests setting an allowlist could intermittently make `Messaging.can_receive_remote_dm?/2` and other federation guards reject valid remote actors in unrelated tests. When `:settings_cache_enabled` is `false` (test env) the cache now reads domain settings from the caller's sandboxed DB instead of the shared ETS table.
- **`DeliveryWorkerTest` no longer clobbers global Federation config** — the test replaced `:baudrate, Baudrate.Federation` with just `delivery_poll_interval` and reset it to `[]` on exit, dropping `max_payload_size` and other entries for any later test. It now saves and restores the original config.

### Changed

- **`mix format` applied across pre-existing drift** in `lib/baudrate/auth/session_cleaner.ex`, `lib/baudrate/bots/feed_parser.ex`, `lib/baudrate/content/articles.ex`, `lib/baudrate/content/board.ex`, `lib/baudrate_web/components/layouts/root.html.heex`, `lib/baudrate_web/live/article_live.ex`, and several tests so `mix precommit` passes its `--check-formatted` gate.

## [1.8.5] — 2026-05-11

### Security

- **Server-side authorization on comment submission** — `BaudrateWeb.ArticleLive` now calls `Content.can_comment_on_article?/2` inside `submit_comment` before stamping `article_id` / `user_id`. Previously the handler relied on the client-side hiding of the comment form, so a forged LiveView event could comment on locked articles or boards where the user could view but not post. The same handler also now rejects forged `parent_id` values whose parent comment belongs to a different article, preventing orphaned/cross-article reply chains.
- **Cross-article moderator delete guard** — `delete_comment` now refuses to soft-delete a comment whose `article_id` does not match `socket.assigns.article.id`. Board moderators (and admins acting via forged events) can no longer reach into other boards by guessing comment IDs while viewing an article they moderate.
- **Trusted-proxy boundary for `X-Forwarded-For`** — `BaudrateWeb.Plugs.RealIp` and `BaudrateWeb.Helpers.extract_peer_ip/1` now honor the configured forwarded-IP header **only** when the immediate peer matches an entry in `trusted_proxies` (exact IPs or CIDR ranges). `config/prod.exs` defaults to `["127.0.0.1", "::1"]`. If the application is reachable directly, or if the proxy appends rather than replaces the header, untrusted peers can no longer spoof their IP for rate-limiting or audit logging. When `trusted_proxies` is unset the legacy "trust everything" behavior is preserved.
- **Hardened LiveView event handlers against forged IDs** — `feed_live` reply submission and forward-to-board, `article_live` comment forwarding, and `article_edit_live` image removal switched their record lookups from `Repo.get!/2` to safe variants (`Repo.get/2` plus a new `Content.get_article_image/1`). Forged or stale IDs now produce a flash message instead of crashing the LiveView process.

### Tests

- New tests in `test/baudrate_web/live/article_live_test.exs` covering forged comment submission on a locked article, forged reply with a cross-article `parent_id`, and forged delete of a foreign comment.
- New tests in `test/baudrate_web/plugs/real_ip_test.exs` covering trusted/untrusted peers with both exact-IP and CIDR entries.

## [1.8.4] — 2026-05-09

### Fixed

- **Inbound `Like` / `Announce` on local articles in non-federated boards are now accepted when the article author has remote followers** — user-actor federation publishes articles to follower inboxes (e.g. `mastodon.social/users/them` follows `@author@baudrate.tw`) regardless of board AP status, so the published article exists on remote instances with a resolvable `ap_id`. Remote favourites and boosts addressed at that `ap_id` were silently dropped because `Federation.InboxHandler.article_federated?/1` only allowed local articles to participate in federation when they belonged to a board with `ap_enabled: true`. Result: `announces` rows accumulated (the general tracker runs *before* the gate) but `article_boosts` / `article_likes` stayed empty, no `article_liked` / `article_forwarded` notifications fired, and the LiveView counters never moved. The gate now also returns true if the article's author has at least one row in `followers` — matching the outbound publish path. Local articles whose author has no remote followers continue to reject inbound activities, preserving the non-federated-board contract for purely-local content.

### Tests

- Two new tests in `test/baudrate/federation/inbox_handler_test.exs` covering the new branch: one for `Like` and one for `Announce`, both placing the article in an `ap_enabled: false` board with a single remote follower of the author, and asserting the `article_likes` / `article_boosts` row is created. The pre-existing "ignores Like for local article in non-federated board" test (no follower scenario) still passes.

## [1.8.3] — 2026-05-09

### Fixed

- **`Baudrate.Release.backfill_ap_ids/1` no longer collides with the running production node** — v1.8.2 introduced the backfill task but it called `Application.ensure_all_started(:baudrate)`, which boots the full supervision tree including `BaudrateWeb.Endpoint`. Run via `bin/baudrate eval` against a server with the production node already running, the second VM crashed on `:eaddrinuse` (port 4000), the app shut down (taking the repo with it), and the backfill query then failed with `Ecto.Repo.Registry`'s "repo not started". The task now uses `Ecto.Migrator.with_repo/2` (mirroring `migrate/0` and `rollback/2` in the same module), so it starts only the repo for the duration of the function and never collides with the live endpoint. Canonical URI building also moved off `Federation.actor_uri/2` (which reads from the endpoint's `:persistent_term` cache that's only populated after the endpoint starts) onto a private helper that reads `:scheme` / `:host` / `:port` straight from the static endpoint config. `doc/sysop.md` now documents both `bin/baudrate rpc` (recommended — runs inside the live VM, no env-file sourcing required) and `bin/baudrate eval` (one-shot VM, needs the EnvironmentFile sourced first).

## [1.8.2] — 2026-05-09

### Fixed

- **`ap_id` stamping is now transactional** — `Articles.create_article/3` and `Comments.create_comment/2` previously inserted their rows inside an `Ecto.Multi`, then ran a *separate* post-commit `Repo.update!/1` to stamp the canonical ActivityPub `ap_id` (article: `<base>/ap/articles/<slug>`, poll: `<article-ap-id>#poll`, comment: `<author-actor>#note-<id>`). If the BEAM process or the DB connection died between commit and stamp, the row was durably persisted with `ap_id = nil`, breaking inbox resolution and forcing every publisher to fall back to slug-derived URIs (and polls had no fallback at all). Stamping now happens inside the same `Ecto.Multi` as the insert, so a row is either fully consistent or fully rolled back. The `:article` and `:poll` keys in the success map are preserved so existing callers don't break, and `Comments.create_comment/2` keeps its legacy `{:ok, comment} | {:error, changeset}` return shape.

### Added

- **`Baudrate.Release.backfill_ap_ids/1` heal task** — for instances upgrading from a version that ran the old non-transactional code path, this task scans local rows (`remote_actor_id` is nil) with `ap_id = nil` across articles, polls, and comments and stamps them in place using the same canonical-URI scheme `create_article` and `create_comment` apply at write time. Idempotent, supports `dry_run: true`. Production invocation:

  ```bash
  bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"
  bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
  ```

  `mix backfill_ap_ids` is a thin dev/test wrapper around the same function. Documented in `doc/sysop.md`.

### Documentation

- `doc/development.md` Tech Stack table now lists Bandit, Req (with the "never HTTPoison/Tesla/httpc" rule), Earmark, tz (cross-linking `Baudrate.Timezone`), and the Gettext locale set — matching `CLAUDE.md`. Elixir line aligned to `1.15+ / OTP 26+`.
- `README.md` heading "Acknowledges" → "Acknowledgements".
- `CHANGELOG.md` link references backfilled for releases 1.3.20 → 1.8.1 (53 entries, skipping 1.3.47 / 1.3.48 which have entries but no git tags) so version anchors at the top of the file all resolve.

### Tests

- New `test/baudrate/bots/bot_test.exs` (18 tests) — direct field-by-field coverage of `Bot.create_changeset/2` (URL validation, `file://` rejection, length cap, fetch-interval bounds, schema defaults), `Bot.update_changeset/2` (verifies `user_id` is dropped from cast and validation still fires), and `Bot.deactivate_changeset/1` (idempotent).
- New `test/baudrate/bots/feed_worker_test.exs` (11 tests) — pins `FeedWorker.build_slug/2`: determinism, hash-suffix collision avoidance under shared titles, CJK / empty / punctuation-only fallback, 60-character title cap, and conformance to the regex `Article.changeset` enforces. Function exposed with `@doc false`.
- Four new tests under `Baudrate.ContentTest` `describe "transactional ap_id stamping"` — pin returned-struct vs DB-row consistency for article, article+poll, comment, and prove a board FK violation rolls back the article row.

## [1.8.1] — 2026-05-09

### Fixed

- **`/search` pagination didn't actually scroll to top** — v1.8.0 wired up the `scroll-to-top` push event on `/search` but the JS handler in `assets/js/app.js` bails out unless it can find a `[data-focus-target]` element inside `#main-content`, and the search result containers never had that attribute. The event fired but the page stayed put. Added `data-focus-target` to all four result containers (articles / comments / boards / users tabs) so navigation now scrolls back to the top, matching `/boards`. Regression test covers the rendered articles tab.

## [1.8.0] — 2026-05-09

### Added

- **Scroll to top on `/search` pagination** — Clicking a page link in `/search` now smoothly scrolls back to the top of the results, matching the long-standing behaviour on `/boards`. The trigger is page-change-only, so switching tabs or refining the query while still on page 1 doesn't disturb scroll position. Implemented via a `scroll-to-top` push event picked up by the existing `phx:scroll-to-top` listener in `assets/js/app.js`.

### Fixed

- **Federation discovery from public article URL** — Remote ActivityPub implementations (Mastodon, etc.) could not discover, like, or boost a Baudrate article when its public URL `https://host/articles/<slug>` was pasted into a search field, because the canonical AP `id` lives at `/ap/articles/<slug>` and the public URL had no link back. Articles whose `Create` activity was never pushed to a remote follower (e.g. boards with no remote followers at posting time) became effectively un-interactive from the Fediverse, while articles that *had* been pushed kept receiving activities — making the bug look intermittent. The new `BaudrateWeb.Plugs.ArticleApContentNeg` plug content-negotiates `/articles/:slug` and forwards AS2 `Accept` headers to the existing AS2 endpoint, the article LiveView now advertises `<link rel="alternate" type="application/activity+json">` for federated articles, and `Federation.InboxHandler.resolve_local_article_by_ap_or_uri/1` accepts both `/ap/articles/<slug>` and `/articles/<slug>` so inbound `Like` / `Announce` / `Create` activities addressed at the human URL no longer get silently dropped.
- **Federation publishers and inbox cross-post path** — Comment Like / Boost / Undo activities emitted `"object" => null` whenever `comment.ap_id` was missing (legacy rows or a transient post-insert stamping failure), which remote instances reject. Article Delete / Announce / Update / vote builders ignored the stored `article.ap_id` and re-derived from `slug`, breaking parity with the documented "stored ap_id with fallback" contract. Both surfaces now derive a stable canonical URI when the stored value is absent. `Content.Boards.seed_sysop_board/1` was missing `BoardCache.refresh()`, so a SysOp board created by the setup wizard would be invisible until the next boot.
- **Cross-post attribution spoofing** — When `Create(Article)` arrived for an `ap_id` that already existed locally, `InboxHandler.create_article_in_board/5` and `maybe_auto_route_to_boards/3` linked the article to additional boards without checking that the verified signer was the article's original author — any other verified actor could spuriously cross-post someone else's article. Both call sites now require `existing.remote_actor_id == remote_actor.id`.
- **Stop overusing `aria-live="polite"` on list/table containers** — ~18 list and table wrappers across `/`, `/boards`, `/search`, `/notifications`, `/messages`, `/users/:username`, `/admin/*`, and similar pages carried `aria-live="polite"` on the container, so screen-reader users heard the entire list read out on initial render. Removed where the list is not a true push stream; kept on the article comments thread, conversation message stream, and search-result `role="status"` summaries that legitimately update after a user action.
- **Bare English role names rendered to non-English UIs** — Five templates (`/`, `/profile`, `/admin/invites`, two sites in `/admin/boards`) leaked the raw role string ("admin", "moderator", "user") into zh_TW and ja_JP UIs. All sites now route through the existing `translate_role/1` helper.

### Security

- **Web Push endpoint URL is now SSRF-validated** — `PushSubscription.endpoint` is a user-supplied URL that the server then POSTs to. The schema only checked the HTTPS scheme, and `Notification.WebPush.send_push/2` ran the request through bare `Req.post/1`, so an authenticated client could submit a private endpoint (`http://127.0.0.1:5432`, `http://169.254.169.254/...`, etc.) and have the server emit blind POSTs with VAPID auth headers toward internal services. Both layers now route the URL through `Federation.HTTPClient.validate_url/1`, which rejects non-HTTPS URLs and resolves the host against the existing private/loopback IP range list. Validation runs at storage and at every send (mitigating DNS-rebinding TOCTOU between subscribe and delivery).

### Documentation

- Refreshed the `doc/development.md` Project Structure tree to add six modules that exist on disk but were missing from the listing (`auth/reserved_handle.ex`, `content/comment_image.ex`, `content/interactions.ex`, `content/title_deriver.ex`, `federation/feed_item_reply_image.ex`, `federation/reply_images.ex`).
- Reworded the `doc/api.md` opening to clarify that the AP and `/.well-known` endpoints documented there are the federation surface, with non-AP HTTP endpoints (RSS/Atom feeds, push subscriptions, Web Share Target, `/@:handle` redirect, health probe) intentionally not covered. Added the `Mastodon / Lemmy Compatibility` and `CORS Preflight` H2s to the table of contents.

## [1.7.1] — 2026-05-06

### Fixed

- **Locale flip from browser language to English on LiveView reconnect** — Anonymous visitors whose browser preferred a non-English locale (e.g. Japanese via `Accept-Language: ja`) saw the HTTP dead-render in the correct language, then a sudden flip to English the moment the LiveView WebSocket connected. The `SetLocale` plug applied `Gettext.put_locale` only to the dead-render process; the LV mount ran in a fresh process where Gettext defaulted back to `"en"`, and the `on_mount` hooks only re-applied a locale for *logged-in* users. The plug now also persists the resolved locale into the session cookie, and every relevant `on_mount` hook (`:require_auth`, `:optional_auth`, `:require_password_auth`, `:redirect_if_authenticated`) re-applies it to the LV process. This also fixes the registration flow — a Japanese new user now sees Japanese validation errors and flash messages throughout `/register`.

## [1.7.0] — 2026-05-06

### Added

- **Web Share button for PWA / smartphone sharing** — A new "Share this page" button in the site header invokes the browser's Web Share API to surface the OS-level share sheet, letting users on smartphones (and installed PWAs) forward the current page to other apps such as Messages, Mail, or Mastodon. Hidden on platforms where `navigator.share` is unavailable (most desktop browsers) so it only appears where the share sheet can fulfill the request. Defaults to `document.title` and `location.href`, with per-page overrides via `data-share-title`, `data-share-text`, and `data-share-url` attributes. Translated in en / zh_TW / ja_JP.

## [1.6.0] — 2026-04-22

### Added

- **Search-based multi-board picker on article creation forms** — Both `/articles/new` and the `/feed` quick-post composer now select destination boards through a debounced search input with removable chip selections, replacing the old top-category checkbox list (which hid sub-boards entirely) on `/articles/new` and adding board cross-posting to the feed composer (previously boardless-only). The search respects `Content.can_post_in_board?/2`.
- **Styled 404 and 500 error pages** — `BaudrateWeb.ErrorHTML` now embeds dedicated HEEx templates instead of returning plain-text status messages. Each page renders a DaisyUI card with a Heroicon, a translated description, and a "Back to home" CTA inside the standard site shell. Translated in en / zh_TW / ja_JP.
- **Search result count on every tab** — `/search` now shows a pluralized "%{count} results" label on all four tabs (previously the users tab had none) and upgrades to "Page X of Y — N results total" when pagination is active. The count element uses `aria-live="polite"` + `role="status"` so screen readers hear the update when a tab or query changes.

### Security

- **Reject forged `board_ids[]` on article creation (OWASP A01: Broken Access Control)** — `Content.create_article/3` accepted board IDs as raw input without per-board authorization, and both the `ArticleNewLive` and `FeedLive` quick-post submit handlers trusted the client-provided list. A logged-in user could open DevTools, inject a hidden `<input name="board_ids[]">` referencing a moderator-only (or otherwise-restricted) board, and cross-post into it. Introduced `Content.authorize_post_in_boards/2` in `Content.Permissions` that loads each board once and rejects the submission with `{:error, :forbidden}` when any board fails `can_post_in_board?/2` (or `{:error, :not_found}` if an ID does not resolve), and wired it into both submit handlers before `create_article/3`.

### Fixed

- **Bottom mobile dock no longer clipped on notched devices** — Added `pb-[env(safe-area-inset-bottom)]` to `#mobile-bottom-nav`. The viewport meta already sets `viewport-fit=cover`, so iOS (home indicator) and Android (gesture bar) now sit below the dock instead of over it.
- **Unread / notification badge numbers cap at "99+"** — A new `display_badge_count/1` helper keeps the badge pill from stretching or overflowing on narrow phones. Applied at all four badge call sites (navbar DM / notification, mobile dock DM / notification).
- **Theme and font-size FOUC on hard reload** — A minimal inline `<script>` in the `<head>`, running before the stylesheet is parsed, reads `phx:theme` / `phx:font-size` from `localStorage` (respecting the `prefers-color-scheme` media query when the user's choice is `system`) and applies them to `<html>` so the first paint uses the correct DaisyUI variables. Runtime toggling still lives in `app.js`; the inline script only covers the pre-hydration window.
- **"Mark all as read" buttons use `type="button"`** — On `/boards/:slug` and `/notifications`, the action was missing an explicit button type, so any future ancestor `<form>` would cause it to implicitly submit. Added `type="button"` to both.
- **Image upload progress announced to assistive tech** — The `<progress>` elements in `ArticleNewLive` and the `FeedLive` quick-post composer now carry `aria-label`, `aria-valuenow`, `aria-valuemin`, and `aria-valuemax` so screen readers announce live upload progress.
- **Unread indicator dots on home / board pages paired with visually-hidden text** — Adds `role="img"` + an `sr-only` "Unread" label to the small coloured dots on the boards index (`/`) and the board article list. Colour alone is no longer the only signal to colour-blind or screen-reader users.
- **Remote-actor avatar placeholders in the feed expose the actor's display name** — Wrapped the inline remote avatar containers in `FeedLive` with `role="img"` + `aria-label={display_name}`, and set `alt=""` on the adjacent image so screen readers announce the actor name exactly once.

## [1.5.9] — 2026-04-06

### Fixed

- **Remote articles in non-federated boards can now receive federation activities** — `article_federated?` was previously returning `false` for any article in a board with `ap_enabled: false`, silently dropping incoming Like, Announce (Boost), and Create/Reply activities even for articles that originated from the fediverse and already carry an `ap_id`. Remote articles (`remote_actor_id` non-nil) now always qualify to receive federation interactions regardless of the board's `ap_enabled` setting. Local articles in non-federated boards remain non-federated.
- **Non-federated boards incorrectly accepted Follow activities via the shared inbox** — The board inbox controller already rejected Follows for non-federated boards (returning 404), but the shared inbox had no such guard. A remote actor could send a Follow targeting a board actor URI directly to `/ap/inbox` and receive an `Accept`, creating a spurious follower record. The shared inbox Follow handler now checks whether the targeted actor is a non-federated board and sends a `Reject(Follow)` instead.
- **`Delivery.get_private_key/1` could panic on deleted local actors** — `Repo.get_by!` was used to look up users and boards by URI prefix, raising `Ecto.NoResultsError` if the actor was deleted after a delivery job was created. This caused the Task to die without updating the job status, leaving it permanently in `"pending"` and triggering endless retry loops. Changed to `Repo.get_by` with a `nil` guard that returns `{:error, :unknown_actor}` and lets the job be marked as failed.
- **Dead code clause in `do_deliver/1`** — The `:error ->` match arm (line 217) was unreachable because `get_private_key/1` never returns a bare `:error` atom; the tuple `{:error, :unknown_actor}` was already caught by the `{:error, _}` clause below it. Removed the dead branch.

## [1.5.8] — 2026-04-04

### Fixed

- **Non-deterministic ordering in 8 queries lacking an `id` tiebreaker** — Queries in article listing, comment search, tag articles, user profile feed, admin user list, login attempts, WebAuthn credential list, and bot list were ordered solely by `inserted_at` (or `updated_at`). When multiple records share the same timestamp — common in tests and rapid sequential inserts — PostgreSQL returns rows in an arbitrary order. Added `id` as a secondary sort key to all affected queries for stable, reproducible ordering.
- **Missing "Scroll to top" translations** — The `aria-label` on the scroll-to-top button was untranslated in zh_TW and ja_JP. Translated as `回到頂部` and `トップへ戻る` respectively.

## [1.5.7] — 2026-03-31

### Added

- **"View original" link in article actions for remote articles** — Articles sourced from RSS/Atom feed bots or received via ActivityPub now show a "View original" link (with a link icon) as the first item in the article actions bar, before the like and boost buttons. The link opens the canonical source URL in a new tab. Hidden for locally-authored articles.

### Fixed

- **`&nbsp;` entities rendered as literal text in RSS bot articles** — Feed HTML stored by bots was later re-processed through Earmark at render time. Any `&nbsp;` appearing outside a block-level element was treated as inline Markdown text, causing Earmark to HTML-escape the ampersand (`&` → `&amp;`), producing the visible string `&nbsp;` in the browser. `normalize_feed_html/1` now replaces `&nbsp;` with regular spaces before storage.

## [1.5.6] — 2026-03-30

### Fixed

- **Article search results not sorted by date** — Search results were always ordered by article ID regardless of the intended `inserted_at DESC` ordering. The base query used `distinct: a.id`, which PostgreSQL translates to `DISTINCT ON (a.id)` and silently prepends `a.id` to `ORDER BY`, overriding any other sort. Fixed by replacing the JOIN + DISTINCT pattern with a correlated `EXISTS` subquery for board visibility, eliminating the need for `DISTINCT` entirely. Additionally, the English full-text path had `ts_rank` as its primary sort key; all article searches now sort uniformly by `inserted_at DESC, id DESC` (most recent first).

## [1.5.5] — 2026-03-30

### Fixed

- **YouTube embed Error 153 (player configuration error)** — The `<iframe>` used `referrerpolicy="no-referrer"`, which suppressed the `Referer` header entirely. YouTube's embed player requires the embedding origin in the `Referer` header to verify that the domain is permitted to embed the video; without it, playback fails with Error 153. Changed to `referrerpolicy="strict-origin"`, which sends only the scheme and host (no URL path) to YouTube — preserving user privacy while satisfying YouTube's origin check.

## [1.5.4] — 2026-03-30

### Fixed

- **YouTube (and large-page) link preview embeds never rendering** — Two bugs prevented the YouTube iframe embed from appearing even when the article contained a YouTube URL. First, `fetch_or_get` used `to_string/1` on the error reason, which crashes on tuple errors like `{:http_error, 403, …}` before `upsert_failed` could write the failure record; changed to `inspect/1`. Second, the link preview worker only set `link_preview_id` on success — on failure it logged and moved on, so the article had no preview attached. The worker now looks up the recorded (failed) `LinkPreview` by URL hash after a fetch error and still attaches it to the article, allowing the component to render the YouTube embed using only the stored URL (no metadata needed). Root cause for YouTube: HTML pages are ~500 KB–1 MB and exceed the 256 KB `max_payload_size`.
- **Non-deterministic ordering in conversations, remote feed, and session eviction** — Three queries lacked a secondary sort by `id`, causing unpredictable row order when timestamps collide: `list_conversations` (`last_message_at`), remote feed items (`published_at`), and `evict_excess_sessions` (`refreshed_at`). Added `id` as a tiebreaker to all three.
- **Missing translations for "Bot account" and "or"** — Both strings had empty `msgstr` in zh_TW and ja_JP locale files. Translated as `Bot 帳號` / `Bot アカウント` and `或` / `または` respectively.
- **Bare placeholder strings not wrapped in `gettext()`** — Six placeholder attributes in admin settings, bot edit form, recovery code, and password reset templates were plain string literals. Wrapped in `gettext()` and extracted into the locale catalogue.

## [1.5.3] — 2026-03-24

### Fixed

- **Images lost when forwarding a feed item to a board** — `forward_feed_item_to_board` was not passing `image_attachments` to `create_remote_article`, so AP attachment images stored on the feed item were never fetched and stored as article images. They are now correctly carried over and downloaded asynchronously when a feed item is materialised into a board article.

## [1.5.2] — 2026-03-24

### Removed

- **Wayback Machine fallback in favicon fetcher** — The `web.archive.org` fallback that was attempted when all direct favicon candidates failed has been removed. It added latency and rarely produced usable results; direct candidate resolution (HTML `<link>` tags + standard well-known paths) is now the final step.

## [1.5.1] — 2026-03-24

### Added

- **RSS/Atom feed HTML normalizer** — `normalize_feed_html/1` Rust NIF applies the markdown sanitization allowlist via Ammonia/html5ever, then removes common feed artefacts: empty `<p>` elements left behind when `<div>`/`<span>` wrappers are stripped, and runs of 3+ consecutive `<br>` collapsed to `<br><br>`. Used in `feed_parser.ex` for all bot feed body content.

### Fixed

- **Scroll-to-top FAB not appearing after LiveView navigation** — Cached DOM element references became stale when LiveView's morphdom patched the layout during navigation. Switched to looking up `#scroll-to-top-btn` by ID on every scroll/navigation event and handling clicks via `document` event delegation, so the FAB works correctly after any client-side navigation without a manual page refresh.

## [1.5.0] — 2026-03-24

### Added

- **Scroll-to-top FAB** — A floating action button (56 px, primary colour) appears after the user scrolls past the header and returns to the top of the page on click. Animated with a spring pop-in/out effect (cubic-bezier 0.34, 1.56, 0.64, 1). Positioned above the mobile bottom dock on small screens.

### Fixed

- **`&nbsp;` in article digests** — Leading and trailing `&nbsp;` entities are now trimmed inside the Rust `strip_tags` NIF (Ammonia); interior `&nbsp;` are decoded to regular spaces by `decode_html_entities/1`. Digest text on board, feed, and user-profile pages no longer contains stray non-breaking spaces.
- **Pagination scroll position** — Clicking a pagination link on a board page now scrolls the first article into view, offset by the sticky header height, instead of leaving the viewport anchored at the bottom of the previous page.

## [1.4.0] — 2026-03-22

### Added

- **Image attachments for comments** — Users can now attach up to 4 images (JPEG, PNG, WebP, GIF, max 8 MB each) when posting a comment or inline reply on an article page. Images are processed to WebP with EXIF stripped and dimensions capped at 1024 px, displayed as a gallery below the comment body. Attached images are included as `attachment` entries in federated `Create(Note)` ActivityPub activities so remote instances can display them. Orphaned uploads (never submitted) are cleaned up after 24 hours by `SessionCleaner`.
- **Image attachments for feed replies** — The same upload capability is available when replying to a remote actor's post on the `/feed` page. Up to 4 images per reply; images are sent as AP attachments to the remote actor's inbox and the replying user's AP follower inboxes. Previously sent reply images are shown in the local reply list.
- **`CommentImage` and `FeedItemReplyImage` schemas** — New DB tables (`comment_images`, `feed_item_reply_images`) with nullable FK columns supporting the upload-before-save pattern; cascade-deleted with their parent records.

## [1.3.58] — 2026-03-22

### Fixed

- **HTML entity double-encoding in article digests and display names** — `strip_tags` (Ammonia) re-encodes special characters as HTML entities (e.g. `&` → `&amp;`). When the output was interpolated into a HEEx template, Phoenix would escape it again (`&amp;amp;`), causing browsers to render literal `&amp;` instead of `&`. Added a public `decode_html_entities/1` helper to `Baudrate.Sanitizer.Native` and applied it after every `strip_tags` call whose result is used as plain text: `digest/1` in board, feed, and user-profile live views; `excerpt/1` in `linked_data.ex`; `sanitize_display_name/1` in `Federation.Sanitizer` and `Setup.User`; and `normalize_title/1` in the RSS/Atom feed parser.

## [1.3.57] — 2026-03-20

### Changed

- **Fediverse handle icon size increased** — The `hero-identification` icon next to the fediverse handle on user profile and board pages is now `size-6` (24 px) for better visual prominence.

## [1.3.56] — 2026-03-20

### Added

- **Handle reservation on deletion (anti-fraud)** — When a bot account or board is deleted, its username/slug is permanently recorded in a new `reserved_handles` table. Subsequent attempts to register a username or create a board with a reserved handle are rejected with a clear error message, preventing impersonation of well-known identities after deletion. Reservation happens inside the deletion transaction so no handle leaks on rollback. Both the `User` and `Board` changeset validators now check this table in addition to the existing cross-type conflict check.

## [1.3.55] — 2026-03-20

### Fixed

- **Username/board-slug WebFinger conflict prevented** — A username whose lowercase form matched an existing board slug would shadow that board in WebFinger resolution (users are checked before boards), making the board undiscoverable from Mastodon and other federation clients. Added `validate_username_not_board_slug/1` to `User` changeset and `validate_slug_not_username/1` to `Board` changeset so the conflict is caught at creation time with a clear error message on both sides.

## [1.3.54] — 2026-03-20

### Added

- **Fediverse handle on user profiles and board pages** — Registered users and federated boards now display their fediverse handle (e.g. `@hiroshiyui@baudrate.tw`) with a heroicon identification icon. The handle is always shown on user profile pages; on board pages it appears only when `ap_enabled` is true. Added `fediverse_handle/1` helper in `BaudrateWeb.Helpers` (delegated via `core_components.ex`). Translations added for zh_TW (`聯邦宇宙帳號`) and ja_JP (`Fediverseハンドル`).

## [1.3.53] — 2026-03-20

### Fixed

- **PWA draft content cleared on return from background** — When a user switched away from the app and came back, LiveView reconnected and re-rendered the page with empty server state, wiping any in-progress draft. Added a `reconnected()` callback to `DraftSaveHook` that restores saved draft content from `localStorage` via `requestAnimationFrame` after LiveView finishes patching the DOM.

## [1.3.52] — 2026-03-19

### Added

- **Real-time unread board indicators on the home page** — The boards listing now subscribes to `board:<id>` PubSub topics on mount (authenticated users only) and re-computes `unread_board_ids` whenever an `:article_created` event is received. The unread dot appears immediately without requiring a manual page reload.

## [1.3.51] — 2026-03-18

### Fixed

- **Bot feed deduplication now checks source URL in addition to GUID** — Previously, `already_posted?` only compared the feed entry GUID against `bot_feed_items`. If a feed publisher changed a `<guid>` between fetch cycles (e.g. switching from a relative path to a canonical URL), the same article would slip through and be posted twice. `already_posted?/3` now also queries `articles(user_id, url)` for any non-deleted article posted by the bot with the same source URL. A partial index on `articles(user_id, url) WHERE url IS NOT NULL` keeps the lookup efficient.

## [1.3.50] — 2026-03-18

### Fixed

- **Bot profile field inputs reset on every keystroke** — In the `/admin/bots` edit form, plain HTML `<input>` elements for profile fields (Label / Content) had their `value` bound to `@editing_bot_profile_fields`, which is only populated when the edit button is clicked and never updated during `phx-change="validate"`. Every keystroke triggered a LiveView re-render that reset the inputs to their original server-side values. Fixed by adding `phx-update="ignore"` to the profile fields container div, preventing LiveView from patching those DOM nodes after the initial mount. The `:if={@editing_bot}` wrapper ensures a fresh mount with correctly pre-filled values each time a bot's edit form is opened.

## [1.3.49] — 2026-03-18

### Changed

- **Feed parser replaced with feedparser-rs Rustler NIF** — The Elixir `fiet` and `saxy` libraries have been replaced by a new `baudrate_feed_parser` Rustler NIF backed by the [`feedparser-rs`](https://github.com/bug-ops/feedparser-rs) Rust crate. The new parser supports RSS 0.9x/2.0, RSS 1.0 (RDF), Atom 0.3/1.0, and JSON Feed natively in a single pass with no per-format fallback logic. Dates are returned as RFC 3339 strings and parsed by `DateTime.from_iso8601/1` on the Elixir side. HTML sanitization remains in Elixir via the existing `baudrate_sanitizer` NIF.

### Removed

- **`fiet` and `saxy` dependencies** — Both packages are no longer needed and have been removed from `mix.exs` and unlocked from `mix.lock`.

## [1.3.48] — 2026-03-18

### Added

- **Bot bio editing in admin UI** — The `/admin/bots` edit and create forms now include a `Bio` textarea. On creation, the bio defaults to the feed URL when left blank. On edit, the current bio is pre-filled and submitted explicitly, bypassing the legacy auto-bio-from-feed_url fallback. Admins can use this to add disclaimer text such as "Unofficial — not affiliated with the source."
- **Bot profile fields in admin UI** — The `/admin/bots` edit form now exposes 4 profile field rows (label + content) that are stored on the bot's user account and federated as `PropertyValue` attachments on the bot's AP actor, following the Mastodon convention. Admins can use these to add structured metadata such as a notice of non-affiliation with the feed source.

## [1.3.47] — 2026-03-18

### Added

- **User profile fields (Mastodon-compatible)** — Users can now add up to 4 custom profile fields (name + value pairs, e.g. "Website", "Location") at `/profile`. Fields are stored as a `jsonb[]` column on the `users` table, validated (name ≤ 255 chars, value ≤ 2048 chars, max 4 fields), and displayed on public profile pages. For ActivityPub federation, fields are published as `PropertyValue` attachments on the Person actor with the schema.org context (`schema:PropertyValue`, `schema:value`), ensuring compatibility with Mastodon and other AP clients that render profile metadata.
- **Remote actor profile fields** — Incoming AP actors' `attachment` arrays are parsed for `PropertyValue` entries (up to 4), stored in a new `profile_fields` column on `remote_actors`, and displayed on the remote user's local profile page.

### Database

- New `profile_fields jsonb[] NOT NULL DEFAULT '{}'` column on both `users` and `remote_actors` tables (migration `20260318000000_add_profile_fields_to_users_and_remote_actors`).

## [1.3.46] — 2026-03-17

### Changed

- **Article image upload limit raised to 8 MB** — The maximum file size for article image uploads (new and edit) has been increased from 5 MB to 8 MB, both client-side (`allow_upload`) and server-side (`Content.Images`).

## [1.3.45] — 2026-03-17

### Added

- **RSS bot favicon fetch retry limit** — Automatic favicon fetching is now paused after 3 consecutive failures per bot, preventing repeated requests to unreachable or bot-blocking sites. A new `favicon_fail_count` column on the `bots` table tracks consecutive failures; the counter resets to 0 on any successful fetch. The admin "Refresh Favicon" button bypasses the gate and always attempts a fetch, re-enabling automatic fetches on success.

### Tests

- Added essential WebAuthn unit tests: `begin_registration/1` (token+JSON structure, ETS storage, single-use), `begin_authentication/1` (token+JSON, empty/populated `allowCredentials`, challenge type), `finish_registration/4` (invalid base64 inputs), `finish_authentication/6` (`:unknown_credential` for missing, cross-user, and invalid base64 credential ID).
- Updated WebAuthn controller tests to use `Wax.new_authentication_challenge/1` instead of plain map challenges.
- Added tests for `favicon_fail_count` gate logic, `increment_favicon_fail_count/1`, and `mark_avatar_refreshed/1` counter reset.

## [1.3.44] — 2026-03-17

### Fixed

- **WebAuthn admin sudo verification — 500 error on `Wax.authenticate/6`** — The argument order was wrong: `challenge` and `credentials` were swapped (positions 5 and 6). Additionally, `credentials` must be a `[{credential_id, cose_key}]` tuple list, not a map, and the sign count is not part of the credentials list. The return value is `{:ok, Wax.AuthenticatorData.t()}` — the new sign count is read from `auth_data.sign_count`.

## [1.3.43] — 2026-03-17

### Fixed

- **WebAuthn admin sudo verification always failing with `:unknown_credential`** — Two bugs:
  1. `Wax.new_authentication_challenge/1` was passed `allow_credentials` as a list of raw credential ID binaries, but wax_ expects `[{credential_id, cose_key}]` tuples. When `allow_credentials` is non-empty, wax_ uses it (not the `cred_map` passed to `Wax.authenticate/6`) for key lookup, so verification always failed. Fixed by omitting `allow_credentials` from the challenge, causing wax_ to fall back to the `credentials` map passed directly to `Wax.authenticate/6`.
  2. The `WebAuthnAuthenticate` hook set hidden form inputs then pushed `webauthn_credential_received` to trigger `phx-trigger-action`. When LiveView sent back the diff, morphdom patched the DOM before form submission, resetting the JS-set `credential_id`/`signature`/etc. fields to empty. Fixed by calling `requestSubmit()` directly from JS (same as `WebAuthnRegister`), removing the `phx-trigger-action` approach for this form.

## [1.3.42] — 2026-03-17

### Fixed

- **WebAuthn registration — public key cast error** — `Wax.register/3` returns the credential public key as a decoded COSE key map (`Wax.CoseKey.t()`), not raw bytes. Storing it directly into a `:binary` schema field caused an Ecto cast error on every registration. The key is now CBOR-encoded before storage and decoded back (with `CBOR.Tag` byte-string unwrapping) before being passed to `Wax.authenticate/6`. Added `{:cbor, "~> 1.0"}` as an explicit dependency.

## [1.3.41] — 2026-03-17

### Fixed

- **WebAuthn registration always failing** — `Wax.Challenge` stores `attestation` and `user_verification` as strings (`"none"`, `"preferred"`), but the challenge options were passing atoms (`:none`, `:preferred`). The atom overwrote the string default, causing `AttestationStatementFormat.None.verify/4` to never match its `%Wax.Challenge{attestation: "none"}` clause and rejecting every registration attempt with `invalid_attestation_conveyance_preference`. The incorrect options are now removed from both challenge calls and the config, letting the correct string defaults take effect. `user_presence: true` (not a recognized `Wax.Challenge` option) was also removed.

## [1.3.40] — 2026-03-17

### Fixed

- **WebAuthn registration failure reason now logged** — The `else` clause in the registration controller was discarding the actual error, making production failures impossible to diagnose. The error is now included in the warning log line.

## [1.3.39] — 2026-03-17

### Added

- **WebAuthn / FIDO2 hardware security key support** — Users can register FIDO2-compatible hardware security keys (YubiKey, passkeys, Touch ID, etc.) at `/profile` → "Security Keys". Registered keys can be used as an alternative to TOTP when completing admin sudo-mode re-verification at `/admin/verify`. Multiple keys per user are supported; each has a user-defined label, a last-used timestamp, and a sign count for clone detection.

## [1.3.38] — 2026-03-16

### Fixed

- **User boosts not delivered to booster's followers** — When a local user boosted an article or comment, the `Announce` activity was incorrectly delivered to the *article author's* followers instead of the *booster's* followers, making the boost invisible to anyone following the booster on remote instances. The delivery now uses `enqueue_for_followers/2` with the booster's actor URI.

## [1.3.37] — 2026-03-16

### Fixed

- **Bot favicon wrong site for feed proxies** — Feed proxy services (e.g. FeedBurner at `feeds.feedburner.com`) and CDN feed subdomains (e.g. `feeds.bbci.co.uk`) serve feeds from a different host than the actual website, so the favicon was never found. The fetcher now reads the feed XML first and extracts the channel `<link>` element (the actual website URL) to use as the favicon base, falling back to the feed URL's origin if extraction fails.

## [1.3.36] — 2026-03-16

### Added

- **Wayback Machine favicon fallback** — When all direct favicon fetches fail (e.g. the production server IP is blocked at a CDN/WAF), the favicon fetcher now retries the same candidate list via the Internet Archive Wayback Machine (`web.archive.org/web/2if_/{url}`), which returns the most recently archived raw file. This allows bots to acquire favicons from sites like Bahamut that block non-browser IPs.

## [1.3.35] — 2026-03-16

### Added

- **Bot "Reset & Retry" button** — The admin bots page now shows a "Reset & Retry" button on any bot with errors. Clicking it clears the error count and last error message, resets `next_fetch_at` to now (bypassing exponential backoff), and immediately triggers a re-fetch without waiting for the next scheduled poll cycle.

## [1.3.34] — 2026-03-16

### Fixed

- **Feed parser rejects BOM-prefixed feeds** — Some feeds (e.g. news.ltn.com.tw) prepend a UTF-8 BOM (`EF BB BF`) which caused Saxy to fail with a parse error on the leading `<` of `<?xml`. The BOM is now stripped before any parsing.

## [1.3.33] — 2026-03-16

### Added

- **RSS 1.0 (RDF) feed support** — Feed bots can now subscribe to RSS 1.0/RDF feeds (e.g. Impress Watch). These use a flat `<rdf:RDF>` root with `<item>` siblings rather than nesting inside a `<channel>`. Parsed directly via `Saxy.SimpleForm` as a third fallback after RSS 2.0 and Atom 1.0. Supports `dc:date`, `content:encoded`, `rdf:about` as GUID, and standard `title`/`link` fields.

## [1.3.32] — 2026-03-16

### Fixed

- **Bot article titles "(untitled)"** — RSS feeds that embed raw HTML in `<title>` without CDATA wrapping (e.g. Drupal-style `<title><a href="...">text</a></title>`) caused fiet/Saxy to see nested XML elements and return an empty title, falling back to "(untitled)". The feed parser now pre-processes such title elements by stripping tags and re-wrapping the text in CDATA before parsing. HTML entities (e.g. `&amp;`) are also decoded so titles are stored as plain text.
- **Bot article bodies missing paragraphs / rendered as blockquotes** — Bot articles store sanitized HTML in the body field. `Markdown.to_html/1` runs input through Earmark, which requires blank lines between block-level elements to recognize them as HTML blocks. Without them, Earmark dropped all paragraphs after the first, and lines starting with `>` were misinterpreted as Markdown blockquotes. A normalization step now inserts `\n\n` after block-level closing tags and trims leading/trailing whitespace before handing text to Earmark. Fixes rendering for all existing bot articles without any DB migration.

## [1.3.31] — 2026-03-16

### Added

- **Bot favicon manual refresh** — Added a "Refresh Favicon" button to the admin bots page (`/admin/bots`). Clicking it immediately re-fetches the favicon from the feed site and sets it as the bot's avatar, without waiting for the next scheduled feed cycle. The action is logged to the moderation audit log.

## [1.3.30] — 2026-03-16

### Fixed

- **Bot favicon WAF bypass** — The favicon fetcher now uses a browser-like Firefox User-Agent for all favicon HTTP requests (homepage fetch + candidate downloads). Sites that block bot user-agents at the CDN/WAF layer (e.g. gnn.gamer.com.tw / Bahamut) now return the correct responses.
- **`HTTPClient.get_html/2`** — Added a `:user_agent` option to allow callers to override the default generic User-Agent string.

## [1.3.29] — 2026-03-16

### Fixed

- **Bot favicon CDN hotlink protection** — The favicon fetcher now sends the site's origin URL as the `Referer` header when downloading favicon candidates. CDNs that reject requests without a `Referer` (e.g. Bahamut's `i2.bahamut.com.tw`) now serve the image correctly.

## [1.3.28] — 2026-03-16

### Added

- **Bot profile shows feed URL** — Bot user profiles now display the feed URL in the bio field automatically. The bio is set on bot creation and kept in sync whenever the feed URL is updated.

### Fixed

- **Bot avatar fetching** — The favicon fetcher now handles two common failure cases:
  - Sites that advertise only an SVG favicon (e.g. gamer.com.tw) — SVG links are now skipped; the `apple-touch-icon` PNG is used instead.
  - Sites that advertise only a `favicon.ico` but don't include it in `<link>` tags (e.g. ithome.com.tw) — each candidate URL is now tried end-to-end (download + avatar process); if ICO fails the avatar pipeline, the standard `/apple-touch-icon.png` path is probed as a fallback.
- **Article timestamps** — Bot and federated articles now show their original `published_at` date (from RSS `<pubDate>` / Atom `<published>`) instead of the time the bot fetched them. Regular user articles are unaffected.

## [1.3.27] — 2026-03-16

### Added

- **RSS/Atom Feed Bot Accounts** — Administrators can now create bot accounts that periodically fetch RSS/Atom feeds and post entries as articles. Bots are full ActivityPub actors — remote users and boards can follow them and receive federated articles. Bots cannot be logged into by humans and cannot receive DMs. A "Bot" badge is shown on profiles and post bylines.
- **Admin Bot Management UI** — New admin page at `/admin/bots` for creating, editing, toggling, and deleting bot accounts with feed URL, target boards, and fetch interval configuration.
- **Board Follows discoverability** — Added a "Follows" action link to the admin board management table for federated boards, so admins can reach board follows pages without explicitly being board moderators.

### Fixed

- **Bot login crash (critical)** — Logging in with a bot account username no longer causes a `CaseClauseError` (500 error). The attempt is now rejected with the same generic "Invalid username or password" message and recorded as a failed login attempt.
- **Feed item deduplication race** — `record_feed_item/3` now uses `on_conflict: :nothing` to safely handle concurrent duplicate GUID inserts without raising a constraint error.
- **User-Agent version** — The federation HTTP client now reads the version from `Application.spec/2` at runtime instead of hardcoding `0.1.0`, keeping the User-Agent accurate across releases.
- **Local handle search on board follows page** — Searching for a local user handle (e.g. `@botname`) on the board follows page now shows a helpful error directing the admin to configure bot board targets via Admin → Bots, instead of silently failing.

### Improved

- **Accessibility** — Bot badge spans now carry `role="img"` and `aria-label="Bot account"` for screen reader clarity. Profile page dropdown trigger has `aria-expanded`. Article thumbnail `alt` text now uses the article title instead of the generic "Article image".

## [1.3.26] — 2026-03-15

### Added

- **CI/CD Hardening** — Integrated `credo` linting, enforced `mix format` checks, and enabled `warnings-as-errors` in the GitHub CI pipeline to ensure long-term code quality.
- **Pending User Profiles** — Users awaiting administrative approval can now personalize their profile by uploading an avatar and updating their bio and display name.

### Changed

- **Auth Context Refactor** — Major architectural cleanup of the `Baudrate.Auth` module. Logic has been extracted into specialized sub-modules (`Invites`, `Sessions`, `SecondFactor`, `Moderation`, `Users`, `Profiles`, `Passwords`) while maintaining a clean facade.
- **Federation Context Refactor** — Architectural cleanup of the `Baudrate.Federation` module. Logic has been extracted into focused sub-modules (`Follows`, `Feed`, `Discovery`, `Collections`, `ObjectBuilder`, `ActorRenderer`) to improve maintainability and testability.
- **ArticleLive Refactor** — Simplified the main `ArticleLive` module by extracting pure helper logic into `ArticleHelpers` and moving comment tree rendering into `CommentComponents`.
- **Invite Quota Relaxation** — Removed the 7-day account age requirement for generating invite codes, allowing new users to invite others immediately after registration.

### Fixed

- **Compiler Warnings** — Cleaned up unused default values in test helpers (`insert_board/2`, `create_image/3`).
- **Code Hygiene** — Fixed multiple linting issues including large number formatting and expensive list length checks.

## [1.3.25] — 2026-03-14

### Added

- **Remote comment/DM image attachments** — image attachments on incoming
  federated comments and DMs are now displayed as `<img>` tags in the
  rendered body (HTTPS only). Previously, images sent as AP attachments
  on Note objects were silently stripped by the sanitizer.
- **Test coverage** — added 55 tests for `Content.Search`, `Content.ReadTracking`,
  and `InteractionHelpers` modules

### Fixed

- **Announce-to-boards missing images** — articles routed via Announce
  (boost) to boards now correctly extract and store image attachments
- **Actor resolver nil TTL** — `stale?()` no longer returns false when
  `actor_cache_ttl` config is nil (Elixir term ordering edge case),
  preventing stale actors from being served without refetch
- **AttachmentExtractor** — `Image` type attachments without a URL are
  now correctly rejected

## [1.3.24] — 2026-03-14

### Improved

- **Board search in article forwarding** — the forward-to-board search now
  matches against board slugs in addition to board names, making it easier
  to find boards by their URL identifier

## [1.3.23] — 2026-03-12

### Fixed

- **Actor discovery on Threads.net and similar instances** — expanded the
  signed fetch fallback to also trigger on 403 and 404 HTTP responses, not
  just 401. Threads.net returns 404 for unsigned actor profile requests,
  which previously prevented discovering and following accounts there

## [1.3.22] — 2026-03-12

### Fixed

- **Federation delivery crash on remote article like/boost** — liking or
  boosting a remote article (no local user) crashed `enqueue_for_article`
  with `BadMapError` when accessing `article.user.username`. Now skips user
  follower inbox resolution for remote articles

## [1.3.21] — 2026-03-12

### Added

- **User profile: boosted articles & comments** — user profile pages now show
  a two-column layout with recent articles & comments on the left and boosted
  articles & comments on the right, with content digests, image previews, and
  load-more pagination
- **Profile username link** — username on the profile settings page is now a
  clickable link to the public profile, with a copy-to-clipboard button for
  the full profile URL

### Fixed

- **Rate limiting gap** — the PWA Web Share Target endpoint (`POST /share`)
  now has rate limiting (10 req/min per IP)
- **Accessibility** — link preview images now have descriptive `alt` text,
  article elements have `aria-labelledby`/`aria-label` attributes, admin panel
  text opacity raised from 60% to 70% for WCAG AA contrast compliance
- **Defensive `Repo.get!` calls** — `stamp_local_ap_id` and `stamp_ap_id` now
  use `Repo.get` with graceful nil handling instead of raising on deleted
  records

### Tests

- Added 27 dedicated tests for `ArticleImageStorage` (image processing, edge
  cases, invalid inputs)
- Added 26 dedicated tests for `Content.Interactions` (visibility checks, role
  access, AP ID stamping)

## [1.3.20] — 2026-03-11

### Fixed

- **Remote article images** — articles imported via federation (inbox delivery,
  auto-routing to boards, and `/search` import) now fetch and store image
  attachments from the AP object's `attachment` array. Images go through the
  same security pipeline as local uploads (magic byte validation, WebP
  re-encoding, EXIF strip, max 1024px)

## [1.3.19] — 2026-03-10

### Changed

- **Draft save indicator** — replaced "Draft saved" text with a loading dots
  animation during debounce and a cloud-arrow-up Heroicon when saved;
  indicator is now inline after the submit button in all forms

## [1.3.18] — 2026-03-10

### Fixed

- **Draft indicator layout shift** — moved "Draft saved" indicator outside
  the inline controls row in article new, edit, and comment forms so it no
  longer pushes the visibility selector and submit button when appearing
- **Inline form controls vertical alignment** — stripped DaisyUI fieldset
  and label padding in all inline form control rows (article new/edit,
  comment, reply, feed quick-post) for proper vertical centering
- **Comment and reply form controls left-aligned** — visibility selector
  and Post/Reply button are now left-aligned with flex-wrap for mobile
  responsiveness, consistent with article and feed forms
- **Search operators card readability** — bumped title and table text size
  for better readability
- **Ansible version comparison** — stripped `v` prefix before semver
  comparison to prevent false "deploying older version" warnings

## [1.3.15] — 2026-03-10

### Changed

- **Article form controls consolidated** — visibility selector, "Allow
  forwarding" checkbox, and Create/Save button now share a single inline
  row on article create and edit pages; visibility label removed (kept as
  `aria-label` for accessibility)
- **Markdown toolbar repositioned** — formatting toolbar now appears below
  the textarea instead of above it
- **Feed quick-post controls left-aligned** — visibility selector and Post
  button in the feed composer are now left-aligned with flex-wrap for
  mobile responsiveness

## [1.3.14] — 2026-03-10

### Fixed

- **Comment visibility selector layout** — moved the visibility selector
  before the Post/Reply button in comment and reply forms; fixed vertical
  misalignment caused by DaisyUI fieldset margin

## [1.3.13] — 2026-03-10

### Fixed

- **False "edited" indicator on Mastodon** — ActivityPub article objects no
  longer unconditionally include the `"updated"` field; it is now only emitted
  when the article was genuinely edited (>5s after creation), preventing
  Mastodon from showing an "edited" badge on unedited articles

### Reverted

- **Sitemap generation** — reverted v1.3.13–v1.3.15 sitemap feature due to
  OTP release read-only filesystem constraints; will revisit with a different
  approach

## [1.3.12] — 2026-03-10

### Added

- **Visibility selector** — article create/edit forms, comment forms, and feed
  quick post now include a visibility selector (Public, Unlisted, Followers-only,
  Direct) with full i18n support (en, zh_TW, ja_JP)
- **Remote object resolution via search** — paste a remote Fediverse post URL
  into search to preview it without storing; click "Import & interact" to
  materialize locally for liking, boosting, or forwarding (two-phase
  `ObjectResolver.fetch/1` + `resolve/1`, loop-safe)
- **Feed item and comment forwarding to boards** — users can forward feed items
  and comments to boards they have posting access to, with federation publishing
- **Forwarding UI** — forward buttons on feed items and comments with board
  selector modal
- **Nginx bot/scanner blocking rules** — example configuration for blocking
  common vulnerability scanners and malicious bots

### Fixed

- **Article title length validation** — all article changesets now enforce
  max 255 characters; `TitleDeriver` truncates remote AP object names to
  prevent oversized titles from malicious servers
- **Deterministic query ordering** — added `id` tiebreakers to all `order_by`
  queries across auth, content, federation, messaging, and moderation contexts
  to prevent nondeterministic results when timestamps collide
- **Comment creation mixed map keys** — normalized all keys to strings before
  merging `body_html` to prevent `Ecto.CastError` under concurrent execution
- **Visibility selector alignment** — fixed DaisyUI fieldset margin causing
  misalignment with Post button in feed quick post
- **Fuzzy gettext auto-matches** — cleared all incorrect fuzzy translations
  (e.g., "Public" → "Public Key") across en, zh_TW, ja_JP locales
- **Remote article forwardable flag** — added `:forwardable` to remote article
  changeset so visibility-based forwardability is persisted

### Changed

- **TitleDeriver extracted** — title derivation logic moved to shared
  `Content.TitleDeriver` module for reuse across inbox handler and
  ObjectResolver

## [1.3.11] — 2026-03-09

### Fixed

- **DM input not clearing after send** — message compose input now clears
  after sending by using a dynamic form ID that forces DOM recreation
- **Send button icon disappearing** — removed `phx-disable-with` that was
  stripping the paper airplane icon and not restoring it after re-enable

## [1.3.10] — 2026-03-09

### Added

- **YouTube video embeds** — link previews for YouTube URLs now render an
  embedded video player (via privacy-enhanced `youtube-nocookie.com`) instead
  of a static Open Graph card; supports watch, youtu.be, embed, and shorts URLs
- **Boosted content in personal feed** — articles boosted (Announced) by
  followed remote accounts now appear in the user's personal feed with
  boost attribution; supports both bare-URI and embedded-object Announce formats
  (Mastodon and Lemmy interop)
- **Board routing for boosts** — boosted Article/Page content is routed to
  boards following the booster, with deduplication by `ap_id` to prevent
  duplicates when multiple actors boost the same content; Notes remain feed-only
- **Remote image attachments** — image attachments from remote ActivityPub
  objects are displayed in the feed timeline (up to 4 images per item)

### Fixed

- **Flaky federation tests** — `ValidatorTest` no longer relies on
  `Application.get_env` which could return `nil` during concurrent test runs;
  `ActorResolverTest` uses unique `ap_id` values to prevent race conditions

### Security

- **CSP frame-src** — added `frame-src https://www.youtube-nocookie.com` to
  Content Security Policy; only YouTube embeds are allowed, no other iframes

## [1.3.9] — 2026-03-09

### Fixed

- **Remote article "View original" links** — links now point to the
  human-readable URL (e.g. `https://instance/@user/123`) instead of the
  canonical AP ID (e.g. `https://instance/ap/users/.../statuses/...`);
  a new `url` field on articles stores the browsable permalink from
  incoming ActivityPub objects

### Added

- **"View original" link on article page** — remote articles now show a
  "View original" link on the full article detail page

## [1.3.8] — 2026-03-09

### Added

- **@mention autocomplete** — typing `@` in article, comment, and feed text
  areas shows a dropdown of matching users; supports keyboard navigation
  (Arrow keys, Enter/Tab to accept, Escape to dismiss)
- **Federated mention suggestions** — the @mention dropdown includes remote
  actors who participated in the current discussion thread (article author
  and commenters), displayed as `@username@domain`

## [1.3.7] — 2026-03-09

### Added

- **Article images in ActivityPub payload** — federated articles now include
  uploaded images as Document attachments, visible on remote instances
- **Article images in feed and board views** — article image thumbnails are
  displayed in the feed timeline and board article listings
- **Add Images icon button** — replaced the file input widget with a compact
  icon button; "Add Images" and "Add Poll" now share a single toolbar row

### Fixed

- **Multi-image upload stalling** — fixed parallel uploads silently failing by
  consuming each upload entry individually as it completes
- **Oversized file upload errors not shown** — per-entry upload errors (e.g.
  file too large) are now displayed to the user

## [1.3.6] — 2026-03-09

### Added

- **Full-featured feed post composer** — the feed quick-post form now includes
  a markdown formatting toolbar, image uploads (up to 4 images), and optional
  polls, matching the article creation page
- **Collapsible markdown toolbar** — all markdown toolbars now have a pencil
  icon toggle to collapse/expand formatting buttons; collapsed by default,
  state persisted in localStorage

## [1.3.5] — 2026-03-08

### Fixed

- **Wrong repository URL in NodeInfo** — `software.repository` in `/nodeinfo/2.1`
  now points to the correct GitHub repository

## [1.3.4] — 2026-03-08

### Fixed

- **Instance actor not discoverable via WebFinger** — remote instances querying
  `acct:site@host` now correctly resolve to the site actor (`/ap/site`) instead
  of returning 404, enabling proper instance-level federation discovery

## [1.3.3] — 2026-03-08

### Added

- **"Remove from board" action** on multi-board articles — when an article exists
  in multiple boards, the dropdown shows per-board removal buttons that detach
  the article from individual boards without affecting forwarded copies

### Fixed

- **Forwarded article disappears from all boards on delete** — deleting a
  multi-board article now only removes the board association, not the article
  itself; forwarded copies in other boards remain visible
- **Soft-deleted articles accessible via direct URL** — `get_article_by_slug!`
  now filters out articles with `deleted_at` set, returning 404 instead of
  showing deleted content

## [1.3.2] — 2026-03-08

### Fixed

- **Startup crash in v1.3.1** — `shutdown_timeout` must be nested under
  `thousand_island_options` in Bandit config, not at the top level

## [1.3.1] — 2026-03-08

### Added

- **Near-zero downtime deploys** — nginx `proxy_next_upstream` retries requests
  during restarts (up to 30s, 3 attempts) with custom 502 maintenance page as
  fallback; Bandit `shutdown_timeout` drains in-flight requests for 30s on
  SIGTERM; systemd `TimeoutStopSec=35` for graceful shutdown margin

### Changed

- Database migrations now run **before** symlink swap and service restart during
  Ansible deploys, reducing the restart window to just the symlink swap + restart

### Documentation

- Added "Near-Zero Downtime Deploys" section to SysOp guide
- Added CHANGELOG.md update step to release engineering checklist in CLAUDE.md

## [1.3.0] — 2026-03-08

### Added

- **Article and comment boosts** — fully federated via ActivityPub `Announce` /
  `Undo(Announce)` activities, with self-boost prevention and soft-delete guards
- **Like and boost buttons** on article pages, board listings, and personal feed
  for both local content and remote feed items
- **Feed item interactions** — like and boost remote feed items, sending AP
  `Like` / `Announce` activities to the remote actor's inbox
- **Boost notification types** — `article_boosted` and `comment_boosted` with
  per-user notification preferences
- New database tables: `article_boosts`, `comment_boosts`, `feed_item_likes`,
  `feed_item_boosts`

### Changed

- **Comment likes now federated** — upgraded from local-only to sending AP
  `Like` / `Undo(Like)` activities with AP ID stamping (previously comment likes
  had no federation support)
- **Shared interaction helpers** — extracted `Content.Interactions` module
  (visibility checks, AP ID stamping, constraint detection) and
  `InteractionHelpers` module (generic LiveView toggle handlers), reducing ~336
  lines of duplication across likes, boosts, and three LiveViews

### Fixed

- **Unsafe integer parsing in feed toggle handlers** — replaced
  `String.to_integer` with `parse_id/1` to prevent crashes from malicious input
- **IDOR on feed item interactions** — added `feed_item_accessible?/2` check to
  verify user follows the remote actor before allowing like/boost
- **Board visibility bypass on like/boost** — added `article_visible_to_user?/2`
  to prevent interaction with articles in boards the user lacks permission to view
- **Remote Like/Announce on private content** — inbox handler now rejects
  incoming AP activities targeting articles in non-public or non-AP-enabled boards
- **Missing AP ID format validation** — remote boost schemas now validate that
  `ap_id` is an HTTP(S) URL
- **Missing `comment_liked` notification preference** in profile settings UI

### Security

- Board visibility enforcement on all like/boost toggle operations
- Feed item access validation requiring active follow relationship
- AP ID URL format validation on remote boost changesets
- Reject federation activities targeting non-federated content

[1.8.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.8.4
[1.8.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.8.3
[1.8.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.8.2
[1.8.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.8.1
[1.8.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.8.0
[1.7.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.7.1
[1.7.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.7.0
[1.6.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.6.0
[1.5.9]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.9
[1.5.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.8
[1.5.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.7
[1.5.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.6
[1.5.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.5
[1.5.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.4
[1.5.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.3
[1.5.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.2
[1.5.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.1
[1.5.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.5.0
[1.4.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.4.0
[1.3.58]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.58
[1.3.57]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.57
[1.3.56]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.56
[1.3.55]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.55
[1.3.54]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.54
[1.3.53]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.53
[1.3.52]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.52
[1.3.51]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.51
[1.3.50]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.50
[1.3.49]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.49
[1.3.46]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.46
[1.3.45]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.45
[1.3.44]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.44
[1.3.43]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.43
[1.3.42]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.42
[1.3.41]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.41
[1.3.40]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.40
[1.3.39]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.39
[1.3.38]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.38
[1.3.37]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.37
[1.3.36]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.36
[1.3.35]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.35
[1.3.34]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.34
[1.3.33]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.33
[1.3.32]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.32
[1.3.31]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.31
[1.3.30]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.30
[1.3.29]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.29
[1.3.28]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.28
[1.3.27]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.27
[1.3.26]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.26
[1.3.25]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.25
[1.3.24]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.24
[1.3.23]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.23
[1.3.22]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.22
[1.3.21]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.21
[1.3.20]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.20
[1.3.19]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.19
[1.3.18]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.18
[1.3.17]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.17
[1.3.16]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.16
[1.3.15]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.15
[1.3.14]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.14
[1.3.13]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.13
[1.3.12]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.12
[1.3.11]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.11
[1.3.10]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.10
[1.3.9]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.9
[1.3.8]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.8
[1.3.7]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.7
[1.3.6]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.6
[1.3.5]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.5
[1.3.4]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.4
[1.3.3]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.3
[1.3.2]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.2
[1.3.1]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.1
[1.3.0]: https://github.com/hiroshiyui/baudrate/releases/tag/v1.3.0
