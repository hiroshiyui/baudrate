# ActivityPub API Reference

Baudrate exposes an ActivityPub-compatible API for federation and programmatic
access. All endpoints live under `/ap/` (objects and actors) or
`/.well-known/` (discovery). No separate REST API exists — the AP endpoints
**are** the public API.

**Base URL:** `https://<your-instance>`

---

## Table of Contents

- [Global Behavior](#global-behavior)
- [Content Negotiation](#content-negotiation)
- [Discovery](#discovery)
  - [WebFinger](#webfinger)
  - [NodeInfo](#nodeinfo)
- [Actors](#actors)
  - [Person (User)](#person-user)
  - [Group (Board)](#group-board)
  - [Organization (Site)](#organization-site)
- [Objects](#objects)
  - [Article](#article)
- [Collections](#collections)
  - [User Outbox](#user-outbox)
  - [Board Outbox](#board-outbox)
  - [User Followers](#user-followers)
  - [Board Followers](#board-followers)
  - [User Following](#user-following)
  - [Board Following](#board-following)
  - [Boards Index](#boards-index)
  - [Article Replies](#article-replies)
  - [Search](#search)
- [Inboxes](#inboxes)
  - [Shared Inbox](#shared-inbox)
  - [User Inbox](#user-inbox)
  - [Board Inbox](#board-inbox)
  - [HTTP Signature Requirements](#http-signature-requirements)
  - [Supported Activity Types](#supported-activity-types)
  - [DM Detection](#dm-detection)
- [Error Responses](#error-responses)
- [Rate Limits](#rate-limits)
- [Baudrate Extensions](#baudrate-extensions)

---

## Global Behavior

| Aspect | Detail |
|--------|--------|
| **Federation kill switch** | Setting `ap_federation_enabled` (admin panel). When disabled, all `/ap/*` endpoints return 404. Discovery endpoints remain available. |
| **CORS** | `Access-Control-Allow-Origin: *` on all GET `/ap/*` responses. `OPTIONS` returns 204 with allowed methods `GET, HEAD, OPTIONS`. |
| **Vary** | Content-negotiated endpoints include `Vary: Accept` for proper cache behavior. |
| **Authorized fetch** | Optional setting `ap_authorized_fetch`. When enabled, unsigned GET requests to `/ap/*` return 401. Discovery endpoints are exempt. |
| **Domain filtering** | `blocklist` mode (default): reject domains in `ap_domain_blocklist`. `allowlist` mode: only accept domains in `ap_domain_allowlist` (empty list blocks all). |
| **Payload size** | Inbox POST bodies capped at 256 KB (`413 Payload Too Large`). Content bodies capped at 64 KB. |
| **JSON-LD contexts** | `https://www.w3.org/ns/activitystreams` and `https://w3id.org/security/v1` |

---

## Content Negotiation

Endpoints that represent both a web page and an AP object (actors, articles)
perform content negotiation on the `Accept` header:

| Accept header | Response |
|--------------|----------|
| `application/activity+json` | JSON-LD (AP object) |
| `application/ld+json` | JSON-LD (AP object) |
| `application/json` | JSON-LD (AP object) |
| `text/html` or other | 302 redirect to web UI |

Machine-only endpoints (collections, inboxes, discovery) always return JSON.

---

## Discovery

### WebFinger

Resolve local actors by `acct:` URI per [RFC 7033](https://www.rfc-editor.org/rfc/rfc7033).

```
GET /.well-known/webfinger?resource=acct:alice@example.com
```

**Content-Type:** `application/jrd+json`
**Auth:** None (exempt from authorized fetch)
**Rate limit:** 120 req/min per IP

**Query parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `resource` | Yes | `acct:username@host` for users, `acct:!slug@host` for boards (Lemmy-compatible `!` prefix) |

**Example response:**

```json
{
  "subject": "acct:alice@example.com",
  "aliases": ["https://example.com/ap/users/alice"],
  "links": [
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://example.com/ap/users/alice"
    },
    {
      "rel": "http://webfinger.net/rel/profile-page",
      "type": "text/html",
      "href": "https://example.com/@alice"
    }
  ]
}
```

**Errors:**

| Status | Condition |
|--------|-----------|
| 400 | Missing `resource` parameter or invalid format |
| 404 | User/board not found, or board is private (`min_role_to_view != "guest"`) |

**Notes:**
- Only public boards (`min_role_to_view == "guest"` and `ap_enabled == true`) are discoverable
- Board resources use the `!` prefix convention: `acct:!general@example.com`

---

### NodeInfo

Instance metadata per [NodeInfo 2.1](https://nodeinfo.diaspora.software/protocol).

#### Discovery document

```
GET /.well-known/nodeinfo
```

**Content-Type:** `application/json`
**Auth:** None (exempt from authorized fetch)

Returns a links array pointing to the full NodeInfo document:

```json
{
  "links": [
    {
      "rel": "http://nodeinfo.diaspora.software/ns/schema/2.1",
      "href": "https://example.com/nodeinfo/2.1"
    }
  ]
}
```

#### Full document

```
GET /nodeinfo/2.1
```

**Content-Type:** `application/json`
**Auth:** None (exempt from authorized fetch)

```json
{
  "version": "2.1",
  "software": {
    "name": "baudrate",
    "version": "0.1.0",
    "repository": "https://github.com/example/baudrate"
  },
  "protocols": ["activitypub"],
  "openRegistrations": true,
  "usage": {
    "users": { "total": 42 },
    "localPosts": 128
  },
  "metadata": {
    "nodeName": "My Forum"
  }
}
```

---

## Actors

### Person (User)

```
GET /ap/users/:username
```

**Content-Type:** `application/activity+json` (content-negotiated)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Path validation:** Username matches `[a-zA-Z0-9_]+`

**Example response:**

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ],
  "id": "https://example.com/ap/users/alice",
  "type": "Person",
  "preferredUsername": "alice",
  "summary": "User's signature text",
  "inbox": "https://example.com/ap/users/alice/inbox",
  "outbox": "https://example.com/ap/users/alice/outbox",
  "followers": "https://example.com/ap/users/alice/followers",
  "url": "https://example.com/@alice",
  "published": "2026-01-15T10:30:00Z",
  "icon": {
    "type": "Image",
    "mediaType": "image/webp",
    "url": "https://example.com/uploads/avatars/abc123/48.webp"
  },
  "endpoints": {
    "sharedInbox": "https://example.com/ap/inbox"
  },
  "publicKey": {
    "id": "https://example.com/ap/users/alice#main-key",
    "owner": "https://example.com/ap/users/alice",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
  }
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"Person"` |
| `preferredUsername` | string | The username |
| `summary` | string | User's signature/bio (optional) |
| `published` | ISO 8601 | Account creation timestamp |
| `icon` | Image | Avatar as WebP (optional, present if user has avatar) |
| `publicKey` | object | RSA-SHA256 public key for HTTP Signature verification |
| `endpoints.sharedInbox` | URI | Shared inbox URL |

**Errors:**

| Status | Condition |
|--------|-----------|
| 401 | Authorized fetch enabled and no valid HTTP Signature |
| 404 | User not found |

---

### Group (Board)

```
GET /ap/boards/:slug
```

**Content-Type:** `application/activity+json` (content-negotiated)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Path validation:** Slug matches `[a-z0-9]+(?:-[a-z0-9]+)*`

**Access control:** Returns 404 if `min_role_to_view != "guest"` or `ap_enabled != true`.

**Example response:**

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ],
  "id": "https://example.com/ap/boards/general",
  "type": "Group",
  "preferredUsername": "general",
  "name": "General Discussion",
  "summary": "A board for general topics",
  "inbox": "https://example.com/ap/boards/general/inbox",
  "outbox": "https://example.com/ap/boards/general/outbox",
  "followers": "https://example.com/ap/boards/general/followers",
  "url": "https://example.com/boards/general",
  "baudrate:parentBoard": "https://example.com/ap/boards/community",
  "baudrate:subBoards": [
    "https://example.com/ap/boards/general-offtopic"
  ],
  "endpoints": {
    "sharedInbox": "https://example.com/ap/inbox"
  },
  "publicKey": {
    "id": "https://example.com/ap/boards/general#main-key",
    "owner": "https://example.com/ap/boards/general",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
  }
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"Group"` |
| `preferredUsername` | string | Board slug |
| `name` | string | Board display name |
| `summary` | string | Board description |
| `baudrate:parentBoard` | URI | Parent board actor URI (optional, see [Baudrate Extensions](#baudrate-extensions)) |
| `baudrate:subBoards` | array of URIs | Sub-board actor URIs (optional, only public AP-enabled children) |

**Errors:**

| Status | Condition |
|--------|-----------|
| 401 | Authorized fetch enabled and no valid HTTP Signature |
| 404 | Board not found, private, or AP disabled |

---

### Organization (Site)

```
GET /ap/site
```

**Content-Type:** `application/activity+json` (content-negotiated)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ],
  "id": "https://example.com/ap/site",
  "type": "Organization",
  "preferredUsername": "site",
  "name": "My Forum",
  "inbox": "https://example.com/ap/site/inbox",
  "outbox": "https://example.com/ap/site/outbox",
  "followers": "https://example.com/ap/site/followers",
  "url": "https://example.com",
  "endpoints": {
    "sharedInbox": "https://example.com/ap/inbox"
  },
  "publicKey": {
    "id": "https://example.com/ap/site#main-key",
    "owner": "https://example.com/ap/site",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
  }
}
```

---

## Objects

### Article

```
GET /ap/articles/:slug
```

**Content-Type:** `application/activity+json` (content-negotiated)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Path validation:** Slug matches `[a-z0-9]+(?:-[a-z0-9]+)*`

**Access control:** Returns 404 if the article only belongs to private boards.

**Example response:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/articles/hello-world-a1b2c3",
  "type": "Article",
  "name": "Hello World",
  "summary": "This is a plain-text preview of the article body...",
  "content": "<p>This is the <strong>rendered HTML</strong> content.</p>",
  "mediaType": "text/html",
  "source": {
    "content": "This is the **rendered HTML** content.",
    "mediaType": "text/markdown"
  },
  "attributedTo": "https://example.com/ap/users/alice",
  "published": "2026-02-20T08:00:00Z",
  "updated": "2026-02-21T12:30:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://example.com/ap/boards/general"],
  "audience": ["https://example.com/ap/boards/general"],
  "url": "https://example.com/articles/hello-world-a1b2c3",
  "replies": "https://example.com/ap/articles/hello-world-a1b2c3/replies",
  "baudrate:pinned": false,
  "baudrate:locked": false,
  "baudrate:commentCount": 5,
  "baudrate:likeCount": 12,
  "tag": [
    {
      "type": "Hashtag",
      "name": "#elixir",
      "href": "https://example.com/tags/elixir"
    }
  ]
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"Article"` |
| `name` | string | Article title |
| `summary` | string | Plain-text preview (max 500 chars, markdown stripped) |
| `content` | string | HTML rendered from Markdown body |
| `mediaType` | string | Always `"text/html"` |
| `source` | object | Original Markdown body with `mediaType: "text/markdown"` |
| `attributedTo` | URI | Author's Person actor URI |
| `published` | ISO 8601 | Creation timestamp |
| `updated` | ISO 8601 | Last modification timestamp |
| `to` | array | Always `["https://www.w3.org/ns/activitystreams#Public"]` |
| `cc` | array of URIs | Board actor URIs the article belongs to |
| `audience` | array of URIs | Same as `cc` |
| `url` | URI | Web UI URL for the article |
| `replies` | URI | Replies collection endpoint |
| `tag` | array | Hashtag objects extracted from body (optional, omitted if empty) |
| `baudrate:pinned` | boolean | Whether the article is pinned in its board |
| `baudrate:locked` | boolean | Whether the article is locked from new comments |
| `baudrate:commentCount` | integer | Number of comments |
| `baudrate:likeCount` | integer | Number of likes |

**Hashtag extraction:**
- Pattern: `#[a-zA-Z][a-zA-Z0-9_]*` (1-64 chars after `#`)
- Code blocks and inline code are excluded
- Case-insensitive deduplication, case-preserving output
- Links to `/tags/:hashtag` (lowercase)

**Errors:**

| Status | Condition |
|--------|-----------|
| 401 | Authorized fetch enabled and no valid HTTP Signature |
| 404 | Article not found or only in private boards |

---

## Collections

All paginated collections follow the same scheme:

- **Without `?page`**: Returns an `OrderedCollection` root with `totalItems` and `first` link
- **With `?page=N`**: Returns an `OrderedCollectionPage` with up to 20 items
- **Page numbering**: 1-based (`?page=1` is the first page)
- **Navigation**: Pages include `prev`/`next` links where applicable

**Root collection example:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/users/alice/outbox",
  "type": "OrderedCollection",
  "totalItems": 42,
  "first": "https://example.com/ap/users/alice/outbox?page=1"
}
```

**Collection page example:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/users/alice/outbox?page=2",
  "type": "OrderedCollectionPage",
  "partOf": "https://example.com/ap/users/alice/outbox",
  "prev": "https://example.com/ap/users/alice/outbox?page=1",
  "next": "https://example.com/ap/users/alice/outbox?page=3",
  "orderedItems": [ ... ]
}
```

---

### User Outbox

```
GET /ap/users/:username/outbox
GET /ap/users/:username/outbox?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Returns `Create` activities wrapping Article objects. Only includes articles
in public boards.

**Item structure:**

```json
{
  "type": "Create",
  "actor": "https://example.com/ap/users/alice",
  "published": "2026-02-20T08:00:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "object": { ... }
}
```

---

### Board Outbox

```
GET /ap/boards/:slug/outbox
GET /ap/boards/:slug/outbox?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Access control:** Returns 404 if board is private or AP disabled.

Returns `Announce` activities for articles posted to the board.

**Item structure:**

```json
{
  "type": "Announce",
  "actor": "https://example.com/ap/boards/general",
  "published": "2026-02-20T08:00:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "object": "https://example.com/ap/articles/hello-world-a1b2c3"
}
```

---

### User Followers

```
GET /ap/users/:username/followers
GET /ap/users/:username/followers?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Items are remote actor URIs (strings).

---

### Board Followers

```
GET /ap/boards/:slug/followers
GET /ap/boards/:slug/followers?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Access control:** Returns 404 if board is private or AP disabled.

Items are remote actor URIs (strings).

---

### User Following

```
GET /ap/users/:username/following
GET /ap/users/:username/following?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Paginated `OrderedCollection` of actor URIs the user follows (accepted follows only).
Items are remote actor URIs (strings) and local user actor URIs.

---

### Board Following

```
GET /ap/boards/:slug/following
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Access control:** Returns 404 if board is private or AP disabled.

Returns an empty `OrderedCollection` (boards do not follow other actors).

---

### Boards Index

```
GET /ap/boards
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Returns an `OrderedCollection` of all public, AP-enabled boards. **Not
paginated** — all boards are returned in a single response.

**Item structure:**

```json
{
  "id": "https://example.com/ap/boards/general",
  "type": "Group",
  "name": "General Discussion",
  "summary": "A board for general topics",
  "url": "https://example.com/boards/general"
}
```

---

### Article Replies

```
GET /ap/articles/:slug/replies
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Access control:** Returns 404 if article is only in private boards.

Returns an `OrderedCollection` of comments as Note objects. **Not paginated**
— all comments are returned in a single response.

**Item structure:**

```json
{
  "type": "Note",
  "id": "https://remote.example/comments/abc123",
  "content": "<p>Great article!</p>",
  "attributedTo": "https://example.com/ap/users/bob",
  "inReplyTo": "https://example.com/ap/articles/hello-world-a1b2c3",
  "published": "2026-02-20T09:15:00Z"
}
```

---

### Search

```
GET /ap/search?q=elixir
GET /ap/search?q=elixir&page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Full-text search across articles in public boards. Returns a paginated
`OrderedCollection` of Article objects.

**Query parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `q` | Yes | Search query (minimum 1 byte) |
| `page` | No | Page number (1-based) |

**Errors:**

| Status | Condition |
|--------|-----------|
| 400 | Missing `q` parameter |

---

## Inboxes

All inbox endpoints accept `POST` requests with ActivityPub activities.

### Shared Inbox

```
POST /ap/inbox
```

Accepts activities targeting any local actor.

### User Inbox

```
POST /ap/users/:username/inbox
```

Accepts activities targeting a specific user. Returns 404 if user not found.

### Board Inbox

```
POST /ap/boards/:slug/inbox
```

Accepts activities targeting a specific board. Returns 404 if board is
private or AP disabled.

---

### HTTP Signature Requirements

All inbox POST requests require a valid HTTP Signature per
[draft-cavage-http-signatures](https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures).

**Required `Content-Type`** (one of):
- `application/activity+json`
- `application/ld+json`
- `application/json`

Charset parameters are accepted (e.g., `application/json; charset=utf-8`).
Other content types return `415 Unsupported Media Type`.

**Signature header format:**

```
Signature: keyId="https://remote.example/users/bob#main-key",
           algorithm="rsa-sha256",
           headers="(request-target) host date digest",
           signature="<base64>"
```

**Required signed headers:**

| Header | Description |
|--------|-------------|
| `(request-target)` | Pseudo-header: `post /ap/inbox` |
| `host` | Request host |
| `date` | RFC 7231 HTTP date (validated within +/-30 seconds) |
| `digest` | `SHA-256=<base64>` of request body |

**Algorithm:** `rsa-sha256` (also accepts `hs2019`)

**Key resolution:** The `keyId` value is used to resolve the remote actor.
The actor's `publicKey.publicKeyPem` field provides the RSA public key for
verification.

---

### Supported Activity Types

| Activity | Object type | Effect |
|----------|-------------|--------|
| `Follow` | actor URI | Creates follower relationship; auto-accepted with `Accept(Follow)` |
| `Undo` | `Follow` | Removes follower relationship |
| `Create` | `Article` or `Page` | Creates remote article in target board |
| `Create` | `Note` (public) | Creates comment on local article (resolved via `inReplyTo`) |
| `Create` | `Note` (DM) | Creates direct message (see [DM Detection](#dm-detection)) |
| `Like` | article URI | Records a like on the article |
| `Undo` | `Like` | Removes the like |
| `Announce` | article URI or embedded object | Records a boost/share |
| `Undo` | `Announce` | Removes the boost |
| `Update` | `Article`, `Page`, or `Note` | Updates remote content (authorship verified) |
| `Update` | `Person` or `Group` | Refreshes cached remote actor profile |
| `Delete` | content URI or `Tombstone` | Soft-deletes matching article, comment, or DM (authorship verified) |
| `Delete` | actor URI | Removes all follower relationships for the deleted actor |
| `Flag` | array of URIs | Creates a moderation report |
| `Block` | actor URI | Logged for informational purposes |
| `Undo` | `Block` | Logged for informational purposes |

**Unrecognized activity types** are logged and ignored (no error returned).

**Idempotency:** Duplicate activities (same `ap_id`) are silently accepted
without error.

---

### DM Detection

An incoming `Create(Note)` is treated as a direct message when **all** of the
following conditions are met:

1. `https://www.w3.org/ns/activitystreams#Public` is NOT in `to` or `cc`
2. No `/followers` collection URIs appear in `to` or `cc`
3. At least one local user actor URI appears in `to`

DMs are routed to `Messaging.receive_remote_dm/3` instead of being stored as
comments.

---

## Error Responses

All AP endpoints return errors as JSON:

```json
{
  "error": "Not Found"
}
```

| Status | Meaning |
|--------|---------|
| 400 | Bad request (missing required parameter, invalid JSON) |
| 401 | Unauthorized (invalid HTTP Signature, or authorized fetch enabled without signature) |
| 404 | Not found (resource doesn't exist, private, or federation disabled) |
| 413 | Payload too large (inbox POST body exceeds 256 KB) |
| 415 | Unsupported media type (inbox POST with non-AP content type) |
| 422 | Unprocessable entity (activity validation or processing error) |
| 429 | Too many requests (rate limit exceeded) |

---

## Rate Limits

| Scope | Limit | Window |
|-------|-------|--------|
| All AP endpoints | 120 requests | 1 minute per IP |
| Inbox POST | 60 requests | 1 minute per remote domain |

Rate-limited responses return `429 Too Many Requests` with:

```json
{
  "error": "Too Many Requests"
}
```

**Failure mode:** Rate limiting fails open — if the rate-limit backend (ETS)
encounters an error, the request is allowed through.

---

## Baudrate Extensions

Baudrate extends standard ActivityPub objects with custom properties under the
`baudrate:` namespace prefix.

### Article extensions

| Property | Type | Description |
|----------|------|-------------|
| `baudrate:pinned` | boolean | Article is pinned to the top of its board |
| `baudrate:locked` | boolean | Article is locked (new comments disabled) |
| `baudrate:commentCount` | integer | Total number of comments |
| `baudrate:likeCount` | integer | Total number of likes |

### Board (Group) extensions

| Property | Type | Description |
|----------|------|-------------|
| `baudrate:parentBoard` | URI | Parent board's actor URI (for hierarchical boards) |
| `baudrate:subBoards` | array of URIs | Child board actor URIs (only public, AP-enabled children included) |

---

## Mastodon / Lemmy Compatibility

Baudrate handles several compatibility concerns with popular Fediverse
software:

- **`attributedTo` arrays** — Extracts the first binary URI (Mastodon may send arrays)
- **Content warnings** — `sensitive: true` + `summary` fields are prepended as `[CW: summary]` to the body
- **Lemmy `Page` objects** — Treated identically to `Article` for `Create` and `Update`
- **Lemmy `Announce` with embedded objects** — Extracts the inner `id` field (not just bare URIs)
- **Lemmy WebFinger boards** — `acct:!slug@host` format with `!` prefix
- **Mastodon HTML classes** — `<span>` tags with safe classes (`h-card`, `hashtag`, `mention`, `invisible`) are preserved through the HTML sanitizer
- **Cross-post deduplication** — The same remote article arriving via multiple board inboxes is linked to all boards (not duplicated)

---

## CORS Preflight

All `/ap/*` endpoints respond to `OPTIONS` with:

```
HTTP/1.1 204 No Content
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, HEAD, OPTIONS
Access-Control-Allow-Headers: accept, content-type
```
