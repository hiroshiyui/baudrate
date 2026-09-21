defmodule Baudrate.Auth.AccountReset do
  @moduledoc """
  An admin-issued, single-use password reset link (ADR 0058).

  Issued only after the member's OpenPGP signature has been verified out of
  band, and handed to them through that same channel — this instance sends no
  mail. The row is the record of *that* decision: who issued it, against which
  verified contact, and whether the second-factor tick was set.

  **Only the hash of the token is stored.** The link is shown to the admin
  once; reading this table afterwards yields nothing redeemable, which matters
  because an admin surface displays these rows and a database backup outlives
  the 24 hours the link is good for.

  Redemption is claimed with one conditional `UPDATE ... WHERE used_at IS NULL`
  in `Baudrate.Auth.Recovery`, so two simultaneous attempts cannot both win.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Auth.RecoveryContact
  alias Baudrate.Setup.User

  @token_bytes 32
  @ttl_hours 24

  @type t :: %__MODULE__{}

  schema "account_resets" do
    field :token_hash, :binary, redact: true
    field :clear_second_factors, :boolean, default: false
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User
    belongs_to :issued_by, User
    belongs_to :contact, RecoveryContact

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Mints a link token and the row that will redeem it.

  Returns `{token, changeset}` — the token is returned rather than stored, and
  the caller is responsible for showing it exactly once.
  """
  @spec build(User.t(), User.t(), RecoveryContact.t(), boolean()) ::
          {String.t(), Ecto.Changeset.t()}
  def build(%User{} = user, %User{} = issuer, %RecoveryContact{} = contact, clear_second_factors?) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    changeset =
      %__MODULE__{}
      |> change(%{
        user_id: user.id,
        issued_by_id: issuer.id,
        contact_id: contact.id,
        token_hash: hash(token),
        clear_second_factors: clear_second_factors?,
        expires_at: DateTime.add(DateTime.utc_now(:second), @ttl_hours * 3600, :second)
      })
      |> validate_required([:user_id, :token_hash, :expires_at])

    {token, changeset}
  end

  @doc """
  The stored form of a link token.

  SHA-256 rather than a password hash on purpose: the token is 32 random bytes
  from `:crypto.strong_rand_bytes/1`, so there is no guessing to slow down, and
  redemption has to be a single indexed lookup.
  """
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "How long an issued link is good for, in hours."
  def ttl_hours, do: @ttl_hours
end
