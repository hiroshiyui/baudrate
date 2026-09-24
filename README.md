
<p align="center">
  <img src="priv/static/images/icon-192.png" alt="Baudrate" width="192" height="192">
</p>

# Baudrate: ActivityPub-enabled Bulletin Board System

## About

Baudrate is an ActivityPub-enabled BBS built with [Elixir](https://elixir-lang.org/) and [Phoenix](https://www.phoenixframework.org/).

It aims to be **a boring but friendly environment for online discussion**
([ADR 0056](doc/adr/0056-boring-but-friendly.md)). Boring: nothing here is
ranked by engagement, there is no river of posts, and no score compares one
person or board with another — a forum that is exciting to *open* is usually
exciting because someone is fighting in it. Friendly: blocks, sanctions,
domain blocks and published rules are load-bearing, and no page contacts a
third party on your behalf.

### Features

- **Real-time UI** with Phoenix LiveView
- **Hierarchical boards** -- nested board structure with breadcrumb navigation, sub-board display, per-board role-based access (`min_role_to_view`, `min_role_to_post`), and board moderator management
- **Guest browsing** -- guest-visible boards and articles are accessible without login
- **Cross-posted articles** -- articles can span multiple boards, with author-controlled forwarding (`forwardable` toggle) and cross-board forwarding by any user; authors can remove their articles from specific boards
- **Threaded comments** -- with support for remote replies via ActivityPub, threading correctly in both directions; comments new since your last visit are marked, with a link to the first of them on whatever page it is, and every comment has a permanent address that opens the right page
- **Editable comments, with a public history** -- an author can fix their own comment at any time; every edit keeps what it replaced, an "edited" marker links to a diff anyone reading the thread can open, and the change federates as `Update(Note)`. Only the author may edit: moderation's tool is deletion, because editing someone else's words under their name cannot be told apart from their own
- **Image descriptions** -- describe any image you upload, on articles, comments and timeline replies; the description travels with the image as the ActivityPub attachment `name`, which is what other fediverse clients show as alt text, and a description a remote instance sent us is kept and shown
- **Drafts** -- an unfinished article is saved to your account as you write, so a post begun on one device can be finished on another; the browser-side autosave stays alongside it, because that is the half that still works when the connection does not
- **Content warnings** -- an optional warning on any article, comment or reply; content behind one stays collapsed until the reader opens it, and a warning from another instance is kept as a warning rather than pasted into the text
- **Mentions** -- `@name` for members here and `@user@domain` for anyone on the fediverse; a remote mention is delivered to the person named, and never carries a post out of a board that does not federate
- **Role-based access control** -- admin, moderator, user, and guest roles with per-board permission levels
- **Board moderation** -- board moderators can pin/lock threads and delete articles/comments
- **TOTP two-factor authentication** -- required for admin/moderator, optional for users, with recovery codes
- **WebAuthn / FIDO2 security keys** -- register hardware security keys or passkeys (e.g. YubiKey, Touch ID) for second-factor and admin sudo-mode re-verification
- **Account security** -- password change and sign out everywhere behind step-up re-authentication; a list of your own sessions (browser and dates, with the addresses and a per-session sign-out once you confirm your identity); always-delivered notices when a password, second factor, or session changes
- **Account recovery without email** -- this instance sends no mail, so recovery codes are the way back and they can be replaced from your profile at any time. Past them, recovery is anchored on an OpenPGP key: a member registers an address and a public key from their own session, an admin verifies a signed message against that key **in their own mail client**, and only then can a single-use reset link be issued. The instance issues the one-line challenge the member signs — single-use, expiring, and spent by the verification or the link — with a mail ready to paste in the member's own language ([ADR 0067](doc/adr/0067-the-instance-issues-the-challenge-the-admin-still-verifies-it.md)). A confirmed account carries an **OpenPGP key confirmed** badge on its profile, which says what was checked and never that the site verified who anybody is ([ADR 0068](doc/adr/0068-a-profile-says-what-was-checked-not-that-someone-is-verified.md)). Baudrate sends no mail, verifies no signature and fetches no key ([ADR 0058](doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md))
- **Account migration** -- aliases (`alsoKnownAs`) and ActivityPub `Move` to another server, with a 24-hour cooling-off and warning banner, a destination check at request and send time, and a read-only old account whose redirect can be removed; followers of accounts that move elsewhere are refollowed properly
- **Data export** -- download a JSON + media archive of what you wrote and own, designed against data leakage: TOTP-gated, 24-hour cooling-off with a site-wide warning banner, re-authentication for every download, and no archive ever stored on the server
- **Deleting your account** -- from your own settings, behind your password; it waits seven days and signing in cancels it. The account becomes a tombstone rather than a deleted row, so the discussions it took part in stay intact: your posts remain under "deleted account" unless you choose to withdraw them, your username stays reserved, and other servers are told it is gone ([ADR 0072](doc/adr/0072-a-deleted-account-leaves-a-tombstone.md))
- **Privacy settings** -- mute a whole server or words for your own views (a matching post is folded, never removed, and nobody is told), approve new followers yourself (a request is a follower nowhere until you do), and opt out of search engines and the member search while your pages stay public ([ADR 0073](doc/adr/0073-privacy-settings-shape-what-a-member-sees-and-who-finds-them.md))
- **ActivityPub federation** -- federate with Mastodon, Lemmy, and the Fediverse
  - WebFinger and NodeInfo discovery
  - Incoming follows, comments, likes, boosts, updates, deletes, and Flag reports
  - Outbound delivery of articles, deletes, announces, and Flag reports to remote instances
  - Threaded conversations: a reply names the comment it answers, so discussions keep their shape on Mastodon instead of arriving flat
  - Comments and polls are fetchable objects with URIs of their own (`/ap/comments/:id`, `/ap/polls/:id`)
  - Profile and board edits reach followers as `Update(Person)` / `Update(Group)`; a closed poll publishes its final counts
  - DB-backed delivery queue written in the same transaction as the post, sent as soon as it commits, with exponential backoff retry and a per-instance circuit breaker
  - Inbound activities stored and acknowledged at once, then processed in order per remote account with bounded concurrency
  - Shared inbox deduplication for efficient delivery
  - HTTP Signature verification and signing, HTML sanitization, SSRF-safe fetches
  - Domain blocklist and allowlist modes for instance-level federation control
  - Federation kill switch and per-board federation toggle
  - Cross-post deduplication for articles arriving via multiple board inboxes
  - Mastodon compatibility: `attributedTo` arrays, `to`/`cc` addressing, `<span>` tag preservation, `Mention` and hashtag tags
  - Lemmy compatibility: `Page` object type, `Announce` with embedded objects, group-relayed activities (FEP-1b12), `!board@host` WebFinger
- **Watching** -- watch a board to hear about its new threads, or a thread to hear about its new comments; nothing is watched unless you turn it on, and `/watching` lists everything you watch
- **Your followers** -- `/followers` lists who follows you, here and on other servers, and lets you remove any of them (an account elsewhere is sent `Reject(Follow)`); the count is shown to you and nobody else
- **Personal timeline** -- follow remote accounts and local users from `/following`, and read their posts at `/timeline`, merged with local articles from people you follow and with comments on threads you took part in; reply, like, boost, or forward an item to a board. Non-public posts stay out: a boost of a followers-only post is never shown, and a direct message never appears
- **Link previews** -- server-side Open Graph / Twitter Card metadata fetching with image proxy for articles, comments, and DMs
- **No page contacts a third party on your behalf** -- every remote image, avatar and preview thumbnail is re-encoded and served from this host, so reading a federated thread discloses nothing to the instance that wrote it; the one embed, the YouTube player, loads only when you press play, from a poster stored locally
- **Nothing is ranked by engagement** -- there is no "popular", "trending" or "hot" page, no river of posts across boards, and no post count comparing one board with another; the home page lists the boards in the order the admin chose. A ranking is a feedback loop, not a measurement, and engagement cannot tell an argument from a conversation ([ADR 0054](doc/adr/0054-attention-follows-the-board-not-a-ranking.md))
- **User public profiles** -- public profile pages with stats, recent articles, and clickable author names
- **Avatar system** -- upload, crop, WebP conversion with server-side security
- **Flexible registration** -- open, approval-required, or invite-only modes with admin-managed invite codes; registering signs you in once you have saved your recovery codes, and a one-time first-visit step asks for a display name and picture. An account waiting for approval is told what it may do meanwhile, and told again when it is approved
- **A door that costs something to knock on** -- registering takes a proof-of-work challenge the browser solves while the form is filled in, self-hosted rather than a CAPTCHA that would hand a third party every registrant's address; admins can ban an address or network from registering and signing in (never from reading), and ban an account together with the accounts it invited, ticking each one after seeing it ([ADR 0063](doc/adr/0063-the-door-is-defended-by-work-not-by-a-third-party.md))
- **New accounts are slowed down, not shut out** -- until an account is a few days old and has a few posts that were not removed, it may put one link and one image in a post, post ten times an hour, add no link or image to the signature shown under its articles, and send direct messages only to people who follow it, who wrote to it first, or who are staff; the site works this out each time rather than storing it, bots and staff are never limited, and a member who runs into a limit is told when it lifts ([ADR 0064](doc/adr/0064-a-new-account-is-slowed-down-not-shut-out.md))
- **A queue in front of new accounts, and filters an admin can write mid-wave** -- an admin can have each account's first posts wait for a moderator, and a held post is a submission of its own rather than hidden content, so nothing can leak it; approving publishes it as its author, once. Filters on words, text and linked domains refuse, hold or report a post when it is written and when it is edited, and drop or report what arrives from other servers; they are never regular expressions, fold the usual evasions, never tell a spammer which word failed, and never read direct messages ([ADR 0065](doc/adr/0065-what-waits-for-review-is-not-content-yet.md))
- **Admin dashboard** -- one page with what is waiting for review, member counts, federation figures and each health check's status, so running the site does not need a shell ([ADR 0074](doc/adr/0074-the-dashboard-reads-the-health-checks-behind-the-admin-session.md)); plus moving an article to another board and emptying a board before deleting it, board order set with move up and move down, site announcements shown on every page and optionally sent as a notification, a contact line in the footer, site settings, registration mode, pending user approval, federation, a delivery queue page with per-server retry and abandon and the open circuits, moderation queue, held posts, moderation log, invite code management, IP bans, content filters
- **Rate limiting** on login, TOTP, registration, avatar uploads, and federation endpoints
- **Security hardened** -- HSTS, CSP, signed + encrypted cookies, and secrets encrypted at rest under per-class keys that can be rotated without locking anyone out
- **Retention** -- hourly purges destroy a deleted article or comment, its revisions and its image files 90 days after deletion, untouched timeline items after 90 days, and remote boost records after 180 days; anything a moderation report points at is kept at any age
- **Notifications** -- real-time in-app notifications for replies, mentions, follows, likes, boosts, closed polls, moderator actions and account-security events, with likes and boosts of one post grouped, a filter by kind, and links that open the page a comment is on; admins are also told when a health check has been failing for over an hour, so a backup that stopped does not stay quiet
- **Direct messages** -- 1-on-1 conversations with read cursors, mute controls, and federated delivery; a push when one arrives that names the sender and never the text; private images between members of this site, shown only to the two people in the conversation; and a search of your own conversations
- **Search** -- full-text search across articles and comments with CJK support, sorted by relevance or date, with a board and date filter and the same `author:` / `board:` / `tag:` / `has:` / `before:` / `after:` operators on both tabs. A search has to name something to search within: a date range on its own is not a search, it is a list of everything recent
- **Polls** -- single/multi-choice polls with anonymous voting, expiration, and denormalized counters
- **Bookmarks** -- bookmark articles and comments for later reference
- **Emoji autocomplete** -- type `:shortcode` in any textarea for instant emoji suggestions
- **Markdown toolbar** -- toolbar with formatting shortcuts for article and comment editing
- **Syndication feeds** -- RSS 2.0 and Atom for the site, each board, each user and each tag; every page carries and advertises the feed for the thing you are looking at
- **Findable from outside** -- a `sitemap.xml` that invites only what a guest can already see, a `robots.txt` that blocks machine endpoints rather than pages, and a self-referencing canonical URL and description on every page. Unlisted articles stay out of both, and member profiles are crawlable but never enumerated ([ADR 0057](doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md))
- **RSS/Atom bot accounts** -- admin-managed feed bots that periodically fetch RSS 0.9x/2.0, RSS 1.0 (RDF), Atom, and JSON Feed sources and post articles to target boards; configurable fetch interval, include and exclude patterns, a first fetch that posts only the newest few entries instead of the whole backlog, a dry run that shows what the next fetch would post, conditional requests so an unchanged feed costs a 304, per-bot bio and profile fields, automatic favicon avatar fetching, and exponential backoff that switches a bot off and tells the admins after ten failures in a row
- **User blocking, muting and reporting** -- block local or remote accounts to stop replies, likes, boosts, follows and messages in both directions; mute to hide content locally; report posts, comments, timeline items, received messages and accounts to moderators
- **Push notifications** -- PWA with Web Push support and service worker
- **Installable, and it survives a dropped connection** -- the service worker is registered on every page, independently of whether push is configured, and serves an offline page when a navigation cannot reach the server. It caches that page and the fingerprinted CSS/JS and **nothing else**: no article, comment or message is written to a reader's disk, because a cache on a forum is a record of what somebody read on a device that may not be theirs alone ([ADR 0059](doc/adr/0059-the-service-worker-caches-the-shell-and-never-content.md))
- **Web Share** -- share the current page to other apps via the OS-level share sheet (smartphone / installed PWA), and copy the link instead on the desktop browsers that have no share sheet
- **Follow from your instance** -- a fediverse visitor on a profile or a federated board enters their own handle and is handed a link to their own server's follow page, discovered from its WebFinger subscribe template rather than guessed; the handle is always there to copy as well
- **Internationalization** -- Gettext with zh_TW and ja_JP locales, Accept-Language auto-detection, and a footer language switcher any visitor can use; the choice is kept in a cookie for a year, and works with JavaScript off. Times are shown in each member's own time zone (or the site's), and the footer says which

