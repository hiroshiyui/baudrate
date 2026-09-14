defmodule Baudrate.Repo.Migrations.AddReporterRemoteActorToReports do
  use Ecto.Migration

  # Reports from other instances (inbound `Flag`) used to store the *reporting*
  # remote actor in `remote_actor_id`, the column the moderation queue shows as
  # the reported actor and sends "Send Flag" to. Give the reporter its own
  # column and move existing rows over: a report with no local reporter and a
  # remote actor came from an inbound Flag, because local reports always carry
  # `reporter_id` (users are never hard-deleted).
  def up do
    alter table(:reports) do
      add :reporter_remote_actor_id, references(:remote_actors, on_delete: :nilify_all)
    end

    create index(:reports, [:reporter_remote_actor_id])

    execute """
    UPDATE reports
    SET reporter_remote_actor_id = remote_actor_id, remote_actor_id = NULL
    WHERE reporter_id IS NULL AND remote_actor_id IS NOT NULL
    """
  end

  def down do
    execute """
    UPDATE reports
    SET remote_actor_id = reporter_remote_actor_id
    WHERE reporter_remote_actor_id IS NOT NULL AND remote_actor_id IS NULL
    """

    drop index(:reports, [:reporter_remote_actor_id])

    alter table(:reports) do
      remove :reporter_remote_actor_id
    end
  end
end
