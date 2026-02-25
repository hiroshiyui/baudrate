defmodule Baudrate.Repo.Migrations.CreateUserFollows do
  use Ecto.Migration

  def change do
    create table(:user_follows) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "pending"
      add :ap_id, :text, null: false
      add :accepted_at, :utc_datetime
      add :rejected_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_follows, [:user_id, :remote_actor_id])
    create index(:user_follows, [:remote_actor_id])
    create index(:user_follows, [:user_id, :state])
    create unique_index(:user_follows, [:ap_id])
  end
end
