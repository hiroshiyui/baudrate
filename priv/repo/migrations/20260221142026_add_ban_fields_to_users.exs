defmodule Baudrate.Repo.Migrations.AddBanFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :banned_at, :utc_datetime
      add :ban_reason, :text
    end

    create index(:users, [:status])
  end
end
