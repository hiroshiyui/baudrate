# 0087 — The feed parser NIF is built on feed-rs

- **Status:** Accepted
- **Date:** 2026-11-28
- **Deciders:** Baudrate maintainers
- **Amends** [0005](0005-rust-nifs-for-untrusted-parsing.md): feed parsing
  stays a Rust NIF; the crate behind `baudrate_feed_parser` changes from
  `feedparser-rs` to `feed-rs`.

## Context

`baudrate_feed_parser` parses RSS, Atom and JSON Feed that bot accounts fetch
from sites nobody here controls. It was built on `feedparser-rs` 0.7, which
depends on `chrono`. On 2026-09-14 `chrono` was declared unmaintained
(RUSTSEC-2026-0543), and `cargo audit` has flagged it since. It is not a
vulnerability, but it does mean the date parser on an ingest boundary will
get no more fixes. The other Rust feed crates (`rss`, `atom_syndication`) also
depend on `chrono`. `feed-rs` 3.x uses `jiff` instead, and is widely used and
maintained.

## Decision

`baudrate_feed_parser` uses `feed-rs` with default features off. The NIF's
output (`SyndicationFeedParserNative.Entry`) does not change, so the Elixir
side is untouched except as listed below.

- **No invented ids.** `feed-rs` hashes link and title into an id for an
  entry that has none. The NIF installs an id generator that returns an empty
  string, so the entry's id is `None` and `SyndicationFeedParser` keys it by
  its link as before. A hashed id changes whenever a title is edited, so the
  same post would be syndicated twice.
- **No crate-side sanitizing.** The `sanitize` feature (which pulls in
  Ammonia) stays off and `sanitize_content(false)` is set as well. Ammonia on
  the Elixir side remains the one sanitizer of record.
- **Dates are sent as UTC instants** (`…Z`), which `DateTime.from_iso8601/1`
  reads.
- **Comment links are never the entry link.** `<comments>` and
  `wfw:commentRss` carry a link target and are skipped.

## Consequences

- `chrono` leaves the dependency tree; `cargo audit` is clean.
- **Input that is not a feed is an error**, not an empty list. A bot whose URL
  starts serving an HTML page now records `last_error` and counts toward the
  automatic switch-off, instead of fetching nothing for ever.
- **`dc:subject` is not read.** `feed-rs` ignores it, so feeds that tag only
  with `dc:subject` (common in RSS 1.0) arrive without tags. `<category>`
  (RSS) and `category` (Atom) still work.
- **Atom 0.3 is not read.** A feed in the `http://purl.org/atom/ns#`
  namespace parses with no entries. Atom 0.3 was replaced by Atom 1.0 in 2005.
- `feed-rs` tracks nesting depth with counters, not recursion, so a deeply
  nested document cannot overflow a dirty scheduler's stack (a NIF that
  overflows takes down the VM). The input is capped at 5 MB by
  `Bots.Fetcher` before it reaches the NIF.

## Acceptance gate

The crate's unit tests (`cargo test` in `native/baudrate_feed_parser`, run by
CI's NIF step): unsanitized HTML, the empty id, comment links, RSS 1.0
`dc:date`, input that is not a feed, and 200 000 levels of nesting on a
256 KB stack. On the Elixir side,
`test/baudrate/bots/syndication_feed_parser_test.exs`.

## Alternatives considered

- **Wait for `feedparser-rs` to replace `chrono`.** Free, but leaves an
  unmaintained date parser on an ingest boundary for an unknown time.
- **`rss` + `atom_syndication`.** Two crates, no JSON Feed, and
  `atom_syndication` requires `chrono`.
- **Parse feeds in Elixir.** Rejected in 0005: the Elixir XML parsers and feed
  libraries cover fewer dialects and bring entity-expansion risks.
- **A second XML pass for `dc:subject`.** Possible with `quick-xml` (already
  in the tree), but it would parse hostile input twice and match items by
  position. Not worth it for one tag source.
