# 0003 — Federate over ActivityPub, mapping boards to Group actors

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Baudrate is a BBS that should not be an island. The realistic options for
interoperating with the wider network were ActivityPub (the W3C recommendation,
spoken by Mastodon, Lemmy, PeerTube and most of the fediverse), a
BBS-native protocol (NNTP, FidoNet-style echomail), or a bespoke
Baudrate-to-Baudrate protocol.

ActivityPub does not define a "forum" actor. Lemmy established the de facto
convention of modelling a community as an `as:Group` and boosting posts to its
followers, and Mastodon interoperates with that convention.

## Decision

Federate over **ActivityPub**, with HTTP Signatures for authentication and
JSON-LD for serialization, following the Lemmy conventions for forum semantics.

Actor mapping:

| Local entity | AP type | URI |
|---|---|---|
| User | `Person` | `/ap/users/:username` |
| Board | `Group` | `/ap/boards/:slug` |
| Instance | `Organization` | `/ap/site` |
| Article | `Article` | `/ap/articles/:slug` |

Supporting decisions that follow from this mapping:

- **Boards announce, users create.** A local article is delivered as
  `Create(Article)` from the user actor and `Announce(Article)` from the board
  actor, so both follower sets see it under the correct authorship.
- **`Page` is accepted alongside `Article`** on ingest for Lemmy interop.
- **Every local AP object is stamped with a canonical `ap_id` at creation**,
  post-insert (the URI embeds the DB id). Publishers use the stored `ap_id`
  with a fallback to `Federation.actor_uri/2`.
- **WebFinger subjects must match `preferredUsername` exactly** — Mastodon
  derives the WebFinger query from `preferredUsername` and returns 422 on a
  mismatch, so board subjects use the bare slug (the `!slug` Lemmy form is
  accepted on input only). A `properties` field carries the actor type so
  clients can tell a board from a user.
- Human URLs are **content-negotiated**: an AP `Accept` header on
  `/articles/:slug` is forwarded to the AS2 endpoint, and the HTML page emits
  `<link rel="alternate" type="application/activity+json">`.

## Consequences

- Baudrate appears in Mastodon as a followable account per board and per user,
  and in Lemmy as a community.
- The inbox is a public, unauthenticated-by-default endpoint accepting
  attacker-controlled JSON-LD. Every field is untrusted input; this drives
  ADR 0004 (federation gate), ADR 0007 (SSRF-safe fetching), and the origin
  binding rules on actors, `Announce` attribution and `Move`.
- We inherit AP's compatibility burden: quirks of each implementation surface
  as interop bugs, and spec compliance is a standing requirement.
- Content size limits (256 KB payload, 64 KB body) and per-domain rate limits
  are mandatory, not optional.

## Alternatives considered

- **NNTP.** Rejected: no identity or signature story, and the fediverse is
  where the users are.
- **A Baudrate-only protocol.** Rejected: a federation protocol with one
  implementation is a private API.
- **Modelling boards as `Person`.** Rejected: Lemmy's `Group` convention is
  what other implementations already understand as a forum.
