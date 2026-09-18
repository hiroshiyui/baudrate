# 0039 — The personal stream is a timeline, not a feed

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Related:** renames the tables named in
  [0015](0015-soft-deletion.md), [0016](0016-authorization-at-the-context-boundary.md)
  and [0025](0025-account-migration.md), whose text keeps the old names as
  those records are not rewritten

## Context

"Feed" named four unrelated things:

| Sense | Where |
|---|---|
| RSS and Atom arriving from bots | `Bots.FeedParser`, `FeedWorker`, `bot_feed_items` |
| RSS and Atom we publish | `FeedController`, `feed_xml` |
| Public board listings | `Content.Feed` |
| Posts from followed remote actors | `feed_items` + four satellite tables, `Federation.Feed`, `/feed` |

The first three are feeds in the ordinary sense. The fourth is not: it is what
every other fediverse implementation calls a timeline.

The collision was not theoretical. Planning 2F's retention purge, the operator
read "`feed_items` … after 90 days" as the RSS entries their bots post and
asked for those to be exempt. They already were — RSS entries become ordinary
articles — but the question exposed a worse neighbour: **`bot_feed_items`**,
one character away from the table 2F does purge, holding the `(bot_id, guid)`
ledger that stops a bot re-posting. A retention job written from a table name
would have made every bot re-publish its entire back catalogue.

## Decision

The fourth sense becomes the **timeline**: `timeline_items` and its four
satellite tables, `Federation.Timeline`, `TimelineLive`, `/timeline`.

The three genuine feeds keep the name. `Content.Feed` also keeps it for now —
"public feed listings" is a separate question from this one, and renaming it
would enlarge a change whose value is precision, not tidiness.

**Why "timeline" and not "incoming".** The operator first proposed
`incoming_items` and `/incomings`. Rejected: RSS entries are also incoming, so
it would leave a reader choosing between `incoming_items` and
`bot_feed_items` — the same collision in new words. Mastodon, Pleroma,
Akkoma, Misskey and GoToSocial all say timeline, so it is also the word our
own members already know.

### What the migration has to rename with the tables

Indexes and constraints, not just the tables. Ecto derives a default
constraint name from the table and column, so a renamed table with its old
index names would make `unique_constraint([:timeline_item_id, :user_id])` look
for a name that does not exist — and a duplicate like or boost would raise a
Postgrex error instead of returning a changeset error. The rename walks
`pg_constraint` and `pg_class` rather than a hand-kept list, and excludes
`bot_feed_item%` by name.

### What deliberately does not change

- **`role="feed"`** in the template. That is the WAI-ARIA role for a stream of
  articles and means something to a screen reader that our vocabulary does not.
- **`ap_id` fragments already published.** Replies written before this keep
  `#feed-reply-…`; an `ap_id` is immutable once a remote server holds it.
  Nothing parses the fragment, so both forms coexist.
- **ADRs 0015, 0016 and 0025**, which name `feed_items`. Accepted records are
  not rewritten ([0000](0000-use-architecture-decision-records.md)); this one
  is the pointer that explains the old names.

## Consequences

- `/feed` redirects permanently to `/timeline`: members bookmark that page.
- A rollback past this release needs the migration rolled back too, which
  `down` does, index names included.
- Anyone reading an older ADR, a v1.27.0 backup manifest or a support thread
  will meet `feed_items`. That cost is paid once; the collision it removes was
  going to be paid every time someone wrote a query against the wrong table.
- **The rename is not what protects `bot_feed_items`.** Distinct names make
  the mistake unlikely, not impossible, so 2F carries the exclusion in writing.

## Alternatives considered

- **Leave the names and document the difference.** This is what was done
  first, and it survives in 2F. Rejected as the whole answer: a note in a
  roadmap does not reach someone reading table names in `psql`.
- **`incoming_items` / `/incomings`.** See above.
- **`stream_items`.** Unambiguous, but matches nothing our members see
  elsewhere in the fediverse.
- **Renaming `Content.Feed` too.** Deferred, not rejected — a separate
  question about a separate ambiguity.

## Acceptance gate

The suite, unchanged in count: the rename touched 65 files and 4,292 tests
still pass. `test/baudrate/federation/timeline_item_test.exs`,
`timeline_item_context_test.exs` and `timeline_item_reply_test.exs` carry the
schema behaviour; `test/baudrate_web/live/timeline_live_test.exs` covers the
page and its pager.
