defmodule Baudrate.Repo.Migrations.CreateAccountResets do
  use Ecto.Migration

  # An admin-issued, single-use password reset link (ADR 0058), handed to the
  # member out of band after their OpenPGP signature has been verified.
  #
  # Only the SHA-256 of the token is stored: reading this table yields nothing
  # that can be redeemed. `used_at` is claimed with one conditional UPDATE, so
  # two simultaneous redemptions cannot both win.
  def change do
    create table(:account_resets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :issued_by_id, references(:users, on_delete: :nilify_all)
      add :contact_id, references(:recovery_contacts, on_delete: :nilify_all)
      add :clear_second_factors, :boolean, null: false, default: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_resets, [:token_hash])
    create index(:account_resets, [:user_id])

    # One live reset per account: issuing another revokes the first, and this
    # index is what makes "is there one outstanding" a cheap question.
    create index(:account_resets, [:user_id],
             where: "used_at IS NULL AND revoked_at IS NULL",
             name: :account_resets_live_user_id_index
           )
  end
end
