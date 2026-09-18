defmodule Baudrate.Repo.Migrations.RenameBotFeedItemsToBotSyndicationItems do
  @moduledoc """
  Renames the feed-bot dedup ledger from "bot feed item" to "bot syndication
  item", finishing the vocabulary split ADR 0039 began and ADR 0041 completes.

  ADR 0039 renamed the personal stream to "timeline" and deliberately left this
  table alone, on the reasoning that RSS and Atom really are feeds. ADR 0041
  revisits that: "feed" still named two things afterwards, and the one the
  operator has to reason about under pressure — *which* table does retention
  purge — was still distinguished only by a `bot_` prefix. "Syndication" is the
  word for what RSS and Atom are, and it collides with nothing.

  Sibling of `20260918120000_rename_feed_items_to_timeline_items.exs`, and
  deliberately its mirror image: that migration excluded `bot_feed_item%`
  because renaming this ledger was the one change that could lose data. Here it
  is the only target, so the same care applies in the opposite direction — the
  exclusions are inverted, and nothing matching `timeline_item%` is touched.

  ## Why the ledger is delicate

  `bot_syndication_items` holds `(bot_id, guid)`: the record of which
  syndication entries a bot has already posted. It is not content and retention
  never purges it, because deleting a row republishes that entry — a lost
  ledger means every bot re-posts its entire back catalogue to every board it
  writes to. The rename therefore moves the table, its indexes, its
  constraints and its sequence, and adds no `DELETE` of any kind.

  Index and constraint names move with it for the reason the sibling migration
  gives: Ecto derives a default constraint name from the table and column, so a
  `unique_constraint([:bot_id, :guid])` left pointing at
  `bot_feed_items_bot_id_guid_index` would raise a Postgrex error on a
  duplicate instead of returning a changeset error — and a duplicate here is
  the ordinary case every poll, not an edge case.
  """

  use Ecto.Migration

  def up do
    rename(table(:bot_feed_items), to: table(:bot_syndication_items))
    rename_objects("bot_feed_item", "bot_syndication_item")
  end

  def down do
    rename(table(:bot_syndication_items), to: table(:bot_feed_items))
    rename_objects("bot_syndication_item", "bot_feed_item")
  end

  # One pass over the catalog rather than a hand-kept list, matching the
  # sibling migration and `StaleActorCleaner`. Constraints first: renaming a
  # constraint renames the index backing it, so the index pass that follows
  # sees only plain indexes. Sequences are included here — the sibling left
  # them, and `bot_feed_items_id_seq` surviving a rename is exactly the stale
  # name this change exists to remove. A column default references its
  # sequence by OID, so renaming one is safe.
  defp rename_objects(from, to) do
    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT conrelid::regclass::text AS tbl, conname AS name
        FROM pg_constraint
        WHERE conname LIKE '#{from}%'
      LOOP
        EXECUTE format(
          'ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
          r.tbl, r.name, replace(r.name, '#{from}', '#{to}')
        );
      END LOOP;

      FOR r IN
        SELECT c.relname AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'i'
          AND n.nspname = current_schema()
          AND c.relname LIKE '#{from}%'
      LOOP
        EXECUTE format(
          'ALTER INDEX %I RENAME TO %I',
          r.name, replace(r.name, '#{from}', '#{to}')
        );
      END LOOP;

      FOR r IN
        SELECT c.relname AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S'
          AND n.nspname = current_schema()
          AND c.relname LIKE '#{from}%'
      LOOP
        EXECUTE format(
          'ALTER SEQUENCE %I RENAME TO %I',
          r.name, replace(r.name, '#{from}', '#{to}')
        );
      END LOOP;
    END $$;
    """)
  end
end
