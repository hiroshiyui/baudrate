defmodule Baudrate.Repo.Migrations.AddFaviconFailCountToBots do
  use Ecto.Migration

  def change do
    alter table(:bots) do
      add :favicon_fail_count, :integer, null: false, default: 0
    end
  end
end
