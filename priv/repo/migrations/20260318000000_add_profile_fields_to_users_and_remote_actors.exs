defmodule Baudrate.Repo.Migrations.AddProfileFieldsToUsersAndRemoteActors do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :profile_fields, {:array, :map}, default: [], null: false
    end

    alter table(:remote_actors) do
      add :profile_fields, {:array, :map}, default: [], null: false
    end
  end
end
