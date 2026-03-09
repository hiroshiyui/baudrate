defmodule Baudrate.Repo.Migrations.AddUrlToArticles do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :url, :string
    end
  end
end
