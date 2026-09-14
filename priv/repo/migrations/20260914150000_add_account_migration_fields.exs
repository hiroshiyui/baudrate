defmodule Baudrate.Repo.Migrations.AddAccountMigrationFields do
  use Ecto.Migration

  # ADR 0025: aliases and the moved state for local users, and the last
  # processed Move for remote actors.
  def change do
    alter table(:users) do
      # Actor ids of other accounts this user claims (`alsoKnownAs`).
      add :also_known_as, {:array, :string}, null: false, default: []
      # Set once a Move was sent; cleared by "Remove redirect".
      add :moved_to, :string
      add :moved_at, :utc_datetime
    end

    alter table(:remote_actors) do
      # The target of the last Move processed from this actor, and when.
      add :moved_to_ap_id, :string
      add :moved_at, :utc_datetime
    end
  end
end
