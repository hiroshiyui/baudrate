# 0083 — The inbound gate is the outbound gate

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Baudrate maintainers
- **Supersedes** exception 2 of [0004](0004-federation-gate-for-non-public-boards.md)
  ("local articles whose author has remote followers accept them"). The rest
  of 0004 — one predicate for every inbound interaction, remote articles always
  accepted, silent `:ok` drops — stands.
- **Related:** [0043](0043-the-outbound-federation-gate-and-withdrawals.md)
  (the outbound gate), [0050](0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md)
  (comment and poll URIs), [0082](0082-federated-articles-may-be-quoted.md)
  (quotes already use the outbound predicate)

## Context

0004 let a local article in a board that does not federate take inbound
likes, boosts, replies and poll votes when its author had an accepted remote
follower, because "user-actor fan-out may already have published the article".

That premise stopped holding when 0043 gated the author's own follower fan-out:
`Delivery.enqueue_for_article/4` sends nothing to the author's followers unless
the article is board-less or in a federated board. Since then no follower has
ever received such an article, yet the inbound exception stayed.

What remained was a way in. Follows are auto-accepted unless the member turns
on `manually_approves_followers`, so any remote server could follow a member
and then reply to, like, boost or vote on everything they wrote in members-only
and staff-only boards. It did not need a slug: comment and poll ids are
sequential (`/ap/comments/<N>`, `/ap/polls/<N>`, ADR 0050), so every thread was
enumerable. Each reply stored a comment in the private thread and notified the
author and the thread's watchers.

## Decision

`InboxHandler.article_federated?/1` answers for a local article with
`Delivery.article_boards_federated?/1`, the predicate the outbound gate uses:
board-less, or in at least one board where `Board.federated?/1` holds.
**Inbound is never wider than outbound** — a peer may interact only with what
we would have sent it. A deleted article still takes nothing; a remote article
still takes everything 0004 allows.

A board-less local article now accepts interactions whether or not its author
has followers, because outbound publishes it.

## Consequences

- Private, staff-only and AP-disabled boards cannot be written into from the
  network by following their members first.
- The gate preloads `:boards`; one more query per inbound interaction on a
  local article, the same cost `QuoteRequest` already paid.
- An author who has followers and posts in a board that does not federate gets
  no remote interactions on that post — which is correct, since no remote
  server was ever sent it.

## Acceptance gate

`test/baudrate/federation/inbox_handler_test.exs`: likes, boosts and replies
(by article URI and by comment URI, private and staff boards) are refused when
the author has remote followers.

## Alternatives considered

- **Keep the exception but require the author's follower to be the
  interacting actor.** Rejected: that follower never received the article
  either, and comment ids remain enumerable.
- **Gate only replies.** Rejected for the reason 0004 gives: a gate applied to
  some interactions and not others reopens the hole through the rest.
