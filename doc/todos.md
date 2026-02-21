# Planned Features

## Content
- [ ] Article editing and deletion (by author and moderators)
- [x] Comment schema and federation support (threaded, local + remote)
- [ ] Comment UI on article pages (local posting, display)
- [x] Markdown rendering for article body
- [ ] Article search
- [ ] Article pagination
- [ ] File attachments on articles

## Moderation
- [x] Admin settings UI (site name, registration mode)
- [x] Admin pending-users approval page
- [ ] Admin dashboard with user management (full)
- [ ] User banning / suspension
- [ ] Content reporting system
- [ ] Moderation log

## User Features
- [ ] Password reset / recovery
- [ ] Email integration (notifications, verification)
- [ ] User public profile pages
- [ ] User signatures

## Board Management
- [ ] Admin UI for creating / editing boards
- [x] Board visibility (public/private) with guest access control
- [ ] Board-level permissions (beyond visibility)
- [ ] Sub-board navigation

## System
- [ ] Closed registration mode (invite-only)
- [ ] API endpoints (JSON)
- [ ] Real-time updates via PubSub (new articles, comments)
- [ ] Search indexing

## ActivityPub Federation

ActivityPub implementation for federating with the Fediverse (Mastodon, Lemmy, etc.).
Built from scratch using Erlang's `:public_key`/`:crypto` and existing deps (Jason, Req).

**Actor mapping:** User → Person, Board → Group, Site → Organization, Article → Article
**URI scheme:** `/ap/users/:username`, `/ap/boards/:slug`, `/ap/site`, `/ap/articles/:slug`
**Context module:** `Baudrate.Federation` with sub-modules under `lib/baudrate/federation/`

### Phase 1 — Read-Only Endpoints (Discovery & Actor Profiles)

Expose actors and content as read-only ActivityPub/JSON-LD. No inbox, no signatures yet.

- [x] **WebFinger endpoint** (`/.well-known/webfinger`)
  - [x] Resolve `acct:username@host` → User actor URI
  - [x] Resolve `acct:!slug@host` → Board actor URI (Lemmy-compatible)
  - [x] Validate `resource` param as well-formed `acct:` URI; reject malformed input
- [x] **NodeInfo endpoints**
  - [x] `/.well-known/nodeinfo` — link to NodeInfo 2.1 document
  - [x] `/nodeinfo/2.1` — expose software name/version, protocols, usage stats
- [x] **Actor endpoints** (JSON-LD with `application/activity+json`)
  - [x] `/ap/users/:username` — Person actor with `publicKey`, `inbox`, `outbox`, `followers`
  - [x] `/ap/boards/:slug` — Group actor with `publicKey`, `inbox`, `outbox`, `followers`
  - [x] `/ap/site` — Organization actor for the instance
  - [x] Content-negotiation: serve JSON-LD for `Accept: application/activity+json`, redirect to HTML otherwise
- [x] **Outbox endpoints** (read-only, paginated `OrderedCollection`)
  - [x] `/ap/users/:username/outbox` — user's published articles as `Create(Article)` activities
  - [x] `/ap/boards/:slug/outbox` — board's articles as `Announce(Article)` activities
- [x] **Object endpoints**
  - [x] `/ap/articles/:slug` — Article object with `content`, `attributedTo`, `audience`, `context`
  - [x] Article `content` rendered as sanitized HTML from Markdown source
- [x] **Router pipeline** (`:activity_pub`)
  - [x] Accept `application/activity+json` and `application/ld+json`
  - [x] JSON parsing (Jason), no CSRF token, no session
  - [x] Rate limiting on all AP endpoints
  - [x] Scopes: `/.well-known/*`, `/ap/*`, `/nodeinfo/*`
- [x] **Schema — key pairs**
  - [x] Migration: add `ap_public_key` / `ap_private_key_encrypted` to users table
  - [x] Migration: add `ap_public_key` / `ap_private_key_encrypted` to boards table
  - [x] Migration: add site-level keypair to settings
  - [x] `Federation.KeyStore` — generate RSA-2048 keypairs on actor creation
  - [x] Private key encryption at rest with AES-256-GCM (follow `TotpVault` pattern)
