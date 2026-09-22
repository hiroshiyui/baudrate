defmodule Baudrate.Repo.Migrations.CreateIpBans do
  use Ecto.Migration

  def change do
    create table(:ip_bans) do
      # The network address with its host bits cleared, as `:inet.ntoa/1`
      # prints it, plus the prefix length. Stored as text rather than as
      # PostgreSQL's `inet`: the table holds tens of rows at most, matching
      # happens in memory against the cache, and a native type would need an
      # Ecto type of its own for no gain.
      add :address, :string, null: false
      add :prefix_length, :integer, null: false
      add :family, :string, null: false
      add :reason, :text

      # NULL means the ban does not end. Whether it is active is decided by the
      # clock when it is read, never by a sweep (ADR 0029's rule for sanctions).
      add :expires_at, :utc_datetime

      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ip_bans, [:address, :prefix_length])
  end
end
