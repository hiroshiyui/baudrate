defmodule Baudrate.Repo.Migrations.CreateDeliveryCircuits do
  use Ecto.Migration

  # Phase 2C: a per-domain circuit breaker for outbound delivery. A domain that
  # keeps failing has its jobs held back together, instead of each job taking a
  # worker slot until its own timeout. `delivery_jobs.domain` is the join key,
  # so selecting ready jobs can leave out an open circuit's jobs in SQL rather
  # than after they have already filled the batch.
  def up do
    alter table(:delivery_jobs) do
      add :domain, :text
    end

    # Only the jobs still waiting matter to the breaker; finished rows keep a
    # NULL domain until they are purged.
    execute("""
    UPDATE delivery_jobs
    SET domain = lower(substring(inbox_url from '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^/@]*@)?([^/:?#]+)'))
    WHERE status IN ('pending', 'failed')
    """)

    create index(:delivery_jobs, [:domain, :id],
             where: "status IN ('pending', 'failed')",
             name: :delivery_jobs_waiting_domain_index
           )

    create table(:delivery_circuits, primary_key: false) do
      add :domain, :text, primary_key: true
      # Consecutive failures that say the server is unreachable (connection
      # errors, timeouts, 5xx, 429). Any response that proves it is reachable
      # deletes the row.
      add :failures, :integer, null: false, default: 0
      # How many times the circuit has opened since the domain was last
      # reachable; picks the step in the backoff schedule.
      add :trips, :integer, null: false, default: 0
      add :open_until, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:delivery_circuits)
    drop index(:delivery_jobs, [:domain, :id], name: :delivery_jobs_waiting_domain_index)

    alter table(:delivery_jobs) do
      remove :domain
    end
  end
end
