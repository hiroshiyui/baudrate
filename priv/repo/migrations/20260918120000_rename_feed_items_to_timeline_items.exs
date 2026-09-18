defmodule Baudrate.Repo.Migrations.RenameFeedItemsToTimelineItems do
  @moduledoc """
  Renames the personal fediverse stream from "feed item" to "timeline item".

  "Feed" named three unrelated things: RSS and Atom arriving from bots
  (`bot_feed_items`, `Bots.FeedParser`), the RSS and Atom we publish
  (`FeedController`), and this — the posts of remote actors a member follows.
  Only the last is not a feed in the RSS sense, so only it is renamed;
  `bot_feed_items` is deliberately left alone.

  Index and constraint names are renamed with the tables, because Ecto derives
  a default constraint name from the table and column. Left behind,
  `unique_constraint([:timeline_item_id, :user_id])` would look for
  `timeline_item_likes_timeline_item_id_user_id_index` and never find
  `feed_item_likes_feed_item_id_user_id_index`, so a duplicate like or boost
  would raise a Postgrex error instead of returning a changeset error.
  """

  use Ecto.Migration

  @tables [
    {:feed_items, :timeline_items},
    {:feed_item_likes, :timeline_item_likes},
    {:feed_item_boosts, :timeline_item_boosts},
    {:feed_item_replies, :timeline_item_replies},
    {:feed_item_reply_images, :timeline_item_reply_images}
  ]

  # Tables carrying a `feed_item_id` reference, under their new names.
  @columns [:timeline_item_likes, :timeline_item_boosts, :timeline_item_replies, :reports]

  def up do
    for {from, to} <- @tables, do: rename(table(from), to: table(to))

    for t <- @columns do
      rename(table(t), :feed_item_id, to: :timeline_item_id)
    end

    rename_objects("feed_item", "timeline_item")
  end

  def down do
    for t <- @columns do
      rename(table(t), :timeline_item_id, to: :feed_item_id)
    end

    for {from, to} <- @tables, do: rename(table(to), to: table(from))

    rename_objects("timeline_item", "feed_item")
  end

  # Renames every index and constraint whose name mentions `from`, in one pass
  # over the catalog rather than a hand-kept list — the same reason
  # `StaleActorCleaner` reads `pg_constraint` instead of naming its foreign
  # keys. `bot_feed_item%` is excluded explicitly: it is a different table with
  # a confusingly similar name, and renaming its ledger would be the one change
  # here that could lose data.
  #
  # Constraints come first: renaming a constraint renames the index backing it,
  # so by the time the index pass runs, only plain indexes are left.
  defp rename_objects(from, to) do
    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT conrelid::regclass::text AS tbl, conname AS name
        FROM pg_constraint
        WHERE conname LIKE '%#{from}%'
          AND conname NOT LIKE 'bot_feed_item%'
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
          AND c.relname LIKE '%#{from}%'
          AND c.relname NOT LIKE 'bot_feed_item%'
      LOOP
        EXECUTE format(
          'ALTER INDEX %I RENAME TO %I',
          r.name, replace(r.name, '#{from}', '#{to}')
        );
      END LOOP;
    END $$;
    """)
  end
end
