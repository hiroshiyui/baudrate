defmodule Baudrate.DataPortability do
  @moduledoc """
  The DataPortability context: self-service data export requests (ADR 0023).

  An export is the most valuable thing an attacker can take from a
  compromised account, so every entry point here assumes the caller might be
  a hijacked session:

    * **Eligibility.** Self-service export needs an active, non-bot account
      with TOTP enabled for at least 7 days (`eligibility/1`). Everyone else
      goes through the audited SysOp task.
    * **Step-up re-authentication happens here**, not only in the web layer.
      `request_export/3` and `authorize_download/4` call
      `Auth.verify_reauthentication/5` themselves (password plus TOTP, never
      a recovery code), so no caller can skip it (ADR 0016).
    * **Cooling-off.** A request becomes downloadable 24 hours after it is
      made and stays so for 48 hours, with at most 3 downloads. Any session
      can cancel it meanwhile.
    * **Automatic cancellation** (`cancel_active_exports/2`) on password
      change or reset, TOTP reset or disable, a ban, and sign out everywhere.
    * **Limits are enforced by PostgreSQL**, not the in-memory rate limiter:
      a partial unique index allows one active request per user, a counted
      cap allows 2 requests per 7 days, and `claim_download/2` is a single
      conditional `UPDATE … RETURNING`.
    * **Always-delivered notices** (`data_export_requested`, `_ready`,
      `_downloaded`, `_cancelled`) tell the real user what is happening.

  No archive is ever stored: rows are request records, and the archive is
  built at download time (`Baudrate.DataPortability.Archive`).

  ## Status transitions

  `pending → ready → expired` transitions are applied by
  `sweep_transitions/1`, a conditional `UPDATE` that runs hourly from
  `Auth.SessionCleaner` and before every read. A transition happens exactly
  once, so its notice is sent exactly once.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.{Auth, Repo}
  alias Baudrate.DataPortability.{ExportRequest, UserAgent}
  alias Baudrate.Notification.Hooks
  alias Baudrate.Setup.User

  @ready_delay_seconds 24 * 3600
  @download_window_seconds 48 * 3600
  @max_downloads 3
  @weekly_request_cap 2
  @min_totp_age_days 7
  @history_retention_days 365
  @active_statuses ExportRequest.active_statuses()
  @cancel_reasons ExportRequest.cancel_reasons()

  @doc "Seconds between requesting an export and being able to download it (24 h)."
  def ready_delay_seconds, do: @ready_delay_seconds

  @doc "Seconds a ready export stays downloadable (48 h)."
  def download_window_seconds, do: @download_window_seconds

  @doc "Maximum downloads per request (3)."
  def max_downloads, do: @max_downloads

  @doc "Minimum age in days of the TOTP enrolment required to export (7)."
  def min_totp_age_days, do: @min_totp_age_days

  # ---------------------------------------------------------------------------
  # Eligibility
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when `user` may use self-service export, otherwise
  `{:error, :bot | :not_active | :totp_required | {:totp_too_new, days_left}}`.

  Callers should pass a freshly loaded user. `request_export/3` and
  `authorize_download/4` reload it themselves.
  """
  @spec eligibility(User.t()) ::
          :ok
          | {:error, :bot | :not_active | :totp_required | {:totp_too_new, pos_integer()}}
  def eligibility(%User{} = user) do
    cond do
      user.is_bot -> {:error, :bot}
      user.status != "active" -> {:error, :not_active}
      not user.totp_enabled -> {:error, :totp_required}
      not Auth.totp_enabled_for_at_least?(user, @min_totp_age_days) -> totp_too_new(user)
      true -> :ok
    end
  end

  defp totp_too_new(%User{totp_enabled_at: %DateTime{} = enabled_at}) do
    eligible_at = DateTime.add(enabled_at, @min_totp_age_days * 86_400, :second)
    remaining = max(DateTime.diff(eligible_at, DateTime.utc_now(), :second), 1)
    {:error, {:totp_too_new, div(remaining + 86_399, 86_400)}}
  end

  # TOTP on but no timestamp: fail closed with the full wait.
  defp totp_too_new(_user), do: {:error, {:totp_too_new, @min_totp_age_days}}

  # ---------------------------------------------------------------------------
  # Requesting
  # ---------------------------------------------------------------------------

  @doc """
  Requests a data export for `user` after step-up re-authentication.

  `credentials` is `%{password: _, code: _}`. Options:

    * `:ip_address` — recorded with failed re-authentication (required)
    * `:session_id` — the requesting `user_sessions` row id
    * `:user_agent` — the raw User-Agent header; only its family is stored

  Checks run in this order, so a request that could never succeed does not
  use up a re-authentication attempt: eligibility, no active request, the
  weekly cap, then step-up re-authentication.

  Returns `{:ok, request}` or `{:error, reason}`, where `reason` is an
  eligibility error, `:active_request_exists`, `:weekly_limit_reached`,
  `:invalid_credentials`, or `{:throttled, seconds}`.
  """
  @spec request_export(User.t(), map(), keyword()) :: {:ok, ExportRequest.t()} | {:error, term()}
  def request_export(%User{} = user, credentials, opts) do
    user = Repo.get!(User, user.id)
    now = now()

    with :ok <- eligibility(user),
         :ok <- ensure_no_active_request(user.id),
         :ok <- ensure_under_weekly_cap(user.id, now),
         :ok <-
           Auth.verify_reauthentication(
             user,
             credential(credentials, :password),
             credential(credentials, :code),
             Keyword.fetch!(opts, :ip_address),
             :data_export_request
           ),
         {:ok, request} <- insert_request(user, now, opts) do
      Hooks.notify_account_security(user.id, "data_export_requested", %{
        "ready_at" => DateTime.to_iso8601(request.ready_at),
        "browser" => request.requested_user_agent_family || ""
      })

      Logger.info(
        "data_export.requested: user_id=#{user.id} request_id=#{request.id} ready_at=#{request.ready_at}"
      )

      {:ok, request}
    end
  end

  defp ensure_no_active_request(user_id) do
    if active_request(user_id), do: {:error, :active_request_exists}, else: :ok
  end

  # Cancelled and expired requests count too: otherwise request-and-cancel
  # cycles would allow unlimited notices and re-authentication prompts.
  defp ensure_under_weekly_cap(user_id, now) do
    since = DateTime.add(now, -7 * 86_400, :second)

    count =
      Repo.aggregate(
        from(r in ExportRequest,
          where: r.user_id == ^user_id and r.source == "self_service" and r.requested_at > ^since
        ),
        :count
      )

    if count >= @weekly_request_cap, do: {:error, :weekly_limit_reached}, else: :ok
  end

  defp insert_request(user, now, opts) do
    ready_at = DateTime.add(now, @ready_delay_seconds, :second)

    %ExportRequest{}
    |> ExportRequest.create_changeset(%{
      user_id: user.id,
      status: "pending",
      source: "self_service",
      requested_at: now,
      ready_at: ready_at,
      expires_at: DateTime.add(ready_at, @download_window_seconds, :second),
      requested_session_id: Keyword.get(opts, :session_id),
      requested_user_agent_family: UserAgent.family(Keyword.get(opts, :user_agent))
    })
    |> Repo.insert()
    |> case do
      {:ok, request} ->
        {:ok, request}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # The partial unique index lost a race with a concurrent request.
        case Keyword.get(errors, :user_id) do
          {_msg, opts} when is_list(opts) ->
            if opts[:constraint] == :unique,
              do: {:error, :active_request_exists},
              else: {:error, changeset}

          _ ->
            {:error, changeset}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Downloading
  # ---------------------------------------------------------------------------

  @doc """
  Authorizes a download of `request_id` for `user` after step-up
  re-authentication, **without** counting it.

  The web layer then issues a short-lived, single-use token, and the download
  endpoint calls `claim_download/2`. Checks eligibility and that the request
  is currently downloadable before re-authenticating.

  Returns `{:ok, request}`, `{:error, :not_found}`, an eligibility error,
  `{:error, :invalid_credentials}`, or `{:error, {:throttled, seconds}}`.
  """
  @spec authorize_download(User.t(), integer(), map(), keyword()) ::
          {:ok, ExportRequest.t()} | {:error, term()}
  def authorize_download(%User{} = user, request_id, credentials, opts) do
    user = Repo.get!(User, user.id)

    with :ok <- eligibility(user),
         %ExportRequest{} = request <-
           downloadable_request(user.id, request_id) || {:error, :not_found},
         :ok <-
           Auth.verify_reauthentication(
             user,
             credential(credentials, :password),
             credential(credentials, :code),
             Keyword.fetch!(opts, :ip_address),
             :data_export_download
           ) do
      {:ok, request}
    end
  end

  defp downloadable_request(user_id, request_id) when is_integer(request_id) do
    now = now()

    Repo.one(
      from(r in ExportRequest,
        where:
          r.id == ^request_id and r.user_id == ^user_id and r.status in ^@active_statuses and
            r.ready_at <= ^now and r.expires_at > ^now and r.download_count < @max_downloads
      )
    )
  end

  defp downloadable_request(_user_id, _request_id), do: nil

  @doc """
  Atomically counts one download of `request_id` for `user_id`.

  A single `UPDATE … RETURNING` succeeds only while the request is active,
  inside its window, and under the download cap, so concurrent claims can
  never exceed #{@max_downloads}. The request becomes `completed` on the last
  allowed download. Sends a `data_export_downloaded` notice.

  Returns `{:ok, request}` or `{:error, :not_found}`, the same answer for a
  request that does not exist, belongs to someone else, is not ready, has
  expired, or is exhausted.
  """
  @spec claim_download(integer(), integer()) :: {:ok, ExportRequest.t()} | {:error, :not_found}
  def claim_download(user_id, request_id) when is_integer(user_id) and is_integer(request_id) do
    now = now()

    query =
      from(r in ExportRequest,
        where:
          r.id == ^request_id and r.user_id == ^user_id and r.status in ^@active_statuses and
            r.ready_at <= ^now and r.expires_at > ^now and r.download_count < @max_downloads,
        select: r,
        update: [
          set: [
            download_count: fragment("? + 1", r.download_count),
            status:
              fragment(
                "CASE WHEN ? + 1 >= ? THEN 'completed' ELSE 'ready' END",
                r.download_count,
                ^@max_downloads
              ),
            updated_at: ^now
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [request]} ->
        Hooks.notify_account_security(user_id, "data_export_downloaded", %{
          "count" => request.download_count,
          "remaining" => @max_downloads - request.download_count
        })

        Logger.info(
          "data_export.download_claimed: user_id=#{user_id} request_id=#{request_id} count=#{request.download_count}"
        )

        {:ok, request}

      _ ->
        {:error, :not_found}
    end
  end

  def claim_download(_user_id, _request_id), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Cancelling
  # ---------------------------------------------------------------------------

  @doc """
  Cancels the user's active request `request_id` (scoped to `user_id`).
  Sends a `data_export_cancelled` notice.

  Returns `{:ok, request}` or `{:error, :not_found}`.
  """
  @spec cancel_export(integer(), integer(), String.t()) ::
          {:ok, ExportRequest.t()} | {:error, :not_found}
  def cancel_export(user_id, request_id, reason \\ "user")
      when is_integer(user_id) and is_integer(request_id) do
    case cancel(from(r in ExportRequest, where: r.id == ^request_id), user_id, reason) do
      [request] -> {:ok, request}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Cancels every active request of `user_id`, e.g. after a password change,
  TOTP reset or disable, a ban, or sign out everywhere. Returns the number of
  requests cancelled.
  """
  @spec cancel_active_exports(integer(), String.t()) :: non_neg_integer()
  def cancel_active_exports(user_id, reason) when is_integer(user_id) do
    ExportRequest |> cancel(user_id, reason) |> length()
  end

  defp cancel(queryable, user_id, reason) when reason in @cancel_reasons do
    now = now()

    {_count, cancelled} =
      from(r in queryable,
        where: r.user_id == ^user_id and r.status in ^@active_statuses,
        select: r,
        update: [
          set: [status: "cancelled", cancelled_at: ^now, cancel_reason: ^reason, updated_at: ^now]
        ]
      )
      |> Repo.update_all([])

    Enum.each(cancelled, fn request ->
      Hooks.notify_account_security(user_id, "data_export_cancelled", %{"reason" => reason})

      Logger.info(
        "data_export.cancelled: user_id=#{user_id} request_id=#{request.id} reason=#{reason}"
      )
    end)

    cancelled
  end

  # ---------------------------------------------------------------------------
  # Reading and housekeeping
  # ---------------------------------------------------------------------------

  @doc "Returns the user's active (pending or ready) request, or `nil`."
  @spec active_request(integer()) :: ExportRequest.t() | nil
  def active_request(user_id) when is_integer(user_id) do
    sweep_transitions(user_id)

    Repo.one(
      from(r in ExportRequest, where: r.user_id == ^user_id and r.status in ^@active_statuses)
    )
  end

  @doc "Returns the user's export history, newest first."
  @spec list_export_history(integer()) :: [ExportRequest.t()]
  def list_export_history(user_id) when is_integer(user_id) do
    sweep_transitions(user_id)

    Repo.all(
      from(r in ExportRequest,
        where: r.user_id == ^user_id,
        order_by: [desc: r.requested_at, desc: r.id]
      )
    )
  end

  @doc """
  Admin view: the most recent export requests across all users, with users
  preloaded. Never exposed to moderators (ADR 0023).
  """
  @spec list_export_requests(keyword()) :: [ExportRequest.t()]
  def list_export_requests(opts \\ []) do
    sweep_transitions(:all)
    limit = opts |> Keyword.get(:limit, 50) |> min(200)

    Repo.all(
      from(r in ExportRequest,
        order_by: [desc: r.requested_at, desc: r.id],
        limit: ^limit,
        preload: [:user]
      )
    )
  end

  @doc """
  Applies due status transitions for one user (`user_id`) or everyone
  (`:all`). Expiry is applied first, so a request whose whole window passed
  unseen goes straight to `expired`, never `ready`. Sends a
  `data_export_ready` notice for each request that became ready.
  """
  @spec sweep_transitions(integer() | :all) :: :ok
  def sweep_transitions(scope \\ :all) do
    now = now()

    from(r in scoped(scope),
      where: r.status in ^@active_statuses and r.expires_at <= ^now,
      update: [set: [status: "expired", updated_at: ^now]]
    )
    |> Repo.update_all([])

    {_count, ready} =
      from(r in scoped(scope),
        where: r.status == "pending" and r.ready_at <= ^now,
        select: r,
        update: [set: [status: "ready", updated_at: ^now]]
      )
      |> Repo.update_all([])

    Enum.each(ready, fn request ->
      Hooks.notify_account_security(request.user_id, "data_export_ready", %{
        "expires_at" => DateTime.to_iso8601(request.expires_at)
      })
    end)

    :ok
  end

  defp scoped(:all), do: ExportRequest

  defp scoped(user_id) when is_integer(user_id),
    do: from(r in ExportRequest, where: r.user_id == ^user_id)

  @doc "Deletes finished requests older than #{@history_retention_days} days. Returns the count."
  @spec purge_old_history(pos_integer()) :: non_neg_integer()
  def purge_old_history(days \\ @history_retention_days) do
    cutoff = DateTime.add(now(), -days * 86_400, :second)

    {count, _} =
      from(r in ExportRequest,
        where: r.requested_at < ^cutoff and r.status not in ^@active_statuses
      )
      |> Repo.delete_all()

    count
  end

  defp credential(credentials, key) when is_map(credentials),
    do: Map.get(credentials, key) || Map.get(credentials, Atom.to_string(key))

  defp credential(_credentials, _key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
