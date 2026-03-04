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
    Board,
    BoardArticle,
    Comment
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
      order_by: [desc: a.inserted_at],
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
          order_by: [desc: a.inserted_at],
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
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      preload: [:user, :boards]
    )
    |> Repo.all()
  end

  # --- User Content Queries ---

  @doc """
  Returns recent non-deleted articles by a user, newest first, with boards preloaded.
  """
  def list_recent_articles_by_user(user_id, limit \\ 10) do
    from(a in Article,
      where: a.user_id == ^user_id and is_nil(a.deleted_at),
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      preload: :boards
    )
    |> Repo.all()
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

    base_query =
      from(a in Article,
        where: a.user_id == ^user_id and is_nil(a.deleted_at),
        distinct: a.id
      )

    Pagination.paginate_query(base_query, pagination,
      result_key: :articles,
      order_by: [desc: dynamic([q], q.inserted_at)],
      preloads: [:user, :boards]
    )
  end

  @doc """
  Returns paginated non-deleted comments by a user, newest first.
  """
  def paginate_comments_by_user(user_id, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)

    base_query =
      from(c in Comment,
        where: c.user_id == ^user_id and is_nil(c.deleted_at),
        distinct: c.id
      )

    Pagination.paginate_query(base_query, pagination,
      result_key: :comments,
      order_by: [desc: dynamic([q], q.inserted_at)],
      preloads: [:user, article: :boards]
    )
  end
end
