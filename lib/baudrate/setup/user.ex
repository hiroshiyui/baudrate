defmodule Baudrate.Setup.User do
  @moduledoc """
  Schema for users stored in the `users` table.

  ## Password Policy

  Enforced by `registration_changeset/2`:

    * Minimum 12 characters, maximum 72 (bcrypt limit)
    * Must contain: lowercase, uppercase, digit, and special character
    * Passwords are hashed with bcrypt before storage; the plaintext is
      deleted from the changeset after hashing

  ## TOTP Fields

    * `totp_secret` — AES-256-GCM encrypted TOTP secret (binary), or `nil`
      if TOTP has not been enabled. Never stores the raw secret.
    * `totp_enabled` — boolean flag; when `true`, login requires TOTP verification

  ## Status

    * `"active"` — fully functional account (default)
    * `"pending"` — awaiting admin approval; can log in and browse,
      but cannot create articles or upload avatars
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :hashed_password, :string
    field :totp_secret, :binary
    field :totp_enabled, :boolean, default: false
    field :avatar_id, :string
    field :status, :string, default: "active"

    belongs_to :role, Baudrate.Setup.Role

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password, :password_confirmation, :role_id])
    |> validate_username()
    |> validate_password()
    |> assoc_constraint(:role)
    |> hash_password()
  end

  defp validate_username(changeset) do
    changeset
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "only allows letters, numbers, and underscores"
    )
    |> unique_constraint(:username)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> validate_format(:password, ~r/[a-z]/, message: "must contain a lowercase letter")
    |> validate_format(:password, ~r/[A-Z]/, message: "must contain an uppercase letter")
    |> validate_format(:password, ~r/[0-9]/, message: "must contain a digit")
    |> validate_format(:password, ~r/[^a-zA-Z0-9]/, message: "must contain a special character")
    |> validate_confirmation(:password, message: "does not match password")
  end

  def avatar_changeset(user, attrs) do
    user
    |> cast(attrs, [:avatar_id])
  end

  def totp_changeset(user, attrs) do
    user
    |> cast(attrs, [:totp_secret, :totp_enabled])
  end

  def status_changeset(user, attrs) do
    user
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["active", "pending"])
  end

  defp hash_password(changeset) do
    if changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(get_change(changeset, :password)))
      |> delete_change(:password)
      |> delete_change(:password_confirmation)
    else
      changeset
    end
  end
end
