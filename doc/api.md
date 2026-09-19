# ActivityPub API Reference

Baudrate exposes an ActivityPub-compatible API for federation and programmatic
access. All endpoints documented here live under `/ap/` (objects and actors) or
`/.well-known/` (discovery) — these form the federation surface.

A handful of additional first-party HTTP endpoints (RSS/Atom feeds at
`/feeds/{rss,atom}` and per-board/user variants, the Web Push subscription
endpoints `POST/DELETE /api/push-subscriptions`, the PWA Web Share Target at
`POST /share`, the Mastodon-style `GET /@:handle` redirect, the signed media
proxy `GET /media/:sig/:encoded`, and the health probe `GET /health`) are
intended for browser, PWA, or sysop use rather than federation; they are wired
up in `lib/baudrate_web/router.ex` and not documented as part of the AP
surface.

**Base URL:** `https://<your-instance>`

---

## Table of Contents

- [Global Behavior](#global-behavior)
  - [Extension terms](#extension-terms)
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
  - [Comment](#comment)
  - [Poll](#poll)
- [Collections](#collections)
  - [User Outbox](#user-outbox)
  - [Board Outbox](#board-outbox)
  - [Site Outbox](#site-outbox)
  - [User Followers](#user-followers)
  - [Board Followers](#board-followers)
  - [Site Followers](#site-followers)
  - [User Following](#user-following)
  - [Board Following](#board-following)
  - [Boards Index](#boards-index)
  - [Article Replies](#article-replies)
  - [Search](#search)
- [Inboxes](#inboxes)
  - [Shared Inbox](#shared-inbox)
  - [User Inbox](#user-inbox)
  - [Board Inbox](#board-inbox)
  - [Site Inbox](#site-inbox)
  - [Inbox Responses](#inbox-responses)
  - [HTTP Signature Requirements](#http-signature-requirements)
  - [Supported Activity Types](#supported-activity-types)
  - [DM Detection](#dm-detection)
- [Error Responses](#error-responses)
- [Rate Limits](#rate-limits)
- [Baudrate Extensions](#baudrate-extensions)
- [Mastodon / Lemmy Compatibility](#mastodon--lemmy-compatibility)
- [CORS Preflight](#cors-preflight)

---

## Global Behavior

| Aspect | Detail |
|--------|--------|
| **Federation kill switch** | Setting `ap_federation_enabled` (admin panel). When disabled, all `/ap/*` endpoints return 404. Discovery endpoints remain available. |
| **CORS** | `Access-Control-Allow-Origin: *` on all GET `/ap/*` responses. `OPTIONS` returns 204 with allowed methods `GET, HEAD, OPTIONS`. |
| **Vary** | Content-negotiated endpoints include `Vary: Accept` for proper cache behavior. |
| **Authorized fetch** | Optional setting `ap_authorized_fetch`. When enabled, unsigned GET requests to `/ap/*` return 401. Discovery endpoints are exempt. |
| **Domain filtering** | `blocklist` mode (default): reject domains blocked at `/admin/federation`. `allowlist` mode: only accept domains in `ap_domain_allowlist` (empty list blocks all). |
| **Payload size** | Inbox POST bodies capped at 256 KB (`413 Payload Too Large`). Content bodies capped at 64 KB. |
| **JSON-LD contexts** | `https://www.w3.org/ns/activitystreams`, `https://w3id.org/security/v1`, and an inline terms object declaring the `baudrate:` and `schema:` prefixes (see below) |
| **Caching** | Actor documents are served `public, max-age=180` — but `no-store` on every 404, every HTML redirect, and on **all** actor responses while authorized fetch is enabled, because the answer then depends on the requester's signature |

### Extension terms

Fields outside the standard vocabulary carry the `baudrate:` prefix, declared
in the `@context` of every object, activity and actor that may use them:

```json
"@context": [
  "https://www.w3.org/ns/activitystreams",
  "https://w3id.org/security/v1",
  {
    "baudrate": "https://github.com/hiroshiyui/baudrate/ns#",
    "schema": "http://schema.org/",
    "PropertyValue": "schema:PropertyValue",
    "value": "schema:value"
  }
]
```

| Term | On | Meaning |
|------|----|---------|
| `baudrate:pinned` | `Article` | Pinned in its board |
| `baudrate:locked` | `Article` | Closed to new comments |
| `baudrate:commentCount` | `Article` | Comments, excluding deleted |
| `baudrate:likeCount` | `Article` | Likes |
| `baudrate:parentBoard` | `Group` | Actor URI of the board this one sits under |
| `baudrate:subBoards` | `Group` | Actor URIs of the federated boards beneath it |

The namespace identifies the **software**, not the instance — every Baudrate
instance uses the same prefix, so the terms mean the same thing everywhere.
Like Mastodon's `http://joinmastodon.org/ns#`, it is an identifier rather
than a document and does not have to resolve.

---

## Content Negotiation

Endpoints that represent both a web page and an AP object (actors, articles)
perform content negotiation on the `Accept` header:

| Accept header | Response |
|--------------|----------|
| `application/activity+json` | JSON-LD (AP object) |
| `application/ld+json` | JSON-LD (AP object) |
| `application/json` | JSON-LD (AP object) |
| `text/html` or other | 302 redirect to the matching page: `/boards/:slug` for a board, `/articles/:slug` for an article. The Person and site actors redirect to `/` |

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
| `resource` | Yes | `acct:site@host` for the instance actor (resolved first, so no user or board may take the name `site`), `acct:username@host` for users, `acct:slug@host` for boards (also accepts `acct:!slug@host` with Lemmy-compatible `!` prefix) |

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
    }
  ]
}
```

**Errors:**

| Status | Condition |
|--------|-----------|
| 400 | Missing `resource` parameter or invalid format |
| 404 | User/board not found, or the board is not federated — private (`min_role_to_view != "guest"`) **or** `ap_enabled == false` |

**Board WebFinger example:**

```
GET /.well-known/webfinger?resource=acct:general@example.com
```

```json
{
  "subject": "acct:general@example.com",
  "aliases": ["https://example.com/ap/boards/general"],
  "links": [
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://example.com/ap/boards/general"
    }
  ],
  "properties": {
    "https://www.w3.org/ns/activitystreams#type": "Group"
  }
}
```

**Notes:**
- Only federated boards (`min_role_to_view == "guest"` and `ap_enabled == true`) are discoverable
- Board WebFinger uses the bare slug in `subject` (matching `preferredUsername`) for Mastodon compatibility
- The `properties` field with `type: "Group"` follows the Lemmy convention for actor type disambiguation
- Queries with `!` prefix (`acct:!general@example.com`) are accepted for Lemmy backward compatibility
- `acct:site@host` resolves to the instance actor, with `properties` carrying `type: "Organization"`; it is checked before user and board lookups
- The response carries exactly one `links` entry (`rel: "self"`, `type: "application/activity+json"`) — there is no `profile-page` link for any actor type

---

### NodeInfo

Instance metadata per [NodeInfo](https://nodeinfo.diaspora.software/protocol),
served at both **2.0** and **2.1**. The two describe the same instance and
differ only in what their schemas permit.

#### Discovery document

```
GET /.well-known/nodeinfo
```

**Content-Type:** `application/json`
**Auth:** None (exempt from authorized fetch)

Returns a links array pointing to both documents:

```json
{
  "links": [
    {
      "rel": "http://nodeinfo.diaspora.software/ns/schema/2.0",
      "href": "https://example.com/nodeinfo/2.0"
    },
    {
      "rel": "http://nodeinfo.diaspora.software/ns/schema/2.1",
      "href": "https://example.com/nodeinfo/2.1"
    }
  ]
}
```

#### Full document

```
GET /nodeinfo/2.0
GET /nodeinfo/2.1
```

**Content-Type:** `application/json`
**Auth:** None (exempt from authorized fetch)

```json
{
  "version": "2.1",
  "software": {
    "name": "baudrate",
    "version": "1.28.2",
    "repository": "https://github.com/hiroshiyui/baudrate"
  },
  "protocols": ["activitypub"],
  "services": { "inbound": [], "outbound": [] },
  "openRegistrations": true,
  "usage": {
    "users": { "total": 42, "activeMonth": 17, "activeHalfyear": 31 },
    "localPosts": 128,
    "localComments": 904
  },
  "metadata": {
    "nodeName": "My Forum",
    "nodeDescription": "A small forum about radios"
  }
}
```

`software.repository` appears only in **2.1** — the 2.0 schema has no place
for it, and a 2.0 document carrying it fails validation.

**What the counts mean:**

| Field | Counts | Excludes |
|-------|--------|----------|
| `users.total` | accounts | bot accounts, banned accounts |
| `users.activeMonth` | accounts that signed in within 30 days | accounts that have not signed in since this instance upgraded to v1.31.0 |
| `users.activeHalfyear` | the same, within 180 days | as above |
| `localPosts` | articles written here | articles mirrored from other instances, soft-deleted articles |
| `localComments` | comments written here | as above |

Activity comes from a per-account **date** of last sign-in, not from session
rows: a session lives 14 days and is then purged, so it cannot answer a
question about a month. The date has no time component, deliberately — the
question is which month somebody was last here.

`software.version` reflects the running release (the `:baudrate` app version),
`openRegistrations` mirrors the current registration mode,
`metadata.nodeDescription` is omitted when the `site_description` setting is
unset, and every count is computed live — the values above are illustrative.

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
    "https://w3id.org/security/v1",
    {
      "schema": "http://schema.org/",
      "PropertyValue": "schema:PropertyValue",
      "value": "schema:value"
    }
  ],
  "id": "https://example.com/ap/users/alice",
  "type": "Person",
  "preferredUsername": "alice",
  "name": "Alice",
  "summary": "Alice's profile bio, escaped, with newlines as &lt;br&gt;",
  "inbox": "https://example.com/ap/users/alice/inbox",
  "outbox": "https://example.com/ap/users/alice/outbox",
  "followers": "https://example.com/ap/users/alice/followers",
  "following": "https://example.com/ap/users/alice/following",
  "url": "https://example.com/@alice",
  "published": "2026-01-15T10:30:00Z",
  "icon": {
    "type": "Image",
    "mediaType": "image/webp",
    "url": "https://example.com/uploads/avatars/abc123/48.webp"
  },
  "attachment": [
    { "type": "PropertyValue", "name": "Website", "value": "https://alice.example" }
  ],
  "alsoKnownAs": ["https://other.example/users/alice"],
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
| `name` | string | Display name (optional, omitted when unset) |
| `summary` | string | The user's profile **bio**, HTML-escaped with newlines as `<br>` (optional). `users.signature` is never federated |
| `published` | ISO 8601 | Account creation timestamp |
| `icon` | Image | Avatar as WebP (optional, present if user has avatar) |
| `attachment` | array | Profile fields as `schema:PropertyValue` objects (optional) — which is why Person actors carry a third `@context` entry |
| `following` | URI | Following collection URL |
| `alsoKnownAs` | array of URIs | Account aliases, for migration (optional, ADR 0025) |
| `movedTo` | URI | The account this one moved to (optional, ADR 0025) |
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
  "following": "https://example.com/ap/boards/general/following",
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

**Access control:** Returns 404 unless the article is board-less or sits in at
least one **federated** board (`min_role_to_view == "guest"` **and**
`ap_enabled == true`) — turning a board's federation off stops its articles
being served as AP objects, not just announced. A remote article is also
refused when it was ingested as `followers_only`/`direct`, and when its actor
is suspended or its domain blocked (ADR 0030). These refusals apply to every
requester, signed or not, including one whose signature belongs to an admin.

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
| `summary` | string | The **content warning**, when the author set one. Omitted otherwise. It is not a body excerpt — it carried one until v1.31.0, and since Mastodon maps `summary` to `spoiler_text` for every object type, that made every article arrive there hidden behind its own opening paragraph (ADR 0052) |
| `sensitive` | boolean | Present and `true` only alongside a content warning |
| `published` | ISO 8601 | Creation timestamp |
| `updated` | ISO 8601 | Last modification timestamp (optional — omitted unless the article was edited more than 5 s after it was created, so peers do not mark a freshly posted article as edited) |
| `to` | array | Always `["https://www.w3.org/ns/activitystreams#Public"]` |
| `cc` | array of URIs | Actor URIs of the article's **federated** boards only (`min_role_to_view == "guest"` and `ap_enabled == true`); private and AP-disabled boards are filtered out, so this can be empty. Plus the actor URI of each resolved remote mention, subject to the same gate |
| `audience` | array of URIs | Same as `cc`, filtered the same way |
| `url` | URI | Web UI URL for the article |
| `replies` | URI | Replies collection endpoint |
| `tag` | array | `Hashtag` objects extracted from the body, and a `Mention` object (`href` = the actor's URI, `name` = `@user@domain`) for each remote handle this instance could resolve. Optional, omitted if empty. Mentions appear only when the article may federate at all — an article whose boards are all private or AP-disabled carries none, and its mentioned actors are not in `cc` either (ADR 0043, ADR 0051) |
| `attachment` | array | Images (`Document`, `image/webp`, with `width`/`height`), an attached poll (a `Question` with `oneOf` for single-choice or `anyOf` for multiple-choice, `votersCount`, per-option `replies.totalItems`, and `endTime` when the poll closes), and a fetched link preview (`Document`, `text/html`). Omitted when the article has none |
| `baudrate:pinned` | boolean | Whether the article is pinned in its board |
| `baudrate:locked` | boolean | Whether the article is locked from new comments |
| `baudrate:commentCount` | integer | Number of comments |
| `baudrate:likeCount` | integer | Number of likes |

**Hashtag extraction:**
- Pattern: `#` then a Unicode letter (`\p{L}`) and up to 63 further word
  characters — so `#日本語` and `#Élan` are hashtags, not just ASCII. The `#`
  must follow the start of the text, whitespace, or a non-word character
  other than `&` (so `&#8212;` is not a tag)
- Code blocks and inline code are excluded
- Tags are **lowercased** on extraction, then deduplicated: `#Elixir`
  federates as `"name": "#elixir"`
- Links to `/tags/:hashtag`

**Errors:**

| Status | Condition |
|--------|-----------|
| 401 | Authorized fetch enabled and no valid HTTP Signature |
| 404 | Article not found, or not servable: no federated board, non-public remote visibility, or a suspended actor / blocked domain |

---

### Comment

```
GET /ap/comments/:id
```

**Content-Type:** `application/activity+json` (content-negotiated — an ordinary
browser is redirected to `/articles/:slug#comment-:id`)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Comments have been fetchable objects since v1.31.0 (ADR 0050). Before that
their `ap_id` was `<actor-uri>#note-<id>`, a fragment, which dereferenced to
the author's Person document — so no instance could resolve a comment, thread
against it, or cite it. Comments created before the upgrade were rewritten to
this scheme and **still answer to their old id** on every inbound path
(`inReplyTo`, `Like`, `Announce`, `Delete`), and a deletion is published under
both ids.

**Access control:** the gate is the **owning article's** — exactly the
conditions listed for `GET /ap/articles/:slug`. On top of that, 404 for a
comment that is soft-deleted, that was authored remotely (its `id` belongs to
another host, so serving it here would assert this instance as its origin), or
whose `visibility` is not `public`/`unlisted`.

**Example response:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/comments/42",
  "type": "Note",
  "url": "https://example.com/articles/hello-world-a1b2c3#comment-42",
  "content": "<p>Good point.</p>",
  "mediaType": "text/html",
  "attributedTo": "https://example.com/ap/users/alice",
  "inReplyTo": "https://example.com/ap/articles/hello-world-a1b2c3",
  "published": "2026-02-20T09:15:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://example.com/ap/users/alice/followers"]
}
```

`summary` and `sensitive` carry a content warning when the author set one,
exactly as on an Article.

`inReplyTo` names the **parent comment** when the comment is a reply, and the
article only when it is top-level (ADR 0051). A reply to a remote comment
names that comment's own URI, so it threads back into the conversation on the
instance it started from.

`attachment` carries the comment's images (`Image`, `image/webp`, with
`width`/`height`) and is omitted when there are none. `tag` carries a
`Mention` object per resolved remote handle, subject to the owning article's
federation gate.

---

### Poll

```
GET /ap/polls/:id
```

**Content-Type:** `application/activity+json` (content-negotiated — a browser
is redirected to the article)
**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

The same `Question` the owning Article embeds in its `attachment`, served on
its own so a remote client can address a vote to it. Both carry the same `id`.

**Access control:** the owning article's, unchanged.

**Example response:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/polls/7",
  "type": "Question",
  "name": "Hello World",
  "attributedTo": "https://example.com/ap/users/alice",
  "context": "https://example.com/ap/articles/hello-world-a1b2c3",
  "url": "https://example.com/articles/hello-world-a1b2c3",
  "published": "2026-02-20T08:00:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://example.com/ap/boards/general"],
  "votersCount": 17,
  "endTime": "2026-02-27T08:00:00Z",
  "oneOf": [
    {"type": "Note", "name": "Yes", "replies": {"type": "Collection", "totalItems": 12}},
    {"type": "Note", "name": "No", "replies": {"type": "Collection", "totalItems": 5}}
  ]
}
```

`context` rather than `inReplyTo`: the poll belongs to its article, it is not a
reply to it. Each option's `replies` collection gives `totalItems` and
deliberately **no** `items` — the counts are public, the voters are not
(ADR 0048).

**Voting:** send a `Create(Note)` whose `name` matches an option's `name` and
whose `inReplyTo` is either this poll's `id` or the owning article's. Both are
accepted: the article URI is what this instance published before polls had
their own id.

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

Returns `Create` activities wrapping Article objects. Only articles in
**federated** boards (`min_role_to_view == "guest"` **and** `ap_enabled == true`)
are listed; a board-less article is not listed here at all, because the query
joins `board_articles`. `totalItems` and the pages apply the same filter.

**Item structure:**

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/articles/hello-world-a1b2c3#create",
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
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/ap/articles/hello-world-a1b2c3#announce",
  "type": "Announce",
  "actor": "https://example.com/ap/boards/general",
  "published": "2026-02-20T08:00:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "object": "https://example.com/ap/articles/hello-world-a1b2c3"
}
```

---

### Site Outbox

```
GET /ap/site/outbox
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

Always an empty `OrderedCollection` (`totalItems: 0`). The site actor signs
instance-level activities and publishes no content of its own, but an actor
that advertises an `outbox` it does not serve fails a peer's discovery —
Mastodon fetches it when the actor is first seen. An explicit empty collection
is the answer, not a 404.

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

### Site Followers

```
GET /ap/site/followers
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP

The site actor's genuine followers collection, served by the same code as the
user and board ones — empty in practice, because remote instances follow users
and boards rather than the instance actor. The endpoint exists because the
actor document advertises it, and a peer that fetches an advertised collection
must not get a 404.

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
GET /ap/boards/:slug/following?page=1
```

**Auth:** HTTP Signature required if authorized fetch is enabled
**Rate limit:** 120 req/min per IP
**Access control:** Returns 404 if board is private or AP disabled.

Returns an `OrderedCollection` root whose `totalItems` counts the remote actors
the board follows — accepted board follows only, which is how remote content is
routed into a board — and `?page=N` returns an `OrderedCollectionPage` of their
actor URIs, 20 per page, newest follow first. Paginated like every other
collection. It is **not** empty: a board following remote actors is the
mechanism, not an edge case.

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
**Access control:** Returns 404 under exactly the same conditions as
`GET /ap/articles/:slug` (no federated board, non-public remote visibility, or a
suspended actor / blocked domain).

Returns an `OrderedCollection` of comments as Note objects. **Not paginated**
— all comments are returned in a single response. Soft-deleted comments, and
remote comments ingested as `followers_only`/`direct` or belonging to a
suspended actor or blocked domain, are left out.

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

Full-text search across articles in **federated** boards — `min_role_to_view
== "guest"` *and* `ap_enabled == true`, the same gate
`GET /ap/articles/:slug` applies. Returns a paginated `OrderedCollection` of
Article objects.

**Access control:** an article in a guest-readable board whose federation is
switched off is absent from these results, as it is from every other AP
surface ([ADR 0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md)).
The site's own search is unaffected by `ap_enabled`.

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

### Site Inbox

```
POST /ap/site/inbox
```

The site actor's own inbox, which its actor document advertises. It is handled
by the same action as `/ap/inbox`: the target is resolved from the activity's
addressing either way, so a `Follow` of a user or board delivered here behaves
exactly as it would at the shared inbox. Before this route existed the actor
advertised an endpoint that returned 404, and a peer that posted a `Follow`
there was told nothing.

### Inbox Responses

The inbox admits an activity, stores it and answers immediately; the work
happens afterwards in a background worker (ADR 0034), so the sender never waits
for reply-chain walks or object fetches.

| Status | Body | Condition |
|--------|------|-----------|
| 202 | `{"status": "accepted"}` | Stored for processing, or already stored (a redelivery of the same activity id from the same signing actor) |
| 202 | *(empty)* | Dropped on purpose: a blocked domain is answered 202 rather than 401 so the sender stops retrying. This comes from `VerifyHTTPSignature`, before the controller runs, so it carries no body |
| 400 | `{"error": "Invalid JSON"}` | Body is not valid JSON |
| 401 | `{"error": "Invalid signature"}` | HTTP Signature missing or invalid |
| 413 | `{"error": "Payload too large"}` | Body over 256 KB |
| 415 | `{"error": "Unsupported Media Type"}` | `Content-Type` is not an AP JSON type |
| 422 | `{"error": "Unprocessable"}` | Failed **admission**: malformed activity, an activity `id` on a different host from the actor, a blocked domain, a suspended actor, claiming to be a local actor, or a signer/actor mismatch |
| 429 | `{"error": "Rate limited"}` | Per-IP or per-domain rate limit exceeded |

**What a handler makes of the activity is never reported to the sender.** A
refusal after storage — a non-federated board, a locked or deleted article, a
block — is recorded in `inbound_activities.last_error` and logged; the sender
has already had its 202. Processing is at-least-once, so handlers are idempotent
under redelivery.

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
| `date` | RFC 7231 HTTP date (validated within +/-300 seconds) |
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
| `Create` | `Article`, `Page` or `Question` | Creates remote article in target board (a `Question` becomes an article with an attached poll) |
| `Create` | `Note` (vote) | A Note whose `name` matches an option of the poll named by `inReplyTo` is counted as a poll vote, not a comment |
| `Create` | `Note` (public) | Creates comment on local article (resolved via `inReplyTo`). Dropped silently when the target article is not in a federated board, is locked, or has been deleted |
| `Create` | `Note` (DM) | Creates direct message (see [DM Detection](#dm-detection)) |
| `Like` | article or comment URI | Records a like on the article or comment |
| `Undo` | `Like` | Removes the like (from both article and comment likes) |
| `Announce` | article or comment URI, or embedded object | Records a boost/share (creates article/comment boost for local content) |
| `Undo` | `Announce` | Removes the boost (from announces and article/comment boosts) |
| `Update` | `Article`, `Page`, or `Note` | Updates remote content (authorship verified) |
| `Update` | `Question` | Refreshes a remote poll's vote and voter counts |
| `Update` | `Person` or `Group` | Refreshes cached remote actor profile |
| `Delete` | content URI or `Tombstone` | Soft-deletes matching article, comment, or DM (authorship verified) |
| `Delete` | actor URI | Removes all follower relationships for the deleted actor |
| `Flag` | array of URIs | Creates a moderation report |
| `Block` | actor URI | Logged for informational purposes |
| `Undo` | `Block` | Logged for informational purposes |
| `Accept` | `Follow` | Marks a pending outbound user follow as accepted |
| `Reject` | `Follow` | Marks a pending outbound user follow as rejected |
| `Move` | actor URI (`target`) | Migrates local users' follows to the target actor. Authorized only when the signer is the Move `actor` **and** the target's `alsoKnownAs` claims the moving actor; otherwise rejected |

**Unrecognized activity types** are logged and ignored (no error returned).

**Idempotency:** Duplicate activities (same `ap_id`) are silently accepted
without error.

**Peer-supplied `published` dates are clamped.** A `published` value in the
future is replaced with the time of arrival — any value past "now", by however
little: the timeline orders on it, so a date years ahead would pin an item to
the top of every follower's timeline. (A changeset backstop separately refuses
to store a `published_at` more than 60 s ahead, which is where the allowance
for clock skew lives.)

**Refusals are not errors.** An activity a handler declines — a non-federated
board, a locked or deleted article, a block, a suspended actor — is dropped with
a log line, not a 4xx, so remote instances do not retry.

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

All AP endpoints return errors as JSON, with one exception: when federation is
switched off entirely, `/ap/*` answers 404 with an empty body.

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
| 422 | Unprocessable entity — the activity failed inbox admission (see [Inbox Responses](#inbox-responses)) |
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
- **Board WebFinger** — Uses bare slug in `subject` (matching `preferredUsername`) for Mastodon compatibility; includes `properties` with `type: "Group"` for Lemmy-compatible disambiguation; accepts `!` prefix in queries for backward compatibility
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
