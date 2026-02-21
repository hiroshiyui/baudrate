defmodule Baudrate.Content do
  @moduledoc """
  The Content context manages boards, articles, comments, and likes.

  Boards are organized hierarchically via `parent_id`. Articles can be
  cross-posted to multiple boards through the `board_articles` join table.
  Comments support threading via `parent_id`. Likes track article favorites
  from both local users and remote actors.

  Content mutations that are federation-relevant (`create_article/2`,
  `soft_delete_article/1`) automatically enqueue delivery of the
  corresponding ActivityPub activities to remote followers via
  `Federation.Publisher` and `Federation.TaskSupervisor`.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Attachment, ArticleLike, Board, BoardArticle, BoardModerator, Comment}

  # --- Boards ---

  @doc """
  Returns top-level boards (no parent), ordered by position.
  """
  def list_top_boards do
    from(b in Board, where: is_nil(b.parent_id), order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Returns top-level public boards (no parent, visibility "public"), ordered by position.
  """
  def list_public_top_boards do
    from(b in Board,
      where: is_nil(b.parent_id) and b.visibility == "public",
      order_by: b.position
    )
    |> Repo.all()
  end

  @doc """
  Returns child boards of the given board, ordered by position.
  """
  def list_sub_boards(%Board{id: board_id}) do
    from(b in Board, where: b.parent_id == ^board_id, order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Fetches a board by ID or raises `Ecto.NoResultsError`.
  """
  def get_board!(id) do
    Repo.get!(Board, id)
  end

  @doc """
  Returns all boards ordered by position and name, with parent preloaded.
  """
  def list_all_boards do
    from(b in Board, order_by: [asc: b.position, asc: b.name], preload: [:parent])
    |> Repo.all()
  end

  @doc """
  Returns a board changeset for form tracking.
  """
  def change_board(board \\ %Board{}, attrs \\ %{}) do
    Board.changeset(board, attrs)
  end

  @doc """
  Creates a board.
  """
  def create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a board using `update_changeset` (slug excluded).
  """
  def update_board(%Board{} = board, attrs) do
    board
    |> Board.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a board if it has no linked articles.

  Returns `{:error, :has_articles}` if the board has articles.
  """
  def delete_board(%Board{} = board) do
    count = Repo.one(from(ba in BoardArticle, where: ba.board_id == ^board.id, select: count()))

    if count > 0 do
      {:error, :has_articles}
    else
      Repo.delete(board)
    end
  end

  @doc """
  Fetches a board by slug or raises `Ecto.NoResultsError`.
  """
  def get_board_by_slug!(slug) do
    Repo.get_by!(Board, slug: slug)
  end

  # --- Articles ---

  @doc """
  Returns articles in a board, pinned first, then by newest.
  """
  def list_articles_for_board(%Board{id: board_id}) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      where: ba.board_id == ^board_id and is_nil(a.deleted_at),
      order_by: [desc: a.pinned, desc: a.inserted_at],
      preload: :user
    )
    |> Repo.all()
  end

  @per_page 20

  @doc """
  Returns a paginated list of articles for a board.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})

  Returns `%{articles: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_articles_for_board(%Board{id: board_id}, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page

    base_query =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        where: ba.board_id == ^board_id and is_nil(a.deleted_at)
      )

    total = Repo.one(from(q in base_query, select: count(q.id)))

    articles =
      from(q in base_query,
        order_by: [desc: q.pinned, desc: q.inserted_at],
        offset: ^offset,
        limit: ^per_page,
        preload: :user
      )
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{
      articles: articles,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Fetches an article by slug with boards and user preloaded,
  or raises `Ecto.NoResultsError`.
  """
  def get_article_by_slug!(slug) do
    Article
    |> Repo.get_by!(slug: slug)
    |> Repo.preload([:boards, :user])
  end

  @doc """
  Creates an article and links it to the given board IDs in a transaction.

  ## Parameters

    * `attrs` — article attributes (title, body, slug, user_id, etc.)
    * `board_ids` — list of board IDs to place the article in
  """
  def create_article(attrs, board_ids) when is_list(board_ids) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:article, Article.changeset(%Article{}, attrs))
      |> Ecto.Multi.run(:board_articles, fn repo, %{article: article} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entries =
          Enum.map(board_ids, fn board_id ->
            %{board_id: board_id, article_id: article.id, inserted_at: now, updated_at: now}
          end)

        {count, _} = repo.insert_all(BoardArticle, entries)

        if count == length(board_ids) do
          {:ok, count}
        else
          {:error, :board_articles_insert_mismatch}
        end
      end)
      |> Repo.transaction()

    with {:ok, %{article: article}} <- result do
      schedule_federation_task(fn ->
        article = Repo.preload(article, [:boards, :user])
        Baudrate.Federation.Publisher.publish_article_created(article)
      end)

      result
    end
  end

  @doc """
  Returns an article changeset for form tracking.
  """
  def change_article(article \\ %Article{}, attrs \\ %{}) do
    Article.changeset(article, attrs)
  end

  @doc """
  Returns an article changeset for edit form tracking.
  """
  def change_article_for_edit(%Article{} = article, attrs \\ %{}) do
    Article.update_changeset(article, attrs)
  end

  @doc """
  Updates a local article's title and body.

  Publishes an `Update(Article)` activity to federation after success.
  """
  def update_article(%Article{} = article, attrs) do
    result =
      article
      |> Article.update_changeset(attrs)
      |> Repo.update()

    with {:ok, updated_article} <- result do
      if updated_article.user_id do
        schedule_federation_task(fn ->
          updated_article = Repo.preload(updated_article, [:boards, :user])
          Baudrate.Federation.Publisher.publish_article_updated(updated_article)
        end)
      end

      result
    end
  end

  @doc """
  Returns `true` if the user can manage (edit/delete) the article.

  A user can manage an article if they are the author or an admin.
  """
  def can_manage_article?(%{role: %{name: "admin"}}, %Article{}), do: true
  def can_manage_article?(%{id: user_id}, %Article{user_id: article_user_id}), do: user_id == article_user_id
  def can_manage_article?(_, _), do: false

  @doc """
  Generates a URL-safe slug from a title string.

  Converts to lowercase, replaces non-alphanumeric characters with hyphens,
  trims leading/trailing hyphens, collapses consecutive hyphens, and appends
  a short random suffix to avoid collisions.
  """
  def generate_slug(title) when is_binary(title) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.replace(~r/^-|-$/, "")
      |> String.replace(~r/-{2,}/, "-")

    case base do
      "" -> suffix
      base -> "#{base}-#{suffix}"
    end
  end

  # --- Search ---

  @doc """
  Full-text search across articles by title and body.

  Uses PostgreSQL `websearch_to_tsquery` for natural search syntax.
  Only searches non-deleted articles in public boards.

  Returns `%{articles, total, page, per_page, total_pages}`.
  """
  def search_articles(query_string, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page

    base_query =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          is_nil(a.deleted_at) and
            b.visibility == "public" and
            fragment("?.search_vector @@ websearch_to_tsquery('english', ?)", a, ^query_string),
        distinct: a.id
      )

    total = Repo.one(from(q in subquery(base_query), select: count()))

    articles =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          is_nil(a.deleted_at) and
            b.visibility == "public" and
            fragment("?.search_vector @@ websearch_to_tsquery('english', ?)", a, ^query_string),
        distinct: a.id,
        order_by: [
          desc: fragment("ts_rank(?.search_vector, websearch_to_tsquery('english', ?))", a, ^query_string),
          desc: a.inserted_at
        ],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :boards]
      )
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{
      articles: articles,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  # --- Cross-post ---

  @doc """
  Links an existing article to an additional board.
  Used for cross-post deduplication when the same remote article
  arrives via multiple board inboxes.
  """
  def add_article_to_board(%Article{id: article_id}, board_id) do
    %BoardArticle{}
    |> BoardArticle.changeset(%{board_id: board_id, article_id: article_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  # --- Remote Articles ---

  @doc """
  Creates a remote article and links it to the given board IDs in a transaction.
  """
  def create_remote_article(attrs, board_ids) when is_list(board_ids) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:article, Article.remote_changeset(%Article{}, attrs))
    |> Ecto.Multi.run(:board_articles, fn repo, %{article: article} ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(board_ids, fn board_id ->
          %{board_id: board_id, article_id: article.id, inserted_at: now, updated_at: now}
        end)

      {count, _} = repo.insert_all(BoardArticle, entries)

      if count == length(board_ids) do
        {:ok, count}
      else
        {:error, :board_articles_insert_mismatch}
      end
    end)
    |> Repo.transaction()
  end

  @doc """
  Fetches an article by its ActivityPub ID.
  """
  def get_article_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(Article, ap_id: ap_id)
  end

  @doc """
  Soft-deletes an article by setting `deleted_at`.
  """
  def soft_delete_article(%Article{} = article) do
    result =
      article
      |> Article.soft_delete_changeset()
      |> Repo.update()

    with {:ok, deleted_article} <- result do
      # Only publish deletion for local articles (those with a user_id)
      if deleted_article.user_id do
        schedule_federation_task(fn ->
          deleted_article = Repo.preload(deleted_article, [:boards, :user])
          Baudrate.Federation.Publisher.publish_article_deleted(deleted_article)
        end)
      end

      result
    end
  end

  @doc """
  Updates a remote article's content.
  """
  def update_remote_article(%Article{} = article, attrs) do
    article
    |> Article.update_remote_changeset(attrs)
    |> Repo.update()
  end

  # --- Comments ---

  @doc """
  Creates a local comment on an article.

  Renders the body to HTML via `Markdown.to_html/1` and publishes a
  `Create(Note)` activity to federation.
  """
  def create_comment(attrs) do
    body_html = Baudrate.Content.Markdown.to_html(attrs["body"] || attrs[:body] || "")

    result =
      %Comment{}
      |> Comment.changeset(Map.put(attrs, "body_html", body_html))
      |> Repo.insert()

    with {:ok, comment} <- result do
      if comment.user_id do
        schedule_federation_task(fn ->
          comment = Repo.preload(comment, [:user])
          article = Repo.get!(Article, comment.article_id) |> Repo.preload([:boards, :user])
          Baudrate.Federation.Publisher.publish_comment_created(comment, article)
        end)
      end

      result
    end
  end

  @doc """
  Returns a comment changeset for form tracking.
  """
  def change_comment(comment \\ %Comment{}, attrs \\ %{}) do
    Comment.changeset(comment, attrs)
  end

  @doc """
  Creates a remote comment received via ActivityPub.
  """
  def create_remote_comment(attrs) do
    %Comment{}
    |> Comment.remote_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a comment by its ActivityPub ID.
  """
  def get_comment_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(Comment, ap_id: ap_id)
  end

  @doc """
  Lists non-deleted comments for an article, threaded by parent.
  """
  def list_comments_for_article(%Article{id: article_id}) do
    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at],
      preload: [:user, :remote_actor]
    )
    |> Repo.all()
  end

  @doc """
  Soft-deletes a comment by setting `deleted_at` and clearing body.
  """
  def soft_delete_comment(%Comment{} = comment) do
    comment
    |> Comment.soft_delete_changeset()
    |> Repo.update()
  end

  @doc """
  Updates a remote comment's content.
  """
  def update_remote_comment(%Comment{} = comment, attrs) do
    comment
    |> Ecto.Changeset.cast(attrs, [:body, :body_html])
    |> Ecto.Changeset.validate_required([:body])
    |> Repo.update()
  end

  # --- Article Likes ---

  @doc """
  Creates a remote article like received via ActivityPub.
  """
  def create_remote_article_like(attrs) do
    %ArticleLike{}
    |> ArticleLike.remote_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes an article like by its ActivityPub ID.
  """
  def delete_article_like_by_ap_id(ap_id) when is_binary(ap_id) do
    from(l in ArticleLike, where: l.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of likes for an article.
  """
  def count_article_likes(%Article{id: article_id}) do
    Repo.one(from(l in ArticleLike, where: l.article_id == ^article_id, select: count(l.id))) ||
      0
  end

  # --- Attachments ---

  @doc """
  Creates an attachment record.
  """
  def create_attachment(attrs) do
    %Attachment{}
    |> Attachment.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists attachments for an article.
  """
  def list_attachments_for_article(%Article{id: article_id}) do
    from(a in Attachment,
      where: a.article_id == ^article_id,
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Deletes an attachment record and its file on disk.
  """
  def delete_attachment(%Attachment{} = attachment) do
    Baudrate.AttachmentStorage.delete_attachment(attachment)
    Repo.delete(attachment)
  end

  @doc """
  Fetches an attachment by ID.
  """
  def get_attachment!(id), do: Repo.get!(Attachment, id)

  # --- Federation Hooks ---

  defp schedule_federation_task(fun) do
    Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
  end

  # --- SysOp Board ---

  @doc """
  Creates the predefined SysOp board and assigns the given user as its moderator.

  Returns `{:ok, board}` on success.
  """
  def seed_sysop_board(%{id: user_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    board_changeset =
      Board.changeset(%Board{}, %{
        name: "SysOp",
        slug: "sysop",
        description: "System Operations",
        position: 0
      })

    with {:ok, board} <- Repo.insert(board_changeset) do
      Repo.insert!(%BoardModerator{
        board_id: board.id,
        user_id: user_id,
        inserted_at: now,
        updated_at: now
      })

      {:ok, board}
    end
  end
end
