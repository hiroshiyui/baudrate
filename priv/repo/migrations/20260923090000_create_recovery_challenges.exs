defmodule Baudrate.Repo.Migrations.CreateRecoveryChallenges do
  @moduledoc """
  The text a member is asked to sign before an admin acts on their anchor
  (ADR 0058, refined by ADR 0067).

  Rows are never deleted or reused: a challenge is what was asked, and when it
  was answered, beside the moderation log entry that names it. Only the newest
  row for a contact counts, and only while it is unconsumed and unexpired, so
  re-issuing supersedes without a column saying so.
  """

  use Ecto.Migration

  def change do
    create table(:recovery_challenges) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :recovery_contact_id, references(:recovery_contacts, on_delete: :delete_all),
        null: false

      add :phrase, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :issued_by_id, references(:users, on_delete: :nilify_all)
      add :consumed_at, :utc_datetime
      add :consumed_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:recovery_challenges, [:user_id])

    # The live-challenge lookup is "newest row for this contact", which is
    # this index read backwards.
    create index(:recovery_challenges, [:recovery_contact_id, :id])
  end
end
