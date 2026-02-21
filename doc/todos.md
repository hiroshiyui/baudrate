# Planned Features

## Content
- [ ] Article editing and deletion (by author and moderators)
- [ ] Comment system on articles
- [ ] Markdown rendering for article body
- [ ] Article search
- [ ] Article pagination
- [ ] File attachments on articles

## Moderation
- [ ] Admin dashboard with user management
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
- [ ] Board-level permissions
- [ ] Sub-board navigation

## System
- [ ] Closed registration mode (invite-only)
- [x] Admin settings UI (registration mode, site name, etc.)
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
  - [ ] Content-negotiation: serve JSON-LD for `Accept: application/activity+json`, redirect to HTML otherwise
- [x] **Outbox endpoints** (read-only, paginated `OrderedCollection`)
  - [x] `/ap/users/:username/outbox` — user's published articles as `Create(Article)` activities
  - [x] `/ap/boards/:slug/outbox` — board's articles as `Announce(Article)` activities
- [x] **Object endpoints**
  - [x] `/ap/articles/:slug` — Article object with `content`, `attributedTo`, `audience`, `context`
  - [ ] Article `content` rendered as sanitized HTML from Markdown source
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

### Phase 2 — HTTP Signatures & Inbox (Receiving Activities)

Accept and verify incoming activities. Follow/unfollow, receiving remote posts.

- [ ] **HTTP Signature verification** (`Federation.HTTPSignature`)
  - [ ] Parse `Signature` header (keyId, algorithm, headers, signature)
  - [ ] Fetch remote actor's `publicKey` by dereferencing `keyId` URL
  - [ ] Verify signature using `:public_key.verify/4`
  - [ ] Cache fetched public keys with TTL (invalidate on `Update(Person)`)
  - [ ] Reject expired signatures (enforce `Date` header within ±30s window)
  - [ ] Require `(request-target)`, `host`, `date`, `digest` in signed headers
- [ ] **Inbox endpoints**
  - [ ] `/ap/users/:username/inbox` — POST, signature-verified
  - [ ] `/ap/boards/:slug/inbox` — POST, signature-verified
  - [ ] `/ap/inbox` — shared inbox for efficient delivery
- [ ] **Activity handlers** (`Federation.InboxHandler`)
  - [ ] `Follow` → record follower, send `Accept(Follow)` response
  - [ ] `Undo(Follow)` → remove follower
  - [ ] `Create(Note)` → store as remote comment (if `inReplyTo` matches local article)
  - [ ] `Create(Article)` → store as remote article in target board (if `audience` matches)
  - [ ] `Announce` → record boost/share
  - [ ] `Like` → record like/favorite
  - [ ] `Delete` → soft-delete matching remote content
  - [ ] `Update` → update matching remote content
- [ ] **Remote actor resolution** (`Federation.ActorResolver`)
  - [ ] Fetch and cache remote actor profiles
  - [ ] Store display name, avatar URL, instance domain
  - [ ] `RemoteActor` schema — `ap_id`, `username`, `domain`, `display_name`, `avatar_url`, `public_key`, `inbox`, `shared_inbox`
  - [ ] Periodic refresh of cached actor data
- [ ] **Schema — federation fields**
  - [ ] Migration: `remote_actors` table
  - [ ] Migration: `followers` table (`actor_uri`, `follower_uri`, `accepted_at`)
  - [ ] Migration: add `ap_id` (nullable) to articles for remote content
  - [ ] Migration: add `remote_actor_id` (nullable FK) to articles/comments
