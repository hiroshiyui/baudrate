defmodule Baudrate.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :endpoint, :text, null: false
      add :p256dh, :binary, null: false
      add :auth, :binary, null: false
      add :user_agent, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
