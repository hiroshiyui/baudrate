defmodule Baudrate.Repo.Migrations.AddSuspensionToRemoteActors do
  @moduledoc """
  Lets a single remote actor be suspended instance-wide (ADR 0030, decision 6),
  so a report about one account has an answer proportionate to it instead of a
  choice between telling the reporter to block it personally and blocking the
  account's entire domain.
  """

  use Ecto.Migration

  def change do
    alter table(:remote_actors) do
      add :suspended_at, :utc_datetime
      add :suspend_reason, :text
      add :suspended_by_id, references(:users, on_delete: :nilify_all)
    end

    # The hiding filter asks for suspended actors, never for the rest, so the
    # index only has to cover the ones that are.
    create index(:remote_actors, [:suspended_at], where: "suspended_at IS NOT NULL")
    create index(:remote_actors, [:suspended_by_id])
  end
end
