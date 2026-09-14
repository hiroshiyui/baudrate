defmodule Baudrate.Moderation do
  @moduledoc """
  The Moderation context manages content reports and moderation actions.

  Reports can target articles, comments, remote actors, or local users.
  Admins and moderators can review, resolve, or dismiss reports through
  the moderation queue. Authenticated users can submit reports from
  article pages, comment threads, and user profile pages.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Repo
  alias Baudrate.Moderation.{Log, Report}

  @log_per_page 25

  @doc """
  Creates a new report.
  """
  @spec create_report(map()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create_report(attrs) do
    result =
      %Report{}
      |> Report.changeset(attrs)
      |> Repo.insert()

    with {:ok, report} <- result do
      Baudrate.Notification.Hooks.notify_report_created(report.id)
      result
    end
  end

  @doc """
  Creates a report from an inbound `Flag` (see `Report.remote_flag_changeset/2`)
  and notifies moderators.

  An open report from the same remote reporter about exactly the same targets
  is not duplicated: `{:ok, :duplicate}` is returned instead.
  """
  @spec create_remote_flag_report(map()) ::
          {:ok, Report.t()} | {:ok, :duplicate} | {:error, Ecto.Changeset.t()}
  def create_remote_flag_report(attrs) do
    duplicate? =
      Repo.exists?(
        from(r in Report,
          where:
            r.status == "open" and
              r.reporter_remote_actor_id == ^attrs.reporter_remote_actor_id,
          where: ^same_target(:article_id, attrs[:article_id]),
          where: ^same_target(:comment_id, attrs[:comment_id]),
          where: ^same_target(:reported_user_id, attrs[:reported_user_id])
        )
      )

    if duplicate? do
      {:ok, :duplicate}
    else
      result = %Report{} |> Report.remote_flag_changeset(attrs) |> Repo.insert()

      with {:ok, report} <- result do
        Baudrate.Notification.Hooks.notify_report_created(report.id)
        result
      end
    end
  end

  defp same_target(field, nil), do: dynamic([r], is_nil(field(r, ^field)))
  defp same_target(field, id), do: dynamic([r], field(r, ^field) == ^id)

  @doc """
  Checks whether the given reporter already has an open report for the
  same target. Returns `true` if a duplicate exists.
  """
  @spec has_open_report?(integer(), map()) :: boolean()
  def has_open_report?(reporter_id, target_attrs) do
    base =
      from(r in Report,
        where: r.reporter_id == ^reporter_id and r.status == "open"
      )

    query =
      Enum.reduce(target_attrs, base, fn
        {:article_id, id}, q when not is_nil(id) ->
          from(r in q, where: r.article_id == ^id)

        {:comment_id, id}, q when not is_nil(id) ->
          from(r in q, where: r.comment_id == ^id)

        {:reported_user_id, id}, q when not is_nil(id) ->
          from(r in q, where: r.reported_user_id == ^id)

        {:remote_actor_id, id}, q when not is_nil(id) ->
          from(r in q, where: r.remote_actor_id == ^id)

        _, q ->
          q
      end)

    Repo.exists?(query)
  end

  @doc """
  Lists reports filtered by status. Defaults to "open".
  Preloads reporter, article, comment, remote_actor, reported_user, and resolved_by.
  """
  @spec list_reports(keyword()) :: [Report.t()]
  def list_reports(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    from(r in Report,
      where: r.status == ^status,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: [
        :reporter,
        :reporter_remote_actor,
        :article,
        :comment,
        :remote_actor,
        :reported_user,
        :resolved_by
      ]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a report by ID with all preloads, or raises.
  """
  @spec get_report!(integer()) :: Report.t()
  def get_report!(id) do
    Report
    |> Repo.get!(id)
    |> Repo.preload([
      :reporter,
      :reporter_remote_actor,
      :article,
      :comment,
      :remote_actor,
      :reported_user,
      :resolved_by
    ])
  end

  @doc """
  Resolves a report with a resolution note, marking who resolved it.
  """
  @spec resolve_report(Report.t(), integer(), String.t() | nil) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def resolve_report(%Report{} = report, resolver_id, note \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    report
    |> Report.changeset(%{
      status: "resolved",
      resolved_by_id: resolver_id,
      resolved_at: now,
      resolution_note: note
    })
    |> Repo.update()
  end

  @doc """
  Dismisses a report (no action taken).
  """
  @spec dismiss_report(Report.t(), integer()) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_report(%Report{} = report, resolver_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    report
    |> Report.changeset(%{
      status: "dismissed",
      resolved_by_id: resolver_id,
      resolved_at: now
    })
    |> Repo.update()
  end

  @doc """
  Returns the count of open reports.
  """
  @spec open_report_count() :: non_neg_integer()
  def open_report_count do
    Repo.one(from(r in Report, where: r.status == "open", select: count(r.id))) || 0
  end

  # --- Moderation Log ---

  @doc """
  Records a moderation action in the log.

  ## Options

    * `:target_type` — type of target ("user", "article", "comment", "board", "report")
    * `:target_id` — ID of the target entity
    * `:details` — map of additional context (reason, old_role, new_role, etc.)
  """
  @spec log_action(integer(), String.t(), keyword()) ::
          {:ok, Log.t()} | {:error, Ecto.Changeset.t()}
  def log_action(actor_id, action, opts \\ []) do
    result =
      %Log{}
      |> Log.changeset(%{
        actor_id: actor_id,
        action: action,
        target_type: Keyword.get(opts, :target_type),
        target_id: Keyword.get(opts, :target_id),
        details: Keyword.get(opts, :details, %{})
      })
      |> Repo.insert()

    # Callers do not check the result, so a refused entry must not vanish.
    with {:error, changeset} <- result do
      Logger.error(
        "moderation.log_failed: action=#{inspect(action)} errors=#{inspect(changeset.errors)}"
      )
    end

    result
  end

  @doc """
  Lists moderation logs with pagination and optional action filter.

  ## Options

    * `:page` — page number (default 1)
    * `:action` — filter by action type
  """
  @spec list_moderation_logs(keyword()) :: map()
  def list_moderation_logs(opts \\ []) do
    alias Baudrate.Pagination

    action_filter = Keyword.get(opts, :action)
    pagination = Pagination.paginate_opts(opts, @log_per_page)

    base_query =
      if action_filter && action_filter != "" do
        from(l in Log, where: l.action == ^action_filter)
      else
        from(l in Log)
      end

    base_query
    |> Pagination.paginate_query(pagination,
      result_key: :logs,
      order_by: [desc: dynamic([l], l.inserted_at), desc: dynamic([l], l.id)],
      preloads: [:actor]
    )
  end
end
