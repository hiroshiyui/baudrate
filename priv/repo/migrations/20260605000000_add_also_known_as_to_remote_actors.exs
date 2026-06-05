defmodule Baudrate.Repo.Migrations.AddAlsoKnownAsToRemoteActors do
  use Ecto.Migration

  def change do
    alter table(:remote_actors) do
      add :also_known_as, {:array, :string}, null: false, default: []
    end
  end
end
