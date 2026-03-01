defmodule Baudrate.Moderation do
  @moduledoc """
  The Moderation context manages content reports and moderation actions.

  Reports can target articles, comments, or remote actors. Admins and
  moderators can review, resolve, or dismiss reports through the
  moderation queue.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Moderation.{Log, Report}

  @log_per_page 25

  @doc """
  Creates a new report.
  """
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
  Lists reports filtered by status. Defaults to "open".
  Preloads reporter, article, comment, and remote_actor.
  """
  def list_reports(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    from(r in Report,
      where: r.status == ^status,
      order_by: [desc: r.inserted_at],
      preload: [:reporter, :article, :comment, :remote_actor, :resolved_by]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a report by ID with all preloads, or raises.
  """
  def get_report!(id) do
    Report
    |> Repo.get!(id)
    |> Repo.preload([:reporter, :article, :comment, :remote_actor, :resolved_by])
  end

  @doc """
  Resolves a report with a resolution note, marking who resolved it.
  """
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
  def log_action(actor_id, action, opts \\ []) do
    %Log{}
    |> Log.changeset(%{
      actor_id: actor_id,
      action: action,
      target_type: Keyword.get(opts, :target_type),
      target_id: Keyword.get(opts, :target_id),
      details: Keyword.get(opts, :details, %{})
    })
    |> Repo.insert()
  end

  @doc """
  Lists moderation logs with pagination and optional action filter.

  ## Options

    * `:page` — page number (default 1)
    * `:action` — filter by action type
  """
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
