defmodule Baudrate.Moderation do
  @moduledoc """
  The Moderation context manages content reports and moderation actions.

  Reports can target articles, comments, remote actors, local users, feed
  items, or received direct messages. Admins and moderators can review,
  resolve, or dismiss reports through the moderation queue. Authenticated
  users can submit reports from article pages, comment threads, user profile
  pages, their feed, and their conversations. `report_feed_item/3`,
  `report_message/3` and `report_remote_actor/3` check that the reporter can
  see what they report.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Pagination
  alias Baudrate.Repo
  alias Baudrate.Content.{BoardArticle, Comment}
  alias Baudrate.Federation.{FeedItem, RemoteActor}
  alias Baudrate.Messaging.DirectMessage
  alias Baudrate.Moderation.{Log, Report}
  alias Baudrate.Setup.User

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

  @target_fields ~w(article_id comment_id remote_actor_id reported_user_id feed_item_id message_id)a

  # Every target except the reported message: a report carries its own copy of
  # that one message's text in `message_body`.
  @report_preloads [
    :reporter,
    :reporter_remote_actor,
    :article,
    :remote_actor,
    :reported_user,
    :resolved_by,
    # The article a reported comment is on, so the queue can link to it.
    comment: :article,
    feed_item: :remote_actor
  ]

  @doc """
  Checks whether the given reporter already has an open report for exactly
  the same target: every target field (`article_id`, `comment_id`,
  `remote_actor_id`, `reported_user_id`, `feed_item_id`, `message_id`) must
  match, and a field missing from `target_attrs` must be empty. So a report
  about one of an account's posts does not count as a report about the
  account. Returns `true` if a duplicate exists.
  """
  @spec has_open_report?(integer(), map()) :: boolean()
  def has_open_report?(reporter_id, target_attrs) do
    query =
      Enum.reduce(
        @target_fields,
        from(r in Report, where: r.reporter_id == ^reporter_id and r.status == "open"),
        fn field, q -> from(r in q, where: ^same_target(field, target_attrs[field])) end
      )

    Repo.exists?(query)
  end

  @doc """
  Reports a feed item on behalf of a member. The member must be able to see
  the item (`Federation.feed_item_accessible?/2`); its remote author is
  recorded as the reported actor, so moderators can "Send Flag".

  `details` is what the member filled in: `%{reason: …, category: …}`.

  Returns `{:ok, report}`, `{:error, :not_found}`, `{:error, :already_reported}`
  or `{:error, changeset}`.
  """
  @spec report_feed_item(User.t(), term(), map()) ::
          {:ok, Report.t()} | {:error, :not_found | :already_reported | Ecto.Changeset.t()}
  def report_feed_item(%User{} = reporter, feed_item_id, details) do
    with %FeedItem{} = item <- get_by_id(FeedItem, feed_item_id),
         true <- Baudrate.Federation.feed_item_accessible?(reporter, item) do
      file_report(
        reporter,
        %{feed_item_id: item.id, remote_actor_id: item.remote_actor_id},
        details
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Reports a direct message on behalf of a member who received it.

  The member must be a participant of the conversation and must not be the
  sender, and the message must not be deleted. A copy of that one message's
  text is stored with the report (`message_body`); nothing else from the
  conversation is. The sender is recorded as the reported user or actor.

  `details` is what the member filled in: `%{reason: …, category: …}`.

  Returns `{:ok, report}`, `{:error, :not_found}`, `{:error, :already_reported}`
  or `{:error, changeset}`.
  """
  @spec report_message(User.t(), term(), map()) ::
          {:ok, Report.t()} | {:error, :not_found | :already_reported | Ecto.Changeset.t()}
  def report_message(%User{id: user_id} = reporter, message_id, details) do
    message =
      with {:ok, id} <- cast_id(message_id) do
        Repo.one(
          from(dm in DirectMessage,
            join: c in assoc(dm, :conversation),
            where: dm.id == ^id and is_nil(dm.deleted_at),
            where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
            where: is_nil(dm.sender_user_id) or dm.sender_user_id != ^user_id
          )
        )
      end

    case message do
      %DirectMessage{} = dm ->
        target = %{
          message_id: dm.id,
          reported_user_id: dm.sender_user_id,
          remote_actor_id: dm.sender_remote_actor_id
        }

        file_report(reporter, target, details, %Report{message_body: dm.body})

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Reports a remote account on behalf of a member.

  `details` is what the member filled in: `%{reason: …, category: …}`.

  Returns `{:ok, report}`, `{:error, :not_found}`, `{:error, :already_reported}`
  or `{:error, changeset}`.
  """
  @spec report_remote_actor(User.t(), term(), map()) ::
          {:ok, Report.t()} | {:error, :not_found | :already_reported | Ecto.Changeset.t()}
  def report_remote_actor(%User{} = reporter, remote_actor_id, details) do
    case get_by_id(RemoteActor, remote_actor_id) do
      %RemoteActor{id: id} -> file_report(reporter, %{remote_actor_id: id}, details)
      nil -> {:error, :not_found}
    end
  end

  # `details` carries what the member filled in: `:reason` and `:category`
  # (P1-D9). Only the target fields come from the server.
  defp file_report(reporter, target, details, report \\ %Report{}) do
    target = Map.reject(target, fn {_field, value} -> is_nil(value) end)

    if has_open_report?(reporter.id, target) do
      {:error, :already_reported}
    else
      details = Map.take(details, [:reason, :category])
      attrs = target |> Map.merge(details) |> Map.put(:reporter_id, reporter.id)

      result = report |> Report.changeset(attrs) |> Repo.insert()

      with {:ok, report} <- result do
        Baudrate.Notification.Hooks.notify_report_created(report.id)
        result
      end
    end
  end

  defp get_by_id(schema, id) do
    case cast_id(id) do
      {:ok, id} -> Repo.get(schema, id)
      :error -> nil
    end
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp cast_id(_), do: :error

  @doc """
  Lists reports filtered by status. Defaults to "open".
  Preloads the reporter, every target except the reported message (the report
  carries its own copy of the text in `message_body`), and resolved_by.
  """
  @spec list_reports(keyword()) :: [Report.t()]
  def list_reports(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    from(r in Report,
      where: r.status == ^status,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: ^@report_preloads
    )
    |> Repo.all()
  end

  @doc """
  A page of reports with the same preloads as `list_reports/1`.

  Options: `:status` (default `"open"`), `:page`, `:per_page` (default 20,
  at most 100), and `:boards` — a list of board IDs, which narrows the page to
  reports about articles in those boards and comments on them. A board
  moderator sees nothing else: no reports about accounts, direct messages or
  feed items, and none about other boards (`Content.moderated_board_ids/1`).

  Returns `%{reports: […], page:, per_page:, total:, total_pages:}`.
  """
  @spec paginate_reports(keyword()) :: map()
  def paginate_reports(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    from(r in Report, where: r.status == ^status)
    |> scope_to_boards(Keyword.get(opts, :boards))
    |> Pagination.paginate_query(Pagination.paginate_opts(opts, 20, max_per_page: 100),
      result_key: :reports,
      order_by: [desc: :inserted_at, desc: :id],
      preloads: @report_preloads
    )
  end

  # Reports about content in these boards: the article itself, or a comment on
  # an article in one of them.
  defp scope_to_boards(query, nil), do: query

  defp scope_to_boards(query, board_ids) when is_list(board_ids) do
    article_ids =
      from(ba in BoardArticle, where: ba.board_id in ^board_ids, select: ba.article_id)

    comment_ids =
      from(c in Comment,
        join: ba in BoardArticle,
        on: ba.article_id == c.article_id,
        where: ba.board_id in ^board_ids,
        select: c.id
      )

    from(r in query,
      where:
        r.article_id in subquery(article_ids) or
          r.comment_id in subquery(comment_ids)
    )
  end

  @doc """
  Whether `report` is about an article in one of `board_ids`, or a comment on
  one. The only reports a board moderator may see or act on; every action on
  the board moderators' queue re-checks it, because the report id comes from
  the client.
  """
  @spec report_in_boards?(Report.t(), [integer()]) :: boolean()
  def report_in_boards?(_report, []), do: false

  def report_in_boards?(%Report{article_id: article_id}, board_ids) when not is_nil(article_id) do
    Repo.exists?(
      from(ba in BoardArticle, where: ba.article_id == ^article_id and ba.board_id in ^board_ids)
    )
  end

  def report_in_boards?(%Report{comment_id: comment_id}, board_ids) when not is_nil(comment_id) do
    Repo.exists?(
      from(c in Comment,
        join: ba in BoardArticle,
        on: ba.article_id == c.article_id,
        where: c.id == ^comment_id and ba.board_id in ^board_ids
      )
    )
  end

  def report_in_boards?(_report, _board_ids), do: false

  @doc """
  How many **other** open reports each of `reports` shares a target with,
  as `%{report_id => count}`. A target reported by several members, or
  reported again after a dismissal, is worth seeing at a glance.
  """
  @spec other_open_report_counts([Report.t()]) :: %{integer() => non_neg_integer()}
  def other_open_report_counts(reports) do
    Enum.reduce(@target_fields, %{}, fn field, acc ->
      ids = reports |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      if ids == [] do
        acc
      else
        counts =
          from(r in Report,
            where: r.status == "open" and field(r, ^field) in ^ids,
            group_by: field(r, ^field),
            select: {field(r, ^field), count(r.id)}
          )
          |> Repo.all()
          |> Map.new()

        Enum.reduce(reports, acc, fn report, acc ->
          case Map.get(report, field) do
            nil ->
              acc

            value ->
              Map.update(acc, report.id, others(counts, value), &(&1 + others(counts, value)))
          end
        end)
      end
    end)
  end

  # The report itself is in the count when it is still open.
  defp others(counts, value), do: max(Map.get(counts, value, 0) - 1, 0)

  @doc """
  Fetches a report by ID with all preloads, or `nil`. For ids that came from a
  client, where a missing report is an ordinary outcome.
  """
  @spec get_report(integer()) :: Report.t() | nil
  def get_report(id) do
    case Repo.get(Report, id) do
      nil -> nil
      report -> Repo.preload(report, @report_preloads ++ [:message])
    end
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
      :resolved_by,
      :message,
      feed_item: :remote_actor
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
