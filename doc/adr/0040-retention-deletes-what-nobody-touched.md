# 0040 — Retention deletes what nobody touched

- **Status:** Accepted; the names in this record predate [0041](0041-rss-and-atom-are-syndication.md), which renamed `bot_feed_items` to `bot_syndication_items`
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Related:** completes Phase 2F and the periods set by P2-D4; depends on the
  evidence window of P1-D6; deletes rows
  [0015](0015-soft-deletion.md) only marked
- **Supersedes nothing.** Complements
  [0028](0028-backups-are-complete-folders-with-count-based-retention.md): a
  purged row is still in the backups until they rotate out.

## Context

Three tables grow without bound and nothing ever removed a row:

| Table | What it holds | Growth |
|---|---|---|
| `timeline_items` | posts from followed remote actors | one row per activity from every followed account |
| `announces` | that a remote actor boosted something | one row per remote boost |
| `articles`, `comments` with `deleted_at` | content its author or a moderator removed | never shrinks; the body stays in the row |

A single-node instance (ADR 0033) with one disk cannot outrun that, and the
third case is a privacy problem as much as a capacity one: ADR 0015 chose soft
deletion so a moderator could still see what was removed, and P1-D6 gave that
copy a 90-day life inside a report — but the row the member deleted kept its
body forever, which is not what "delete" means to the person who clicked it.

## Decision

Three passes, hourly, from `Baudrate.Auth.SessionCleaner`:

1. **Timeline items** older than **90 days** that have no like, boost or
   reply. The originals live on the servers that published them, so a row here
   is a cache of someone else's post.
2. **Announce records** older than **180 days**.
3. **Articles and comments** whose `deleted_at` is more than **90 days** old —
   hard-deleted, with their image files removed from disk.

### Nothing a report points at is ever deleted

`reports.timeline_item_id`, `article_id` and `comment_id` are all
`nilify_all`, so deleting the subject of a report does not fail — it quietly
empties the report's pointer. Reports are never deleted, so a reported row is
kept indefinitely. A moderation record whose subject cannot be read is worse
than a table slightly larger than necessary.

### Cutoffs measure our clock, not the peer's

Timeline items age by `inserted_at`, never `published_at`. `published_at`
arrives in the remote object and a peer controls it: a date far in the future
would pin a row forever, and one in the past would drop it the hour it landed.

### The bot ledger is not a feed item, and is never purged

`bot_feed_items` holds the `(bot_id, guid)` record of what each feed bot has
already posted. Deleting a row makes that bot publish the entry again, so the
purge never touches it — and because a purged article would otherwise take its
ledger row's reference with it, `bot_feed_items.article_id` became
`nilify_all`. The names were one character apart until
[0039](0039-the-personal-stream-is-a-timeline.md); that near-miss is why this
is written down twice, here and in the roadmap.

### Files are removed explicitly

Deleting an article cascades to its `article_images` rows. `SessionCleaner`'s
orphan sweeps find images whose *row* has lost its parent, not files whose row
is gone, so a cascade alone would leak the bytes forever. The paths are read
before the delete and unlinked after.

They are rebuilt from the `filename` column through
`Baudrate.DataPortability.Files`, not read from `storage_path`. `storage_path`
holds an absolute path into whichever release directory was current when the
file was uploaded, and the deploy keeps only the newest few releases — so for
any file old enough to purge it names a directory that no longer exists, and
the unlink was a silent no-op while the row that pointed at the file was
destroyed. `DataPortability.Files` already refused to trust that column, for
the same reason, and says so in its moduledoc; retention went back to trusting
it, for a destructive operation rather than a read. Rebuilding also confines
the path under the uploads root and requires a hex `.webp` name, so a tampered
row cannot steer the unlink. A missing file is logged at info: the original
bug was invisible precisely because `{:error, :enoent}` was swallowed and the
run reported `files=0`.

### Batched, and safe to interrupt

PostgreSQL has no `DELETE … LIMIT`, so each pass selects ids and deletes by
id, looping until nothing is left. A pass that dies half-way has simply done
less; the next hour continues. `dry_run: true` counts without deleting, for an
operator who wants to know what a first run would take.

## Consequences

- **A member's deleted article is genuinely gone after 90 days**, including
  from `article_revisions`, which cascades. That closes what 1B left open.
- `Federation.count_announces/1` drifts down on content older than 180 days.
  Accepted: the alternative is unbounded growth for a count nobody disputes.
- A remote server re-announcing something older than 180 days is treated as
  new. Harmless — it creates a timeline item again.
- **Backups still hold what was purged** until they rotate out (ADR 0028), so
  a purge is not a way to honour an erasure request quickly.
- Periods are module attributes, not settings. An operator who wants different
  ones edits and redeploys; a knob here would be a promise to support every
  combination of them.

## Alternatives considered

- **A worker of its own.** Rejected: `SessionCleaner` already has the
  heartbeat the health report watches (ADR 0035) and a `run_step/2` that
  isolates one failing step from the rest.
- **Keeping `announces` forever** so boost counts never change. Rejected by
  the operator; it is the fastest-growing table after `timeline_items`.
- **Purging timeline items nobody bookmarked.** P2-D4 said this, but
  `bookmarks` only targets articles and comments — a timeline item cannot be
  bookmarked, so the rule is likes, boosts and replies.
- **Deleting reported rows once their report closes.** Rejected: a closed
  report can be reopened, and the evidence copy is a slice of the body, not
  the row.
- **Age-based backup deletion to match.** Explicitly not revisited here; ADR
  0028 chose count-based retention and nothing about this changes that.

## Acceptance gate

`test/baudrate/retention_test.exs` — each keep rule has its own test: an
untouched item goes, a liked, boosted or replied-to one stays, a reported one
stays at 400 days old, a soft-deleted article inside the window stays, and the
image file of a purged article is gone from disk. Add a test there for every
new table the purges learn about.

A file test must let the module derive the path itself, from a file written
under the real `ArticleImageStorage.upload_dir()`. The first two file tests
handed in a fabricated `System.tmp_dir!()` path, so they proved only that the
code unlinks whatever path it is given — which is why the `storage_path` bug
above survived them.
