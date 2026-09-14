defmodule Baudrate.Repo.Migrations.DedupDeliveryJobsPerActivity do
  use Ecto.Migration

  # The pending-job dedup index covered only (inbox_url, actor_uri), so while
  # an actor had any pending or failed job for an inbox, every other activity
  # it sent to that inbox was silently dropped (a like followed by a boost, two
  # board articles within a worker poll, everything during a remote outage).
  # Dedup is per activity: the same activity is still queued once per inbox.
  def up do
    alter table(:delivery_jobs) do
      add :activity_id, :text
    end

    execute("""
    UPDATE delivery_jobs
    SET activity_id = COALESCE(activity_json::jsonb ->> 'id', md5(activity_json))
    """)

    execute("ALTER TABLE delivery_jobs ALTER COLUMN activity_id SET NOT NULL")

    drop index(:delivery_jobs, [:inbox_url, :actor_uri], name: :delivery_jobs_pending_dedup_index)

    create unique_index(:delivery_jobs, [:inbox_url, :actor_uri, :activity_id],
             where: "status IN ('pending', 'failed')",
             name: :delivery_jobs_pending_activity_dedup_index
           )
  end

  def down do
    drop index(:delivery_jobs, [:inbox_url, :actor_uri, :activity_id],
           name: :delivery_jobs_pending_activity_dedup_index
         )

    # Restoring the old index needs at most one pending/failed job per
    # (inbox_url, actor_uri); keep the oldest and abandon the rest.
    execute("""
    UPDATE delivery_jobs SET status = 'abandoned'
    WHERE status IN ('pending', 'failed') AND id NOT IN (
      SELECT min(id) FROM delivery_jobs
      WHERE status IN ('pending', 'failed')
      GROUP BY inbox_url, actor_uri
    )
    """)

    create unique_index(:delivery_jobs, [:inbox_url, :actor_uri],
             where: "status IN ('pending', 'failed')",
             name: :delivery_jobs_pending_dedup_index
           )

    alter table(:delivery_jobs) do
      remove :activity_id
    end
  end
end
