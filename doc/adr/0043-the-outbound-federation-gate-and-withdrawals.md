# 0043 — The outbound federation gate, and the withdrawals it must not touch

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Complements** [0004](0004-federation-gate-for-non-public-boards.md),
  which records the *inbound* half of the same predicate and whose Context
  already assumed this half existed. Supersedes nothing.

## Context

[ADR 0004](0004-federation-gate-for-non-public-boards.md) decided
that one predicate gates **every inbound** interaction with a local article,
and opens with the reason it is needed: *"Enforcing that on the outbound side
alone is not enough."* That sentence presumes a working outbound gate, and no
ADR ever recorded one. The rule lived in a `CLAUDE.md` gotcha and in comments
next to each of its call sites.

Undocumented, it was also incomplete. The v1.28.0 audit found four surfaces
publishing content out of boards whose federation an admin had switched off,
and a fifth was found afterwards by reading `doc/api.md` against the code:

| Surface | What leaked |
|---|---|
| `Delivery.enqueue_for_article/4` | the author's **own** follower fan-out — only the board fan-out was gated |
| `Publisher.enqueue_for_followers_and_authors/4` | a user `Announce`, whose object URI carries a slug derived from the title |
| `ObjectBuilder.article_object/1` | `cc`/`audience`, which name a board's actor URI and so its slug |
| `ActivityPubController.publicly_servable?/1` | the article object and the user outbox, which tested `min_role_to_view` only |
| `Content.Search.search_articles/2` (`/ap/search`) | full Article objects to anonymous callers, stamped `as:Public` |

One unsolicited Follow was the whole attack for the first of those: after it,
every post its author wrote in a staff-only board arrived on the follower's
instance.

Closing them created the opposite failure, which is the part worth a record.
Gating the outbound side uniformly also gated `Delete(Tombstone)` — so an
article that had left its last federated board could no longer be withdrawn.
Moderation removing a post from a public board is exactly what strands it: the
author's later delete never reaches the servers holding it, and the post stays
published on the fediverse forever. A correct-looking tightening of the gate
produced a permanent leak.

## Decision

**One predicate, `Content.Board.federated?/1`**: a board is federated when
`min_role_to_view == "guest"` **and** `ap_enabled == true`. Content leaves this
instance only for an article that is board-less or in at least one federated
board. All five surfaces above apply it.

**Never `Board.public?/1` for anything federation-related.** It asks only about
the view role. Turning `ap_enabled` off does not remove followers a board
already has, so `public?/1` would keep publishing to them. It remains correct
for site-side questions — guest board visibility, the RSS `<link>` tag, admin
badges — and those are its only remaining callers.

**A withdrawal is never gated.** `Delete(Tombstone)` and `Undo` pass
`intent: :withdraw` and go out regardless of the board:

- `publish_article_deleted/1`, `publish_comment_deleted/2` — `Delete`
- `publish_article_unliked/3`, `publish_comment_unliked/3`,
  `publish_article_unboosted/3`, `publish_comment_unboosted/3` — `Undo`

The reason is not a special case, it is the gate's own logic run to its
conclusion: **the gate exists to stop content leaving, and a withdrawal
carries no content.** Refusing to send one cannot protect anything. It can only
leave something already published in place.

`intent` defaults to `:publish`, so a new activity is gated unless its author
says otherwise. That is the right default — forgetting the option withholds a
post, which is recoverable; the opposite forgetting publishes a private one.

**The remote author of a remote article is never gated either.** A remote
article already exists on the fediverse under its own `ap_id`; the local board
it happens to sit in is not ours to enforce against its home instance. This is
the outbound twin of ADR 0004's first exception.

## Consequences

- **Two questions, not one, at every new outbound path**: does this carry
  content, and is the board federated? Only the second is a gate.
- Turning `ap_enabled` off now means what it says. Before this it removed a
  board from board fan-out and left four other routes open.
- `/ap/search` needed the gate as an **opt-in** option
  (`federated_only: true`), because `search_articles/2` also backs the site's
  own search, which must keep listing content in boards that do not federate.
  Hiding content from the instance's own members is not what the AP switch is
  for. The condition is a clause in the query rather than a filter over the
  results, so `totalItems` cannot advertise a count the pages are unable to
  fill.
- A member who deletes a post gets a `Delete` sent even from a board that
  never federated. That is deliberate: it may be a no-op on every recipient,
  and a no-op is the acceptable cost of never stranding a retraction.
- `test/baudrate/federation/publisher_test.exs` holds the acceptance gate —
  the describe block *"withdrawals are never gated by the board"*, eleven
  tests. **Add every new outbound path to it**, on both sides of the question.
  Unlike ADR 0030's and ADR 0040's gates, this one is not a file of its own;
  it sits with the publisher because that is where the `intent` option is read.

## Alternatives considered

- **Gate withdrawals too, for uniformity.** This is what closing the leak did
  at first, and it is the failure this record exists to prevent someone
  re-introducing. A uniform rule reads better and strands retracted posts on
  other people's servers.
- **Send withdrawals only to recipients that were sent the original.** Correct
  in principle and unimplementable in practice: delivery jobs are pruned, so
  there is no durable record of who received a post months ago. Sending the
  `Delete` to the current audience is the available approximation, and an
  unrecognised `Delete` is a no-op for the recipient.
- **Gate at the transport**, in `Delivery.deliver/2`, so no caller can forget.
  Rejected: the transport cannot tell a `Create` from a `Delete` without
  parsing the activity it is about to sign, and the decision needs the
  *article*, which the transport does not have. It also gave no way to express
  the withdrawal exception except by sniffing activity types, which is how the
  two rules would drift apart.
- **Strip the board from `cc`/`audience` and publish anyway.** Rejected: the
  object body is the content, and three unauthenticated endpoints serve it
  verbatim. Removing the addressing hides who it went to, not what it says.
