defmodule Baudrate.Auth.UserSession do
  @moduledoc """
  Schema for server-side sessions stored in the `user_sessions` table.

  ## Token Hashing

  Raw session and refresh tokens are never stored. Only their SHA-256 hashes
  (`token_hash`, `refresh_token_hash`) are persisted, so a database compromise
  does not expose usable session credentials.

  ## Eviction Policy

  Each user may have at most 3 concurrent sessions (enforced by
  `Auth.create_user_session/2`). When a new session would exceed the limit,
  the oldest session by `refreshed_at` is evicted within the same transaction.

  ## Fields

    * `token_hash` — SHA-256 of the session token (used for request auth)
    * `refresh_token_hash` — SHA-256 of the refresh token (used for rotation)
    * `expires_at` — absolute expiry (14 days from creation/refresh)
    * `refreshed_at` — last rotation timestamp; also used for eviction ordering
    * `ip_address`, `user_agent` — recorded at creation for audit logging
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_sessions" do
    field :token_hash, :binary
    field :refresh_token_hash, :binary
    field :expires_at, :utc_datetime
    field :refreshed_at, :utc_datetime
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Casts and validates fields for creating a user session record."
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :token_hash,
      :refresh_token_hash,
      :expires_at,
      :refreshed_at,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:user_id, :token_hash, :refresh_token_hash, :expires_at, :refreshed_at])
    |> assoc_constraint(:user)
  end
end
