defmodule Baudrate.Content.Bookmarks do
  @moduledoc """
  Article and comment bookmark operations.

  Manages bookmark creation, deletion, toggling, and paginated listing.

  ## Authorization

  The toggle functions take a client-supplied target ID, so they gate on
  `Interactions.article_visible_to_user?/2` at the context boundary rather than
  trusting the caller (see `doc/adr/0016-authorization-at-the-context-boundary.md`).
  Without it a user could bookmark a guessed article or comment ID in a board
  they cannot view and then read its title and body excerpt on `/bookmarks`.
  Soft-deleted targets are refused for the same reason.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Bookmark, Comment, Interactions}

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

  Returns `{:ok, bookmark}` when created, `{:ok, :removed}` when deleted, or
  `{:error, :not_found}` when the article is missing, soft-deleted, or lives in
  a board the user cannot view.
  """
  @spec toggle_article_bookmark(term(), term()) ::
          {:ok, %Bookmark{}} | {:ok, :removed} | {:error, :not_found | Ecto.Changeset.t()}
  def toggle_article_bookmark(user_id, article_id) do
    with :ok <- authorize_article(user_id, article_id) do
      case Repo.get_by(Bookmark, user_id: user_id, article_id: article_id) do
        nil ->
          bookmark_article(user_id, article_id)
          |> handle_bookmark_conflict(user_id, article_id: article_id)

        bookmark ->
          do_delete_bookmark(bookmark)
      end
    end
  end

  @doc """
  Toggles a comment bookmark — creates if not exists, deletes if exists.

  Returns `{:ok, bookmark}` when created, `{:ok, :removed}` when deleted, or
  `{:error, :not_found}` when the comment is missing, soft-deleted, or belongs
  to an article the user cannot view.
  """
  @spec toggle_comment_bookmark(term(), term()) ::
          {:ok, %Bookmark{}} | {:ok, :removed} | {:error, :not_found | Ecto.Changeset.t()}
  def toggle_comment_bookmark(user_id, comment_id) do
    with :ok <- authorize_comment(user_id, comment_id) do
      case Repo.get_by(Bookmark, user_id: user_id, comment_id: comment_id) do
        nil ->
          bookmark_comment(user_id, comment_id)
          |> handle_bookmark_conflict(user_id, comment_id: comment_id)

        bookmark ->
          do_delete_bookmark(bookmark)
      end
    end
  end

  @doc """
  Returns the subset of `comment_ids` the user has bookmarked, as a `MapSet`.

  Mirrors `Content.comment_likes_by_user/2` so a comment thread can render its
  bookmark state in one query rather than one per comment.
  """
  @spec comment_bookmarks_by_user(term(), [term()]) :: MapSet.t()
  def comment_bookmarks_by_user(_user_id, []), do: MapSet.new()

  def comment_bookmarks_by_user(user_id, comment_ids) when is_list(comment_ids) do
    from(b in Bookmark,
      where: b.user_id == ^user_id and b.comment_id in ^comment_ids,
      select: b.comment_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # An existing bookmark is always removable: a board whose `min_role_to_view`
  # was raised after the fact must not strand the row on the user's list.
  defp authorize_article(user_id, article_id) do
    cond do
      Repo.exists?(
        from(b in Bookmark, where: b.user_id == ^user_id and b.article_id == ^article_id)
      ) ->
        :ok

      not article_readable?(user_id, article_id) ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  defp authorize_comment(user_id, comment_id) do
    cond do
      Repo.exists?(
        from(b in Bookmark, where: b.user_id == ^user_id and b.comment_id == ^comment_id)
      ) ->
        :ok

      true ->
        case Repo.get(Comment, comment_id) do
          %Comment{deleted_at: nil, article_id: article_id} ->
            if article_readable?(user_id, article_id), do: :ok, else: {:error, :not_found}

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp article_readable?(user_id, article_id) do
    case Repo.get(Article, article_id) do
      %Article{deleted_at: nil} -> Interactions.article_visible_to_user?(article_id, user_id)
      _ -> false
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
    if Baudrate.Content.Interactions.has_unique_constraint_error?(cs) do
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
        preload: [
          article: [:boards, :user, :remote_actor],
          comment: [:article, :user, :remote_actor]
        ]
      )
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{bookmarks: bookmarks, page: page, total_pages: total_pages}
  end
end
