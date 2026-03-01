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

  ## Locale Preferences

  Users can set an ordered list of preferred locales via `update_preferred_locales/2`.
  The first match against known Gettext locales wins. If empty, the system falls
  back to the browser's `Accept-Language` header.

  ## Key Constants

    * `@session_ttl_seconds` — 14 days; both session and refresh tokens expire after this
    * `@max_sessions_per_user` — 3; oldest session (by `refreshed_at`) is evicted when exceeded
  """

  import Ecto.Query

  alias Baudrate.Auth.{
    InviteCode,
    LoginAttempt,
    RecoveryCode,
    TotpVault,
    UserBlock,
    UserMute,
    UserSession
  }

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  @recovery_code_count 10

  @session_ttl_seconds 14 * 86_400
  @max_sessions_per_user 3

  @invite_quota_limit 5
  @invite_quota_window_days 30
  @invite_min_account_age_days 7
  @invite_default_expiry_days 7

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
      if user.status == "banned" do
        {:error, :banned}
      else
        {:ok, user}
      end
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

  @doc """
  Gets a user by username with role preloaded, or nil if not found.
  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.one(from u in User, where: u.username == ^username, preload: :role)
  end

  @doc """
  Gets a user by username (case-insensitive) with role preloaded, or nil if not found.

  Used by mention parsing where `@Username` and `@username` should resolve to
  the same user.
  """
  def get_user_by_username_ci(username) when is_binary(username) do
    downcased = String.downcase(username)

    Repo.one(
      from u in User, where: fragment("lower(?)", u.username) == ^downcased, preload: :role
    )
  end

  @doc """
  Verifies a user's password. Returns `true` if the password matches,
  `false` otherwise. Uses constant-time comparison via bcrypt.
  """
  def verify_password(%User{hashed_password: hashed}, password) when is_binary(password) do
    Bcrypt.verify_pass(password, hashed)
  end

  def verify_password(_, _) do
    Bcrypt.no_user_verify()
    false
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
  Deletes all server-side sessions for a given user ID.
  Used during TOTP reset to invalidate all existing sessions.
  """
  def delete_all_sessions_for_user(user_id) do
    from(s in UserSession, where: s.user_id == ^user_id)
    |> Repo.delete_all()
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

  # --- Registration & Approval ---

  @doc """
  Registers a new user with the `"user"` role.

  The account status depends on `Setup.registration_mode/0`:
    * `"open"` → status `"active"` (immediately usable)
    * `"approval_required"` → status `"pending"` (can log in but restricted)
  """
  def register_user(attrs) do
    mode = Setup.registration_mode()

    case mode do
      "invite_only" -> register_with_invite(attrs)
      _ -> register_standard(attrs, mode)
    end
  end

  defp register_standard(attrs, mode) do
    role = Repo.one!(from r in Role, where: r.name == "user")

    status =
      case mode do
        "open" -> "active"
        _ -> "pending"
      end

    attrs =
      attrs
      |> Map.put("role_id", role.id)
      |> Map.put("status", status)

    result =
      %User{}
      |> User.registration_changeset(Map.delete(attrs, "status"))
      |> User.validate_terms()
      |> Ecto.Changeset.put_change(:status, status)
      |> Repo.insert()

    with {:ok, user} <- result do
      codes = generate_recovery_codes(user)
      {:ok, user, codes}
    end
  end

  defp register_with_invite(attrs) do
    invite_code = attrs["invite_code"] || attrs[:invite_code]

    if is_nil(invite_code) || invite_code == "" do
      {:error, :invite_required}
    else
      case validate_invite_code(invite_code) do
        {:ok, invite} ->
          role = Repo.one!(from r in Role, where: r.name == "user")

          attrs =
            attrs
            |> Map.put("role_id", role.id)
            |> Map.put("status", "active")

          reg_attrs =
            attrs
            |> Map.delete("status")
            |> Map.delete("invite_code")
            |> Map.put("invited_by_id", invite.created_by_id)

          changeset =
            %User{}
            |> User.registration_changeset(reg_attrs)
            |> User.validate_terms()
            |> Ecto.Changeset.put_change(:status, "active")

          Repo.transaction(fn ->
            case Repo.insert(changeset) do
              {:ok, user} ->
                use_invite_code(invite, user.id)
                codes = generate_recovery_codes(user)
                {user, codes}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)
          |> case do
            {:ok, {user, codes}} -> {:ok, user, codes}
            {:error, changeset} -> {:error, changeset}
          end

        {:error, reason} ->
          {:error, {:invalid_invite, reason}}
      end
    end
  end

  @doc """
  Approves a pending user by setting their status to `"active"`.
  """
  def approve_user(user) do
    user
    |> User.status_changeset(%{status: "active"})
    |> Repo.update()
  end

  @doc """
  Returns all users with `status: "pending"`, ordered by registration date.
  """
  def list_pending_users do
    from(u in User,
      where: u.status == "pending",
      order_by: [asc: u.inserted_at],
      preload: :role
    )
    |> Repo.all()
  end

  @doc """
  Returns `true` if the user's account is active.
  """
  def user_active?(user), do: user.status == "active"

  @doc """
  Returns `true` if the user can create content.

  Requires both:
    1. Account status is `"active"` (pending users cannot post)
    2. Role has the `"user.create_content"` permission
  """
  def can_create_content?(user) do
    user_active?(user) && Setup.has_permission?(user.role.name, "user.create_content")
  end

  @doc """
  Searches active users by partial username match.

  Used for recipient selection in DMs and other user pickers.
  Sanitizes the search term to prevent SQL wildcard injection.

  ## Options

    * `:limit` — max results to return (default 10)
    * `:exclude_id` — exclude a specific user ID from results (e.g. current user)
  """
  def search_users(term, opts \\ []) when is_binary(term) do
    limit = Keyword.get(opts, :limit, 10)
    exclude_id = Keyword.get(opts, :exclude_id)

    sanitized = Repo.sanitize_like(term)

    query =
      from(u in User,
        where: u.status == "active" and ilike(u.username, ^"%#{sanitized}%"),
        order_by: u.username,
        limit: ^limit,
        preload: :role
      )

    query = if exclude_id, do: from(u in query, where: u.id != ^exclude_id), else: query
    Repo.all(query)
  end

  # --- User Management ---

  @users_per_page 20

  @doc """
  Lists users with optional filters.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"pending"`, `"banned"`)
    * `:role` — filter by role name
    * `:search` — ILIKE search on username
  """
  def list_users(opts \\ []) do
    Repo.all(users_base_query(opts))
  end

  @doc """
  Returns a paginated list of users with optional filters.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"pending"`, `"banned"`)
    * `:role` — filter by role name
    * `:search` — ILIKE search on username
    * `:page` — page number (default 1)
    * `:per_page` — users per page (default #{@users_per_page})

  Returns `%{users: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_users(opts \\ []) do
    alias Baudrate.Pagination

    pagination = Pagination.paginate_opts(opts, @users_per_page)

    users_filter_query(opts)
    |> Pagination.paginate_query(pagination,
      result_key: :users,
      order_by: [desc: dynamic([u], u.inserted_at)],
      preloads: [:role]
    )
  end

  defp users_base_query(opts) do
    from(u in users_filter_query(opts), order_by: [desc: u.inserted_at], preload: :role)
  end

  defp users_filter_query(opts) do
    query = from(u in User)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(u in query, where: u.status == ^status)
      end

    query =
      case Keyword.get(opts, :role) do
        nil -> query
        role_name -> from(u in query, join: r in assoc(u, :role), where: r.name == ^role_name)
      end

    case Keyword.get(opts, :search) do
      nil ->
        query

      "" ->
        query

      term ->
        sanitized = Repo.sanitize_like(term)
        from(u in query, where: ilike(u.username, ^"%#{sanitized}%"))
    end
  end

  @doc """
  Returns a map of status counts, e.g. `%{"active" => 5, "pending" => 2, "banned" => 1}`.
  """
  def count_users_by_status do
    from(u in User, group_by: u.status, select: {u.status, count(u.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Bans a user. Guards against self-ban.

  Sets status to `"banned"`, records `banned_at` and optional `ban_reason`,
  then invalidates all existing sessions and revokes all active invite codes
  for the user. Returns `{:ok, banned_user, revoked_codes_count}`.
  """
  def ban_user(user, admin_id, reason \\ nil)

  def ban_user(%User{id: id}, admin_id, _reason) when id == admin_id do
    {:error, :self_action}
  end

  def ban_user(%User{} = user, admin_id, reason)
      when is_integer(admin_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      user
      |> User.ban_changeset(%{status: "banned", banned_at: now, ban_reason: reason})
      |> Repo.update()

    with {:ok, banned_user} <- result do
      delete_all_sessions_for_user(banned_user.id)
      {revoked_count, _} = revoke_invite_codes_for_user(banned_user.id)
      {:ok, banned_user, revoked_count}
    end
  end

  @doc """
  Unbans a user by setting status back to `"active"` and clearing ban fields.
  """
  def unban_user(%User{} = user) do
    user
    |> User.unban_changeset()
    |> Repo.update()
  end

  @doc """
  Updates a user's role. Returns `{:error, :self_action}` on self-role-change.
  """
  def update_user_role(%User{id: id}, _role_id, admin_id) when id == admin_id do
    {:error, :self_action}
  end

  def update_user_role(%User{} = user, role_id, admin_id)
      when is_integer(admin_id) do
    user
    |> User.role_changeset(%{role_id: role_id})
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, Repo.preload(user, :role, force: true)}
      error -> error
    end
  end

  # --- Locale preferences ---

  @doc """
  Updates a user's preferred locales list.

  Validates that all entries are known Gettext locales via `User.locale_changeset/2`.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_preferred_locales(user, locales) when is_list(locales) do
    user
    |> User.locale_changeset(%{preferred_locales: locales})
    |> Repo.update()
  end

  # --- Avatar management ---

  @doc """
  Updates a user's avatar_id.
  """
  def update_avatar(user, avatar_id) do
    user
    |> User.avatar_changeset(%{avatar_id: avatar_id})
    |> Repo.update()
  end

  @doc """
  Removes a user's avatar by setting avatar_id to nil.
  """
  def remove_avatar(user) do
    user
    |> User.avatar_changeset(%{avatar_id: nil})
    |> Repo.update()
  end

  # --- Signature ---

  @doc """
  Updates a user's signature.
  """
  def update_signature(user, signature) do
    user
    |> User.signature_changeset(%{signature: signature})
    |> Repo.update()
  end

  # --- Display Name ---

  @doc """
  Updates a user's display name. Pass `nil` or empty string to clear.
  """
  def update_display_name(user, display_name) do
    user
    |> User.display_name_changeset(%{display_name: display_name})
    |> Repo.update()
  end

  # --- Bio ---

  @doc """
  Updates a user's bio.
  """
  def update_bio(user, bio) do
    user
    |> User.bio_changeset(%{bio: bio})
    |> Repo.update()
  end

  # --- Invite Codes ---

  @doc """
  Checks whether a user can generate an invite code.

  Returns `{:ok, remaining}` where remaining is an integer or `:unlimited`,
  or `{:error, reason}`.

  ## Checks

    1. Admin role → `{:ok, :unlimited}` (bypasses all limits)
    2. Account age >= #{@invite_min_account_age_days} days
    3. Quota remaining > 0 within rolling #{@invite_quota_window_days}-day window
  """
  def can_generate_invite?(%User{} = user) do
    cond do
      user.role.name == "admin" ->
        {:ok, :unlimited}

      DateTime.diff(DateTime.utc_now(), user.inserted_at, :second) / 86_400 <
          @invite_min_account_age_days ->
        {:error, :account_too_new}

      true ->
        remaining = invite_quota_remaining(user)

        if remaining > 0 do
          {:ok, remaining}
        else
          {:error, :invite_quota_exceeded}
        end
    end
  end

  @doc """
  Returns the number of invite codes the user can still generate in the
  current #{@invite_quota_window_days}-day rolling window (0–#{@invite_quota_limit}).

  Admin users always return #{@invite_quota_limit} (they have unlimited quota
  but this function returns the limit for display consistency).
  """
  def invite_quota_remaining(%User{} = user) do
    if user.role.name == "admin" do
      @invite_quota_limit
    else
      cutoff =
        DateTime.utc_now()
        |> DateTime.add(-@invite_quota_window_days * 86_400, :second)

      count =
        from(i in InviteCode,
          where: i.created_by_id == ^user.id and i.inserted_at > ^cutoff,
          select: count(i.id)
        )
        |> Repo.one()

      max(@invite_quota_limit - count, 0)
    end
  end

  @doc """
  Returns the invite quota limit constant.
  """
  def invite_quota_limit, do: @invite_quota_limit

  @doc """
  Lists invite codes created by a specific user, newest first, with `:used_by` preloaded.
  """
  def list_user_invite_codes(%User{id: user_id}) do
    from(i in InviteCode,
      where: i.created_by_id == ^user_id,
      order_by: [desc: i.inserted_at],
      preload: [:used_by]
    )
    |> Repo.all()
  end

  @doc """
  Generates an invite code created by the given user.

  Requires a `%User{}` struct with role preloaded. Enforces quota for non-admin
  users and auto-sets expiry to #{@invite_default_expiry_days} days for non-admins.

  ## Options

    * `:max_uses` — max number of times the code can be used (default 1)
    * `:expires_in_days` — number of days until expiration (forced to
      #{@invite_default_expiry_days} for non-admins unless a shorter value is provided)
  """
  def generate_invite_code(%User{} = user, opts \\ []) do
    case can_generate_invite?(user) do
      {:ok, _remaining} ->
        do_generate_invite_code(user, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an invite code on behalf of a target user, callable only by admins.

  Bypasses the account age restriction but still enforces the rolling
  #{@invite_quota_window_days}-day quota (max #{@invite_quota_limit} codes).
  The code's `created_by_id` is set to the target user.

  Uses admin expiry rules (no forced #{@invite_default_expiry_days}-day cap).

  Returns `{:ok, invite_code}` or `{:error, reason}`.

  ## Errors

    * `{:error, :unauthorized}` — caller is not an admin
    * `{:error, :invite_quota_exceeded}` — target user's quota is exhausted
  """
  def admin_generate_invite_code_for_user(%User{} = admin, %User{} = target_user, opts \\ []) do
    if admin.role.name != "admin" do
      {:error, :unauthorized}
    else
      remaining = invite_quota_remaining(target_user)

      if remaining <= 0 do
        {:error, :invite_quota_exceeded}
      else
        do_generate_invite_code(target_user, opts)
      end
    end
  end

  defp do_generate_invite_code(%User{} = user, opts) do
    code = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    max_uses = Keyword.get(opts, :max_uses, 1)

    expires_in_days =
      if user.role.name == "admin" do
        Keyword.get(opts, :expires_in_days)
      else
        explicit = Keyword.get(opts, :expires_in_days)

        cond do
          is_nil(explicit) -> @invite_default_expiry_days
          explicit > @invite_default_expiry_days -> @invite_default_expiry_days
          true -> explicit
        end
      end

    expires_at =
      case expires_in_days do
        nil ->
          nil

        days ->
          DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)
      end

    %InviteCode{}
    |> InviteCode.changeset(%{
      code: code,
      created_by_id: user.id,
      max_uses: max_uses,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc """
  Validates an invite code string.

  Returns `{:ok, invite}` if valid, or `{:error, reason}` if invalid.
  """
  def validate_invite_code(code) when is_binary(code) do
    case Repo.one(from(i in InviteCode, where: i.code == ^code, preload: [:created_by])) do
      nil ->
        {:error, :not_found}

      %InviteCode{revoked: true} ->
        {:error, :revoked}

      %InviteCode{expires_at: expires_at} = invite when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          {:error, :expired}
        else
          check_uses(invite)
        end

      invite ->
        check_uses(invite)
    end
  end

  def validate_invite_code(_), do: {:error, :not_found}

  defp check_uses(%InviteCode{use_count: use_count, max_uses: max_uses})
       when use_count >= max_uses do
    {:error, :fully_used}
  end

  defp check_uses(invite), do: {:ok, invite}

  @doc """
  Records the use of an invite code by a new user.
  """
  def use_invite_code(%InviteCode{} = invite, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invite
    |> InviteCode.use_changeset(%{
      used_by_id: user_id,
      used_at: now,
      use_count: invite.use_count + 1
    })
    |> Repo.update()
  end

  @doc """
  Lists all invite codes with preloads, newest first.
  """
  def list_all_invite_codes do
    from(i in InviteCode,
      order_by: [desc: i.inserted_at],
      preload: [:created_by, :used_by]
    )
    |> Repo.all()
  end

  @doc """
  Revokes an invite code.
  """
  def revoke_invite_code(%InviteCode{} = invite) do
    invite
    |> InviteCode.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Bulk-revokes all active invite codes created by the given user.

  Active = not revoked, not expired, and not fully used.
  Returns `{count, nil}` with the number of revoked codes.
  """
  def revoke_invite_codes_for_user(user_id) do
    now = DateTime.utc_now()

    from(i in InviteCode,
      where: i.created_by_id == ^user_id,
      where: i.revoked == false,
      where: is_nil(i.expires_at) or i.expires_at > ^now,
      where: i.use_count < i.max_uses
    )
    |> Repo.update_all(set: [revoked: true])
  end

  # --- Password reset ---

  @doc """
  Resets a user's password using a recovery code.

  Looks up the user by username, verifies the recovery code (consuming it),
  then updates the password. Returns generic errors to prevent user enumeration.
  """
  def reset_password_with_recovery_code(
        username,
        recovery_code,
        new_password,
        new_password_confirmation
      ) do
    user = Repo.one(from u in User, where: u.username == ^username, preload: :role)

    if is_nil(user) do
      # Constant-time: still hash to prevent timing attacks
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    else
      case verify_recovery_code(user, recovery_code) do
        :ok ->
          changeset =
            User.password_reset_changeset(user, %{
              password: new_password,
              password_confirmation: new_password_confirmation
            })

          case Repo.update(changeset) do
            {:ok, user} ->
              delete_all_sessions_for_user(user.id)
              {:ok, user}

            {:error, changeset} ->
              {:error, changeset}
          end

        :error ->
          {:error, :invalid_credentials}
      end
    end
  end

  # --- Per-account brute-force protection ---

  @login_throttle_window_seconds 3600
  @login_throttle_schedule [
    {5, 5},
    {10, 30},
    {15, 120}
  ]
  @login_attempts_per_page 20
  @login_attempts_retention_days 7

  @doc """
  Records a login attempt for the given username.

  The username is lowercased for case-insensitive matching.
  Both successful and failed attempts are recorded for audit purposes.
  """
  def record_login_attempt(username, ip_address, success) when is_binary(username) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %LoginAttempt{}
    |> LoginAttempt.changeset(%{
      username: String.downcase(username),
      ip_address: ip_address,
      success: success,
      inserted_at: now
    })
    |> Repo.insert()
  end

  @doc """
  Checks whether a login attempt for the given username should be throttled.

  Returns `:ok` if the attempt can proceed, or `{:delay, seconds_remaining}`
  if the account is currently throttled due to too many recent failures.

  ## Throttle Schedule

  Failures are counted in a 1-hour sliding window:

    * 0–4 failures: no delay
    * 5–9 failures: 5 seconds after last failure
    * 10–14 failures: 30 seconds after last failure
    * 15+ failures: 120 seconds after last failure
  """
  def check_login_throttle(username) when is_binary(username) do
    lower = String.downcase(username)
    cutoff = DateTime.utc_now() |> DateTime.add(-@login_throttle_window_seconds, :second)

    query =
      from(a in LoginAttempt,
        where: a.username == ^lower and a.success == false and a.inserted_at > ^cutoff,
        select: %{count: count(a.id), last_at: max(a.inserted_at)}
      )

    case Repo.one(query) do
      %{count: count, last_at: last_at} when count > 0 and not is_nil(last_at) ->
        delay = delay_for_failures(count)

        if delay > 0 do
          unlocked_at = DateTime.add(last_at, delay, :second)
          remaining = DateTime.diff(unlocked_at, DateTime.utc_now(), :second)

          if remaining > 0 do
            {:delay, remaining}
          else
            :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp delay_for_failures(count) do
    @login_throttle_schedule
    |> Enum.reverse()
    |> Enum.find_value(0, fn {threshold, delay} ->
      if count >= threshold, do: delay
    end)
  end

  @doc """
  Returns a paginated list of login attempts for the admin panel.

  ## Options

    * `:username` — filter by username (case-insensitive ILIKE search)
    * `:page` — page number (default 1)
    * `:per_page` — items per page (default #{@login_attempts_per_page})

  Returns `%{attempts: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_login_attempts(opts \\ []) do
    alias Baudrate.Pagination

    pagination = Pagination.paginate_opts(opts, @login_attempts_per_page)

    login_attempts_filter_query(opts)
    |> Pagination.paginate_query(pagination,
      result_key: :attempts,
      order_by: [desc: dynamic([a], a.inserted_at)],
      preloads: []
    )
  end

  defp login_attempts_filter_query(opts) do
    query = from(a in LoginAttempt)

    case Keyword.get(opts, :username) do
      nil ->
        query

      "" ->
        query

      term ->
        sanitized = Repo.sanitize_like(term)
        from(a in query, where: ilike(a.username, ^"%#{sanitized}%"))
    end
  end

  @doc """
  Purges login attempt records older than #{@login_attempts_retention_days} days.

  Called periodically by `SessionCleaner`.
  Returns `{count, nil}` with the number of deleted rows.
  """
  def purge_old_login_attempts do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@login_attempts_retention_days * 86_400, :second)

    from(a in LoginAttempt, where: a.inserted_at < ^cutoff)
    |> Repo.delete_all()
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

    case Repo.one(
           from s in UserSession, where: s.token_hash == ^token_hash, preload: [user: :role]
         ) do
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

  # --- DM Access ---

  @doc """
  Updates a user's DM access preference.

  Valid values: `"anyone"`, `"followers"`, `"nobody"`.
  """
  def update_dm_access(user, value) when is_binary(value) do
    user
    |> User.dm_access_changeset(%{dm_access: value})
    |> Repo.update()
  end

  # --- Notification Preferences ---

  @doc """
  Updates a user's notification preferences map.

  The `prefs` map has notification type keys (e.g. `"mention"`) with value
  maps like `%{"in_app" => false}`. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_notification_preferences(user, prefs) when is_map(prefs) do
    user
    |> User.notification_preferences_changeset(%{notification_preferences: prefs})
    |> Repo.update()
  end

  # --- User Blocks ---

  @doc """
  Blocks a local user. Returns `{:ok, block}` or `{:error, changeset}`.
  """
  def block_user(%User{id: user_id}, %User{id: blocked_id}) do
    %UserBlock{}
    |> UserBlock.local_changeset(%{user_id: user_id, blocked_user_id: blocked_id})
    |> Repo.insert()
  end

  @doc """
  Blocks a remote actor by AP ID. Returns `{:ok, block}` or `{:error, changeset}`.
  """
  def block_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    %UserBlock{}
    |> UserBlock.remote_changeset(%{user_id: user_id, blocked_actor_ap_id: ap_id})
    |> Repo.insert()
  end

  @doc """
  Unblocks a local user. Returns `{count, nil}`.
  """
  def unblock_user(%User{id: user_id}, %User{id: blocked_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and b.blocked_user_id == ^blocked_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Unblocks a remote actor by AP ID. Returns `{count, nil}`.
  """
  def unblock_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and b.blocked_actor_ap_id == ^ap_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns `true` if the user has blocked the given target (local user or AP ID).
  """
  def blocked?(%User{id: user_id}, %User{id: target_id}) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^user_id and b.blocked_user_id == ^target_id
      )
    )
  end

  def blocked?(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^user_id and b.blocked_actor_ap_id == ^ap_id
      )
    )
  end

  def blocked?(_, _), do: false

  @doc """
  Returns `true` if `blocker_id` has blocked `user_id`. Reverse check for filtering.
  """
  def user_blocked_by?(user_id, blocker_id) when is_integer(user_id) and is_integer(blocker_id) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^blocker_id and b.blocked_user_id == ^user_id
      )
    )
  end

  @doc """
  Lists all blocks for a user, with blocked_user preloaded where applicable.
  """
  def list_blocks(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id,
      order_by: [desc: b.inserted_at],
      preload: [:blocked_user]
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of blocked user IDs for the given user.
  """
  def blocked_user_ids(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and not is_nil(b.blocked_user_id),
      select: b.blocked_user_id
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of blocked remote actor AP IDs for the given user.
  """
  def blocked_actor_ap_ids(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and not is_nil(b.blocked_actor_ap_id),
      select: b.blocked_actor_ap_id
    )
    |> Repo.all()
  end

  # --- User Mutes ---

  @doc """
  Mutes a local user. Returns `{:ok, mute}` or `{:error, changeset}`.
  """
  def mute_user(%User{id: user_id}, %User{id: muted_id}) do
    %UserMute{}
    |> UserMute.local_changeset(%{user_id: user_id, muted_user_id: muted_id})
    |> Repo.insert()
  end

  @doc """
  Mutes a remote actor by AP ID. Returns `{:ok, mute}` or `{:error, changeset}`.
  """
  def mute_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    %UserMute{}
    |> UserMute.remote_changeset(%{user_id: user_id, muted_actor_ap_id: ap_id})
    |> Repo.insert()
  end

  @doc """
  Unmutes a local user. Returns `{count, nil}`.
  """
  def unmute_user(%User{id: user_id}, %User{id: muted_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and m.muted_user_id == ^muted_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Unmutes a remote actor by AP ID. Returns `{count, nil}`.
  """
  def unmute_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    from(m in UserMute,
      where: m.user_id == ^user_id and m.muted_actor_ap_id == ^ap_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns `true` if the user has muted the given target (local user or AP ID).
  """
  def muted?(%User{id: user_id}, %User{id: target_id}) do
    Repo.exists?(
      from(m in UserMute,
        where: m.user_id == ^user_id and m.muted_user_id == ^target_id
      )
    )
  end

  def muted?(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    Repo.exists?(
      from(m in UserMute,
        where: m.user_id == ^user_id and m.muted_actor_ap_id == ^ap_id
      )
    )
  end

  def muted?(_, _), do: false

  @doc """
  Lists all mutes for a user, with muted_user preloaded where applicable.
  """
  def list_mutes(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id,
      order_by: [desc: m.inserted_at],
      preload: [:muted_user]
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of muted user IDs for the given user.
  """
  def muted_user_ids(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and not is_nil(m.muted_user_id),
      select: m.muted_user_id
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of muted remote actor AP IDs for the given user.
  """
  def muted_actor_ap_ids(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and not is_nil(m.muted_actor_ap_id),
      select: m.muted_actor_ap_id
    )
    |> Repo.all()
  end

  @doc """
  Returns combined hidden user IDs and AP IDs from both blocks and mutes
  in only 2 queries (instead of 4).

  Returns `{user_ids, ap_ids}` where both are deduplicated lists.
  """
  def hidden_ids(%User{id: user_id}) do
    blocked =
      from(b in UserBlock,
        where: b.user_id == ^user_id,
        select: %{user_id: b.blocked_user_id, ap_id: b.blocked_actor_ap_id}
      )
      |> Repo.all()

    muted =
      from(m in UserMute,
        where: m.user_id == ^user_id,
        select: %{user_id: m.muted_user_id, ap_id: m.muted_actor_ap_id}
      )
      |> Repo.all()

    all = blocked ++ muted
    user_ids = for(r <- all, r.user_id, do: r.user_id) |> Enum.uniq()
    ap_ids = for(r <- all, r.ap_id, do: r.ap_id) |> Enum.uniq()
    {user_ids, ap_ids}
  end
end
