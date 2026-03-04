defmodule Baudrate.Content.Bookmarks do
  @moduledoc """
  Article and comment bookmark operations.

  Manages bookmark creation, deletion, toggling, and paginated listing.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.{Bookmark, Likes}

  @bookmarks_per_page 20
  @max_bookmarks_per_page 100

  @doc """
  Bookmarks an article for the user.

  Returns `{:ok, bookmark}` or `{:error, changeset}`.
  """
  def bookmark_article(user_id, article_id) do
    %Bookmark{}
    |> Bookmark.changeset(%{user_id: user_id, article_id: article_id})
    |> Repo.insert()
  end

  @doc """
  Bookmarks a comment for the user.

  Returns `{:ok, bookmark}` or `{:error, changeset}`.
  """
  def bookmark_comment(user_id, comment_id) do
    %Bookmark{}
    |> Bookmark.changeset(%{user_id: user_id, comment_id: comment_id})
    |> Repo.insert()
  end

  @doc """
  Removes a bookmark by its ID, scoped to the given user.

  Returns `{:ok, bookmark}` if found and deleted, or `{:error, :not_found}`.
  """
  def delete_bookmark(user_id, bookmark_id) do
    case Repo.get_by(Bookmark, id: bookmark_id, user_id: user_id) do
      nil -> {:error, :not_found}
      bookmark -> Repo.delete(bookmark)
    end
  end

  @doc """
  Returns true if the user has bookmarked the given article.
  """
  def article_bookmarked?(user_id, article_id) do
    Repo.exists?(
      from(b in Bookmark, where: b.user_id == ^user_id and b.article_id == ^article_id)
    )
  end

  @doc """
  Returns true if the user has bookmarked the given comment.
  """
  def comment_bookmarked?(user_id, comment_id) do
    Repo.exists?(
      from(b in Bookmark, where: b.user_id == ^user_id and b.comment_id == ^comment_id)
    )
  end

  @doc """
  Toggles an article bookmark — creates if not exists, deletes if exists.

  Returns `{:ok, bookmark}` when created or `{:ok, :removed}` when deleted.
  """
  @spec toggle_article_bookmark(term(), term()) ::
          {:ok, %Bookmark{}} | {:ok, :removed} | {:error, Ecto.Changeset.t()}
  def toggle_article_bookmark(user_id, article_id) do
    case Repo.get_by(Bookmark, user_id: user_id, article_id: article_id) do
      nil ->
        bookmark_article(user_id, article_id)
        |> handle_bookmark_conflict(user_id, article_id: article_id)

      bookmark ->
        do_delete_bookmark(bookmark)
    end
  end

  @doc """
  Toggles a comment bookmark — creates if not exists, deletes if exists.

  Returns `{:ok, bookmark}` when created, `{:ok, :removed}` when deleted,
  or `{:error, changeset}` on failure.
  """
  @spec toggle_comment_bookmark(term(), term()) ::
          {:ok, %Bookmark{}} | {:ok, :removed} | {:error, Ecto.Changeset.t()}
  def toggle_comment_bookmark(user_id, comment_id) do
    case Repo.get_by(Bookmark, user_id: user_id, comment_id: comment_id) do
      nil ->
        bookmark_comment(user_id, comment_id)
        |> handle_bookmark_conflict(user_id, comment_id: comment_id)

      bookmark ->
        do_delete_bookmark(bookmark)
    end
  end

  defp do_delete_bookmark(bookmark) do
    case Repo.delete(bookmark) do
      {:ok, _} -> {:ok, :removed}
      {:error, cs} -> {:error, cs}
    end
  end

  # Handle unique constraint violation from concurrent toggle — treat as "already exists, so delete"
  defp handle_bookmark_conflict({:ok, bookmark}, _user_id, _opts), do: {:ok, bookmark}

  defp handle_bookmark_conflict({:error, %Ecto.Changeset{} = cs}, user_id, opts) do
    if Likes.has_unique_constraint_error?(cs) do
      case Repo.get_by(Bookmark, [{:user_id, user_id} | opts]) do
        nil -> {:ok, :removed}
        bookmark -> do_delete_bookmark(bookmark)
      end
    else
      {:error, cs}
    end
  end

  @doc """
  Lists bookmarks for a user with pagination.

  Preloads article (with boards and user) and comment (with article and user).
  Excludes bookmarks whose target has been soft-deleted.
  Orders by `inserted_at` descending.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — bookmarks per page (default #{@bookmarks_per_page})

  Returns `%{bookmarks: [...], page: N, total_pages: N}`.
  """
  def list_bookmarks(user_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = opts |> Keyword.get(:per_page, @bookmarks_per_page) |> min(@max_bookmarks_per_page)
    offset = (page - 1) * per_page

    base_query =
      from(b in Bookmark,
        left_join: a in assoc(b, :article),
        left_join: c in assoc(b, :comment),
        where: b.user_id == ^user_id,
        where:
          (not is_nil(b.article_id) and is_nil(a.deleted_at)) or
            (not is_nil(b.comment_id) and is_nil(c.deleted_at))
      )

    total = Repo.one(from(b in subquery(base_query), select: count()))

    bookmarks =
      from(b in Bookmark,
        left_join: a in assoc(b, :article),
        left_join: c in assoc(b, :comment),
        where: b.user_id == ^user_id,
        where:
          (not is_nil(b.article_id) and is_nil(a.deleted_at)) or
            (not is_nil(b.comment_id) and is_nil(c.deleted_at)),
        order_by: [desc: b.inserted_at, desc: b.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [article: [:boards, :user, :remote_actor], comment: [:article, :user, :remote_actor]]
      )
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{bookmarks: bookmarks, page: page, total_pages: total_pages}
  end
end
