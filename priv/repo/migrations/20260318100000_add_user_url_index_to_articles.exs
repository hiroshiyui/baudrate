defmodule Baudrate.Repo.Migrations.AddUserUrlIndexToArticles do
  use Ecto.Migration

  def change do
    create index(:articles, [:user_id, :url], where: "url IS NOT NULL")
  end
end
