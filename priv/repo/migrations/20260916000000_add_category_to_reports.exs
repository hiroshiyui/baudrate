defmodule Baudrate.Repo.Migrations.AddCategoryToReports do
  use Ecto.Migration

  # Every report made on this site now carries a reason category (P1-D9), so
  # the queue can be read and sorted at a glance. Reports that already exist,
  # and inbound federated Flags (which carry no category), keep a null.
  def change do
    alter table(:reports) do
      add :category, :string
    end

    # The queue lists one status at a time, newest first.
    create index(:reports, [:status, :inserted_at])
  end
end
