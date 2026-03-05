defmodule Baudrate.Repo.Migrations.AddUrlToRemoteActors do
  use Ecto.Migration

  def change do
    alter table(:remote_actors) do
      add :url, :string
    end
  end
end
