defmodule Baudrate.Repo.Migrations.CreateBoardFollows do
  use Ecto.Migration

  def change do
    create table(:board_follows) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "pending"
      add :ap_id, :text, null: false
      add :accepted_at, :utc_datetime
      add :rejected_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_follows, [:board_id, :remote_actor_id])
    create index(:board_follows, [:remote_actor_id])
    create index(:board_follows, [:board_id, :state])
    create unique_index(:board_follows, [:ap_id])
  end
end
