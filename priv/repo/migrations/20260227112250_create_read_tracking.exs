defmodule Baudrate.Repo.Migrations.CreateReadTracking do
  use Ecto.Migration

  def change do
    create table(:article_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :read_at, :utc_datetime, null: false
    end

    create unique_index(:article_reads, [:user_id, :article_id])
    create index(:article_reads, [:user_id])

    create table(:board_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :read_at, :utc_datetime, null: false
    end

    create unique_index(:board_reads, [:user_id, :board_id])
    create index(:board_reads, [:user_id])
  end
end
