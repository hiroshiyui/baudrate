defmodule Baudrate.Repo.Migrations.AddLastActiveOnToUsers do
  @moduledoc """
  The day an account was last signed in, for NodeInfo's `activeMonth` and
  `activeHalfyear` (Phase 3F).

  Those counts cannot come from `user_sessions`. A session lives 14 days and
  `purge_expired_sessions` deletes it afterwards, so the table can answer "was
  this account here in the last fortnight" and nothing longer — `activeMonth`
  would undercount and `activeHalfyear` would be close to meaningless. Every
  other durable trace is worse: `login_attempts` is purged after 7 days, and
  counting people by what they *posted* misses everyone who reads.

  **A date, not a timestamp**, and that is the point rather than an
  oversight. The question NodeInfo asks is which month someone was last here;
  a timestamp would additionally record what time of day they read the site,
  every day, for six months — strictly more than the answer needs. A date is
  the smallest column that can answer it.

  Written on session creation and refresh, and only when it changes, so it
  costs at most one write per account per day. Nullable: an account that has
  not signed in since the upgrade has no answer, and pretending otherwise
  would inflate the counts this exists to make honest.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_active_on, :date
    end

    # The counts are two range scans over this column and nothing else.
    create index(:users, [:last_active_on])
  end
end
