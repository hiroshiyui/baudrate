defmodule Baudrate.Auth.SecondFactor do
  @moduledoc """
  Handles TOTP two-factor authentication and recovery codes.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Auth.{RecoveryCode, TotpVault}
  alias Baudrate.Setup.User

  @recovery_code_count 10

  @doc """
  Returns the TOTP policy for a given role name.

  - `:required` — admin, moderator must set up TOTP
  - `:optional` — user can optionally enable TOTP
  - `:disabled` — guest has no TOTP capability
  """
  @spec totp_policy(String.t()) :: :required | :optional | :disabled
  def totp_policy(role_name) when role_name in ["admin", "moderator"], do: :required
  def totp_policy("user"), do: :optional
  def totp_policy(_), do: :disabled

  @doc """
  Determines the next step after password authentication.

  This is the core state machine transition function. Given a user who has
  passed password auth, it returns the next state:

    * `:totp_verify` — user has TOTP enabled, needs to verify a code
    * `:totp_setup` — role requires TOTP but user hasn't enrolled yet
    * `:authenticated` — no TOTP needed, ready to establish a server-side session
  """
  @spec login_next_step(User.t()) :: :totp_verify | :totp_setup | :authenticated
  def login_next_step(user) do
    cond do
      user.totp_enabled -> :totp_verify
      totp_policy(user.role.name) == :required -> :totp_setup
      true -> :authenticated
    end
  end

  @doc """
  Generates a new 20-byte TOTP secret.
  """
  def generate_totp_secret do
    NimbleTOTP.secret()
  end

  @doc """
  Builds an otpauth URI for QR code generation.
  """
  def totp_uri(secret, username, issuer \\ "Baudrate") do
    NimbleTOTP.otpauth_uri("#{issuer}:#{username}", secret, issuer: issuer)
  end

  @doc """
  Generates a Base64-encoded SVG data URI for QR code display.
  """
  def totp_qr_data_uri(uri) do
    svg =
      uri
      |> EQRCode.encode()
      |> EQRCode.svg(width: 264)

    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  @doc """
  Validates a TOTP code against a secret.

  Accepts an optional `since:` unix timestamp or `DateTime` to reject codes
  from the same or earlier time period. This provides replay protection —
  a code that was already used in a given 30-second window will be rejected
  if `since` is set to the timestamp of the previous successful verification.
  """
  @spec valid_totp?(binary(), String.t(), keyword()) :: boolean()
  def valid_totp?(secret, code, opts \\ []) do
    nimble_opts =
      case Keyword.get(opts, :since) do
        nil -> []
        ts when is_integer(ts) -> [since: DateTime.from_unix!(ts)]
        %DateTime{} = dt -> [since: dt]
      end

    NimbleTOTP.valid?(secret, code, nimble_opts)
  end

  @doc """
  Enables TOTP for a user by encrypting the raw secret via `TotpVault.encrypt/1`
  and persisting the ciphertext alongside `totp_enabled: true`.

  The raw secret never touches the database — only the AES-256-GCM ciphertext
  is stored in `users.totp_secret`.
  """
  @spec enable_totp(User.t(), binary()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def enable_totp(user, secret) do
    encrypted = TotpVault.encrypt(secret)

    user
    |> User.totp_changeset(%{totp_secret: encrypted, totp_enabled: true})
    |> Repo.update()
  end

  @doc """
  Decrypts a user's TOTP secret from the stored encrypted form.
  Returns the raw secret binary or nil.
  """
  @spec decrypt_totp_secret(User.t()) :: binary() | nil
  def decrypt_totp_secret(%User{totp_secret: nil}), do: nil

  def decrypt_totp_secret(%User{totp_secret: encrypted}) do
    case TotpVault.decrypt(encrypted) do
      {:ok, secret} -> secret
      :error -> nil
    end
  end

  @doc """
  Disables TOTP for a user by clearing the encrypted secret and setting
  `totp_enabled` to `false`.
  """
  def disable_totp(user) do
    user
    |> User.totp_changeset(%{totp_secret: nil, totp_enabled: false})
    |> Repo.update()
  end

  @doc """
  Generates #{@recovery_code_count} one-time recovery codes for a user.

  Deletes any existing recovery codes, generates new cryptographically random
  codes (5 bytes → 8 base32 chars, ~41 bits of entropy each), stores their
  HMAC-SHA256 hashes, and returns the formatted codes (`xxxx-xxxx`) for
  one-time display to the user.
  """
  def generate_recovery_codes(user) do
    from(rc in RecoveryCode, where: rc.user_id == ^user.id)
    |> Repo.delete_all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    raw_codes =
      Enum.map(1..@recovery_code_count, fn _ ->
        :crypto.strong_rand_bytes(5)
        |> Base.encode32(case: :lower, padding: false)
      end)

    entries =
      Enum.map(raw_codes, fn code ->
        %{
          user_id: user.id,
          code_hash: hmac_recovery_code(code),
          inserted_at: now
        }
      end)

    Repo.insert_all(RecoveryCode, entries)

    Enum.map(raw_codes, &format_recovery_code/1)
  end

  @doc """
  Verifies a recovery code for a user.

  Normalizes the input (strip whitespace, dashes, downcase), computes the
  HMAC-SHA256 hash, and atomically marks the matching unused code as used
  via `Repo.update_all` to prevent TOCTOU race conditions. Returns `:ok`
  if exactly one code was consumed, `:error` otherwise.
  """
  @spec verify_recovery_code(User.t(), String.t() | any()) :: :ok | :error
  def verify_recovery_code(user, code) when is_binary(code) do
    code_hash = hmac_recovery_code(normalize_recovery_code(code))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(rc in RecoveryCode,
        where: rc.user_id == ^user.id and rc.code_hash == ^code_hash and is_nil(rc.used_at)
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  def verify_recovery_code(_, _), do: :error

  defp normalize_recovery_code(code) do
    code |> String.trim() |> String.downcase() |> String.replace("-", "")
  end

  defp format_recovery_code(code) do
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  defp hmac_recovery_code(code) do
    :crypto.mac(:hmac, :sha256, recovery_code_hmac_key(), code)
  end

  defp recovery_code_hmac_key do
    secret_key_base =
      Application.get_env(:baudrate, BaudrateWeb.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "recovery_code_hmac_key", length: 32)
  end
end
