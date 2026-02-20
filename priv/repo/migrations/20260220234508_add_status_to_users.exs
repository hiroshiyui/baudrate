defmodule Baudrate.Repo.Migrations.AddStatusToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :status, :string, null: false, default: "active"
    end
  end
end
