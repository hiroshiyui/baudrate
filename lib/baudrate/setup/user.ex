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

  ## ActivityPub Fields

    * `ap_public_key` — PEM-encoded RSA public key for ActivityPub federation
    * `ap_private_key_encrypted` — AES-256-GCM encrypted PEM-encoded RSA private key

  ## Status

    * `"active"` — fully functional account (default)
    * `"pending"` — awaiting admin approval; can log in and browse,
      but cannot create articles or upload avatars
    * `"banned"` — account suspended by an admin; cannot log in

  ## Ban Fields

    * `banned_at` — UTC timestamp of when the ban was applied
    * `ban_reason` — optional text reason provided by the admin

  ## Locale Preferences

    * `preferred_locales` — ordered list of locale codes (e.g. `["zh_TW", "en"]`).
      When non-empty, the first matching known Gettext locale is used instead of
      the browser's `Accept-Language` header. Validated by `locale_changeset/2`.

  ## Direct Message Access

    * `dm_access` — controls who can send DMs to this user:
      `"anyone"` (default), `"followers"` (AP followers only), or `"nobody"`.

  ## Bio

    * `bio` — plaintext bio/about-me text (max 500 characters). Supports hashtag
      linkification for display. Mapped to the ActivityPub `summary` field on the
      Person actor. Validated by `bio_changeset/2`.

  ## Invite Chain Tracking

    * `invited_by_id` — references the user who generated the invite code used
      during registration. `nil` for users who registered via open/approval modes.
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
    field :preferred_locales, {:array, :string}, default: []
    field :banned_at, :utc_datetime
    field :ban_reason, :string
    field :ap_public_key, :string
    field :ap_private_key_encrypted, :binary
    field :signature, :string
    field :bio, :string
    field :dm_access, :string, default: "anyone"

    belongs_to :role, Baudrate.Setup.Role
    belongs_to :invited_by, __MODULE__

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :terms_accepted, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for new user registration: validates username, password policy, and hashes the password."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :password,
      :password_confirmation,
      :role_id,
      :terms_accepted,
      :invited_by_id
    ])
    |> validate_username()
    |> validate_password()
    |> assoc_constraint(:role)
    |> hash_password()
  end

  @doc """
  Validates that terms have been accepted. Used for public registration only.
  """
  def validate_terms(changeset) do
    validate_acceptance(changeset, :terms_accepted)
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

  @doc "Changeset for resetting a user's password: validates and hashes the new password."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_password()
    |> hash_password()
  end

  @doc "Changeset for updating a user's avatar ID."
  def avatar_changeset(user, attrs) do
    user
    |> cast(attrs, [:avatar_id])
  end

  @doc "Changeset for updating TOTP secret and enabled flag."
  def totp_changeset(user, attrs) do
    user
    |> cast(attrs, [:totp_secret, :totp_enabled])
  end

  @doc "Changeset for setting user status to `\"active\"` or `\"pending\"`."
  def status_changeset(user, attrs) do
    user
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["active", "pending"])
  end

  @doc "Changeset for banning a user: sets status to `\"banned\"` with timestamp and optional reason."
  def ban_changeset(user, attrs) do
    user
    |> cast(attrs, [:status, :banned_at, :ban_reason])
    |> validate_required([:status, :banned_at])
    |> validate_inclusion(:status, ["banned"])
    |> validate_length(:ban_reason, max: 500)
  end

  @doc "Changeset for unbanning a user: resets status to `\"active\"` and clears ban fields."
  def unban_changeset(user) do
    user
    |> cast(%{status: "active"}, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["active"])
    |> put_change(:banned_at, nil)
    |> put_change(:ban_reason, nil)
  end

  @doc "Changeset for updating a user's role assignment."
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role_id])
    |> validate_required([:role_id])
    |> assoc_constraint(:role)
  end

  @doc "Changeset for updating the user's ActivityPub RSA keypair."
  def ap_key_changeset(user, attrs) do
    user
    |> cast(attrs, [:ap_public_key, :ap_private_key_encrypted])
  end

  @max_signature_lines 8

  @doc "Changeset for updating the user's forum signature (max 500 chars, 8 lines)."
  def signature_changeset(user, attrs) do
    user
    |> cast(attrs, [:signature])
    |> validate_length(:signature, max: 500)
    |> validate_change(:signature, fn :signature, signature ->
      newline_count = signature |> String.graphemes() |> Enum.count(&(&1 == "\n"))

      if newline_count > @max_signature_lines - 1 do
        [signature: "must not exceed #{@max_signature_lines} lines"]
      else
        []
      end
    end)
  end

  @doc "Changeset for updating the user's preferred locale list."
  def locale_changeset(user, attrs) do
    known = Gettext.known_locales(BaudrateWeb.Gettext)

    user
    |> cast(attrs, [:preferred_locales])
    |> validate_change(:preferred_locales, fn :preferred_locales, locales ->
      invalid = Enum.reject(locales, &(&1 in known))

      if invalid == [] do
        []
      else
        [preferred_locales: "contains unknown locales: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  @doc "Changeset for updating the user's bio (max 500 chars, plaintext)."
  def bio_changeset(user, attrs) do
    user
    |> cast(attrs, [:bio])
    |> validate_length(:bio, max: 500)
  end

  @doc "Changeset for updating DM access preference (`\"anyone\"`, `\"followers\"`, or `\"nobody\"`)."
  def dm_access_changeset(user, attrs) do
    user
    |> cast(attrs, [:dm_access])
    |> validate_required([:dm_access])
    |> validate_inclusion(:dm_access, ["anyone", "followers", "nobody"])
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
