# 0054 — Attention follows the board, not a ranking

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Related:** states the reason behind `CLAUDE.md`'s opening line — a public
  information hub, not a social network. The personal timeline it leaves alone
  is [0039](0039-the-personal-stream-is-a-timeline.md); the ordering trap it
  shares with inbound content is
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)'s
  neighbour, a peer-supplied `published_at` clamped to now. Resolves **P4-D1**
  in `doc/TODOs.md`.

## Context

Phase 4 (discovery and onboarding) carried an open question, P4-D1, recorded
as *"What 'popular' means"*, with a placeholder answer already written into
it: likes, boosts and comments in the last 7 days, public boards only. Around
it sat the rest of the standard shape — a `/popular` page, a `/recent` river,
and "latest articles from public boards" on the home page.

Answering the question as asked would have built the thing every forum builds.
The question was instead declined, and the reasons are not about discovery
mechanics. They are about what this site is.

**A ranking is not a measurement; it is an intervention.** What a popularity
list surfaces gets read, which raises its rank, which keeps it surfaced. The
list becomes its own cause, and the gap between the first item and the
twentieth widens for reasons that have nothing to do with either. Attention
settles on whoever already had it. A board with three careful posters never
appears on it, and the people who would have enjoyed that board never learn it
is there.

**Engagement cannot tell an argument from a conversation.** A flame war
produces more replies, faster, than anything else a forum ever does. Any
ranking computed on activity therefore promotes it — and promotes it to the
front page, to everyone, including the people who would never have opened that
board. The two effects compound: the ranking selects for conflict, the
conflict draws attention, the attention raises the rank. Nobody has to intend
any of it; the loop does not require bad actors, only arithmetic.

There is a third thing, quieter than either. A visible ranking changes what
people write, because they can see what gets ranked. That cost falls on the
posts that are never made, so it never shows up in any metric the site could
collect about itself.

A social network's job is to decide what you should look at today. A public
information hub's job is that you can find the board you want and read it.
Those are different products, and the ranking is most of the difference.

## Decision

1. **Nothing is ranked by engagement.** No `/popular`, no trending, no hot, no
   score, no leaderboard, no "most active" anything — for content, boards or
   people. P4-D1 is resolved by dropping the feature rather than defining it.

2. **There is no river of posts across boards.** No `/recent`, and the home
   page lists boards rather than the newest articles inside them. Chronology
   is weaker than ranking, not exempt from it: a site-wide river still rewards
   volume, still strips the board context that tells a reader what a post is
   for, and still occupies the one page every visitor lands on.

3. **No count that compares one board with another.** Board cards carry no
   post count — a count is a scoreboard, and it delivers a verdict on the
   quiet boards before a visitor has opened either. **Last activity stays:** it
   answers "is anyone here", which is navigation, and no board is diminished by
   answering it.

4. **Board order is editorial.** The cards come out in `Board.position`, set
   by an admin, and that is the whole ordering. Sorting by activity would
   reintroduce the ranking in the one place it is least visible as one —
   arranged by the site rather than chosen by it.

5. **What this does not touch**, because none of it is the site choosing for a
   reader:
   - chronological order *within* a board, which is what a board is;
   - search, where the query and the ordering are the reader's;
   - tag pages, and the syndication feeds, which are pulled rather than pushed;
   - the personal timeline (0039), which is chronological over accounts the
     reader chose to follow;
   - per-viewer state such as unread markers, which compares nothing between
     boards and is visible to nobody else;
   - `/unanswered`, which is the inverse loop and is kept deliberately: it
     spends attention where none has been.

## Alternatives considered

- **Define "popular" narrowly — a short window, or a decay function.** The
  same loop, forgetting faster. A decayed rank still ranks by engagement, and
  a short window makes it *more* responsive to a fight, not less.
- **Rank on likes only, not replies,** to avoid rewarding arguments. Likes
  track visibility, so the concentration effect is untouched; and it buys the
  appearance of a fix for the half of the problem that was easier to name.
- **Keep `/recent` and drop only `/popular`.** Considered seriously, since
  chronology does not rank. Declined under decision 2: on the front page a
  river is still the site deciding what a visitor sees first, and the rest of
  its costs remain.
- **Make it opt-in per member.** Whatever is on by default is what almost
  everyone gets, so this mostly relocates the decision. It also assumes the
  harm is to the reader, when the part that matters most is what a visible
  ranking does to what gets written.
- **Leave P4-D1 open.** The worst option available: the question already
  contained a plausible answer, so leaving it open meant someone implementing
  the placeholder without ever making the decision.
- **A curated or editor-picked front page.** Not rejected on principle — it is
  a human choosing, which is what decision 4 already allows for board order.
  Out of scope here, and it needs its own record if it is ever built, because
  "the admin picks what everyone sees" carries a different set of problems.

## Consequences

- **Discovery is slower, and that is the trade.** A visitor picks a board.
  Nothing hands them today's best thing, because nothing here believes it
  knows what that is.
- **A good post in a quiet board can go unseen.** Accepted, with
  `/unanswered`, search, tag pages and the feeds as the counterweights — none
  of which rank, and all of which are reached on purpose.
- **Growth is probably slower.** A front-page river is the standard retention
  hook and this gives it up. That is the decision, not an oversight in it.
- **This is a record whose whole job is to be found later.** "Add a popular
  page" and "show the latest posts on the home page" are the two most obvious
  feature requests a forum ever receives, and both look like pure improvements
  from inside a pull request. Reversing this needs a superseding record, not a
  patch.
- Phase 4's "Done when" changed with it: a guest's first page shows the site's
  purpose and the boards it has, not recent content.

## Acceptance gate

`test/baudrate_web/no_content_ranking_test.exs`, which covers the falsifiable
part: no ranking or river route is mounted, the home page lists boards rather
than the articles inside them, and board order comes from `position` and not
from activity. Add a route or a listing that ranks and it fails.

What it cannot check is the judgement — whether some future surface *is* a
ranking. `doc/baudrate-spec.md` says so in the ungated table rather than
pretending otherwise.
