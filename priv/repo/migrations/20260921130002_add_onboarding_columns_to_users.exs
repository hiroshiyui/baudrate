defmodule Baudrate.Repo.Migrations.AddOnboardingColumnsToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      # Set when the first-visit step is finished *or* skipped, so /welcome is
      # shown exactly once. Never cast from params.
      add :onboarded_at, :utc_datetime

      # The recovery notice is dismissible and stays dismissed. Reading this
      # column is also what keeps the notice cheap: the two existence queries
      # behind it run only while it is NULL.
      add :recovery_notice_dismissed_at, :utc_datetime
    end

    # Everyone who is already here has done their onboarding, by definition.
    # Without this, `onboarded_at IS NULL` would send the whole membership to
    # a welcome page on their next sign-in.
    execute "UPDATE users SET onboarded_at = inserted_at", ""
  end

  def down do
    alter table(:users) do
      remove :onboarded_at
      remove :recovery_notice_dismissed_at
    end
  end
end
