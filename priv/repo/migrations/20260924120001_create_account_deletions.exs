defmodule Baudrate.Repo.Migrations.CreateAccountDeletions do
  use Ecto.Migration

  # A member's request to delete their own account (ADR 0072). It waits seven
  # days — signing in cancels it — then the hourly sweep claims it
  # (`executing`) and carries it out step by resumable step. Rows form a
  # history, like `account_moves`.
  def change do
    create table(:account_deletions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      # Withdraw the member's articles and comments too, instead of keeping
      # them under "deleted account".
      add :withdraw_content, :boolean, null: false, default: false
      add :requested_at, :utc_datetime, null: false
      add :execute_after, :utc_datetime, null: false
      add :claimed_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :cancel_reason, :string
      # Coarse browser/OS family, for the notice; never an IP.
      add :requested_user_agent_family, :string, size: 100

      timestamps(type: :utc_datetime)
    end

    create constraint(:account_deletions, :account_deletions_status_check,
             check: "status IN ('pending', 'executing', 'completed', 'cancelled')"
           )

    create unique_index(:account_deletions, [:user_id],
             where: "status IN ('pending', 'executing')",
             name: :account_deletions_one_open_per_user_index
           )

    create index(:account_deletions, [:status, :execute_after])
  end
end
