defmodule Baudrate.Repo.Migrations.AddTotpEnabledAtToUsers do
  use Ecto.Migration

  # `totp_enabled_at` records when TOTP was (re-)enabled, so features that must
  # not trust a freshly enrolled factor can require a minimum age (ADR 0023:
  # self-service data export needs TOTP enabled for at least 7 days).
  #
  # The true enrolment time of accounts that already have TOTP is unknown. They
  # are backfilled with the migration time, not `updated_at` (which changes for
  # unrelated reasons and could predate an attacker's enrolment), so existing
  # users simply wait out the minimum age after the upgrade.
  def up do
    alter table(:users) do
      add :totp_enabled_at, :utc_datetime
    end

    execute("""
    UPDATE users
    SET totp_enabled_at = date_trunc('second', now() AT TIME ZONE 'UTC')
    WHERE totp_enabled = true
    """)
  end

  def down do
    alter table(:users) do
      remove :totp_enabled_at
    end
  end
end