- [x] **Security — Phase 1**
  - [x] All actor URIs use HTTPS only
  - [x] Rate limit WebFinger and actor lookups
  - [x] No private/draft content exposed via AP endpoints
  - [x] Validate all path parameters (username, slug) against expected formats

### Phase 2a — HTTP Signatures & Inbox (Minimum Viable Federation) ✓

Accept and verify incoming Follow activities. Bidirectional federation proof.

- [x] **HTTP Signature verification** (`Federation.HTTPSignature`)
  - [x] Parse `Signature` header (keyId, algorithm, headers, signature)
  - [x] Fetch remote actor's `publicKey` by dereferencing `keyId` URL
  - [x] Verify signature using `:public_key.verify/4`
  - [x] Cache fetched public keys with TTL (invalidate on `Update(Person)`)
  - [x] Reject expired signatures (enforce `Date` header within ±30s window)
  - [x] Require `(request-target)`, `host`, `date`, `digest` in signed headers
- [x] **HTTP Signature signing** (minimal, for `Accept(Follow)`)
  - [x] Sign outgoing requests with actor's RSA private key
  - [x] Include `(request-target)`, `host`, `date`, `digest` in signature
- [x] **Inbox endpoints**
  - [x] `/ap/users/:username/inbox` — POST, signature-verified
  - [x] `/ap/boards/:slug/inbox` — POST, signature-verified
  - [x] `/ap/inbox` — shared inbox for efficient delivery
- [x] **Activity handlers** (`Federation.InboxHandler`)
  - [x] `Follow` → record follower, auto-accept, send `Accept(Follow)` response
  - [x] `Undo(Follow)` → remove follower
  - [x] `Update(Person)` → refresh cached RemoteActor
  - [x] `Delete(actor)` → remove all their follower records
  - [x] `Create(Note/Article)`, `Like`, `Announce` → accept gracefully (202), log, discard (deferred to Phase 2b)
- [x] **Remote actor resolution** (`Federation.ActorResolver`)
  - [x] Fetch and cache remote actor profiles with 24h TTL
  - [x] Store display name, avatar URL, instance domain
  - [x] `RemoteActor` schema — `ap_id`, `username`, `domain`, `display_name`, `avatar_url`, `public_key_pem`, `inbox`, `shared_inbox`
  - [x] Force-refresh on `Update(Person)` activities
- [x] **Schema — federation fields**
  - [x] Migration: `remote_actors` table with indexes
  - [x] Migration: `followers` table (`actor_uri`, `follower_uri`, `accepted_at`, `activity_id`)
  - [x] Migration: add `ap_id` (nullable, unique where not null) to articles
  - [x] Migration: add `remote_actor_id` (nullable FK) to articles
- [x] **Safe HTTP client** (`Federation.HTTPClient`)
  - [x] SSRF protection: reject private/loopback IPs
  - [x] HTTPS only, configurable timeouts, redirect limits
  - [x] Response body size cap (256 KB)
  - [x] Instance-identifying User-Agent header
- [x] **Minimal delivery** (`Federation.Delivery`)
  - [x] Send `Accept(Follow)` via signed HTTP POST
  - [x] Async delivery via `Task.Supervisor`
- [x] **Follower context** (`Federation` module)
  - [x] `create_follower/3`, `delete_follower/2`, `follower_exists?/2`
  - [x] `list_followers/1`, `count_followers/1`
  - [x] `delete_followers_by_remote/1` (for actor deletion)
- [x] **Actor JSON-LD updates**
  - [x] Added `endpoints.sharedInbox` to user and board actors
