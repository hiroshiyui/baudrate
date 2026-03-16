defmodule Baudrate.Repo.Migrations.AddIsBotToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_bot, :boolean, null: false, default: false
    end
  end
end
