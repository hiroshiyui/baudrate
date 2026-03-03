defmodule Baudrate.Repo.Migrations.CreateFeedItemReplies do
  use Ecto.Migration

  def change do
    create table(:feed_item_replies) do
      add :feed_item_id, references(:feed_items, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :body_html, :text
      add :ap_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:feed_item_replies, [:feed_item_id])
    create unique_index(:feed_item_replies, [:ap_id])
  end
end
