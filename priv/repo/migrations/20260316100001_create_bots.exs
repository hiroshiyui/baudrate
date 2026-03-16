defmodule Baudrate.Repo.Migrations.CreateBots do
  use Ecto.Migration

  def change do
    create table(:bots) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_url, :string, size: 2048, null: false
      add :board_ids, {:array, :integer}, null: false, default: []
      add :fetch_interval_minutes, :integer, null: false, default: 60
      add :last_fetched_at, :utc_datetime
      add :next_fetch_at, :utc_datetime
      add :active, :boolean, null: false, default: true
      add :error_count, :integer, null: false, default: 0
      add :last_error, :text
      add :avatar_refreshed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bots, [:user_id])
    create index(:bots, [:active, :next_fetch_at])
  end
end
