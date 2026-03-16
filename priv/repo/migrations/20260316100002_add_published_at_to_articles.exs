defmodule Baudrate.Repo.Migrations.AddPublishedAtToArticles do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :published_at, :utc_datetime_usec
    end
  end
end
