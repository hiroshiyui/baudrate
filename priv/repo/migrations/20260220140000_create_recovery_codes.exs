defmodule Baudrate.Repo.Migrations.CreateRecoveryCodes do
  use Ecto.Migration

  def change do
    create table(:recovery_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:recovery_codes, [:user_id])
  end
end
