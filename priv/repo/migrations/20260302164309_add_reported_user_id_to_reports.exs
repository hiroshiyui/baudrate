defmodule Baudrate.Repo.Migrations.AddReportedUserIdToReports do
  use Ecto.Migration

  def change do
    alter table(:reports) do
      add :reported_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:reports, [:reported_user_id])
  end
end
