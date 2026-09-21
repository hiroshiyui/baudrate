defmodule Baudrate.Repo.Migrations.CreateRecoveryContacts do
  use Ecto.Migration

  # The out-of-band anchor for account recovery (ADR 0058). A member registers
  # an address and an OpenPGP public key while signed in; an admin confirms
  # that a signed message from that address verifies against that key, and
  # marks the row verified. Baudrate sends no mail and verifies no signature.
  #
  # The address is encrypted at rest under the `:auth` keyring class, like a
  # TOTP secret: on a pseudonymous forum a database leak must not hand over
  # members' real-world addresses. The public key is published material and
  # stays readable.
  def change do
    create table(:recovery_contacts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :email_encrypted, :binary, null: false
      add :pgp_public_key, :text, null: false
      add :label, :string
      add :status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime
      add :verified_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:recovery_contacts, [:user_id])

    # The nudge asks "can this account be recovered at all", which is an
    # existence check for a verified row.
    create index(:recovery_contacts, [:user_id],
             where: "status = 'verified'",
             name: :recovery_contacts_verified_user_id_index
           )
  end
end
