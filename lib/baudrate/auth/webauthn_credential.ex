defmodule Baudrate.Auth.WebAuthnCredential do
  @moduledoc """
  Schema for a registered WebAuthn (FIDO2) credential.

  Each row represents one security key or platform authenticator enrolled
  by a user. A user may have multiple credentials for redundancy.

  ## Fields

  - `credential_id` — raw credential ID bytes from the authenticator.
    Used as the lookup key during authentication.
  - `public_key_cbor` — COSE-encoded public key (CBOR bytes). Passed to
    `Wax.authenticate/6` for signature verification.
  - `sign_count` — monotonically increasing counter from the authenticator.
    Checked on every authentication to detect cloned keys.
  - `aaguid` — authenticator model identifier (informational).
  - `label` — user-assigned name, e.g. "YubiKey 5C".
  - `last_used_at` — timestamp of the most recent successful authentication.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  schema "webauthn_credentials" do
    belongs_to :user, User

    field :credential_id, :binary
    field :public_key_cbor, :binary
    field :sign_count, :integer, default: 0
    field :aaguid, :binary
    field :label, :string, default: ""
    field :last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new credential."
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:user_id, :credential_id, :public_key_cbor, :sign_count, :aaguid, :label])
    |> validate_required([:user_id, :credential_id, :public_key_cbor])
    |> validate_length(:label, max: 255)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for updating sign_count and last_used_at after authentication."
  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:sign_count, :last_used_at, :label])
    |> validate_required([:sign_count])
  end
end
