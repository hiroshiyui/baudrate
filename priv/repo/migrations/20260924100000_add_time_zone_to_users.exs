defmodule Baudrate.Repo.Migrations.AddTimeZoneToUsers do
  use Ecto.Migration

  # The zone a member's timestamps are shown in. NULL means the site's
  # `timezone` setting, so every existing account keeps what it sees today.
  def change do
    alter table(:users) do
      add :time_zone, :string, size: 64
    end
  end
end
