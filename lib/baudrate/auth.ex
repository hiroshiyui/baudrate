defmodule Baudrate.Auth do
  @moduledoc """
  The Auth context handles authentication and TOTP two-factor authentication.
  """

  import Ecto.Query
  alias Baudrate.Auth.TotpVault
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @doc """
  Authenticates a user by username and password.
  Returns `{:ok, user}` with role preloaded or `{:error, :invalid_credentials}`.
  """
  def authenticate_by_password(username, password) do
    user = Repo.one(from u in User, where: u.username == ^username, preload: :role)

    if user && Bcrypt.verify_pass(password, user.hashed_password) do
      {:ok, user}
    else
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Returns the TOTP policy for a given role name.

  - `:required` — admin, moderator must set up TOTP
  - `:optional` — user can optionally enable TOTP
  - `:disabled` — guest has no TOTP capability
  """
  def totp_policy(role_name) when role_name in ["admin", "moderator"], do: :required
  def totp_policy("user"), do: :optional
  def totp_policy(_), do: :disabled

  @doc """
  Determines the next step after password authentication.

  - `:totp_verify` — user has TOTP enabled, needs to verify code
  - `:totp_setup` — admin/moderator without TOTP, must set up
  - `:authenticated` — no TOTP needed, fully authenticated
  """
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
  Generates an SVG QR code from an otpauth URI string.
  """
  def totp_qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 264)
  end

  @doc """
  Validates a TOTP code against a secret.

  Accepts an optional `since:` unix timestamp to reject codes from the same
  or earlier time period (replay protection).
  """
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
  Enables TOTP for a user by encrypting and storing the secret,
  and setting totp_enabled to true.
  """
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
  def decrypt_totp_secret(%User{totp_secret: nil}), do: nil

  def decrypt_totp_secret(%User{totp_secret: encrypted}) do
    case TotpVault.decrypt(encrypted) do
      {:ok, secret} -> secret
      :error -> nil
    end
  end

  @doc """
  Gets a user by ID with role preloaded.
  """
  def get_user(id) do
    Repo.one(from u in User, where: u.id == ^id, preload: :role)
  end
end
