defmodule Baudrate.Repo.Migrations.CreateAccountMoves do
  use Ecto.Migration

  # Outbound account moves (ADR 0025). A row is a request: it waits out a
  # 24-hour cooling-off, then the hourly sweep sends the Move or marks it
  # failed. Rows form an immutable history.
  def change do
    create table(:account_moves) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Actor id of the destination account.
      add :target_ap_id, :string, size: 2048, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_at, :utc_datetime, null: false
      add :send_after, :utc_datetime, null: false
      add :sent_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :cancel_reason, :string
      add :failure_reason, :string
      add :requested_session_id, references(:user_sessions, on_delete: :nilify_all)
      # Coarse browser/OS family for the warning banner; never an IP.
      add :requested_user_agent_family, :string, size: 100

      timestamps(type: :utc_datetime)
    end

    create constraint(:account_moves, :account_moves_status_check,
             check: "status IN ('pending', 'sent', 'cancelled', 'failed')"
           )

    create unique_index(:account_moves, [:user_id],
             where: "status = 'pending'",
             name: :account_moves_one_pending_per_user_index
           )

    create index(:account_moves, [:user_id, :requested_at])
    create index(:account_moves, [:status, :send_after])
  end
end
