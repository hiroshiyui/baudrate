defmodule Baudrate.Repo.Migrations.AddVisibilityToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :visibility, :string, null: false, default: "public"
    end
  end
end
