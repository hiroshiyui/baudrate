defmodule Baudrate.Repo.Migrations.AddApEnabledToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :ap_enabled, :boolean, default: true, null: false
    end
  end
end
