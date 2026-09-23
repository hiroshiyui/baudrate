defmodule Baudrate.Repo.Migrations.AddDeletedAtToUsers do
  use Ecto.Migration

  # When a self-deleted account became a tombstone (ADR 0072). The row itself
  # is never deleted: other members' comments, reports and DMs point at it.
  def change do
    alter table(:users) do
      add :deleted_at, :utc_datetime
    end
  end
end
