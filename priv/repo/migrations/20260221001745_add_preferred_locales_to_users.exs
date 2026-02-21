defmodule Baudrate.Repo.Migrations.AddPreferredLocalesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferred_locales, {:array, :string}, default: []
    end
  end
end
