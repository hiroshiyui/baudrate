defmodule Baudrate.Repo.Migrations.CreateBoardModerators do
  use Ecto.Migration

  def change do
    create table(:board_moderators) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_moderators, [:board_id, :user_id])
    create index(:board_moderators, [:user_id])
  end
end
