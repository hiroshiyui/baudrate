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
  alias Baudrate.Content.{Article, ArticleLike, Board, BoardArticle, BoardModerator, Comment}

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
