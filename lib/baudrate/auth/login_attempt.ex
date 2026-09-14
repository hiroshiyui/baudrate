defmodule Baudrate.Auth.LoginAttempt do
  @moduledoc """
  Ecto schema for tracking login attempts per account.

  Used for per-account brute-force protection with progressive delay.
  Each record represents a single login attempt (successful or failed)
  and includes the username (lowercased), client IP, and timestamp.

  `factor` records which check the attempt was for:

    * `"password"` — the password step of login, or a password reset
    * `"totp"` — the TOTP step of login, reached only after the correct
      password. Repeated failures here mean someone knows the password
      (ADR 0024).
    * `"reauth"` — step-up re-authentication from a signed-in session. It
      checks the password and code together and never reveals which was wrong.

  Every factor counts toward the per-account login throttle.

  Records older than 7 days are periodically purged by `SessionCleaner`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @factors ~w(password totp reauth)

  schema "login_attempts" do
    field :username, :string
    field :ip_address, :string
    field :success, :boolean, default: false
    field :factor, :string, default: "password"
    field :inserted_at, :utc_datetime
  end

  @doc """
  Changeset for creating a login attempt record.
  """
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:username, :ip_address, :success, :factor, :inserted_at])
    |> validate_required([:username, :success, :factor, :inserted_at])
    |> validate_inclusion(:factor, @factors)
    |> check_constraint(:factor, name: :login_attempts_factor_check)
    |> update_change(:username, &String.downcase/1)
  end
end
