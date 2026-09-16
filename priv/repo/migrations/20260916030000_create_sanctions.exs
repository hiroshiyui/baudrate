defmodule Baudrate.Repo.Migrations.CreateSanctions do
  use Ecto.Migration

  # A sanction short of a ban is a row with an explicit end, not a new
  # `users.status` value (ADR 0029). Rows are append-only history: a sanction
  # is lifted, never deleted, so a repeat offender's record survives.
  #
  # "Active" is `lifted_at IS NULL AND (expires_at IS NULL OR expires_at >
  # now())`, read directly by the gate. It deliberately has no partial unique
  # index: "active" depends on the current time and cannot be expressed in one.
  def change do
    create table(:sanctions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :reason, :text
      add :issued_by_id, references(:users, on_delete: :nilify_all)
      add :issued_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime
      add :lifted_at, :utc_datetime
      add :lifted_by_id, references(:users, on_delete: :nilify_all)
      add :lift_reason, :text
      # Set when the member was told the sanction ran out, so they are told
      # once. Enforcement never reads it.
      add :ended_notified_at, :utc_datetime
      # The report that prompted the sanction, when there was one.
      add :report_id, references(:reports, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # The gate's lookup: this user's unlifted sanctions of a restricting kind.
    create index(:sanctions, [:user_id, :kind, :lifted_at])
    # The history list on a user detail page, newest first.
    create index(:sanctions, [:user_id, :issued_at])
    create index(:sanctions, [:issued_by_id])
    create index(:sanctions, [:report_id])
  end
end
