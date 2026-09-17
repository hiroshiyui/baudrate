defmodule Baudrate.Auth.RecoveryCode do
  @moduledoc """
  Schema for one-time recovery codes stored in the `recovery_codes` table.

  Each code is a cryptographically random 8-character base32 string (~41 bits
  of entropy), stored as an HMAC-SHA256 hash keyed with a server-side key
  (`Baudrate.Crypto.Keyring`'s `:auth` class, or `secret_key_base` while that
  class has no keys of its own). Codes are generated in batches of 10 and
  each can only be used once (`used_at` is set on use).

  `key_id` records which key hashed the row. A keyed hash cannot be re-keyed
  without the code itself, so codes issued under a retired key keep working
  and the rotation task counts what still depends on it (ADR 0038). It is
  advisory: verification tries every configured key and never filters on this
  column, so a wrong value cannot lock anyone out. It is set when the batch is
  written, never from a form.

  Old codes are deleted whenever new ones are generated (e.g., on TOTP reset).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "recovery_codes" do
    field :code_hash, :binary
    field :key_id, :string
    field :used_at, :utc_datetime

    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Casts and validates fields for creating a recovery code record."
  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:user_id, :code_hash, :used_at])
    |> validate_required([:user_id, :code_hash])
    |> assoc_constraint(:user)
  end
end
