# 0085 — A member's comment is forwarded by others only from a thread that federates

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Baudrate maintainers
- **Related:** [0016](0016-authorization-at-the-context-boundary.md) (the
  context decides), [0029](0029-sanctions-are-rows-with-an-explicit-end.md)
  (who may act), [0043](0043-the-outbound-federation-gate-and-withdrawals.md)
  (the outbound gate), [0083](0083-the-inbound-gate-is-the-outbound-gate.md)

## Context

Forwarding a comment materializes it as an article in a board. For a **local**
comment the article is attributed to the comment's author and published as a
`Create` signed with their key. `create_article/3` takes it with
`forwarded_comment: true`, which skips every gate of new writing, since the
author is not the one acting.

The only checks were the forwarder's: they could see the comment, it was
`public`/`unlisted`, and they could post in the target board. So any member
could take a comment written in a members-only or staff-only thread, or in a
board an admin had kept off the network, and publish it to the fediverse under
its author's name, without the author knowing. A silenced or suspended author
was made to publish this way too. Articles have the author's `forwardable`
opt-in for exactly this; comments had nothing.

## Decision

`Content.forward_comment_to_board/3` lets someone other than the author forward
a local comment only when:

1. its thread already federates (`Delivery.article_boards_federated?/1` on the
   parent article: board-less, or in at least one federated board), so the
   words are already public under the author's name and forwarding exposes
   nothing new; and
2. the author may still act (`Auth.ensure_can_interact/1`).

Admins are held to it too. The author forwarding their own comment decides for
themselves. Remote comments are unchanged: their audience rules are 0030's.

## Consequences

- Members-only, staff-only and non-federating threads cannot be forwarded out
  by anyone but each comment's author.
- A comment from a public, federated thread forwards as before.
- A restricted author's comments cannot be forwarded until the restriction
  ends.

## Acceptance gate

`describe "forward_comment_to_board/3"` in `test/baudrate/content_test.exs`.

## Alternatives considered

- **A `forwardable` flag on comments.** Mirrors articles, but adds a setting
  nobody would think to set on a reply; the thread's own reach is the better
  default for words written into a conversation.
- **Ask the author to approve each forward.** A pending-forward workflow for a
  rare action; the rule above makes every forward one the author has already
  published.
