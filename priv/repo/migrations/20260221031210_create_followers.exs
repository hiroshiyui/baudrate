defmodule Baudrate.Repo.Migrations.CreateFollowers do
  use Ecto.Migration

  def change do
    create table(:followers) do
      add :actor_uri, :text, null: false
      add :follower_uri, :text, null: false
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false
      add :accepted_at, :utc_datetime
      add :activity_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:followers, [:actor_uri, :follower_uri])
    create index(:followers, [:remote_actor_id])
    create index(:followers, [:actor_uri])
  end
end
