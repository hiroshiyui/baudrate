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
  Authorizes a user to post into every board in `board_ids`.

  Loads the boards by ID and verifies that each one passes
  `can_post_in_board?/2`. Returns `{:ok, boards}` preserving the input
  order when every board is postable, `{:error, :not_found}` if any ID
  does not resolve to an existing board, or `{:error, :forbidden}` if
  the user lacks permission on at least one board.

  Callers that accept `board_ids` from untrusted input (form submissions,
  API requests) **must** run this check before passing the IDs to
  `Content.create_article/3` — the create function itself does not
  enforce per-board authorization.
  """
  @spec authorize_post_in_boards(map() | nil, [integer()]) ::
          {:ok, [%Board{}]} | {:error, :not_found | :forbidden}
  def authorize_post_in_boards(_user, []), do: {:ok, []}

  def authorize_post_in_boards(user, board_ids) when is_list(board_ids) do
    ids = Enum.uniq(board_ids)

    boards = Repo.all(from(b in Board, where: b.id in ^ids))

    cond do
      length(boards) != length(ids) ->
        {:error, :not_found}

      Enum.all?(boards, &can_post_in_board?(&1, user)) ->
        by_id = Map.new(boards, &{&1.id, &1})
        {:ok, Enum.map(board_ids, &Map.fetch!(by_id, &1))}

      true ->
        {:error, :forbidden}
    end
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
  Whether the user moderates **every** one of these boards.

  What happens to a cross-posted article happens in each board it is in, so
  deleting, pinning or locking it needs moderation rights on all of them
  (P1-D5); removing it from one board needs rights on that board only
  (`can_remove_from_board?/3`). Admins and global moderators moderate
  everywhere. A member with no boards at all is not a moderator of "all" of
  them.
  """
  @spec board_moderator_for_all?([%Board{}], map() | nil) :: boolean()
  def board_moderator_for_all?(boards, %{id: user_id, role: %{name: role_name}})
      when is_list(boards) do
    cond do
      role_name in ["admin", "moderator"] ->
        true

      boards == [] ->
        false

      true ->
        board_ids = Enum.map(boards, & &1.id)

        moderated =
          Repo.all(
            from(bm in BoardModerator,
              where: bm.board_id in ^board_ids and bm.user_id == ^user_id,
              select: bm.board_id
            )
          )

        MapSet.subset?(MapSet.new(board_ids), MapSet.new(moderated))
    end
  end

  def board_moderator_for_all?(_boards, _user), do: false

  @doc """
  Whether the user may take this article out of one board: its author, staff,
  or a moderator of that board (P1-D5). The article must be in the board.
  """
  @spec can_remove_from_board?(map() | nil, %Article{}, %Board{}) :: boolean()
  def can_remove_from_board?(nil, _article, _board), do: false

  def can_remove_from_board?(user, article, %Board{} = board) do
    article_author_or_admin?(user, article) or board_moderator?(board, user)
  end

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
  Returns true if the user can delete the article: its author, an admin, or a
  moderator of **every** board it is in (P1-D5).
  """
  @spec can_delete_article?(map(), %Article{}) :: boolean()
  def can_delete_article?(%{role: %{name: "admin"}}, _article), do: true
  def can_delete_article?(%{id: uid}, %{user_id: uid}), do: true

  def can_delete_article?(user, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_all?(article.boards, user)
  end

  @doc """
  Returns true if the user can pin the article: an admin, or a moderator of
  **every** board it is in (P1-D5).
  """
  def can_pin_article?(%{role: %{name: "admin"}}, _article), do: true

  def can_pin_article?(user, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_all?(article.boards, user)
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

  # A comment belongs to the article, which may live in several boards, so
  # removing it removes it from all of them: the same rule as the article
  # (P1-D5).
  def can_delete_comment?(user, _comment, article) do
    article = ensure_boards_loaded(article)
    board_moderator_for_all?(article.boards, user)
  end

  @doc """
  Returns true if the user can edit the comment — **the author, and nobody
  else** (ADR 0060).

  Deliberately narrower than `can_edit_article?/2`, which admits an admin. An
  admin editing a comment rewrites attributed speech with nothing on the page
  to distinguish it from the author's own words, and since the edit history is
  public it would put words in that author's history too. Moderation's tool
  for a comment that has to go is deletion, which admins and board moderators
  already have; there is no version of "fix somebody else's comment" that a
  reader could tell from impersonation.

  A remote comment is never editable here: it belongs to the instance that
  minted it, which sends its own `Update(Note)`.
  """
  @spec can_edit_comment?(map() | nil, %Comment{}) :: boolean()
  def can_edit_comment?(%{id: uid}, %Comment{user_id: uid}) when not is_nil(uid), do: true
  def can_edit_comment?(_, _), do: false

  @doc """
  Returns true if the user can forward an article.

  Admins and authors can always forward. For other authenticated users,
  the article must have `forwardable: true` and visibility must be
  `public` or `unlisted`.
  """
  def can_forward_article?(nil, _article), do: false

  # The admin and author exemptions cover `forwardable` and a *local* article's
  # visibility, which are the author's own choices about their own post. They
  # deliberately do **not** cover a remote row that arrived addressed to
  # followers or to one person: forwarding re-publishes it to a board, and the
  # board's outbox stamps it `as:Public`. That is someone else's audience
  # decision on someone else's instance, so it is refused to everyone —
  # including admins, as CLAUDE.md and ADR 0030 both say — and it was not,
  # because this clause matched first and returned before any visibility test.
  def can_forward_article?(user, article) do
    cond do
      not remote_public?(article) -> false
      match?(%{role: %{name: "admin"}}, user) -> unrestricted?(user)
      article.user_id == user.id -> unrestricted?(user)
      true -> unrestricted?(user) and article.forwardable and local_public?(article)
    end
  end

  # A remote row keeps the visibility it was ingested with; a local one is
  # public on this site whatever its addressing, so only remote rows are
  # gated here.
  defp remote_public?(%{remote_actor_id: rid, visibility: vis}) when not is_nil(rid),
    do: vis in ["public", "unlisted"]

  defp remote_public?(_article), do: true

  defp local_public?(article), do: article.visibility in ["public", "unlisted"]

  @doc """
  Returns true if the user can forward a timeline item to a board.

  **There is no admin exemption here**, unlike `can_forward_article?/2` and
  `can_forward_comment?/2`: an authenticated user — admin or not — can forward
  only a timeline item with `public` or `unlisted` visibility that is reachable
  from their own timeline (`Federation.timeline_item_accessible?/2`).
  `timeline_items` rows are global, so without the reachability check any user
  could forward an item belonging to an actor they do not follow; and
  forwarding re-publishes the item to a board's fediverse followers, which a
  `followers_only` or `direct` item must never reach whoever asks for it.
  """
  def can_forward_timeline_item?(nil, _timeline_item), do: false

  # No admin branch. It used to skip both checks below, and forwarding calls
  # `Publisher.publish_article_forwarded/2` — so an admin could take a
  # `followers_only` or `direct` item they were never addressed and re-publish
  # it to a board's fediverse followers. CLAUDE.md is explicit that the
  # row-level gates refuse non-public remote rows to everyone including
  # admins; an admin who wants an item can follow its actor.
  def can_forward_timeline_item?(user, timeline_item) do
    unrestricted?(user) and timeline_item.visibility in ["public", "unlisted"] and
      Baudrate.Federation.timeline_item_accessible?(user, timeline_item)
  end

  # Forwarding republishes someone else's words under your name on another
  # board, so it is an interaction: a moved, silenced or suspended account
  # cannot do it (ADR 0029).
  defp unrestricted?(user), do: Baudrate.Auth.can_interact?(user)

  @doc """
  Returns true if the user can forward a comment to a board.

  Admins and comment authors can always forward. Other authenticated
  users can forward comments with `public` or `unlisted` visibility.
  """
  # `unrestricted?/1` on every clause, like its two siblings above. Forwarding
  # is an interaction, so a silenced, suspended, moved or terms-pending
  # account must not do it (ADR 0029). The outcome was already correct — the
  # context's `can_post_in_board?/2` routes through `Auth.can_create_content?/1`
  # — but the check was in the wrong place, so the day that stops being true
  # comment forwarding would lose the gate silently while the other two kept
  # it.
  def can_forward_comment?(nil, _comment), do: false

  def can_forward_comment?(%{role: %{name: "admin"}} = user, _comment), do: unrestricted?(user)

  def can_forward_comment?(%{id: uid} = user, %{user_id: uid}), do: unrestricted?(user)

  def can_forward_comment?(user, comment) do
    unrestricted?(user) and comment.visibility in ["public", "unlisted"]
  end

  @doc """
  Returns true if the user is the article author or an admin.
  """
  def article_author_or_admin?(nil, _article), do: false
  def article_author_or_admin?(%{role: %{name: "admin"}}, _article), do: true
  def article_author_or_admin?(%{id: uid}, %{user_id: uid}), do: true
  def article_author_or_admin?(_, _), do: false

  @typedoc "A local user, or the id of one. `nil` is never authorized."
  @type actor :: %Baudrate.Setup.User{} | pos_integer() | nil

  @doc """
  Re-checks a moderation right at the moment it is used, against freshly
  loaded actor state (ADR 0016).

  The `can_*?` predicates above answer "should the UI offer this?". These
  answer "may this happen?", and the difference is time: `ArticleLive` computed
  `can_pin` once in `mount/3` and read it on an event that could arrive an hour
  later, so a board moderator removed in between kept pin, lock and delete on
  any page they had left open. A role change revokes sessions and so closed the
  worst case; losing a board-moderator grant does not.

  The actor is reloaded rather than trusted as passed. That is what "freshly
  loaded" means, and it also stops a `%User{}` whose `:role` was never
  preloaded from failing the admin clause and being judged a non-moderator.

  Each returns `:ok` or `{:error, :unauthorized}`.
  """
  @spec authorize_pin(actor(), %Article{}) :: :ok | {:error, :unauthorized}
  def authorize_pin(actor, %Article{} = article),
    do: check(actor, &can_pin_article?(&1, article))

  @spec authorize_lock(actor(), %Article{}) :: :ok | {:error, :unauthorized}
  def authorize_lock(actor, %Article{} = article),
    do: check(actor, &can_lock_article?(&1, article))

  @spec authorize_delete_article(actor(), %Article{}) :: :ok | {:error, :unauthorized}
  def authorize_delete_article(actor, %Article{} = article),
    do: check(actor, &can_delete_article?(&1, article))

  @spec authorize_edit_article(actor(), %Article{}) :: :ok | {:error, :unauthorized}
  def authorize_edit_article(actor, %Article{} = article),
    do: check(actor, &can_edit_article?(&1, article))

  @spec authorize_delete_comment(actor(), %Comment{}, %Article{}) ::
          :ok | {:error, :unauthorized}
  def authorize_delete_comment(actor, %Comment{} = comment, %Article{} = article),
    do: check(actor, &can_delete_comment?(&1, comment, article))

  @spec authorize_edit_comment(actor(), %Comment{}) :: :ok | {:error, :unauthorized}
  def authorize_edit_comment(actor, %Comment{} = comment),
    do: check(actor, &can_edit_comment?(&1, comment))

  defp check(actor, predicate) do
    case reload(actor) do
      nil -> {:error, :unauthorized}
      user -> if predicate.(user), do: :ok, else: {:error, :unauthorized}
    end
  end

  defp reload(%Setup.User{id: id}), do: Auth.get_user(id)
  defp reload(id) when is_integer(id) and id > 0, do: Auth.get_user(id)
  defp reload(_), do: nil

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
