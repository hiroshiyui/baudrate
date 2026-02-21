defmodule Baudrate.Repo.Migrations.CreateDeliveryJobs do
  use Ecto.Migration

  def change do
    create table(:delivery_jobs) do
      add :activity_json, :text, null: false
      add :inbox_url, :text, null: false
      add :actor_uri, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :next_retry_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:delivery_jobs, [:status, :next_retry_at])
    create index(:delivery_jobs, [:status], where: "status = 'pending'", name: :delivery_jobs_pending_status_index)
  end
end
