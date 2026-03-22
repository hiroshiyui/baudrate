defmodule Baudrate.Repo.Migrations.CreateFeedItemReplyImages do
  use Ecto.Migration

  def change do
    create table(:feed_item_reply_images) do
      add :filename, :text, null: false
      add :storage_path, :text, null: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :reply_id, references(:feed_item_replies, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:feed_item_reply_images, [:reply_id])
    create index(:feed_item_reply_images, [:user_id])
  end
end
