defmodule Baudrate.Repo.Migrations.AddDeliveryJobsDedupIndex do
  use Ecto.Migration

  def change do
    create unique_index(:delivery_jobs, [:inbox_url, :actor_uri],
      where: "status IN ('pending', 'failed')",
      name: :delivery_jobs_pending_dedup_index
    )
  end
end
