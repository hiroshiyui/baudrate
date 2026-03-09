defmodule Baudrate.Repo.Migrations.AddBoostedByToFeedItems do
  use Ecto.Migration

  def change do
    alter table(:feed_items) do
      add :boosted_by_actor_id, references(:remote_actors, on_delete: :nilify_all)
    end

    create index(:feed_items, [:boosted_by_actor_id])
  end
end
