defmodule Baudrate.Repo.Migrations.CreateBoards do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :name, :string, null: false
      add :description, :text
      add :slug, :string, null: false
      add :position, :integer, null: false, default: 0
      add :parent_id, references(:boards, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:slug])
    create index(:boards, [:parent_id])
  end
end
