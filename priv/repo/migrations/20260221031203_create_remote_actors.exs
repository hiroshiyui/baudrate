defmodule Baudrate.Repo.Migrations.CreateRemoteActors do
  use Ecto.Migration

  def change do
    create table(:remote_actors) do
      add :ap_id, :text, null: false
      add :username, :string, null: false
      add :domain, :string, null: false
      add :display_name, :string
      add :avatar_url, :text
      add :public_key_pem, :text, null: false
      add :inbox, :text, null: false
      add :shared_inbox, :text
      add :actor_type, :string, null: false, default: "Person"
      add :fetched_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:remote_actors, [:ap_id])
    create index(:remote_actors, [:domain])
    create unique_index(:remote_actors, [:username, :domain])
  end
end
