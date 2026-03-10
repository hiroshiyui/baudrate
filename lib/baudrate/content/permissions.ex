defmodule Baudrate.Content.Permissions do
  @moduledoc """
  Board access checks and granular article/comment permission checks.

  Determines whether users can view, post in, moderate, edit, delete,
  pin, lock, or forward content based on their role and board moderator
  assignments.
  """

  import Ecto.Query
  alias Baudrate.{Auth, Repo, Setup}

  alias Baudrate.Content.{
    Article,
    Board,
    BoardModerator,
    Comment
  }

  # --- Board Access Checks ---

  @doc """
  Returns true if the user can view the given board.
  Guests can only see boards with `min_role_to_view == "guest"`.
  """
  @spec can_view_board?(%Board{}, map() | nil) :: boolean()
  def can_view_board?(board, nil), do: Board.public?(board)

  def can_view_board?(board, user) do
    Setup.role_meets_minimum?(user.role.name, board.min_role_to_view)
  end

  @doc """
  Returns true if the user can post in the given board.
  Requires active account, content creation permission, and sufficient role.
  """
  @spec can_post_in_board?(%Board{}, map() | nil) :: boolean()
  def can_post_in_board?(_board, nil), do: false

  def can_post_in_board?(board, user) do
    Auth.can_create_content?(user) and
      Setup.role_meets_minimum?(user.role.name, board.min_role_to_post)
  end

  @doc """
  Returns true if the user is a board moderator (assigned, global moderator, or admin).
  """
  @spec board_moderator?(%Board{}, map() | nil) :: boolean()
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

  @doc """
  Returns true if the user is a board moderator for any of the given boards.
  """
  def board_moderator_for_any?(boards, %{id: user_id, role: %{name: role_name}})
      when is_list(boards) do
    if role_name in ["admin", "moderator"] do
      true
    else
      board_ids = Enum.map(boards, & &1.id)

      Repo.exists?(
        from(bm in BoardModerator,
          where: bm.board_id in ^board_ids and bm.user_id == ^user_id
        )
      )
    end
  end

  def board_moderator_for_any?(_boards, _user), do: false

  @doc """
  Ensures the `:boards` association is loaded, skipping the query when already present.
  """
  def ensure_boards_loaded(article) do
    if Ecto.assoc_loaded?(article.boards), do: article, else: Repo.preload(article, :boards)
  end

  @doc """
  Returns true if the user can moderate the article (admin, global moderator,
  or board moderator of any board the article belongs to).
  For boardless articles, falls back to admin/moderator role check.
  """
  @spec can_moderate_article?(map() | nil, %Article{}) :: boolean()
  def can_moderate_article?(_user = nil, _article), do: false

  def can_moderate_article?(user, article) do
    article = ensure_boards_loaded(article)

    if article.boards == [] do
      user.role.name in ["admin", "moderator"]
    else
      board_moderator_for_any?(article.boards, user)
    end
  end

  @doc """
  Returns true if the user can comment on the article.
  Requires: user is authenticated, article is not locked, and user can post
  in at least one of the article's boards (or can create content if boardless).
  """
  @spec can_comment_on_article?(map() | nil, %Article{}) :: boolean()
  def can_comment_on_article?(_user = nil, _article), do: false

  def can_comment_on_article?(user, article) do
    article = ensure_boards_loaded(article)

    if article.locked do
      false
    else
      if article.boards == [] do
        Auth.can_create_content?(user)
      else
        Enum.any?(article.boards, &can_post_in_board?(&1, user))
      end
    end
  end

  # --- Granular Article/Comment Permission Checks ---

  @doc """
  Returns true if the user can edit the article (author or admin only).
  Board moderators cannot edit others' articles.
  """
  @spec can_edit_article?(map(), %Article{}) :: boolean()
  def can_edit_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_edit_article?(%{id: uid}, %{user_id: uid}), do: true
  def can_edit_article?(_, _), do: false

  @doc """
  Returns true if the user can delete the article (author, admin, or board moderator).
  """
  @spec can_delete_article?(map(), %Article{}) :: boolean()
  def can_delete_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_delete_article?(%{id: uid}, %{user_id: uid}), do: true

  def can_delete_article?(user, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_any?(article.boards, user)
  end

  @doc """
  Returns true if the user can pin the article (admin or board moderator).
  """
  def can_pin_article?(%{role: %{name: "admin"}}, _article), do: true

  def can_pin_article?(user, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_any?(article.boards, user)
  end

  @doc """
  Returns true if the user can lock the article (admin or board moderator).
  """
  def can_lock_article?(user, article), do: can_pin_article?(user, article)

  @doc """
  Returns true if the user can delete the comment (author, admin, or board moderator).
  """
  @spec can_delete_comment?(map(), %Comment{}, %Article{}) :: boolean()
  def can_delete_comment?(%{role: %{name: "admin"}}, _comment, _article), do: true
  def can_delete_comment?(%{id: uid}, %{user_id: uid}, _article), do: true

  def can_delete_comment?(user, _comment, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_any?(article.boards, user)
  end

  @doc """
  Returns true if the user can forward an article.

  Admins and authors can always forward. For other authenticated users,
  the article must have `forwardable: true` and visibility must be
  `public` or `unlisted`.
  """
  def can_forward_article?(nil, _article), do: false
  def can_forward_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_forward_article?(%{id: uid}, %{user_id: uid}), do: true

  def can_forward_article?(_user, article) do
    article.forwardable and article.visibility in ["public", "unlisted"]
  end

  @doc """
  Returns true if the user can forward a feed item to a board.

  Admins can always forward. Other authenticated users can forward
  feed items with `public` or `unlisted` visibility.
  """
  def can_forward_feed_item?(nil, _feed_item), do: false
  def can_forward_feed_item?(%{role: %{name: "admin"}}, _feed_item), do: true

  def can_forward_feed_item?(_user, feed_item) do
    feed_item.visibility in ["public", "unlisted"]
  end

  @doc """
  Returns true if the user can forward a comment to a board.

  Admins and comment authors can always forward. Other authenticated
  users can forward comments with `public` or `unlisted` visibility.
  """
  def can_forward_comment?(nil, _comment), do: false
  def can_forward_comment?(%{role: %{name: "admin"}}, _comment), do: true
  def can_forward_comment?(%{id: uid}, %{user_id: uid}), do: true

  def can_forward_comment?(_user, comment) do
    comment.visibility in ["public", "unlisted"]
  end

  @doc """
  Returns true if the user is the article author or an admin.
  """
  def article_author_or_admin?(nil, _article), do: false
  def article_author_or_admin?(%{role: %{name: "admin"}}, _article), do: true
  def article_author_or_admin?(%{id: uid}, %{user_id: uid}), do: true
  def article_author_or_admin?(_, _), do: false

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
end
