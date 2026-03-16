defmodule Baudrate.Repo.Migrations.CreateBotFeedItems do
  use Ecto.Migration

  def change do
    create table(:bot_feed_items) do
      add :bot_id, references(:bots, on_delete: :delete_all), null: false
      add :guid, :string, size: 2048, null: false
      add :article_id, references(:articles)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:bot_feed_items, [:bot_id, :guid])
    create index(:bot_feed_items, [:bot_id])
  end
end
