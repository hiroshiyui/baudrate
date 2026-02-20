defmodule Baudrate.Auth do
  @moduledoc """
  The Auth context handles authentication and TOTP two-factor authentication.

  ## Session State Machine

      Unauthenticated
          │
          ▼
      Password Auth ──→ login_next_step/1
          │
          ├─ :totp_verify  → user has TOTP enabled, must verify code
          ├─ :totp_setup   → admin/moderator without TOTP, must enroll
          └─ :authenticated → no TOTP needed, session established
          │
          ▼
      Fully Authenticated (server-side session created)

  ## Token Security Model

  Sessions use a dual-token scheme:

    * **Session token** — stored in the cookie, used for request authentication.
      Only the SHA-256 hash is persisted in the database, so a database leak
      does not compromise active sessions.
    * **Refresh token** — also cookie-stored and hash-persisted. Used to rotate
      both tokens after the refresh interval (see `RefreshSession` plug).

  Both tokens are 32-byte cryptographically random values, URL-safe Base64 encoded.

  ## TOTP Policy

  TOTP requirements are role-based (see `totp_policy/1`):

    * `:required` — admin, moderator (must enroll before first login completes)
    * `:optional` — user (can enable voluntarily)
    * `:disabled` — guest (no TOTP capability)

  ## Key Constants

    * `@session_ttl_seconds` — 14 days; both session and refresh tokens expire after this
    * `@max_sessions_per_user` — 3; oldest session (by `refreshed_at`) is evicted when exceeded
  """

  import Ecto.Query
  alias Baudrate.Auth.{TotpVault, UserSession}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @session_ttl_seconds 14 * 86_400
  @max_sessions_per_user 3

  @doc """
  Authenticates a user by username and password.

  Returns `{:ok, user}` with role preloaded or `{:error, :invalid_credentials}`.

  Uses `Bcrypt.no_user_verify/0` on failed lookups to maintain constant-time
  behavior regardless of whether the username exists, preventing timing-based
  user enumeration.
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

  This is the core state machine transition function. Given a user who has
  passed password auth, it returns the next state:

    * `:totp_verify` — user has TOTP enabled, needs to verify a code
    * `:totp_setup` — role requires TOTP but user hasn't enrolled yet
    * `:authenticated` — no TOTP needed, ready to establish a server-side session
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

  Accepts an optional `since:` unix timestamp or `DateTime` to reject codes
  from the same or earlier time period. This provides replay protection —
  a code that was already used in a given 30-second window will be rejected
  if `since` is set to the timestamp of the previous successful verification.
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
  Enables TOTP for a user by encrypting the raw secret via `TotpVault.encrypt/1`
  and persisting the ciphertext alongside `totp_enabled: true`.

  The raw secret never touches the database — only the AES-256-GCM ciphertext
  is stored in `users.totp_secret`.
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

  # --- Server-side session management ---

  @doc """
  Generates a random 32-byte token, returned as URL-safe Base64.
  """
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns the SHA-256 hash of a raw token (binary).
  """
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token)
  end

  @doc """
  Creates a new server-side session for the given user.

  Generates a fresh session token and refresh token (both 32-byte random),
  stores only their SHA-256 hashes in the database, and returns the raw tokens
  to be placed into the cookie.

  Enforces a maximum of #{@max_sessions_per_user} concurrent sessions per user
  within a transaction. When the limit is exceeded, the oldest session (by
  `refreshed_at`) is evicted before inserting the new one.

  ## Options

    * `:ip_address` — client IP string (logged for security auditing)
    * `:user_agent` — client User-Agent string

  Returns `{:ok, session_token, refresh_token}` or `{:error, changeset}`.
  """
  def create_user_session(user_id, opts \\ []) do
    session_token = generate_token()
    refresh_token = generate_token()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @session_ttl_seconds, :second)

    Repo.transaction(fn ->
      evict_excess_sessions(user_id)

      changeset =
        UserSession.changeset(%UserSession{}, %{
          user_id: user_id,
          token_hash: hash_token(session_token),
          refresh_token_hash: hash_token(refresh_token),
          expires_at: expires_at,
          refreshed_at: now,
          ip_address: opts[:ip_address],
          user_agent: opts[:user_agent]
        })

      case Repo.insert(changeset) do
        {:ok, _session} -> {session_token, refresh_token}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {session_token, refresh_token}} -> {:ok, session_token, refresh_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp evict_excess_sessions(user_id) do
    sessions =
      from(s in UserSession,
        where: s.user_id == ^user_id,
        order_by: [asc: s.refreshed_at],
        select: s.id
      )
      |> Repo.all()

    excess_count = length(sessions) - (@max_sessions_per_user - 1)

    if excess_count > 0 do
      ids_to_delete = Enum.take(sessions, excess_count)
      from(s in UserSession, where: s.id in ^ids_to_delete) |> Repo.delete_all()
    end
  end

  @doc """
  Looks up a user by session token. Returns `{:ok, user}` if the session
  is valid and not expired, or `{:error, :not_found | :expired}`.
  """
  def get_user_by_session_token(raw_token) do
    token_hash = hash_token(raw_token)

    case Repo.one(from s in UserSession, where: s.token_hash == ^token_hash, preload: [user: :role]) do
      nil ->
        {:error, :not_found}

      session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
          {:ok, session.user}
        else
          Repo.delete(session)
          {:error, :expired}
        end
    end
  end

  @doc """
  Rotates both session and refresh tokens using the current refresh token.

  Generates new random tokens, updates their hashes in the database, and resets
  `expires_at` to #{@session_ttl_seconds} seconds from now. The old tokens become
  immediately invalid after rotation.

  If the session has expired, it is deleted and `{:error, :expired}` is returned.

  Returns `{:ok, new_session_token, new_refresh_token}` or `{:error, reason}`.
  """
  def refresh_user_session(raw_refresh_token) do
    refresh_hash = hash_token(raw_refresh_token)

    case Repo.one(from s in UserSession, where: s.refresh_token_hash == ^refresh_hash) do
      nil ->
        {:error, :not_found}

      session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
          new_session_token = generate_token()
          new_refresh_token = generate_token()
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          new_expires_at = DateTime.add(now, @session_ttl_seconds, :second)

          session
          |> Ecto.Changeset.change(%{
            token_hash: hash_token(new_session_token),
            refresh_token_hash: hash_token(new_refresh_token),
            expires_at: new_expires_at,
            refreshed_at: now
          })
          |> Repo.update()
          |> case do
            {:ok, _} -> {:ok, new_session_token, new_refresh_token}
            {:error, changeset} -> {:error, changeset}
          end
        else
          Repo.delete(session)
          {:error, :expired}
        end
    end
  end

  @doc """
  Deletes the session matching the given raw session token.
  """
  def delete_session_by_token(raw_token) do
    token_hash = hash_token(raw_token)
    from(s in UserSession, where: s.token_hash == ^token_hash) |> Repo.delete_all()
    :ok
  end

  @doc """
  Purges all expired sessions from the database.
  Returns `{count, nil}` with the number of deleted rows.
  """
  def purge_expired_sessions do
    now = DateTime.utc_now()
    from(s in UserSession, where: s.expires_at < ^now) |> Repo.delete_all()
  end
end
