defmodule Baudrate.Repo.Migrations.AddUrlToComments do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :url, :string
    end
  end
end
