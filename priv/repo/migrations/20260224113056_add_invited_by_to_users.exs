defmodule Baudrate.Repo.Migrations.AddInvitedByToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :invited_by_id, references(:users, on_delete: :nilify_all), null: true
    end

    create index(:users, [:invited_by_id])
  end
end
