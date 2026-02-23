defmodule Baudrate.Repo.Migrations.AddDmAccessToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :dm_access, :string, null: false, default: "anyone"
    end

    create constraint(:users, :dm_access_valid,
      check: "dm_access IN ('anyone', 'followers', 'nobody')"
    )
  end
end
