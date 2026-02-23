defmodule Baudrate.Repo.Migrations.RemoveVisibilityFromBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      remove :visibility, :string, null: false, default: "public"
    end
  end
end
