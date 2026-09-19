# 0048 — A poll records who voted, and nothing reads it back

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Related:** the promise is a member-facing one, so it lives next to the
  other things a member is told about their own data —
  [0023](0023-data-export-threat-model.md) (their own votes are in their
  export) and [0026](0026-blocks-stop-interaction-locally.md). Recorded
  retroactively: polls shipped with this property and `CLAUDE.md` has stated
  it since, with nothing saying why the row exists at all.

## Context

"Poll votes are anonymous" and "the database tracks voters" are both true, and
read together they look like a contradiction. `poll_votes` holds a `user_id` or
a `remote_actor_id` next to the option, and two unique indexes
(`poll_votes_local_unique`, `poll_votes_remote_unique`) depend on it.

The row is there because a poll has to answer three questions that a bare
counter cannot:

- **Has this person already voted?** Without the voter, one member votes a
  hundred times and the result means nothing.
- **Can they change their mind?** Changing a vote deletes the existing rows and
  inserts new ones inside a transaction, which needs to find *theirs*.
- **What did I pick?** The article page shows the member their own choice, so
  the poll does not look unvoted every time they reload.

So the voter is recorded, and the promise is not that nobody knows — it is that
nothing reads it back. That is a weaker promise than the phrase "anonymous"
suggests, and writing it down is the point of this record: a future reader who
sees `user_id` on the table must find the rule rather than conclude there
isn't one.

## Decision

**The voter is written, and the only thing that ever reads it is the voter.**

1. **One read path, scoped to the asker.** `Polls.get_user_poll_votes/2` takes
   a poll id and a user id and is called only with the current viewer's own.
   There is no `list_voters`, no "who voted for this option", and none is
   added — not for admins, not for moderators, not for the author of the poll.
2. **Every surface renders counts.** `polls.voters_count` and
   `poll_options.votes_count` are denormalized and maintained transactionally
   (`Ecto.Multi`, `FOR UPDATE`). They exist for correctness under concurrency,
   and they are also what makes the anonymous rendering the *easy* one to
   write: no template ever has a list of voters in hand.
3. **Federation publishes counts and no collection.** The `Question` attachment
   gives each option a `replies` of `{"type": "Collection", "totalItems": n}`
   — the count with **no `items` key** — plus `votersCount`. This is Mastodon's
   shape, and the absent `items` is the decision, not an omission: an AP
   `Collection` is the natural place to list who, and it is left empty
   deliberately.
4. **Inbound vote Notes never become visible objects.**
   `InboxHandler.handle_poll_vote_for_article/3` consumes a Mastodon-style vote
   Note and returns `:ok`; it is not stored as a comment and never falls
   through to the comment handler. So a remote vote cannot surface in the
   article's replies collection, which is the way this would otherwise leak by
   accident.
5. **A member's own votes are in their data export** (0023), because they are
   their data. Nobody else's appear there.

## Alternatives considered

- **Do not store the voter at all.** The honest version of "anonymous", and it
  costs all three things above: no deduplication, no changing a vote, and no
  showing a member what they picked. Ballot-box anonymity is not what a forum
  poll is for.
- **Store a hash of the voter and the poll.** Looks stronger and is not: the
  voter set is the site's membership, so the hash is reversible by trying
  everyone. It would buy nothing and read as though it had.
- **Publish a voters collection over ActivityPub**, the way `Like` and
  `Announce` collections work. Rejected: it would make every vote public to the
  whole fediverse permanently, which is the opposite of the promise, and no
  peer asks for it.
- **A moderator tool that reveals voters on a suspicious poll.** The obvious
  request, and the reason the rule is stated absolutely. A capability that
  exists for good reasons is a capability that exists; the answer to brigading
  is the rate limits and the sanctions, not de-anonymising the people who
  voted.

## Consequences

- **This is anonymity from other members, not from the operator.** Anyone with
  the database can read `poll_votes`, and so can a backup
  ([0028](0028-backups-are-complete-folders-with-count-based-retention.md)).
  The site must not claim more than that.
- A brigaded poll can be seen (the counts move) but not investigated. That is
  accepted.
- Retention does not purge `poll_votes`: they belong to the article, and go
  when it is hard-deleted
  ([0040](0040-retention-deletes-what-nobody-touched.md)).
- Any new poll feature — result exports, "see who agrees with you",
  notifications about a vote — reopens this decision rather than extending it.

## Acceptance gate

`test/baudrate/content/poll_anonymity_test.exs`: several members vote, and the
article page, the ActivityPub object and the context API each carry counts and
nothing that identifies a voter other than the viewer themselves. A new surface
that renders a poll belongs in it.
