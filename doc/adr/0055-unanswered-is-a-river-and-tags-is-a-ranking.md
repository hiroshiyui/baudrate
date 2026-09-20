# 0055 — `/unanswered` is a river, `/tags` is a ranking

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Amends** [0054](0054-attention-follows-the-board-not-a-ranking.md),
  decision 5's last bullet, which kept `/unanswered` as an exception.
  Everything else in 0054 stands, and this makes it stricter rather than
  looser: its exception list now holds nothing that crosses boards.
- **Related:** empties the "New pages" item of Phase 4A in `doc/TODOs.md`.

## Context

Phase 4A proposed four pages beyond the board list. 0054 refused two of them,
`/recent` and `/popular`, and two survived: `/unanswered`, and a tag index at
`/tags`.

Both fail 0054 — one on each of its two decisions — and both survived the
record that should have caught them for the same reason. Each looked like the
*opposite* of the thing being refused.

### `/unanswered` is a river

Decision 2 says there is no river of posts across boards: no page that takes
articles out of the boards they were written in and lists them together.
Decision 5 then carved out `/unanswered`, on the grounds that it is "the
inverse loop … it spends attention where none has been."

That answers decision 1, which is about ranking by engagement, and it is true
as far as it goes: a list of posts with no replies cannot concentrate
attention on whoever already had it. It never answers decision 2. A
cross-board list of individual articles is a river. Filtering it by reply
count changes which posts are in it, not what kind of page it is.

The operator put it more briefly: *it is just like `/recent`*. That is the
same observation with the arithmetic done. A post with no replies is
overwhelmingly a post nobody has read **yet** — reply counts start at zero and
only move upward — so membership is mostly a function of age:

- ordered **newest first**, it is `/recent` minus the few posts that happened
  to get an answer inside the window: the page 0054 refused, reached by a
  filter that removes almost nothing;
- ordered **oldest first**, it genuinely is not `/recent` — it is a list of
  the site's least wanted posts, published to everyone, in order of how long
  they have been ignored. That is not a counterweight to the Matthew effect.
  It is a scoreboard of neglect: the comparison 0054 refused to make between
  boards, made between posts instead.

### `/tags` is a ranking

An index of every tag on the site raises one question, which is what orders
it.

By use count it is a popularity ranking of topics, and a tag cloud is that
ranking drawn in type sizes. It is worse than a ranking of posts, because a
tag is a thing people *write toward*: seeing which topics are large tells an
author what to file under, so the loop closes on production and not only on
attention. Alphabetically it ranks nothing and nobody reads it — an inventory
of every string anyone has ever hashed is a sitemap, not a page.

So the ordering that would make it useful is the one 0054 refuses, and the
ordering 0054 permits is the one that makes it useless. There is no third
ordering. That is enough to decide it without needing a rule about tag
indexes.

**What is not affected: `/tags/:tag`**, which already exists and stays. The
reader named the tag, so nothing was chosen for them — 0054 keeps tag pages on
exactly that ground ("pulled rather than pushed") and this record does not
touch it.

## Decision

1. **`/unanswered` is not built,** and joins `/popular`, `/trending`, `/hot`,
   `/recent` and `/top` in the gated route list, so the build fails if it
   appears rather than review having to notice.

2. **There is no tag index at `/tags`.** It is gated the same way. Individual
   tag pages (`/tags/:tag`) are untouched, and so is finding a tag by typing
   it into search or following one from a post.

3. **0054's exception list holds nothing that crosses boards.** What remains
   on it stays for reasons about the reader, not about the filter:
   chronological order *within* a board, which is what a board is; search, tag
   pages and the feeds, which are pulled; the personal timeline (0039), which
   is chronological over accounts the reader chose; and per-viewer state such
   as unread markers, which compares nothing and is visible to nobody else.
   None of them presents an ordering of other people's posts that the site
   picked.

4. **The counterweight for a good post in a quiet board is the board**, plus
   search, tags and the feeds. It is not a page. 0054 listed `/unanswered` as
   one of four counterweights; the honest position is three, and the
   consequence it was softening is accepted plainly instead.

## Alternatives considered

- **Keep `/unanswered`, ordered oldest first.** Considered hardest, because it
  really is not `/recent`. Declined: still a cross-board river, and it
  publishes a ranking of neglect. Telling a member their post is top of the
  ignored list is a worse thing to do to them than letting it be quiet.
- **Keep it per board — `/boards/:slug/unanswered`.** This violates nothing:
  inside a board it crosses no boundary, ranks nothing, and is the board's own
  business. **Not built now** because nobody has asked and a board's
  chronological list already shows reply counts, but it stays available:
  adding it later needs no amendment to 0054 or to this record. Note what it
  is not — the moment such a page aggregates across boards it is the page this
  record refuses.
- **An alphabetical `/tags` index, as a compromise.** Declined as useless
  rather than harmful, which is its own reason not to build it. If an
  inventory of tags is ever wanted it is wanted by a crawler, and that is
  `sitemap.xml` in Phase 4B, where an inventory belongs.
- **Tell the author their post got no reply.** A notification about the
  absence of something, which is a way of making quiet feel like failure. Out
  of scope here and not obviously wanted anywhere.
- **Leave 0054 as it was and drop the pages only from `doc/TODOs.md`.**
  Rejected on process grounds: an accepted record would then name a page that
  will never exist, and the next reader would have to guess which of the two
  was current. 0054 is amended in its Status line and nowhere else.

## Consequences

- **Phase 4A's "New pages" item is now empty.** Discovery is the board list,
  search, the feeds, and a tag you were given by a post. Nothing surveys the
  site for you.
- **A post that gets no reply has no page of its own.** Whether it gets
  attention is the board's business, which is where 0054 put every other such
  question.
- **Topics cannot be browsed, only followed or searched.** The same trade 0054
  made for content, applied to the labels on it.
- **0054 loses a quarter of its stated counterweights,** and the consequence
  it recorded — "a good post in a quiet board can go unseen" — is now accepted
  with three, not four. That is the trade, stated once rather than softened.
- **Both refusals are gated rather than asserted.** Reversing either costs a
  superseding record *and* a test change, which is the point: these pages will
  be proposed again, and they will look like improvements every time.
- **The judgement that caught this was not the record's.** 0054 gates four
  falsifiable shapes and says honestly that whether some *new* surface is a
  ranking is for review. An exception written into the record itself is the
  one thing neither the gate nor that note covers — so an exception list is
  worth re-reading whenever the rule is.

## Acceptance gate

`test/baudrate_web/no_content_ranking_test.exs` — `/unanswered` and `/tags`
are both in `@ranking_paths`, so mounting either fails the build exactly as
`/popular` would. `/tags/:tag` is a different route and is unaffected.

The rest of 0054's gate is unchanged, and so is its limit: no test recognises
a ranking it has not been told about.
