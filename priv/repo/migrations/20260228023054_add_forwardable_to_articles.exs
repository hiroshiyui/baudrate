defmodule Baudrate.Repo.Migrations.AddForwardableToArticles do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :forwardable, :boolean, default: true, null: false
    end
  end
end
