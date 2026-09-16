defmodule Baudrate.Repo.Migrations.AddTermsAcceptanceToUsers do
  @moduledoc """
  Records that a member accepted the terms, and which version they accepted.

  Until now `terms_accepted` was a virtual field: the registration form
  validated the checkbox and then threw the answer away, so editing the terms
  silently changed what everyone had "agreed" to, with no record of who agreed
  to what.

  Existing accounts are stamped as having accepted version 0 — the terms as
  they stood before this existed — at the time they registered. The alternative
  was leaving them null and confronting every member with a blocking banner on
  deploy day, which would make the release itself the disruption rather than
  the admin's first deliberate publication.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :terms_accepted_at, :utc_datetime
      add :terms_version, :integer, default: 0, null: false
    end

    flush()

    # Every existing account accepted whatever stood at registration time.
    execute("UPDATE users SET terms_accepted_at = inserted_at")

    # The published version starts level with them, so nobody is prompted
    # until an admin ticks "require members to accept again".
    execute("""
    INSERT INTO settings (key, value, inserted_at, updated_at)
    VALUES ('eua_version', '0', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM settings WHERE key = 'eua_version'")

    alter table(:users) do
      remove :terms_accepted_at
      remove :terms_version
    end
  end
end
