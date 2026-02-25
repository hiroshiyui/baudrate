defmodule Baudrate.Repo.Migrations.CreateFeedItems do
  use Ecto.Migration

  def change do
    create table(:feed_items) do
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false
      add :activity_type, :string, null: false, default: "Create"
      add :object_type, :string, null: false, default: "Note"
      add :ap_id, :text, null: false
      add :title, :text
      add :body, :text
      add :body_html, :text
      add :source_url, :text
      add :published_at, :utc_datetime, null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feed_items, [:ap_id])
    create index(:feed_items, [:remote_actor_id])
    create index(:feed_items, [:published_at])
    create index(:feed_items, [:remote_actor_id, :published_at])
  end
end
