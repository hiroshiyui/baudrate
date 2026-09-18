defmodule Baudrate.Repo.Migrations.PrepareRetention do
  @moduledoc """
  Makes the retention purges of Phase 2F possible and cheap.

  Two things stood in the way. `bot_feed_items.article_id` had no `on_delete`,
  so hard-deleting a bot-posted article — most of the content on an instance
  that runs feed bots — would have raised a foreign key violation and aborted
  the purge. The ledger exists for its `(bot_id, guid)` pair, which is what
  stops a bot re-posting an entry; the article it produced is incidental, so
  the reference is nullified rather than cascading (deleting the ledger row
  would make the bot publish that entry again).

  And nothing indexed the columns the first two passes select on, so each one
  would have scanned `timeline_items` and `announces` whole.

  This record originally claimed the third pass needed nothing, because
  `articles` and `comments` already carry a `deleted_at` index. They do, but
  it is partial on `deleted_at IS NULL` — the complement of what the purge
  selects — so it could never serve that pass.
  `20260918170000_index_soft_deleted_for_retention` adds the indexes that can.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:bot_feed_items, "bot_feed_items_article_id_fkey"))

    alter table(:bot_feed_items) do
      modify(:article_id, references(:articles, on_delete: :nilify_all))
    end

    create(index(:timeline_items, [:inserted_at]))
    create(index(:announces, [:inserted_at]))
  end

  def down do
    drop(index(:announces, [:inserted_at]))
    drop(index(:timeline_items, [:inserted_at]))

    drop(constraint(:bot_feed_items, "bot_feed_items_article_id_fkey"))

    alter table(:bot_feed_items) do
      modify(:article_id, references(:articles))
    end
  end
end
