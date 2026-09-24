# 0075 — Moving an article arrives where it goes, and withdraws only what stopped being public

- **Status:** Accepted
- **Date:** 2026-09-25
- **Deciders:** Baudrate maintainers
- **Related:** Phase 7C and decision P7-D3 (who may move); builds on the
  cross-posting rule of P1-D5, the outbound gate and withdrawals of
  [0043](0043-the-outbound-federation-gate-and-withdrawals.md), committed
  publishing of [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md),
  and the arrival announcements of
  [0070](0070-a-member-hears-about-what-they-chose.md). v1.42.1's last-board
  fix is the reason a move is never a remove.

## Context

An article posted in the wrong board could only be taken out of it: a
moderator removed it and asked the author to cross-post it again. A board
that should be merged or retired could not be deleted while it held
articles, and nothing moved them, so the fix was SQL. Phase 7 exists so that
running the site does not need a shell.

"Move" sounds like one database write, but the article has also been
published. Its `Create` went to the old board's followers, the board
`Announce`d it, and a Lemmy community treats it as a post of that community.
ActivityPub has no activity that re-homes an object, and no peer re-homes a
post it already holds.

## Decision

### 1. A move needs the rights of both boards

Admins and global moderators may move any article, and so may someone who
moderates **both** boards (`Permissions.can_move_article?/3`). This is P1-D5
applied twice: a move takes the article out of one board, which is that
board's business, and puts it in another, which is that board's business
too. The author alone may not; moving is reorganising the site, not editing
the post.

### 2. One transaction, and never a board-less article

`Content.move_article_to_board/4` locks the article row, removes the link to
`from`, adds the link to `to`, and queues its activities in the same
transaction (0034). It refuses a soft-deleted article, the same board twice,
a `from` the article is not in and a `to` it is already in. Because the new
link is written in the same step, a move can never leave the article in no
board, which v1.42.1 showed would publish it.

### 3. What goes out

- **Arriving in a federated board:** the article arrives exactly as a
  forward delivers it (`Publisher.publish_article_forwarded/2`): `Create` to
  that board's followers for a local article, then the board's `Announce`.
  `announce_arrival/2` tells the board page and its watchers.
- **A local article that stops federating:** if it passed the outbound gate
  before the move and fails it after (it left the only federated board it
  was in for a private or non-federating one), it is **withdrawn** with
  `Delete`, addressed to the audience it had before. This uses
  `intent: :withdraw`, so the gate does not stop it (0043).
- **Anything else sends nothing to the old board's followers.** The article
  is still public where it now lives, so there is nothing to withdraw, and a
  peer would not re-home its copy anyway.
- **A remote article is only relinked here.** We never send `Update` or
  `Delete` for an object another server owns; the new board's `Announce`
  still goes out.

### 4. Emptying a board moves each article

`Content.move_board_articles/3` moves every article of a board, one at a
time through the same function, so each gets its checks and its activities.
An article already in the target board just leaves the old one. A withdrawn
(soft-deleted) article is relinked with no activity, because its link is
what blocks deleting the board and it no longer federates. `delete_board/1`
still refuses a board with articles; emptying it first is the deliberate
step.

### 5. Order is moved, not typed

Boards are ordered by **Move up** and **Move down** among their siblings
(`Content.move_board/2`). The siblings are locked and renumbered in their
current order, so boards that shared a position still move. Every listing
now breaks position ties by `id`, as the board cache already did. A new
board goes after its siblings.

All four actions (moving an article, moving a board's articles,
reordering, and deleting) are recorded in the moderation log.

## Alternatives considered

- **Send `Update(Article)` with the new `audience` to the old board's
  followers.** No implementation re-homes a post from an `Update`, so it
  would cost a delivery to every follower for no effect. It also names the
  new board to servers that never followed it.
- **Always `Delete` from the old board's followers.** A `Delete` names the
  object, not the board, so peers would remove a post that is still public
  here, including for their users who follow the author rather than the
  board.
- **Let the author move their own article.** Authors choose boards when they
  post and can cross-post; moving it out of a board is the board
  moderator's decision (P1-D5).
- **Delete a board's articles with the board.** This would destroy other
  people's writing as a side effect of tidying the board list.

## Consequences

- A moderator can fix a misplaced post, and an admin can merge or retire a
  board, without SQL. Remote copies in the old community stay where they
  are, as they would after any re-organisation on a Lemmy instance.
- An article moved into a private board disappears from other servers, and
  one moved back out is announced again to the new board's followers.
- `test/baudrate/content/article_move_test.exs` is the acceptance gate: the
  rights, the refusals, each of the publishing cases, emptying a board and
  ordering.
