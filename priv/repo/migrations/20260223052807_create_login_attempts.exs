defmodule Baudrate.Repo.Migrations.CreateLoginAttempts do
  use Ecto.Migration

  def change do
    create table(:login_attempts) do
      add :username, :string, null: false
      add :ip_address, :string
      add :success, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:login_attempts, [:username, :inserted_at])
    create index(:login_attempts, [:inserted_at])
  end
end
