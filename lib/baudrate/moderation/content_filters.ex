defmodule Baudrate.Moderation.ContentFilters do
  @moduledoc """
  Admin-managed filters on words, text and linked domains, and the screening
  every post goes through (Phase 5D, ADR 0065).

  Not `Baudrate.Content.Filters`, which is the hidden-content query filters.

  ## Where screening happens

  At the context functions that write, beside `Auth.ensure_can_interact/1`
  and the limits on new accounts — never in a LiveView, where a new way to
  post could forget it:

    * `Content.create_article/3` and `create_comment/2` (and the composers'
      `submit_article/3` / `submit_comment/2`, which are the only callers that
      can hold);
    * `Content.update_article/3` and `update_comment/3`, because posting clean
      and editing dirty is the second way in;
    * `Federation.create_timeline_item_reply/4`;
    * `Federation.InboxHandler`, for content arriving from other instances.

  **Not screened:** direct messages, in either direction. A filter reads what
  no moderator could, and a flag would copy a private message to staff
  without either person in the conversation choosing that — a member who
  wants a moderator to see a message reports it. Nor forwarding, which moves
  words that are already here and were screened where they arrived.

  ## What is matched

  The title, the content warning, the body as a reader sees it (rendered and
  stripped of markup, so an entity or an empty tag inside a word does not
  hide it) and the address of every link, all in `ContentFilter`'s normal
  form. Domain filters match the host of every link that leaves the site,
  resolved as a browser resolves it (`HtmlParser.Native.extract_urls/2`).

  Matching never runs a regular expression built from a pattern: word
  filters are a substring search over the text's words, substring filters a
  substring search (one per `*`-separated part, inside a single word), domain
  filters a comparison of hosts. The cost is proportional to the text.

  ## Outcomes

  `screen/2` returns a verdict whose `outcome` is decided by the strongest
  filter that matched — `block` over `hold` over `flag` — and by where the
  post came from (`:mode`):

  | filter | `:post` (composer) | `:publish` (bot, reply) | `:edit` | `:remote` |
  |---|---|---|---|---|
  | block | block | block | block | drop |
  | hold  | hold  | flag  | block | flag |
  | flag  | flag  | flag  | flag  | flag |

  An edit that is merely flagged has already been published, so a filter
  that should keep something off the site until a moderator has seen it
  refuses the edit instead. And an edit is judged only by what it **adds**:
  a filter the stored version already matched does not stop a typo being
  fixed — the edit rule of ADR 0064, applied to filters.

  A refusal never names the filter or the pattern. A filter that tells a
  spammer which word failed is a word-guessing oracle.

  Every match is recorded (`Baudrate.Moderation.ContentFilterMatch`),
  whatever the outcome.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Content.Markdown
  alias Baudrate.Moderation
  alias Baudrate.Moderation.{ContentFilter, ContentFilterCache, ContentFilterMatch, Report}
  alias Baudrate.Repo
  alias Baudrate.Moderation.PatternMatcher
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @strength %{"block" => 3, "hold" => 2, "flag" => 1}
  @match_days 30

  @typedoc "Where a post came from, which decides what a filter can do to it."
  @type mode :: :post | :publish | :edit | :remote

  @type verdict :: %{
          outcome: :pass | :block | :hold | :flag | :drop,
          filter: map() | nil,
          matched: [map()],
          target_type: String.t() | nil,
          edit: boolean(),
          user_id: integer() | nil,
          remote_actor_id: integer() | nil
        }

  # --- Administration ---

  @doc "Every filter, newest first."
  @spec list_filters() :: [ContentFilter.t()]
  def list_filters do
    from(f in ContentFilter, order_by: [desc: f.inserted_at, desc: f.id], preload: :created_by)
    |> Repo.all()
  end

  @doc "Fetches a filter, or `nil`."
  @spec get_filter(integer()) :: ContentFilter.t() | nil
  def get_filter(id) when is_integer(id), do: Repo.get(ContentFilter, id)
  def get_filter(_), do: nil

  @doc "A changeset for the filter form."
  def change_filter(filter \\ %ContentFilter{}, attrs \\ %{}),
    do: ContentFilter.changeset(filter, attrs)

  @doc """
  Creates a filter as `admin` and records it in the moderation log.

  Authorized here, not only by the page's route hook (ADR 0016): the actor
  needs `admin.manage_users`, the permission IP bans ask for, since both
  decide what reaches the instance at all. Anyone else gets
  `{:error, :unauthorized}`.
  """
  @spec create_filter(map(), User.t()) ::
          {:ok, ContentFilter.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_filter(attrs, admin) do
    with :ok <- authorize(admin) do
      %ContentFilter{created_by_id: admin.id}
      |> ContentFilter.changeset(attrs)
      |> Repo.insert()
      |> after_write(admin.id, "create_filter")
    end
  end

  @doc "Updates a filter as `admin` and records it in the moderation log."
  @spec update_filter(ContentFilter.t(), map(), User.t()) ::
          {:ok, ContentFilter.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_filter(%ContentFilter{} = filter, attrs, admin) do
    with :ok <- authorize(admin) do
      filter
      |> ContentFilter.changeset(attrs)
      |> Repo.update()
      |> after_write(admin.id, "update_filter")
    end
  end

  @doc "Deletes a filter as `admin`, with its match records, and logs it."
  @spec delete_filter(ContentFilter.t(), User.t()) ::
          {:ok, ContentFilter.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_filter(%ContentFilter{} = filter, admin) do
    with :ok <- authorize(admin) do
      filter
      |> Repo.delete()
      |> after_write(admin.id, "delete_filter")
    end
  end

  defp authorize(%User{} = actor) do
    name =
      case actor do
        %User{role: %{name: name}} when is_binary(name) -> name
        _ -> Repo.preload(actor, :role).role.name
      end

    if Setup.has_permission?(name, "admin.manage_users"),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize(_), do: {:error, :unauthorized}

  defp after_write({:ok, filter} = result, admin_id, action) do
    ContentFilterCache.refresh()

    Moderation.log_action(admin_id, action,
      target_type: "content_filter",
      target_id: filter.id,
      details: %{
        "pattern" => filter.pattern,
        "kind" => filter.kind,
        "action" => filter.action,
        "applies_to" => filter.applies_to,
        "enabled" => filter.enabled
      }
    )

    result
  end

  defp after_write(error, _admin_id, _action), do: error

  @doc """
  How many times each filter matched in the last #{@match_days} days, as
  `%{filter_id => count}`.
  """
  @spec recent_match_counts() :: %{integer() => non_neg_integer()}
  def recent_match_counts do
    since = DateTime.utc_now() |> DateTime.add(-@match_days * 86_400, :second)

    from(m in ContentFilterMatch,
      where: m.inserted_at >= ^since,
      group_by: m.content_filter_id,
      select: {m.content_filter_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The window `recent_match_counts/0` counts over, in days."
  def match_days, do: @match_days

  # --- The cache's source ---

  @doc false
  # Every enabled filter, compiled for matching. Read by `ContentFilterCache`.
  @spec compiled_from_db() :: [map()]
  def compiled_from_db do
    from(f in ContentFilter, where: f.enabled, order_by: [asc: f.id])
    |> Repo.all()
    |> Enum.map(&compile/1)
  end

  defp compile(%ContentFilter{} = filter) do
    PatternMatcher.compile(%{
      id: filter.id,
      pattern: filter.pattern,
      kind: filter.kind,
      action: filter.action,
      applies_to: filter.applies_to
    })
  end

  # --- Screening ---

  @doc """
  Screens local writing. `fields` holds any of `:title`, `:summary` and
  `:body` (Markdown, as written), and `:extra` — a list of further plain
  strings that are published with the post (poll options, image
  descriptions), or a zero-arity function returning one, so that loading
  them costs nothing when there is no filter to match.

  ## Options

    * `:mode` — `:post`, `:publish` or `:edit` (see the moduledoc's table).
    * `:previous` — the fields as stored, for an edit: only filters the new
      text matches and the stored text did not are counted.
    * `:target_type`, `:user_id` — recorded with the match.
  """
  @spec screen(map(), keyword()) :: verdict()
  def screen(fields, opts) do
    mode = Keyword.fetch!(opts, :mode)
    filters = filters_for(:local)

    matched =
      if filters == [] do
        []
      else
        found = match_all(filters, local_corpus(fields))

        case Keyword.get(opts, :previous) do
          nil ->
            found

          previous ->
            already = previous |> local_corpus() |> then(&match_all(found, &1)) |> ids()
            Enum.reject(found, &MapSet.member?(already, &1.id))
        end
      end

    verdict(matched, mode, opts)
  end

  @doc """
  Screens an ActivityPub object arriving from `remote_actor`: everything of
  it this instance stores and shows — `name`, `summary`, `content` **and**
  `source.content` (which the inbox falls back to when `content` is empty, so
  reading only one of them let the other carry the text past every filter),
  the names of its attachments (stored as image descriptions) and of a
  poll's options (ADR 0066). Mode `:remote` — a block drops it and a hold
  flags it, since nothing arriving over federation can be held.
  """
  @spec screen_remote(map(), map()) :: verdict()
  def screen_remote(object, remote_actor) when is_map(object) do
    filters = filters_for(:remote)

    matched =
      if filters == [], do: [], else: match_all(filters, remote_corpus(object))

    verdict(matched, :remote,
      target_type: "remote",
      remote_actor_id: remote_actor && remote_actor.id
    )
  end

  defp filters_for(scope) do
    wanted = if scope == :local, do: ~w(local both), else: ~w(remote both)
    Enum.filter(ContentFilterCache.filters(), &(&1.applies_to in wanted))
  end

  defp ids(filters), do: MapSet.new(filters, & &1.id)

  defp verdict(matched, mode, opts) do
    strongest = Enum.max_by(matched, &@strength[&1.action], fn -> nil end)

    %{
      outcome: outcome(strongest, mode),
      filter: strongest,
      matched: matched,
      target_type: Keyword.get(opts, :target_type),
      edit: mode == :edit,
      user_id: Keyword.get(opts, :user_id),
      remote_actor_id: Keyword.get(opts, :remote_actor_id)
    }
  end

  defp outcome(nil, _mode), do: :pass
  defp outcome(%{action: "block"}, :remote), do: :drop
  defp outcome(%{action: "block"}, _mode), do: :block
  defp outcome(%{action: "hold"}, :post), do: :hold
  defp outcome(%{action: "hold"}, :edit), do: :block
  defp outcome(%{action: "hold"}, _mode), do: :flag
  defp outcome(%{action: "flag"}, _mode), do: :flag

  @doc """
  Refuses a blocked post: records the match and returns
  `{:error, :content_filtered}`. Any other verdict is `:ok` and records
  nothing — `record/1` does that once the post has passed every other check.
  """
  @spec refuse_blocked(verdict()) :: :ok | {:error, :content_filtered}
  def refuse_blocked(%{outcome: :block} = verdict) do
    record(verdict)
    {:error, :content_filtered}
  end

  def refuse_blocked(_verdict), do: :ok

  @doc "Records one match row per filter that matched. A pass records nothing."
  @spec record(verdict()) :: :ok
  def record(%{outcome: :pass}), do: :ok

  def record(%{matched: matched, outcome: outcome} = verdict) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(matched, fn filter ->
        %{
          content_filter_id: filter.id,
          action: Atom.to_string(outcome),
          target_type: verdict.target_type || "article",
          edit: verdict.edit,
          user_id: verdict.user_id,
          remote_actor_id: verdict.remote_actor_id,
          inserted_at: now
        }
      end)

    # A filter deleted between the cache read and now would fail the foreign
    # key; losing that one audit row is better than losing the post.
    try do
      Repo.insert_all(ContentFilterMatch, rows)
    rescue
      e in Postgrex.Error ->
        Logger.warning("content_filters.record_failed: #{Exception.message(e)}")
    end

    :ok
  end

  @doc """
  Opens a report for a flagged post, naming the filter, and tells the
  moderators the way any other report does. `target` holds the report's
  target fields (`article_id`, `comment_id`, `timeline_item_id`,
  `reported_user_id`, `remote_actor_id`); `:evidence` is a copy of text that
  has no page of its own to point at (a timeline reply).

  Nothing is opened when an open report from the same filter already names
  the same target: a remote post that is edited three times is one report.
  Returns `:ok` either way.
  """
  @spec flag(verdict(), map(), keyword()) :: :ok
  def flag(verdict, target, opts \\ [])

  def flag(%{outcome: :flag, filter: filter}, target, opts) do
    target = Map.reject(target, fn {_k, v} -> is_nil(v) end)

    unless open_filter_report?(filter.id, target) do
      evidence = Keyword.get(opts, :evidence)

      report =
        if evidence,
          do: %Report{
            evidence_body: String.slice(evidence, 0, 64_000),
            evidence_taken_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          else: %Report{}

      %{report | content_filter_id: filter.id}
      |> Report.changeset(Map.put(target, :reason, filter.pattern))
      |> Repo.insert()
      |> case do
        {:ok, report} ->
          Baudrate.Notification.Hooks.notify_report_created(report.id)

        {:error, changeset} ->
          Logger.warning("content_filters.flag_failed: errors=#{inspect(changeset.errors)}")
      end
    end

    :ok
  end

  def flag(_verdict, _target, _opts), do: :ok

  defp open_filter_report?(filter_id, target) do
    query = from(r in Report, where: r.status == "open" and r.content_filter_id == ^filter_id)

    ~w(article_id comment_id timeline_item_id reported_user_id remote_actor_id)a
    |> Enum.reduce(query, fn field, q ->
      case target[field] do
        nil -> from(r in q, where: is_nil(field(r, ^field)))
        id -> from(r in q, where: field(r, ^field) == ^id)
      end
    end)
    |> Repo.exists?()
  end

  # --- Matching ---

  defp local_corpus(fields) do
    html = Markdown.to_html(field(fields, :body))
    corpus([field(fields, :title), field(fields, :summary), text_of(html)] ++ extra(fields), html)
  end

  defp extra(fields) do
    case fields[:extra] do
      fun when is_function(fun, 0) -> fun.() |> List.wrap() |> strings()
      list when is_list(list) -> strings(list)
      _ -> []
    end
  end

  defp strings(list), do: Enum.filter(list, &is_binary/1)

  defp remote_corpus(object) do
    html =
      [object["content"], get_in_map(object, ["source", "content"])]
      |> strings()
      |> Enum.join("\n")

    names =
      [object["attachment"], object["oneOf"], object["anyOf"]]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        _ -> []
      end)

    corpus([string(object["name"]), string(object["summary"]), text_of(html)] ++ names, html)
  end

  defp get_in_map(%{} = map, [key | rest]), do: get_in_map(Map.get(map, key), rest)
  defp get_in_map(value, []), do: value
  defp get_in_map(_, _), do: nil

  defp field(fields, key), do: string(fields[key] || fields[Atom.to_string(key)])

  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""

  defp text_of(html), do: PatternMatcher.text_of(html)

  defp corpus(texts, html), do: PatternMatcher.corpus(texts, html)

  defp match_all(filters, corpus), do: Enum.filter(filters, &PatternMatcher.matches?(&1, corpus))
end
