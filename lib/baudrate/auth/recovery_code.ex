defmodule Baudrate.Auth.RecoveryCode do
  @moduledoc """
  Schema for one-time recovery codes stored in the `recovery_codes` table.

  Each code is stored as a SHA-256 hash (one-way, like passwords). Codes are
  generated in batches of 10 when TOTP is enabled, and each code can only be
  used once (`used_at` is set on use).

  Old codes are deleted whenever new ones are generated (e.g., on TOTP reset).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "recovery_codes" do
    field :code_hash, :binary
    field :used_at, :utc_datetime

    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:user_id, :code_hash, :used_at])
    |> validate_required([:user_id, :code_hash])
    |> assoc_constraint(:user)
  end
end
