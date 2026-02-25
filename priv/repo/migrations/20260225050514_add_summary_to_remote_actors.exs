defmodule Baudrate.Repo.Migrations.AddSummaryToRemoteActors do
  use Ecto.Migration

  def change do
    alter table(:remote_actors) do
      add :summary, :text
    end
  end
end
