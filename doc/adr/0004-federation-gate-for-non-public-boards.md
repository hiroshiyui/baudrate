# 0004 — A single federation gate for every inbound interaction

- **Status:** Accepted
- **Date:** 2026-08-08 (v1.12.0) — hardened; gate itself predates it

## Context

Not every board should be visible to the network. A board carries
`min_role_to_view` and an `ap_enabled` flag, and only a board that is both
`guest`-viewable and AP-enabled is federated.

Enforcing that on the *outbound* side alone is not enough. Article slugs are
guessable, and the inbox accepts activities addressed to arbitrary object URIs.
If `Like` was gated but `Create(Note)` was not, a remote actor could guess a
slug and inject a comment — plus a notification to the author — into an article
that exists only in a private or AP-disabled board. The same holds for
Mastodon-style poll-vote Notes, which are ordinary Notes and would otherwise
fall through to the comment handler.

Two cases complicate a blanket rule:

- **Remote articles** (`remote_actor_id` set) already exist on the fediverse
  under their own `ap_id`. Refusing interactions with them because of the local
  board they happen to sit in breaks federation semantics.
- **Local articles whose author has remote followers** may already have been
  published by user-actor fan-out, independently of the board. Inbound
  `Like`/`Announce` on that published copy must be honoured.

## Decision

One predicate — `InboxHandler.article_federated?/1` — gates **every** inbound
interaction with a local article: `Like`, `Announce`, `Create(Note)` replies,
and poll-vote Notes. Never gate a subset.

Exceptions, deliberately narrow:

1. Remote articles (`remote_actor_id` non-nil) always accept interactions.
2. Local articles whose author has remote followers accept them, because
   user-actor federation may already have published the article.

Local articles with no remote followers, residing only in non-federated boards,
reject inbound activities.

Related rules:

- A `Follow` targeting a non-federated board actor is answered with
  `Reject(Follow)`, including via the shared inbox — the board inbox route
  already 404s, but the shared inbox needs the same guard.
- A non-federated board's actor, inbox and outbox endpoints return **404**.
- **Refused activities are dropped with `:ok` and a log line, not a 4xx.** A
  4xx makes remote instances retry forever; the activity is simply not one we
  will act on.
- `handle_poll_vote_for_article/3` returns `:not_a_vote` only when the Note
  genuinely is not a vote. A *refused* vote returns `:ok`, so it is dropped
  rather than falling through to the comment/DM handlers.

## Consequences

- Private and AP-disabled boards cannot be probed or written into from the
  network.
- Every new inbound activity type must route through the same gate; adding one
  that forgets it reopens the injection hole. This is a review checklist item.
- Silent drops mean debugging interop requires reading logs, not HTTP status
  codes.

## Alternatives considered

- **Gate only on the outbound side.** Rejected — the injection path above.
- **Return 403 for refused activities.** Rejected: causes unbounded retry
  traffic from well-behaved remote instances.