## Setup

### Prerequisites

The quickest route is the **dev container** in `.devcontainer/`: the image CI
tests in, pinned by digest, with PostgreSQL 15 beside it, so a container
runtime is all you need. See [CONTRIBUTING.md](CONTRIBUTING.md). Otherwise:

- Elixir 1.19 and Erlang/OTP 28 — the versions in `.tool-versions`, which is
  what CI, the release build and production all install
- PostgreSQL 15+
- libvips (for image processing)
- Rust toolchain (to compile the scraper, Ammonia, and feedparser-rs NIFs;
  there are no precompiled binaries, on purpose)

Development and test databases default to user `baudrate_db_user`, password
`baudrate_database` on `localhost`; `PGUSER`, `PGPASSWORD`, `PGHOST` and
`PGPORT` override them.

### Installation

```bash
# Clone the repository
git clone https://github.com/hiroshiyui/baudrate.git
cd baudrate

# Install dependencies
mix setup

# Generate a self-signed cert for local HTTPS
mix phx.gen.cert

# Start the server
mix phx.server
```

The app will be available at https://localhost:4001.

On first visit, you will be redirected to `/setup` to create the initial admin account.

### Environment Variables

For production, you will need to configure:

- `DATABASE_URL` -- PostgreSQL connection string
- `SECRET_KEY_BASE` -- at least 64 bytes of random data (`mix phx.gen.secret`)
- `PHX_HOST` -- your production hostname
- `INSTALLATION_KEY` -- required until the setup wizard is completed; without
  it every page answers 503 (see the
  [SysOp Guide](doc/sysop.md#installation-key))
- `RELEASE_COOKIE` -- the server's own Erlang cookie; a release refuses to start
  with the public one it ships (see the
  [SysOp Guide](doc/sysop.md#erlang-distribution-and-the-remote-console))

Every release is also built, smoke-tested and attested in CI and attached to
its GitHub release, for installing on a host without a toolchain; the Ansible
deploy builds the tag on the server (see the
[SysOp Guide](doc/sysop.md#release-artifacts)).

Recommended for operations: `HEALTH_DETAIL_PORT` serves a detailed health
report (database, federation queues, workers, disk, backup age, encryption
keys) on `127.0.0.1` only, and tells the admins when one of them has been
failing for over an hour. `LOG_FORMAT=json` switches the logs to one JSON
object per line (see the [SysOp Guide](doc/sysop.md#detailed-health-report)).

TOTP secrets, recovery-code hashes, ActivityPub actor private keys and the Web
Push key are encrypted or hashed at rest. Their keys default to being derived
from `SECRET_KEY_BASE`, which then cannot be rotated; `BAUDRATE_AUTH_KEYS` and
`BAUDRATE_SIGNING_KEYS` give each class its own rotatable key (see the
[SysOp Guide](doc/sysop.md#encryption-keys)).

## Documentation

- [SysOp Guide](doc/sysop.md) — installation, configuration, and maintenance for system operators
- [Development Guide](doc/development.md) — architecture, project structure, and development notes
- [Architecture Decision Records](doc/adr/README.md) — why the architecture is the way it is: rationale, alternatives, and trade-offs
- [AP API Reference](doc/api.md) — ActivityPub and public API endpoint documentation
- [Troubleshooting](doc/troubleshooting.md) — common issues and solutions
- [Contributing](CONTRIBUTING.md) — setting up, running the tests, and making a change
- [Security Policy](SECURITY.md) — how to report a vulnerability (privately, by email)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## License

This project is licensed under the [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html) (AGPL-3.0).

## Acknowledgements

Built with these excellent open-source projects:

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
- [Tailwind CSS](https://tailwindcss.com/) + [DaisyUI](https://daisyui.com/)
- [NimbleTOTP](https://hexdocs.pm/nimble_totp/)
- [wax_](https://hexdocs.pm/wax_/) (WebAuthn / FIDO2 relying party)
- [Hammer](https://hexdocs.pm/hammer/)
- [MDEx](https://hexdocs.pm/mdex/) (Markdown rendering, CommonMark + GFM via comrak)
- [Req](https://hexdocs.pm/req/) (HTTP client for federation)
- [scraper](https://crates.io/crates/scraper) (Rust HTML parser NIF for link preview extraction and link counting, built on [html5ever](https://github.com/servo/html5ever))
- [url](https://crates.io/crates/url) (the WHATWG URL parser behind it, from Servo, which resolves each link the way a browser would)
- [Ammonia](https://crates.io/crates/ammonia) (Rust HTML sanitizer)
- [feedparser-rs](https://crates.io/crates/feedparser-rs) (Rust feed parser NIF for RSS/Atom/JSON Feed)
- [Rustler](https://crates.io/crates/rustler) (Rust NIF bindings for Erlang/Elixir)
- [regex](https://crates.io/crates/regex) (Rust regular expressions)
