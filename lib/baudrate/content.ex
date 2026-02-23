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
  alias Baudrate.{Auth, Repo, Setup}
  alias Baudrate.Content.{Article, ArticleImage, ArticleRevision, Attachment, ArticleLike, Board, BoardArticle, BoardModerator, Comment}
  alias Baudrate.Content.PubSub, as: ContentPubSub

  # --- Boards ---

  @doc """
  Returns top-level boards (no parent), ordered by position.
  """
  def list_top_boards do
    from(b in Board, where: is_nil(b.parent_id), order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Returns top-level boards visible to the given user, ordered by position.
  Guests (nil user) only see boards with `min_role_to_view == "guest"`.
  """
  def list_visible_top_boards(user) do
    level = if user, do: Setup.role_level(user.role.name), else: 0

    from(b in Board, where: is_nil(b.parent_id), order_by: b.position)
    |> Repo.all()
    |> Enum.filter(&(Setup.role_level(&1.min_role_to_view) <= level))
  end

  @doc """
  Returns child boards of the given board, ordered by position.
  """
  def list_sub_boards(%Board{id: board_id}) do
    from(b in Board, where: b.parent_id == ^board_id, order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Returns child boards visible to the given user, ordered by position.
  """
  def list_visible_sub_boards(%Board{} = board, user) do
    level = if user, do: Setup.role_level(user.role.name), else: 0

    from(b in Board, where: b.parent_id == ^board.id, order_by: b.position)
    |> Repo.all()
    |> Enum.filter(&(Setup.role_level(&1.min_role_to_view) <= level))
  end

  @doc """
  Returns the ancestor chain for a board, from root to the board itself.

  Walks the `parent_id` chain upward (max 10 levels to prevent infinite loops).
  """
  def board_ancestors(%Board{} = board) do
    do_board_ancestors(board, [], 10)
  end

  defp do_board_ancestors(%Board{parent_id: nil} = board, acc, _remaining) do
    [board | acc]
  end

  defp do_board_ancestors(_board, acc, 0), do: acc

  defp do_board_ancestors(%Board{parent_id: parent_id} = board, acc, remaining) do
    parent = Repo.get!(Board, parent_id)
    do_board_ancestors(parent, [board | acc], remaining - 1)
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
    article_count =
      Repo.one(from(ba in BoardArticle, where: ba.board_id == ^board.id, select: count()))

    child_count =
      Repo.one(from(b in Board, where: b.parent_id == ^board.id, select: count()))

    cond do
      article_count > 0 -> {:error, :has_articles}
      child_count > 0 -> {:error, :has_children}
      true -> Repo.delete(board)
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
  def create_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    image_ids = Keyword.get(opts, :image_ids, [])

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
      |> Ecto.Multi.run(:article_images, fn _repo, %{article: article} ->
        if image_ids != [] do
          user_id = attrs["user_id"] || attrs[:user_id]
          associate_article_images(article.id, image_ids, user_id)
        end

        {:ok, :done}
      end)
      |> Repo.transaction()

    with {:ok, %{article: article}} <- result do
      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

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

  Creates a revision snapshot of the pre-edit state when an `editor` is
  provided (3-arity form). The 2-arity form is kept for backward
  compatibility (federation updates with no local editor).

  Publishes an `Update(Article)` activity to federation after success.
  """
  def update_article(%Article{} = article, attrs) do
    update_article(article, attrs, nil)
  end

  def update_article(%Article{} = article, attrs, editor) do
    result =
      Ecto.Multi.new()
      |> maybe_snapshot_revision(article, editor)
      |> Ecto.Multi.update(:article, Article.update_changeset(article, attrs))
      |> Repo.transaction()

    with {:ok, %{article: updated_article}} <- result do
      updated_article = Repo.preload(updated_article, :boards)

      for board <- updated_article.boards do
        ContentPubSub.broadcast_to_board(board.id, :article_updated, %{article_id: updated_article.id})
      end

      ContentPubSub.broadcast_to_article(updated_article.id, :article_updated, %{article_id: updated_article.id})

      if updated_article.user_id do
        schedule_federation_task(fn ->
          updated_article = Repo.preload(updated_article, [:user])
          Baudrate.Federation.Publisher.publish_article_updated(updated_article)
        end)
      end

      {:ok, updated_article}
    else
      {:error, :article, changeset, _} -> {:error, changeset}
      other -> other
    end
  end

  defp maybe_snapshot_revision(multi, _article, nil), do: multi

  defp maybe_snapshot_revision(multi, article, editor) do
    Ecto.Multi.insert(multi, :revision, fn _changes ->
      ArticleRevision.changeset(%ArticleRevision{}, %{
        title: article.title,
        body: article.body,
        article_id: article.id,
        editor_id: editor.id
      })
    end)
  end

  # --- Board Access Checks ---

  @doc """
  Returns true if the user can view the given board.
  Guests can only see boards with `min_role_to_view == "guest"`.
  """
  def can_view_board?(board, nil), do: board.min_role_to_view == "guest"

  def can_view_board?(board, user) do
    Setup.role_meets_minimum?(user.role.name, board.min_role_to_view)
  end

  @doc """
  Returns true if the user can post in the given board.
  Requires active account, content creation permission, and sufficient role.
  """
  def can_post_in_board?(_board, nil), do: false

  def can_post_in_board?(board, user) do
    Auth.can_create_content?(user) and
      Setup.role_meets_minimum?(user.role.name, board.min_role_to_post)
  end

  @doc """
  Returns true if the user is a board moderator (assigned, global moderator, or admin).
  """
  def board_moderator?(_board, nil), do: false

  def board_moderator?(board, %{id: user_id, role: %{name: role_name}}) do
    role_name in ["admin", "moderator"] or
      Repo.exists?(
        from(bm in BoardModerator,
          where: bm.board_id == ^board.id and bm.user_id == ^user_id
        )
      )
  end

  def board_moderator?(_board, _user), do: false

  # --- Granular Article/Comment Permission Checks ---

  @doc """
  Returns true if the user can edit the article (author or admin only).
  Board moderators cannot edit others' articles.
  """
  def can_edit_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_edit_article?(%{id: uid}, %{user_id: uid}), do: true
  def can_edit_article?(_, _), do: false

  @doc """
  Returns true if the user can delete the article (author, admin, or board moderator).
  """
  def can_delete_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_delete_article?(%{id: uid}, %{user_id: uid}), do: true

  def can_delete_article?(user, article) do
    article = Repo.preload(article, :boards)
    Enum.any?(article.boards, &board_moderator?(&1, user))
  end

  @doc """
  Returns true if the user can pin the article (admin or board moderator).
  """
  def can_pin_article?(%{role: %{name: "admin"}}, _article), do: true

  def can_pin_article?(user, article) do
    article = Repo.preload(article, :boards)
    Enum.any?(article.boards, &board_moderator?(&1, user))
  end

  @doc """
  Returns true if the user can lock the article (admin or board moderator).
  """
  def can_lock_article?(user, article), do: can_pin_article?(user, article)

  @doc """
  Returns true if the user can delete the comment (author, admin, or board moderator).
  """
  def can_delete_comment?(%{role: %{name: "admin"}}, _comment, _article), do: true
  def can_delete_comment?(%{id: uid}, %{user_id: uid}, _article), do: true

  def can_delete_comment?(user, _comment, article) do
    article = Repo.preload(article, :boards)
    Enum.any?(article.boards, &board_moderator?(&1, user))
  end

  @doc """
  Backward-compatible alias for `can_edit_article?/2`.
  """
  def can_manage_article?(user, article), do: can_edit_article?(user, article)

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

  Uses a dual strategy: PostgreSQL `websearch_to_tsquery` for English text,
  and trigram `ILIKE` for CJK (Chinese, Japanese, Korean) queries. The strategy
  is auto-detected based on whether the query contains CJK characters.

  Only searches non-deleted articles in boards the user can view.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})
    * `:user` — current user (nil for guests)

  Returns `%{articles, total, page, per_page, total_pages}`.
  """
  def search_articles(query_string, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page
    user = Keyword.get(opts, :user)
    allowed_roles = allowed_view_roles(user)

    {where_clause, order_clause} = article_search_clauses(query_string)

    base_query =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where: is_nil(a.deleted_at) and b.min_role_to_view in ^allowed_roles,
        where: ^where_clause,
        distinct: a.id
      )

    total = Repo.one(from(q in subquery(base_query), select: count()))

    articles =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where: is_nil(a.deleted_at) and b.min_role_to_view in ^allowed_roles,
        where: ^where_clause,
        distinct: a.id,
        order_by: ^order_clause,
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

  defp article_search_clauses(query_string) do
    if contains_cjk?(query_string) do
      pattern = "%#{sanitize_like(query_string)}%"

      where =
        dynamic([a], ilike(a.title, ^pattern) or ilike(a.body, ^pattern))

      order = [desc: dynamic([a], a.inserted_at)]
      {where, order}
    else
      where =
        dynamic(
          [a],
          fragment(
            "?.search_vector @@ websearch_to_tsquery('english', ?)",
            a,
            ^query_string
          )
        )

      order = [
        desc:
          dynamic(
            [a],
            fragment(
              "ts_rank(?.search_vector, websearch_to_tsquery('english', ?))",
              a,
              ^query_string
            )
          ),
        desc: dynamic([a], a.inserted_at)
      ]

      {where, order}
    end
  end

  @doc """
  Full-text search across comments by body.

  Uses trigram `ILIKE` for both CJK and English queries (comments have no
  tsvector column). Only searches non-deleted comments on non-deleted articles
  in boards the user can view.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — comments per page (default #{@per_page})
    * `:user` — current user (nil for guests)

  Returns `%{comments, total, page, per_page, total_pages}`.
  """
  def search_comments(query_string, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page
    user = Keyword.get(opts, :user)
    allowed_roles = allowed_view_roles(user)

    pattern = "%#{sanitize_like(query_string)}%"

    base_query =
      from(c in Comment,
        join: a in Article,
        on: a.id == c.article_id,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          is_nil(c.deleted_at) and is_nil(a.deleted_at) and
            b.min_role_to_view in ^allowed_roles,
        where: ilike(c.body, ^pattern),
        distinct: c.id
      )

    total = Repo.one(from(q in subquery(base_query), select: count()))

    comments =
      from(c in Comment,
        join: a in Article,
        on: a.id == c.article_id,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          is_nil(c.deleted_at) and is_nil(a.deleted_at) and
            b.min_role_to_view in ^allowed_roles,
        where: ilike(c.body, ^pattern),
        distinct: c.id,
        order_by: [desc: c.inserted_at],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor, article: :boards]
      )
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{
      comments: comments,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  defp contains_cjk?(str) do
    String.match?(str, ~r/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/u)
  end

  defp sanitize_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp allowed_view_roles(nil), do: ["guest"]

  defp allowed_view_roles(%{role: %{name: role_name}}) do
    level = Setup.role_level(role_name)

    for {name, lvl} <- [{"guest", 0}, {"user", 1}, {"moderator", 2}, {"admin", 3}],
        lvl <= level,
        do: name
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
    result =
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

    with {:ok, %{article: article}} <- result do
      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

      result
    end
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
      deleted_article = Repo.preload(deleted_article, :boards)

      for board <- deleted_article.boards do
        ContentPubSub.broadcast_to_board(board.id, :article_deleted, %{article_id: deleted_article.id})
      end

      ContentPubSub.broadcast_to_article(deleted_article.id, :article_deleted, %{article_id: deleted_article.id})

      # Only publish deletion for local articles (those with a user_id)
      if deleted_article.user_id do
        schedule_federation_task(fn ->
          deleted_article = Repo.preload(deleted_article, [:user])
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

  # --- Article Revisions ---

  @doc """
  Creates a revision snapshot of the article's current title and body.
  """
  def create_article_revision(%Article{} = article, editor) do
    %ArticleRevision{}
    |> ArticleRevision.changeset(%{
      title: article.title,
      body: article.body,
      article_id: article.id,
      editor_id: if(editor, do: editor.id)
    })
    |> Repo.insert()
  end

  @doc """
  Lists all revisions for an article, newest first, with editor preloaded.
  """
  def list_article_revisions(article_id) do
    from(r in ArticleRevision,
      where: r.article_id == ^article_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: :editor
    )
    |> Repo.all()
  end

  @doc """
  Fetches a single revision by ID with editor preloaded, or raises.
  """
  def get_article_revision!(id) do
    ArticleRevision
    |> Repo.get!(id)
    |> Repo.preload(:editor)
  end

  @doc """
  Returns the count of revisions for an article.
  """
  def count_article_revisions(article_id) do
    Repo.one(
      from(r in ArticleRevision,
        where: r.article_id == ^article_id,
        select: count(r.id)
      )
    ) || 0
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
      ContentPubSub.broadcast_to_article(comment.article_id, :comment_created, %{comment_id: comment.id})

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
    result =
      %Comment{}
      |> Comment.remote_changeset(attrs)
      |> Repo.insert()

    with {:ok, comment} <- result do
      ContentPubSub.broadcast_to_article(comment.article_id, :comment_created, %{comment_id: comment.id})
      result
    end
  end

  @doc """
  Fetches a comment by its ActivityPub ID.
  """
  def get_comment_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(Comment, ap_id: ap_id)
  end

  @doc """
  Lists non-deleted comments for an article, threaded by parent.

  When `current_user` is provided, comments from blocked users and remote
  actors are filtered out.
  """
  def list_comments_for_article(article, current_user \\ nil)

  def list_comments_for_article(%Article{id: article_id}, nil) do
    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at],
      preload: [:user, :remote_actor]
    )
    |> Repo.all()
  end

  def list_comments_for_article(%Article{id: article_id}, current_user) do
    blocked_uids = Auth.blocked_user_ids(current_user)
    blocked_ap_ids = Auth.blocked_actor_ap_ids(current_user)

    query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at),
        order_by: [asc: c.inserted_at],
        preload: [:user, :remote_actor]
      )

    query =
      if blocked_uids != [] do
        from(c in query, where: is_nil(c.user_id) or c.user_id not in ^blocked_uids)
      else
        query
      end

    query =
      if blocked_ap_ids != [] do
        from(c in query,
          left_join: ra in assoc(c, :remote_actor),
          where: is_nil(c.remote_actor_id) or ra.ap_id not in ^blocked_ap_ids
        )
      else
        query
      end

    Repo.all(query)
  end

  @comments_per_page 20

  @doc """
  Returns a paginated list of comments for an article, preserving thread integrity.

  Paginates by **root comments** (those with `parent_id IS NULL`), then loads
  all descendant replies for each page of roots via iterative widening (max 5
  levels, matching the thread depth limit).

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — root comments per page (default #{@comments_per_page})

  Returns `%{comments: [...], total_roots: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_comments_for_article(article, current_user \\ nil, opts \\ [])

  def paginate_comments_for_article(%Article{id: article_id}, current_user, opts) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @comments_per_page)
    offset = (page - 1) * per_page

    {blocked_uids, blocked_ap_ids} = block_filters(current_user)

    # Count root comments
    root_count_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at) and is_nil(c.parent_id)
      )
      |> apply_block_filters(blocked_uids, blocked_ap_ids)

    total_roots = Repo.one(from(q in root_count_query, select: count(q.id)))

    # Fetch a page of root comments
    root_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at) and is_nil(c.parent_id),
        order_by: [asc: c.inserted_at],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor]
      )
      |> apply_block_filters(blocked_uids, blocked_ap_ids)

    roots = Repo.all(root_query)

    # Iteratively fetch all descendants (max 5 levels)
    descendants = fetch_descendants(article_id, roots, blocked_uids, blocked_ap_ids, 5)

    total_pages = max(ceil(total_roots / per_page), 1)

    %{
      comments: roots ++ descendants,
      total_roots: total_roots,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  defp block_filters(nil), do: {[], []}

  defp block_filters(current_user) do
    {Auth.blocked_user_ids(current_user), Auth.blocked_actor_ap_ids(current_user)}
  end

  defp apply_block_filters(query, [], []), do: query

  defp apply_block_filters(query, blocked_uids, blocked_ap_ids) do
    query =
      if blocked_uids != [] do
        from(c in query, where: is_nil(c.user_id) or c.user_id not in ^blocked_uids)
      else
        query
      end

    if blocked_ap_ids != [] do
      from(c in query,
        left_join: ra in assoc(c, :remote_actor),
        where: is_nil(c.remote_actor_id) or ra.ap_id not in ^blocked_ap_ids
      )
    else
      query
    end
  end

  defp fetch_descendants(_article_id, [], _blocked_uids, _blocked_ap_ids, _remaining), do: []
  defp fetch_descendants(_article_id, _parents, _blocked_uids, _blocked_ap_ids, 0), do: []

  defp fetch_descendants(article_id, parents, blocked_uids, blocked_ap_ids, remaining) do
    parent_ids = Enum.map(parents, & &1.id)

    child_query =
      from(c in Comment,
        where:
          c.article_id == ^article_id and is_nil(c.deleted_at) and
            c.parent_id in ^parent_ids,
        order_by: [asc: c.inserted_at],
        preload: [:user, :remote_actor]
      )
      |> apply_block_filters(blocked_uids, blocked_ap_ids)

    children = Repo.all(child_query)

    if children == [] do
      []
    else
      children ++ fetch_descendants(article_id, children, blocked_uids, blocked_ap_ids, remaining - 1)
    end
  end

  @doc """
  Soft-deletes a comment by setting `deleted_at` and clearing body.
  """
  def soft_delete_comment(%Comment{} = comment) do
    result =
      comment
      |> Comment.soft_delete_changeset()
      |> Repo.update()

    with {:ok, deleted} <- result do
      ContentPubSub.broadcast_to_article(deleted.article_id, :comment_deleted, %{comment_id: deleted.id})
      result
    end
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
  Returns the count of non-deleted comments for an article.
  """
  def count_comments_for_article(%Article{id: article_id}) do
    Repo.one(
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at),
        select: count(c.id)
      )
    ) || 0
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

  # --- Article Images ---

  @doc """
  Creates an article image record.
  """
  def create_article_image(attrs) do
    %ArticleImage{}
    |> ArticleImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists images for an article, ordered by insertion time.
  """
  def list_article_images(article_id) do
    from(ai in ArticleImage,
      where: ai.article_id == ^article_id,
      order_by: [asc: ai.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no article) for a user, for use during article composition.
  """
  def list_orphan_article_images(user_id) do
    from(ai in ArticleImage,
      where: ai.user_id == ^user_id and is_nil(ai.article_id),
      order_by: [asc: ai.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Deletes an article image record and its file on disk.
  """
  def delete_article_image(%ArticleImage{} = image) do
    Baudrate.Content.ArticleImageStorage.delete_image(image)
    Repo.delete(image)
  end

  @doc """
  Associates orphan article images with an article by setting their `article_id`.
  Only updates images owned by the given user that currently have no article.
  """
  def associate_article_images(article_id, image_ids, user_id) when is_list(image_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ai in ArticleImage,
      where:
        ai.id in ^image_ids and
          ai.user_id == ^user_id and
          is_nil(ai.article_id)
    )
    |> Repo.update_all(set: [article_id: article_id, updated_at: now])
  end

  @doc """
  Fetches an article image by ID.
  """
  def get_article_image!(id), do: Repo.get!(ArticleImage, id)

  @doc """
  Returns the count of images for an article.
  """
  def count_article_images(article_id) do
    Repo.one(
      from(ai in ArticleImage,
        where: ai.article_id == ^article_id,
        select: count(ai.id)
      )
    ) || 0
  end

  @doc """
  Deletes orphan article images older than the given cutoff.
  Returns the list of storage paths that were deleted from the database
  (caller should delete the files from disk).
  """
  def delete_orphan_article_images(cutoff) do
    query =
      from(ai in ArticleImage,
        where: is_nil(ai.article_id) and ai.inserted_at < ^cutoff,
        select: ai.storage_path
      )

    paths = Repo.all(query)

    from(ai in ArticleImage,
      where: is_nil(ai.article_id) and ai.inserted_at < ^cutoff
    )
    |> Repo.delete_all()

    paths
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

  # --- Pin / Lock ---

  @doc """
  Toggles the pinned status of an article.
  """
  def toggle_pin_article(%Article{} = article) do
    result =
      article
      |> Ecto.Changeset.change(pinned: !article.pinned)
      |> Repo.update()

    with {:ok, updated} <- result do
      updated = Repo.preload(updated, :boards)
      event = if updated.pinned, do: :article_pinned, else: :article_unpinned

      for board <- updated.boards do
        ContentPubSub.broadcast_to_board(board.id, event, %{article_id: updated.id})
      end

      result
    end
  end

  @doc """
  Toggles the locked status of an article.
  """
  def toggle_lock_article(%Article{} = article) do
    result =
      article
      |> Ecto.Changeset.change(locked: !article.locked)
      |> Repo.update()

    with {:ok, updated} <- result do
      updated = Repo.preload(updated, :boards)
      event = if updated.locked, do: :article_locked, else: :article_unlocked

      for board <- updated.boards do
        ContentPubSub.broadcast_to_board(board.id, event, %{article_id: updated.id})
      end

      result
    end
  end

  # --- Board Moderators ---

  @doc """
  Lists moderators for a board with user and role preloaded.
  """
  def list_board_moderators(%Board{id: board_id}) do
    from(bm in BoardModerator,
      where: bm.board_id == ^board_id,
      preload: [user: :role]
    )
    |> Repo.all()
  end

  @doc """
  Assigns a user as board moderator.
  """
  def add_board_moderator(board_id, user_id) do
    %BoardModerator{}
    |> BoardModerator.changeset(%{board_id: board_id, user_id: user_id})
    |> Repo.insert()
  end

  @doc """
  Removes a user from board moderators.
  """
  def remove_board_moderator(board_id, user_id) do
    from(bm in BoardModerator,
      where: bm.board_id == ^board_id and bm.user_id == ^user_id
    )
    |> Repo.delete_all()
  end

  # --- Federation Hooks ---

  defp schedule_federation_task(fun) do
    if Application.get_env(:baudrate, :federation_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
      :ok
    end
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