- [x] **Security — Phase 2a**
  - [x] **HTML sanitization module** (`Federation.Sanitizer`)
    - [x] Allowlist-based HTML sanitizer for all incoming federated content
    - [x] Strip `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, `<form>`, `<input>`, `<textarea>`, event handlers
    - [x] Allow safe subset: `<p>`, `<br>`, `<a>`, `<strong>`, `<em>`, `<code>`, `<pre>`, `<blockquote>`, `<ul>`, `<ol>`, `<li>`, `<h1>`–`<h6>`, `<hr>`, `<del>`
    - [x] Sanitize `<a href>` — only allow `http:`/`https:` schemes, add `rel="nofollow noopener noreferrer"`
    - [x] Applied **before database storage**, not at render time
  - [x] **Input validation** (`Federation.Validator`)
    - [x] All AP IDs validated as HTTPS URLs with valid hostnames
    - [x] Activity validation: required fields (`type`, `actor`, `object`)
    - [x] Size limits: reject payloads > 256 KB, content fields > 64 KB
    - [x] Reject activities from blocked domains (domain blocklist via settings)
  - [x] **Anti-abuse**
    - [x] Per-domain rate limiting on inbox (60 req/min per domain)
    - [x] Reject self-referencing actor URIs (actor claiming to be local)
    - [x] Validate `attributedTo` matches activity `actor`
    - [x] Log all rejected activities with reason for audit
  - [x] **Fetch safety**
    - [x] Remote HTTP fetches: HTTPS only, follow max 3 redirects
    - [x] DNS rebinding protection — reject private/loopback IPs (SSRF prevention)
    - [x] Timeout all remote fetches (10s connect, 30s total)
    - [x] User-Agent header identifying the instance

### Phase 2b — Content Activities ✓

Handle incoming content activities via `InboxHandler`. Includes comment system,
likes, announces, soft-delete, and Undo variants.

- [x] `Create(Note)` → store as remote comment (if `inReplyTo` matches local article)
  - [x] Threading support: replies to comments set `parent_id`
  - [x] Attribution validation prevents impersonation
  - [x] HTML sanitized via `Federation.Sanitizer` before storage
- [x] `Create(Article)` → store as remote article in target board (if `audience`/`to`/`cc` matches)
  - [x] Board resolved from audience URIs via `resolve_board_from_audience/1`
  - [x] Auto-generated slug from title
- [x] `Announce` → record boost/share in `announces` table
- [x] `Like` → record like/favorite in `article_likes` table
  - [x] Gracefully ignores likes for non-local articles
- [x] `Delete` → soft-delete matching remote article or comment
  - [x] Authorship check via `remote_actor_id` prevents unauthorized deletion
- [x] `Update` → update matching remote article or comment content
  - [x] Authorship check via `remote_actor_id` prevents unauthorized modification
- [x] `Undo(Like)` → remove article like by inner activity's `ap_id`
- [x] `Undo(Announce)` → remove announce by inner activity's `ap_id`
- [x] Idempotency: duplicate `ap_id` on any Create/Like/Announce returns `:ok`

### Phase 3 — Delivery (Sending Activities) ✓

Push local activities to followers' inboxes. Full bidirectional federation.

- [x] **HTTP Signature signing** (`Federation.HTTPSignature`)
  - [x] Sign outgoing requests with actor's private key
  - [x] Include `(request-target)`, `host`, `date`, `digest` headers in signature
  - [x] Generate `Digest` header (SHA-256 of request body)
- [x] **Activity publisher** (`Federation.Publisher`)
  - [x] Build ActivityStreams JSON for local activities
  - [x] `Create(Article)` — when user publishes an article
  - [x] `Update(Article)` — when author edits an article
  - [x] `Delete(Article)` — when article is deleted
  - [x] `Create(Note)` — when user posts a comment
  - [x] `Announce` — when board relays an article to followers
- [x] **Delivery system** (`Federation.Delivery`)
  - [x] Resolve delivery targets: follower inboxes + mentioned actor inboxes
  - [x] Shared inbox deduplication (one delivery per shared inbox per activity)
  - [x] DB-backed delivery queue with `DeliveryJob` schema and `DeliveryWorker` GenServer
  - [x] Exponential backoff on failed deliveries (1m, 5m, 30m, 2h, 12h, 24h)
  - [x] Max retry attempts (configurable, default 6)
  - [x] Track delivery status per recipient (pending → delivered/failed/abandoned)
- [x] **Followers collection**
  - [x] `/ap/users/:username/followers` — `OrderedCollection`
  - [x] `/ap/boards/:slug/followers` — `OrderedCollection` (public boards only)
  - [x] Follower counts visible; individual followers list included
- [x] **Security — Phase 3**
  - [x] Private keys never logged or exposed in error messages
  - [x] Delivery queue respects domain blocks (skip blocked domains)
  - [x] Outgoing content sanitized (no internal metadata leaks)
  - [x] Delivery failures don't expose internal error details to remote servers

### Phase 4a — Mastodon & Lemmy Compatibility ✓

Handle real-world interop quirks from Mastodon and Lemmy without breaking
existing behavior.

- [x] **Sanitizer: `<span>` allowlist**
  - [x] Add `span` to safe tags
  - [x] Preserve safe class values: `h-card`, `hashtag`, `mention`, `invisible`
  - [x] Strip unsafe class values from `<span>` tags
- [x] **Mastodon compatibility**
  - [x] Handle `attributedTo` as array (extract first binary URI)
  - [x] Handle `sensitive` + `summary` as content warnings (prepend `[CW: summary]`)
  - [x] Add `to`/`cc` addressing on outbound Note objects (required by Mastodon for visibility)
  - [x] Add `cc` with board actor URIs on outbound Article objects (improves discoverability)
- [x] **Lemmy compatibility**
  - [x] Handle `Page` object type as `Article` for `Create` and `Update`
  - [x] Handle `Announce` with embedded object maps (extract inner `id`)
  - [x] `!board@host` WebFinger addressing (implemented in Phase 1)

### Phase 4b — Advanced Features & Remaining Compatibility

Cross-platform compatibility, moderation tools, and admin controls.

- [ ] **Mastodon compatibility (remaining)**
  - [ ] Article → Note fallback: send `Note` summary + link for Mastodon followers
  - [ ] Support `Hashtag` objects in `tag` array
  - [ ] Render incoming `Note` objects as comments
- [ ] **Lemmy compatibility (remaining)**
  - [ ] Board → Group actor: `Announce` wrapping for community-style federation
  - [ ] Cross-post detection and deduplication
- [ ] **Moderation tools**
  - [ ] Domain blocklist management (admin UI)
  - [ ] Instance allowlist mode (federate only with approved instances)
  - [ ] Remote content reporting → local moderation queue
  - [ ] `Flag` activity: send reports to remote instance admins
  - [ ] `Block` activity: communicate user-level blocks to remote instances
  - [ ] Bulk actions: block/silence entire instances
- [ ] **Admin federation dashboard**
  - [ ] Known instances list with stats (followers, content, last seen)
  - [ ] Delivery queue status and retry management
  - [ ] Federation health monitoring (failed deliveries, error rates)
  - [ ] Toggle federation on/off per board
  - [ ] Instance-level federation kill switch
- [ ] **Performance & scalability**
  - [ ] Consider migrating delivery to Oban for persistent job queues
  - [ ] Shared inbox aggregation to reduce delivery volume
  - [ ] Background worker for stale actor cache cleanup
  - [ ] Database indexes on `ap_id`, `remote_actor_id`, `domain` columns
- [ ] **Security — Phase 4**
  - [ ] Admin-only federation settings (not moderator-accessible)
  - [ ] Authorized fetch mode (require signatures on GET requests, optional)
  - [ ] Key rotation mechanism for actor keypairs
  - [ ] Regular audit of domain blocklist against known-bad-actor lists
  - [ ] Content-Security-Policy headers for pages displaying remote content
  - [ ] Sanitize remote actor display names (prevent homograph attacks)
