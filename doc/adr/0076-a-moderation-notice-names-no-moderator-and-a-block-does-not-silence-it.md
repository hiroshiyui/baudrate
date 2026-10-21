# 0076 — A moderation notice names no moderator, and a block does not silence it

- **Status:** Accepted
- **Date:** 2026-10-21
- **Deciders:** Baudrate maintainers
- **Related:** the moderation outcomes of P1-D4, the actorless held-post
  notices of [0065](0065-what-waits-for-review-is-not-content-yet.md), and the
  always-delivered notices of
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md).

## Context

When a moderator removes a post, its author is told (`content_removed`), and
the notice is always delivered: notification preferences cannot switch off
being told your own post was removed. The row stores the remover as its
actor. That is deliberate — it is how a moderator who removes their own post
is not notified about it — but `/notifications` put every row's actor in front
of its text, so the author read "**alice** A moderator removed your content."

Two things were wrong with that:

1. **It named the moderator.** The text was written as an anonymous sentence,
   the held-post notices of ADR 0065 already name nobody, and the push of the
   same notice did not name anyone either (since v2.0.8). Naming the person
   who removed a post points the author's frustration at a person rather than
   at the decision, and on a small instance invites argument or harassment.
   The decision stays attributable where it is reviewed: the moderation log.
2. **A block or mute silenced it.** `Notification.create_notification/1` drops
   any notification whose recipient blocked or muted its actor. An author who
   blocked the moderator — the likeliest reaction to the first problem — was
   then never told that moderator removed their post, which undoes "always
   delivered".

## Decision

1. **A notice names its actor only when its text is written to follow a
   name.** `Notification.Notification.actor_named_types/0` lists those
   fragment types ("replied to your article"); every other type is a full
   sentence and is shown, on `/notifications` and in a push title, without any
   actor, even when its row stores one. A new type is shown without an actor
   until it is listed, so the safe default is anonymity; a test fails when the
   list and the texts disagree.
2. **An always-delivered notice ignores blocks and mutes.** Blocking and muting
   decide what a member hears *from* someone. A notice about the member's own
   account, content or the instance is not something that person said, and
   "always delivered" means nothing the recipient sets can drop it.

## Consequences

- `content_removed` keeps its actor in the database (self-removal still
  notifies nobody, and the moderation log is unaffected); only its display
  changes.
- An admin or moderator who mutes a member still hears about that member's
  pending registration: the queue notice is operational, not that member's
  speech.
- Showing an actor for a new notification type is a deliberate act — adding it
  to the list — and the review of that change is where "should this name
  someone?" gets asked.

## Alternatives considered

- **Store no actor for removals.** Rejected: the actor is what suppresses the
  self-notification, and the row is the record of who acted.
- **Keep naming the moderator, and reword the text to follow a name.**
  Rejected for the reasons above; attribution belongs in the moderation log,
  which staff read, not in the notice the affected member reads.
- **Exempt only `content_removed` from block and mute.** Rejected: every
  always-delivered type has the same claim, and a per-type list would drift.
