defmodule Baudrate.Auth.LoginAttempt do
  @moduledoc """
  Ecto schema for tracking login attempts per account.

  Used for per-account brute-force protection with progressive delay.
  Each record represents a single login attempt (successful or failed)
  and includes the username (lowercased), client IP, and timestamp.

  Records older than 7 days are periodically purged by `SessionCleaner`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "login_attempts" do
    field :username, :string
    field :ip_address, :string
    field :success, :boolean, default: false
    field :inserted_at, :utc_datetime
  end

  @doc """
  Changeset for creating a login attempt record.
  """
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:username, :ip_address, :success, :inserted_at])
    |> validate_required([:username, :success, :inserted_at])
    |> update_change(:username, &String.downcase/1)
  end
end
