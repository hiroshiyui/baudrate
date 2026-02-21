defmodule Baudrate.Repo.Migrations.AddDeletedAtToArticles do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :deleted_at, :utc_datetime
    end
  end
end
