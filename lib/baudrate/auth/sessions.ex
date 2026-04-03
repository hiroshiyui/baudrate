defmodule Baudrate.Auth.Sessions do
  @moduledoc """
  Handles server-side session management and login throttling.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Auth.{LoginAttempt, UserSession}
  alias Baudrate.Setup.User

  @session_ttl_seconds 14 * 86_400
  @max_sessions_per_user 3

  @login_throttle_window_seconds 3600
  @login_throttle_schedule [
    {5, 5},
    {10, 30},
    {15, 120}
  ]
  @login_attempts_per_page 20
  @login_attempts_retention_days 7

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
  @spec create_user_session(integer(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, Ecto.Changeset.t()}
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
        order_by: [asc: s.refreshed_at, asc: s.id],
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
  @spec get_user_by_session_token(String.t()) :: {:ok, User.t()} | {:error, :not_found | :expired}
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
  @spec refresh_user_session(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :not_found | :expired | Ecto.Changeset.t()}
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
  Deletes all server-side sessions for a given user ID.
  Used during TOTP reset to invalidate all existing sessions.
  """
  def delete_all_sessions_for_user(user_id) do
    from(s in UserSession, where: s.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Purges all expired sessions from the database.
  Returns `{count, nil}` with the number of deleted rows.
  """
  def purge_expired_sessions do
    now = DateTime.utc_now()
    from(s in UserSession, where: s.expires_at < ^now) |> Repo.delete_all()
  end

  # --- Per-account brute-force protection ---

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
  @spec check_login_throttle(String.t()) :: :ok | {:delay, pos_integer()}
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
      order_by: [desc: dynamic([a], a.inserted_at), desc: dynamic([a], a.id)],
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
end
