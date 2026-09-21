defmodule Baudrate.Auth.RecoveryContact do
  @moduledoc """
  A member's out-of-band recovery anchor: an email address and the OpenPGP
  public key that signs from it (ADR 0058).

  **The member registers it; an admin only confirms it.** Both changesets here
  exist to keep that true:

    * `changeset/3` is the member's, and casts the address, the key and a
      label — never `status`, `verified_at` or `verified_by_id`. A member who
      could set those would verify their own anchor, and the admin's check
      would be decoration (the `terms_version` rule, ADR 0049).
    * `verification_changeset/3` is the admin's, and casts nothing else. An
      admin can confirm a key a member put there and cannot put one there.

  **Any change to the address or the key drops the row back to `pending`.**
  That is the property the whole scheme rests on: an attacker holding a stolen
  session can register a new anchor, but it arrives unverified, and verifying
  it means an admin checking a signature against a key the real member never
  published. Editing in place without re-verification would turn a stolen
  session into a permanent takeover.

  The address is stored encrypted (`Baudrate.Auth.RecoveryContactVault`); the
  public key is published material and is stored as written.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Auth.RecoveryContactVault
  alias Baudrate.Setup.User

  @statuses ~w(pending verified)

  # An armored public key with a few UIDs and signatures runs to a few
  # kilobytes; 16 KB is generous and still bounds what a member can store.
  @max_key_bytes 16_384
  @max_email_length 254

  @type t :: %__MODULE__{}

  schema "recovery_contacts" do
    field :email_encrypted, :binary, redact: true
    field :pgp_public_key, :string
    field :label, :string
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime

    belongs_to :user, User
    belongs_to :verified_by, User

    # Never persisted. The address arrives and leaves in the clear and is
    # encrypted on the way into `:email_encrypted`.
    field :email, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  The member's changeset. `owner` is the account the contact belongs to, and
  is what the address is encrypted against.

  Casting deliberately excludes every verification field: see the moduledoc.
  """
  def changeset(contact, attrs, %User{} = owner) do
    contact
    |> cast(attrs, [:email, :pgp_public_key, :label])
    |> update_change(:email, &normalize_email/1)
    |> update_change(:pgp_public_key, &String.trim/1)
    |> update_change(:label, &String.trim/1)
    |> validate_length(:email, max: @max_email_length)
    |> validate_format(:email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/,
      message: "must be an email address"
    )
    |> validate_length(:label, max: 64)
    |> validate_armored_key()
    |> put_change(:user_id, owner.id)
    |> encrypt_email(owner)
    # Required *after* encryption, and against the stored column rather than
    # the virtual field: an update that changes only the key resubmits no
    # address, and the one already on the row is the answer.
    |> validate_required([:email_encrypted, :pgp_public_key])
    |> reset_verification()
  end

  @doc """
  The admin's changeset: mark a contact verified, or put it back to pending.

  `admin` is recorded as the account that made the call, so the audit log and
  the row agree about who confirmed what.
  """
  def verification_changeset(contact, status, %User{} = admin) when status in @statuses do
    verified_at = if status == "verified", do: DateTime.utc_now(:second)
    verified_by_id = if status == "verified", do: admin.id

    contact
    |> change(%{status: status, verified_at: verified_at, verified_by_id: verified_by_id})
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The statuses a contact may hold."
  def statuses, do: @statuses

  @doc """
  Reads the address back out, or `:error` when it cannot be decrypted.

  The owner has to be passed in because the address is bound to it — a row
  moved to another account does not read back.
  """
  @spec email(t(), User.t() | integer()) :: {:ok, String.t()} | :error
  def email(%__MODULE__{email_encrypted: blob}, owner) when is_binary(blob) do
    RecoveryContactVault.decrypt(blob, owner)
  end

  def email(_contact, _owner), do: :error

  defp normalize_email(nil), do: nil
  defp normalize_email(value), do: value |> String.trim() |> String.downcase()

  # Baudrate parses no OpenPGP and depends on no library for it (ADR 0058):
  # every signature check happens in the admin's own client. This is a shape
  # check, so a member notices they pasted the wrong thing while they are
  # still looking at the form — not a claim that the key is valid.
  defp validate_armored_key(changeset) do
    changeset
    |> validate_length(:pgp_public_key, max: @max_key_bytes, count: :bytes)
    |> validate_change(:pgp_public_key, fn :pgp_public_key, key ->
      cond do
        not String.starts_with?(key, "-----BEGIN PGP PUBLIC KEY BLOCK-----") ->
          [pgp_public_key: "must be an armored OpenPGP public key block"]

        not String.ends_with?(key, "-----END PGP PUBLIC KEY BLOCK-----") ->
          [pgp_public_key: "must end with the armored block's footer"]

        true ->
          []
      end
    end)
  end

  defp encrypt_email(changeset, owner) do
    case get_change(changeset, :email) do
      nil ->
        changeset

      email ->
        changeset
        |> put_change(:email_encrypted, RecoveryContactVault.encrypt(email, owner))
        |> delete_change(:email)
    end
  end

  # A changed address or key is a new anchor, whatever the old one said.
  defp reset_verification(changeset) do
    if changed?(changeset, :email_encrypted) or changed?(changeset, :pgp_public_key) do
      change(changeset, %{status: "pending", verified_at: nil, verified_by_id: nil})
    else
      changeset
    end
  end
end
