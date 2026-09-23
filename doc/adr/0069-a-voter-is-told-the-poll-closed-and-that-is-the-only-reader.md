# 0069 — A voter is told the poll closed, and that is the only other reader

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** Baudrate maintainers
- **Related:** amends [0048](0048-a-poll-records-who-voted-and-nothing-reads-it-back.md)'s
  decision 1, whose Consequences say that "notifications about a vote"
  reopen it rather than extend it — this is that reopening. The sweep it
  hooks into is the one `CLAUDE.md` records under "a closed poll announces its
  final counts once"; the notification is bounded by
  [0056](0056-boring-but-friendly.md) question 3.

## Context

Phase 6B asks for a notification when "a poll you voted in closes". A poll
has no stored closed state — `Poll.closed?/1` reads the clock — so the only
place closing is an *event* is `Content.sweep_closed_polls/0`, which already
runs hourly and stamps `polls.final_update_sent_at` exactly once per poll.

Telling a voter needs their id, and 0048 decision 1 says the only thing that
ever reads `poll_votes.user_id` is the voter, through
`Polls.get_user_poll_votes/2` with their own id. Finding everyone who voted
in a poll is a different read: by poll, not by asker. 0048 anticipated this
request and said it reopens the decision. Two answers need no new reader —
tell only the author, or tell nobody — and the operator chose neither on
2026-09-23: the person who needs to know a poll ended is the one who took
part in it.

## Decision

**The sweep reads a poll's local voters for one purpose — to tell each of
them it closed — and nothing else reads them.**

1. **One new reader, private.** `Polls.local_voter_ids/1` is a `defp` inside
   the sweep's module. It is not exported, not delegated from `Content`, and
   its result goes straight into notification rows. There is still no
   `list_voters` and no "who voted for this option", for anyone.
2. **Each recipient learns only what they already knew.** A `poll_closed`
   notification carries the article and nothing else: no option, no count,
   no vote, no actor. A voter is told that a poll they voted in has closed,
   which is a fact about themselves. The author is told too, and learns
   nothing new either — `voters_count` is already public, and the author gets
   one notice whatever the turnout.
3. **Local voters only.** A remote voter's instance holds its own poll state
   and gets the final counts through the existing `Update(Question)`. Remote
   polls a member here voted in are not swept (their counts are the
   originating instance's), so they send no notice. That is a known gap, not
   a promise.
4. **Once, or not at all.** The stamp is a conditional `UPDATE`, and only the
   run that sets it sends the notices. They are not in the same transaction
   as the stamp: creating a notification broadcasts over PubSub and schedules
   a push, and neither may happen for a row that is not committed yet. A
   crash between the stamp and the notices loses them; that is the better
   failure than sending them twice.
5. **The row-level gate still applies.** A voter who can no longer open the
   article is skipped (`ArticleHelpers.user_can_view_article?/2`), as a
   mention is. The notice can be switched off like other engagement
   notifications.

## Alternatives considered

- **Tell only the author.** Needs no new reader and leaves 0048 untouched.
  Rejected because it answers the wrong person: the author wrote the poll and
  can see when it closes; a voter is the one who has to come back to find out.
- **One notice per option, or the result in the notice.** A notification row
  that carries a tally, or which option won, copies poll data into a table
  retention purges on a different schedule (90 days) from the article's.
  Rejected; the article page renders the result, and the notice links there.
- **Notify from the page when a voter next opens it.** Needs no voter lookup,
  and tells nobody who does not come back — which is everyone the feature is
  for.
- **Let the author choose whether voters are told.** A second setting on a
  feature whose only content is "it's over". Rejected.

## Consequences

- 0048's promise is narrower now, and stated exactly: nothing *displays* or
  *returns* a voter to anyone but themselves; one private function reads them
  to address a notice. Its Status line says so.
- The notification rows are themselves a record of who voted in which poll,
  for 90 days, readable by anyone with the database. That is the same
  exposure `poll_votes` already has ("anonymity from other members, not from
  the operator"), for a shorter time.
- A poll that closed before this shipped and was already stamped sends
  nothing. Nothing is backfilled.

## Acceptance gate

`test/baudrate/content/poll_anonymity_test.exs`, which is 0048's gate, gains
a block for this record:

- the author and each local voter are told once, and a second sweep tells
  nobody;
- the row carries the article and no option, count, vote or actor;
- a voter who lost access to the article is skipped;
- **an AST check that `local_voter_ids/1` is the only function in `Polls`
  that selects `user_id`, and that it is not exported;**
- an AST check that nothing outside the poll schemas, `Polls` and the
  member's own data export names `PollVote`.
