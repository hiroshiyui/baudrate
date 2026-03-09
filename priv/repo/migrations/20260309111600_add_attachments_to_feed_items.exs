defmodule Baudrate.Repo.Migrations.AddAttachmentsToFeedItems do
  use Ecto.Migration

  def change do
    alter table(:feed_items) do
      add :attachments, :jsonb, default: "[]"
    end
  end
end
