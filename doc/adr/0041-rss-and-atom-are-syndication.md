# 0041 — RSS and Atom are syndication, not feeds

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Supersedes** the "What deliberately does not change" carve-out for the two
  RSS senses in [0039](0039-the-personal-stream-is-a-timeline.md). The rest of
  0039 stands: the personal stream is still a timeline, and that is still the
  right rename.

## Context

[0039](0039-the-personal-stream-is-a-timeline.md) found "feed" naming four
unrelated things and renamed one of them — the personal fediverse stream became
the **timeline**. It deliberately left the rest alone, reasoning that RSS and
Atom really are feeds, so the word was correct there.

That reasoning was sound and it did not go far enough. After 0039, "feed" still
named three things:

| Sense | Where, after 0039 |
|---|---|
| RSS and Atom arriving from bots | `Bots.FeedParser`, `Bots.FeedWorker`, `bot_feed_items` |
| RSS and Atom we publish | `FeedController`, `FeedXML` |
| A stream of articles, to a screen reader | `role="feed"` |
| Public board listings | `Content.Feed` |

0039 removed the collision that had already caused a near-miss. It did not
remove the residual work of reading `FeedWorker` and `FeedController` and
holding in mind which direction each one points, or of seeing `BotFeedItem`
next to `TimelineItem` and having to recall that one is a dedup ledger and the
other is content.

The evidence that the split was still incomplete arrived immediately. Reviewing
this release, `Bots.record_feed_item/3` was found renamed to
`record_timeline_item/3` — a mechanical over-application of 0039's own sweep,
onto the one function 0039 had carved out, writing the one table whose loss
would make every bot re-publish its entire back catalogue. The rename sweep
itself could not tell the senses apart, because the word did not distinguish
them.

**Syndication** is the word for what RSS and Atom are — it is the S in RSS, and
it is what the Atom specification calls itself. It collides with nothing in
this codebase and nothing in the fediverse vocabulary.

## Decision

The two RSS senses become **syndication**:

| Before | After |
|---|---|
| `Baudrate.Bots.FeedParser` | `Bots.SyndicationFeedParser` |
| `Baudrate.Bots.FeedParserNative` | `Bots.SyndicationFeedParserNative` |
| `Baudrate.Bots.FeedWorker` | `Bots.SyndicationFeedWorker` |
| `Baudrate.Bots.BotFeedItem` | `Bots.BotSyndicationItem` |
| `bot_feed_items` (table) | `bot_syndication_items` |
| `Bots.record_feed_item/3` | `Bots.record_syndication_item/3` |
| `BaudrateWeb.FeedController` | `BaudrateWeb.SyndicationFeedController` |
| `BaudrateWeb.FeedXML` | `BaudrateWeb.SyndicationFeedXML` |
| `:feed_worker` (heartbeat key) | `:syndication_feed_worker` |

**The table renames too**, which 0039 refused. Its refusal was specific: that
migration renamed five sibling tables by walking `pg_constraint` and `pg_class`
with a `LIKE '%feed_item%'` pattern, and `bot_feed_items` matched it
accidentally. Excluding it by name was protection against a pattern, not a
judgement that the table could never be renamed. Renamed deliberately and
alone — with the exclusions inverted, nothing matching `timeline_item%`
touched, no `DELETE` of any kind, and `down` verified to restore every object
name — the hazard 0039 was guarding against is not present.

### What deliberately does not change

- **`role="feed"`.** The WAI-ARIA role for a stream of articles. It means
  something specific to a screen reader, and it is not ours to rename.
- **The public URLs**: `/feeds/rss`, `/feeds/atom`, `/feeds/boards/:slug/rss`
  and the rest. Every subscriber has one saved, and unlike `/feed` there is
  nothing ambiguous about them — "feed" in an RSS URL is what the whole web
  calls it. Renaming would break readers to make a document read better.
- **The Rust crate `baudrate_feed_parser`** and its directory. The
  reader-facing name is the Elixir module; moving the crate also moves
  `native/`, `mix.exs` and the CI checksums, for no gain in the code anyone
  reads. `SyndicationFeedParserNative` still declares
  `crate: "baudrate_feed_parser"`.
- **`bots.feed_url`.** A column on a bot row, unambiguous in place.
- **`Content.Feed`** — the fifth sense, public board listings, which is neither
  syndication nor the timeline. Its own moduledoc calls its queries "public
  timeline queries", which now reads as the wrong thing entirely. Left for a
  separate change, because the right name is a different question and this
  record should not answer it badly in passing.

## Consequences

- `workers.feed_worker` in the detailed health report becomes
  `workers.syndication_feed_worker`. An operator alerting on that key must
  update it; there is no compatibility alias, because two names for one worker
  is the problem this record exists to remove.
- Log lines change prefix from `bots.feed_worker:` to
  `bots.syndication_feed_worker:`.
- A backup manifest or dump from v1.27.0 or earlier names `bot_feed_items`.
  Restoring one and migrating forward renames it; restoring one *into* a
  v1.28.0 schema does not, which is the ordinary rule for a restore.
- Two renames in one release will read oddly in the changelog: v1.28.0 both
  introduces 0039's decision and amends it. That is the honest record. The
  alternative was shipping a vocabulary we already knew was half-finished, and
  0039's own sweep had already made a mistake inside the part it left alone.

## Alternatives considered

- **Leave it, as 0039 decided.** Rejected: the over-applied
  `record_timeline_item/3` rename is direct evidence that a reader — and a
  sweep — cannot tell the senses apart from the word. The near-miss 0039
  documents was the second such incident, not the first.
- **Rename only the modules, keep the table.** Considered seriously, and it is
  the lower-risk option: no migration, and retention's exclusion keeps working
  untouched. Rejected because the table name is the one a person meets in
  `psql` at the moment they are deciding what is safe to delete, which is
  exactly the situation 0039 was written about.
- **`RssParser` / `RssController`.** Rejected: we parse and emit Atom and JSON
  Feed as well, so naming the family after one member is how the original
  ambiguity started.
- **Rename the public URLs too**, with 301s like `/feed` got. Rejected: a 301
  helps a browser and a bookmark, but feed readers are long-lived, poorly
  supervised, and the URL is not ambiguous to begin with.
