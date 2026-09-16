defmodule Baudrate.Repo.Migrations.AddDeletedByToComments do
  use Ecto.Migration

  # Articles already record who deleted them; comments did not, so a deletion
  # made from a moderation queue could not be traced back (1B).
  def change do
    alter table(:comments) do
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:comments, [:deleted_by_id])
  end
end
