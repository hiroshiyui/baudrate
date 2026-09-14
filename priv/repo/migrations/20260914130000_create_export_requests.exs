defmodule Baudrate.Repo.Migrations.CreateExportRequests do
  use Ecto.Migration

  # Data export requests (ADR 0023). A row is a request record only: no
  # archive is ever stored. Rows form an immutable history; users cannot
  # delete them, and `SessionCleaner` purges them after a year.
  def change do
    create table(:export_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      # "self_service" (web, step-up re-authentication) or "sysop" (audited release task)
      add :source, :string, null: false, default: "self_service"
      add :requested_at, :utc_datetime, null: false
      add :ready_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      add :download_count, :integer, null: false, default: 0
      add :requested_session_id, references(:user_sessions, on_delete: :nilify_all)
      # Coarse browser/OS family for the warning banner ("Firefox on Linux").
      # Deliberately no IP address or full user agent.
      add :requested_user_agent_family, :string, size: 100
      # OS user that ran a SysOp export; nil for self-service.
      add :operator, :string, size: 100
      add :cancelled_at, :utc_datetime
      add :cancel_reason, :string

      timestamps(type: :utc_datetime)
    end

    create constraint(:export_requests, :export_requests_status_check,
             check: "status IN ('pending', 'ready', 'completed', 'cancelled', 'expired')"
           )

    create constraint(:export_requests, :export_requests_source_check,
             check: "source IN ('self_service', 'sysop')"
           )

    create constraint(:export_requests, :export_requests_download_count_check,
             check: "download_count BETWEEN 0 AND 3"
           )

    # One active (pending or ready) request per user, enforced by PostgreSQL.
    create unique_index(:export_requests, [:user_id],
             where: "status IN ('pending', 'ready')",
             name: :export_requests_one_active_per_user_index
           )

    create index(:export_requests, [:user_id, :requested_at])
    create index(:export_requests, [:status, :ready_at])
  end
end
