defmodule Baudrate.Repo.Migrations.CreateWebauthnCredentials do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key_cbor, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :aaguid, :binary
      add :label, :string, null: false, default: ""
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
  end
end
