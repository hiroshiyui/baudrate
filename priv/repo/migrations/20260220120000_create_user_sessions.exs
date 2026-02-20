defmodule Baudrate.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  def change do
    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :refresh_token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :refreshed_at, :utc_datetime, null: false
      add :ip_address, :string
      add :user_agent, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create unique_index(:user_sessions, [:refresh_token_hash])
    create index(:user_sessions, [:user_id])
    create index(:user_sessions, [:expires_at])
  end
end
