defmodule Baudrate.Content.Feed do
  @moduledoc """
  Feed queries and user content statistics.

  Provides public feed listings, per-user article/comment queries,
  and content statistics.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Pagination

  alias Baudrate.Content.{
    Article,
    ArticleBoost,
    Board,
    BoardArticle,
    Comment,
    CommentBoost,
    Filters
  }

  @per_page 20

  # --- Feed Queries ---

  @doc """
  Returns recent local articles across all public boards (guest-visible).

  Only includes local articles (those with a `user_id`), excludes soft-deleted
  articles, and deduplicates cross-posted articles. Results are ordered newest
  first with user and boards preloaded.
  """
  def list_recent_public_articles(limit \\ 20) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      join: b in Board,
      on: b.id == ba.board_id,
      where:
        is_nil(a.deleted_at) and
          not is_nil(a.user_id) and
          b.min_role_to_view == "guest",
      distinct: a.id,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [:user, :boards]
    )
    |> Repo.all()
  end

  @doc """
  Returns recent local articles for a public board.

  Returns `{:ok, articles}` if the board is public (`min_role_to_view == "guest"`),
  or `{:error, :not_public}` otherwise. Only includes local articles.
  """
  def list_recent_articles_for_public_board(%Board{} = board, limit \\ 20) do
    if board.min_role_to_view != "guest" do
      {:error, :not_public}
    else
      articles =
        from(a in Article,
          join: ba in BoardArticle,
          on: ba.article_id == a.id,
          where:
            ba.board_id == ^board.id and
              is_nil(a.deleted_at) and
              not is_nil(a.user_id),
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: ^limit,
          preload: [:user, :boards]
        )
        |> Repo.all()

      {:ok, articles}
    end
  end

  @doc """
  Returns recent articles by a user that appear in at least one public board.

  Inherently local-only since it filters by `user_id`. Results are deduplicated
  and ordered newest first with user and boards preloaded.
  """
  def list_recent_public_articles_by_user(user_id, limit \\ 20) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      join: b in Board,
      on: b.id == ba.board_id,
      where:
        a.user_id == ^user_id and
          is_nil(a.deleted_at) and
          b.min_role_to_view == "guest",
      distinct: a.id,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [:user, :boards]
    )
    |> Repo.all()
  end

  # --- User Content Queries ---

  # Restricts a query with an `:article` named binding to articles the viewer
  # may see: board-less articles (remote imports) are visible to everyone,
  # otherwise at least one of the article's boards must be at or below the
  # viewer's role. Mirrors `ArticleHelpers.user_can_view_article?/2` and the
  # predicate `Search.search_articles/2` uses. Without it, a user's public
  # profile listed titles, board names and comment bodies from boards the
  # viewer (including guests) cannot open.
  defp where_viewable(query, viewer) do
    roles = Filters.allowed_view_roles(viewer)

    from([article: a] in query,
      where:
        not exists(
          from(ba in BoardArticle, where: ba.article_id == parent_as(:article).id, select: 1)
        ) or
          exists(
            from(ba in BoardArticle,
              join: b in Board,
              on: b.id == ba.board_id,
              where:
                ba.article_id == parent_as(:article).id and
                  b.min_role_to_view in ^roles,
              select: 1
            )
          )
    )
  end

  @doc """
  Returns recent non-deleted articles by a user, newest first, with boards and
  article_images preloaded. Only articles the `:viewer` (a user or `nil` for
  guests) may see are returned.
  """
  def list_recent_articles_by_user(user_id, limit \\ 10, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)

    from(a in Article,
      as: :article,
      where: a.user_id == ^user_id and is_nil(a.deleted_at),
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [:boards, :article_images]
    )
    |> where_viewable(viewer)
    |> Repo.all()
  end

  @doc """
  Returns recent non-deleted comments by a user, newest first, with article
  preloaded. Only comments on articles the `:viewer` may see are returned.
  """
  def list_recent_comments_by_user(user_id, limit \\ 10, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)

    from(c in Comment,
      join: a in Article,
      as: :article,
      on: a.id == c.article_id,
      where: c.user_id == ^user_id and is_nil(c.deleted_at) and is_nil(a.deleted_at),
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit,
      preload: [article: :boards]
    )
    |> where_viewable(viewer)
    |> Repo.all()
  end

  @doc """
  Returns a merged timeline of recent articles and comments by a user,
  sorted newest first. Each entry is tagged as `{:article, article}` or
  `{:comment, comment}`. Fetches `limit` of each type, merges, and returns
  the top `limit` entries.
  """
  def list_recent_activity_by_user(user_id, limit \\ 10, opts \\ []) do
    articles =
      list_recent_articles_by_user(user_id, limit, opts)
      |> Enum.map(fn a -> {a.inserted_at, {:article, a}} end)

    comments =
      list_recent_comments_by_user(user_id, limit, opts)
      |> Enum.map(fn c -> {c.inserted_at, {:comment, c}} end)

    merge_and_take(articles ++ comments, limit)
  end

  @doc """
  Returns recent articles boosted by a user, newest first (by boost time).

  Excludes soft-deleted articles. Each result is a 2-tuple of
  `{boost_inserted_at, article}` with boards and article_images preloaded.
  """
  def list_recent_boosted_articles_by_user(user_id, limit \\ 10, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)

    rows =
      from(b in ArticleBoost,
        join: a in Article,
        as: :article,
        on: a.id == b.article_id,
        where: b.user_id == ^user_id and is_nil(a.deleted_at),
        # Boosting does not make someone else's followers-only post public,
        # nor does it bring back a post from an instance we have blocked.
        where: is_nil(a.remote_actor_id) or a.visibility in ["public", "unlisted"],
        where:
          is_nil(a.remote_actor_id) or
            a.remote_actor_id not in subquery(Filters.hidden_actor_ids()),
        order_by: [desc: b.inserted_at, desc: b.id],
        limit: ^limit,
        select: {b.inserted_at, a}
      )
      |> where_viewable(viewer)
      |> Repo.all()

    articles = Enum.map(rows, fn {_ts, a} -> a end) |> Repo.preload([:boards, :article_images])
    article_map = Map.new(articles, &{&1.id, &1})
    Enum.map(rows, fn {ts, a} -> {ts, article_map[a.id]} end)
  end

  @doc """
  Returns recent comments boosted by a user, newest first (by boost time).

  Excludes soft-deleted comments. Each result is a 2-tuple of
  `{boost_inserted_at, comment}` with article and boards preloaded.
  """
  def list_recent_boosted_comments_by_user(user_id, limit \\ 10, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)

    rows =
      from(b in CommentBoost,
        join: c in Comment,
        on: c.id == b.comment_id,
        join: a in Article,
        as: :article,
        on: a.id == c.article_id,
        where: b.user_id == ^user_id and is_nil(c.deleted_at) and is_nil(a.deleted_at),
        where: is_nil(c.remote_actor_id) or c.visibility in ["public", "unlisted"],
        where: is_nil(a.remote_actor_id) or a.visibility in ["public", "unlisted"],
        where:
          is_nil(c.remote_actor_id) or
            c.remote_actor_id not in subquery(Filters.hidden_actor_ids()),
        where:
          is_nil(a.remote_actor_id) or
            a.remote_actor_id not in subquery(Filters.hidden_actor_ids()),
        order_by: [desc: b.inserted_at, desc: b.id],
        limit: ^limit,
        select: {b.inserted_at, c}
      )
      |> where_viewable(viewer)
      |> Repo.all()

    comments = Enum.map(rows, fn {_ts, c} -> c end) |> Repo.preload(article: :boards)
    comment_map = Map.new(comments, &{&1.id, &1})
    Enum.map(rows, fn {ts, c} -> {ts, comment_map[c.id]} end)
  end

  @doc """
  Returns a merged timeline of recently boosted articles and comments by a user,
  sorted newest first by boost time. Each entry is tagged as
  `{:article, boosted_at, article}` or `{:comment, boosted_at, comment}`.
  """
  def list_recent_boosted_by_user(user_id, limit \\ 10, opts \\ []) do
    articles =
      list_recent_boosted_articles_by_user(user_id, limit, opts)
      |> Enum.map(fn {boosted_at, a} -> {boosted_at, {:article, boosted_at, a}} end)

    comments =
      list_recent_boosted_comments_by_user(user_id, limit, opts)
      |> Enum.map(fn {boosted_at, c} -> {boosted_at, {:comment, boosted_at, c}} end)

    merge_and_take(articles ++ comments, limit)
  end

  # Sorts tagged entries by timestamp descending and returns the top `limit`.
  # Each entry is `{timestamp, payload}`. Tiebreaker uses term ordering on
  # the payload to ensure stable sort without relying on cross-table IDs.
  defp merge_and_take(entries, limit) do
    entries
    |> Enum.sort(fn {ts1, _}, {ts2, _} ->
      case DateTime.compare(ts1, ts2) do
        :gt -> true
        :lt -> false
        :eq -> true
      end
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  @doc """
  Returns `{article_count, comment_count}` for a user in a single query.
  """
  def count_user_content_stats(user_id) do
    %{rows: [[articles, comments]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM articles WHERE user_id = $1 AND deleted_at IS NULL),
          (SELECT count(*) FROM comments WHERE user_id = $1 AND deleted_at IS NULL)
        """,
        [user_id]
      )

    {articles, comments}
  end

  @doc """
  Returns the count of non-deleted articles by a user.
  """
  def count_articles_by_user(user_id) do
    Repo.one(
      from(a in Article,
        where: a.user_id == ^user_id and is_nil(a.deleted_at),
        select: count(a.id)
      )
    ) || 0
  end

  @doc """
  Returns the count of non-deleted comments by a user.
  """
  def count_comments_by_user(user_id) do
    Repo.one(
      from(c in Comment,
        where: c.user_id == ^user_id and is_nil(c.deleted_at),
        select: count(c.id)
      )
    ) || 0
  end

  @doc """
  Returns paginated non-deleted articles by a user, newest first.
  """
  def paginate_articles_by_user(user_id, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    viewer = Keyword.get(opts, :viewer)

    base_query =
      from(a in Article,
        as: :article,
        where: a.user_id == ^user_id and is_nil(a.deleted_at),
        distinct: a.id
      )
      |> where_viewable(viewer)

    Pagination.paginate_query(base_query, pagination,
      result_key: :articles,
      order_by: [desc: dynamic([q], q.inserted_at), desc: dynamic([q], q.id)],
      preloads: [:user, :boards]
    )
  end

  @doc """
  Returns paginated non-deleted comments by a user, newest first.
  """
  def paginate_comments_by_user(user_id, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    viewer = Keyword.get(opts, :viewer)

    base_query =
      from(c in Comment,
        join: a in Article,
        as: :article,
        on: a.id == c.article_id,
        where: c.user_id == ^user_id and is_nil(c.deleted_at) and is_nil(a.deleted_at),
        distinct: c.id
      )
      |> where_viewable(viewer)

    Pagination.paginate_query(base_query, pagination,
      result_key: :comments,
      order_by: [desc: dynamic([q], q.inserted_at), desc: dynamic([q], q.id)],
      preloads: [:user, article: :boards]
    )
  end
end
