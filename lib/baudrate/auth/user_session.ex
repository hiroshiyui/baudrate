defmodule Baudrate.Auth.UserSession do
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

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :refresh_token_hash, :expires_at, :refreshed_at, :ip_address, :user_agent])
    |> validate_required([:user_id, :token_hash, :refresh_token_hash, :expires_at, :refreshed_at])
    |> assoc_constraint(:user)
  end
end
