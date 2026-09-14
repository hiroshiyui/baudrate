defmodule Baudrate.Repo.Migrations.AddTotpReplayProtection do
  use Ecto.Migration

  # ADR 0024: a TOTP code is accepted at most once per account, and failed
  # second-factor attempts are told apart from password failures.
  def change do
    alter table(:users) do
      # The most recent TOTP time step (unix time div 30) accepted for this
      # account. A code is accepted only for a later step.
      add :totp_last_used_step, :bigint
    end

    alter table(:login_attempts) do
      add :factor, :string, null: false, default: "password"
    end

    create constraint(:login_attempts, :login_attempts_factor_check,
             check: "factor IN ('password', 'totp', 'reauth')"
           )
  end
end
