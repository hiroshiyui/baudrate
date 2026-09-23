# 0070 — A member hears about what they chose, and their followers are theirs

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** Baudrate maintainers
- **Related:** applies [0056](0056-boring-but-friendly.md)'s questions 2 and
  3 to two Phase 6C features; removing a follower uses the `Reject(Follow)`
  that [0026](0026-blocks-stop-interaction-locally.md) already sends when a
  member blocks; watcher notices are published after the commit in the way
  [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md)
  allows for best-effort work.

## Context

Phase 6C asks for two things: a member can **watch a board or a thread** and
be told about what is new there, and a member can **see their followers**,
with a count and a way to remove one.

Both are old forum features, and both come with a common default that this
site refuses elsewhere:

- Forums usually **watch a thread for you** the moment you reply in it, and
  often the moment you open it. That is a notification the reader never
  asked for — 0056 question 3, "anything whose purpose is the return visit
  rather than the thing returned to".
- Social sites put the **follower count on the profile**. That is a number
  that compares people — 0056 question 2, and the reason 0054 keeps post
  counts off board cards.

Two findings from building it shaped the rest:

- An article reaches a board by at least six paths — written here, arriving
  from another server, forwarded, a remote comment materialised into a board,
  and three inbox cross-posts — and until now only the first ran a hook. The
  inbox's cross-post did not even tell the board page, so its "N new posts"
  offer (6B) never showed one.
- The only way to remove an accepted remote follower was blocking, which also
  deletes the member's own follow in the other direction.

## Decision

1. **A watch is created only by the member's own toggle.** Writing an
   article, commenting, bookmarking and liking create none. The member turns
   it on and off on the board or the thread, and sees and removes every watch
   on `/watching`.
2. **A board watch reports new threads, never comments.** To follow a
   conversation, watch the thread. A busy board would otherwise send a
   notice for every reply in it.
3. **Every arrival is announced once, from one place.**
   `Articles.announce_arrival/2` broadcasts to the board page and tells the
   board's watchers, and every path that places an article in a board calls
   it; the inbox's cross-post goes through `cross_post_article/2`, which
   announces only the boards the article newly joined.
4. **One event is one notice.** A watcher is not told about a comment that
   already reached them as a reply to their article or comment, or as a
   mention, nor about their own post. Blocks and mutes apply as to every
   notification, and a watcher who can no longer open the board or thread is
   skipped — watching never outlives access.
5. **Watcher notices are best-effort.** The fan-out runs after the commit as
   a supervised task (`Federation.schedule_federation_task/1`), so a board
   with many watchers does not hold up the request that posted, and a notice
   lost to a restart is acceptable, as a push is. Nothing that must survive
   depends on it.
6. **A member's follower count and list are shown to the member alone,** on
   `/followers`. Nothing is added to the public profile. The ActivityPub
   followers collection is unchanged: other servers use it, and whether it
   is readable without a signature is `ap_authorized_fetch`'s question.
7. **Removing a follower is `Reject(Follow)` for an account elsewhere and a
   silent delete for a member here,** and tells the follower nothing. It
   does not stop them following again; the page says so, and says that
   blocking does. Watching and removing a follower stay open to a member
   under a sanction: one is reading and the other makes the account safer.

## Alternatives considered

- **Auto-watch the threads a member writes in or replies to.** The forum
  convention. Refused under decision 1: the author already hears about direct
  replies, and anything more is the site deciding the member should come
  back.
- **Let a board watch include replies.** Refused under decision 2; the
  thread watch is the tool for a conversation.
- **A public follower count, with a private list.** Refused under 0056
  question 2.
- **Tell the removed follower.** `Reject(Follow)` deliberately says nothing,
  as a block does not (0026), and a notice would turn a quiet boundary into
  a confrontation.
- **Deliver watcher notices inside the posting transaction.** Durable, and
  it makes the poster wait for every watcher; a notification is not a
  publication (0034 is about the latter).

## Consequences

- A member with many watchers on a board generates that many notification
  rows per thread, bounded only by the board's audience. The rows are purged
  after 90 days like every notification.
- A watcher who is also the thread's author, or was replied to, gets the
  more specific notice rather than two.
- A watch outlives lost access but does nothing: `/watching` lists it
  without its title and lets it be removed.
- Watches are the member's data and are in their export (0023).

## Acceptance gate

`test/baudrate/content/watch_test.exs`:

- toggles, and the refusals for what the member cannot open;
- writing, replying, bookmarking and liking create no watch;
- a board watcher is told about a thread written here, one from another
  server, one forwarded and one cross-posted by the inbox — once — and about
  no comment;
- a thread watcher is told about a new comment, and not about their own, a
  blocked author's, a followers-only one from elsewhere, or one that already
  reached them as a reply or a mention;
- a watcher who lost access is skipped, and a held post is announced only
  when approved.

Removal is covered by `test/baudrate/federation/follower_removal_test.exs`,
and the privacy of the count by `followers_live_test.exs`. **A new way for an
article to reach a board belongs in the gate's board block.**