- [ ] **Security — Phase 2**
  - [ ] **HTML sanitization module** (`Federation.Sanitizer`)
    - [ ] Allowlist-based HTML sanitizer for all incoming federated content
    - [ ] Strip `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, event handlers
    - [ ] Allow safe subset: `<p>`, `<br>`, `<a>`, `<strong>`, `<em>`, `<code>`, `<pre>`, `<blockquote>`, `<ul>`, `<ol>`, `<li>`, `<h1>`–`<h6>`
    - [ ] Sanitize `<a href>` — only allow `http:`/`https:` schemes, add `rel="nofollow noopener"`
    - [ ] Applied **before database storage**, not at render time
  - [ ] **Input validation**
    - [ ] All AP IDs validated as HTTPS URLs with valid hostnames
    - [ ] JSON payloads validated against expected ActivityStreams schemas
    - [ ] Size limits: reject payloads > 256 KB, content fields > 64 KB
    - [ ] Reject activities from blocked domains (domain blocklist)
  - [ ] **Anti-abuse**
    - [ ] Per-domain rate limiting on inbox
    - [ ] Reject self-referencing actor URIs (actor claiming to be local)
    - [ ] Validate `attributedTo` matches activity `actor`
    - [ ] Log all rejected activities with reason for audit
  - [ ] **Fetch safety**
    - [ ] Remote HTTP fetches: HTTPS only, follow max 3 redirects (same-host only)
    - [ ] DNS rebinding protection — reject private/loopback IPs (SSRF prevention)
    - [ ] Timeout all remote fetches (10s connect, 30s total)
    - [ ] User-Agent header identifying the instance

### Phase 3 — Delivery (Sending Activities)

Push local activities to followers' inboxes. Full bidirectional federation.

- [ ] **HTTP Signature signing** (`Federation.HTTPSignature`)
  - [ ] Sign outgoing requests with actor's private key
  - [ ] Include `(request-target)`, `host`, `date`, `digest` headers in signature
  - [ ] Generate `Digest` header (SHA-256 of request body)
- [ ] **Activity publisher** (`Federation.Publisher`)
  - [ ] Build ActivityStreams JSON for local activities
  - [ ] `Create(Article)` — when user publishes an article
  - [ ] `Update(Article)` — when author edits an article
  - [ ] `Delete(Article)` — when article is deleted
  - [ ] `Create(Note)` — when user posts a comment
  - [ ] `Announce` — when board relays an article to followers
- [ ] **Delivery system** (`Federation.Delivery`)
  - [ ] Resolve delivery targets: follower inboxes + mentioned actor inboxes
  - [ ] Shared inbox deduplication (one delivery per shared inbox per activity)
  - [ ] Async delivery via `Task.Supervisor` (no Oban initially)
  - [ ] Exponential backoff on failed deliveries (1m, 5m, 30m, 2h, 12h, 24h)
  - [ ] Max retry attempts (configurable, default 10)
  - [ ] Track delivery status per recipient
- [ ] **Followers collection**
  - [ ] `/ap/users/:username/followers` — paginated `OrderedCollection`
  - [ ] `/ap/boards/:slug/followers` — paginated `OrderedCollection`
  - [ ] Follower counts visible; individual followers list optional (privacy setting)
- [ ] **Security — Phase 3**
  - [ ] Private keys never logged or exposed in error messages
  - [ ] Delivery queue respects domain blocks (skip blocked domains)
  - [ ] Outgoing content sanitized (no internal metadata leaks)
  - [ ] Audit log for all outgoing activities
  - [ ] Delivery failures don't expose internal error details to remote servers

### Phase 4 — Advanced Features & Compatibility

Cross-platform compatibility, moderation tools, and admin controls.

- [ ] **Mastodon compatibility**
  - [ ] Article → Note fallback: send `Note` summary + link for Mastodon followers
  - [ ] Handle Mastodon-specific extensions (`sensitive`, `attachment`, `tag`)
  - [ ] Support `Hashtag` objects in `tag` array
  - [ ] Render incoming `Note` objects as comments
- [ ] **Lemmy compatibility**
  - [ ] Board → Group actor: `Announce` wrapping for community-style federation
  - [ ] Handle Lemmy's `Page` object type (treat as Article)
  - [ ] Support `!board@host` WebFinger addressing
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
