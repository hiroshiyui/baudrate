defmodule Baudrate.Content.Boards do
  @moduledoc """
  Board CRUD, board moderator management, and SysOp board seeding.

  Manages the board hierarchy, board cache integration, federation
  toggle, and board moderator assignments.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup

  alias Baudrate.Auth.ReservedHandle

  alias Baudrate.Content.{
    Article,
    Board,
    BoardArticle,
    BoardCache,
    BoardModerator,
    Filters
  }

  # --- Boards ---

  @doc """
  Returns top-level boards (no parent), ordered by position.
  """
  def list_top_boards do
    if board_cache_enabled?() do
      BoardCache.top_boards()
    else
      from(b in Board, where: is_nil(b.parent_id), order_by: b.position)
      |> Repo.all()
    end
  end

  @doc """
  Returns top-level boards visible to the given user, ordered by position.
  Guests (nil user) only see boards with `min_role_to_view == "guest"`.
  """
  def list_visible_top_boards(user) do
    level = if user, do: Setup.role_level(user.role.name), else: 0

    list_top_boards()
    |> Enum.filter(&(Setup.role_level(&1.min_role_to_view) <= level))
  end

  @doc """
  Returns `%{board_id => DateTime}` for the newest activity in each board.

  A board with nothing in it is absent from the map rather than present with
  `nil`, so a caller renders "no activity yet" by missing key rather than by
  comparing against a sentinel.

  Activity rolls up from sub-boards: a parent is as recent as its most recent
  descendant, which matches how the unread badge already behaves.

  **The filters are `ReadTracking.unread_board_ids/2`'s, deliberately and for
  the same reason.** An article nobody can open must not make a board look
  busy: the timestamp would be an existence signal for a followers-only post
  or for content from a blocked domain, and it would be attacker-controlled —
  a remote instance could keep a board looking alive with posts the reader is
  never shown. Keeping the two in step also keeps the card honest: the unread
  dot and the "last active" line are computed from the same set of rows, so
  they cannot contradict each other.

  Per-viewer blocks and mutes are **not** applied, again matching the unread
  badge. They would make this per-viewer, and a board does not become quiet
  because one of its posters is muted — the posts are still there for everyone
  else.

  `Article.last_activity_at` is maintained by `Comments`, which already
  declines to bump it for a non-servable remote reply, so a hidden comment
  cannot move a board to the top of this map either.
  """
  def last_activity_by_board([]), do: %{}

  def last_activity_by_board(board_ids) do
    descendants = descendant_board_ids_map(board_ids)
    all_desc_ids = descendants |> Map.values() |> List.flatten() |> Enum.uniq()

    by_descendant =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        where: ba.board_id in ^all_desc_ids and is_nil(a.deleted_at),
        where: is_nil(a.remote_actor_id) or a.visibility in ["public", "unlisted"],
        where:
          is_nil(a.remote_actor_id) or
            a.remote_actor_id not in subquery(Filters.hidden_actor_ids()),
        group_by: ba.board_id,
        select: {ba.board_id, max(a.last_activity_at)}
      )
      |> Repo.all()
      |> Map.new()

    board_ids
    |> Enum.reduce(%{}, fn board_id, acc ->
      descendants
      |> Map.get(board_id, [board_id])
      |> Enum.reduce(nil, fn desc_id, latest ->
        latest_datetime(latest, Map.get(by_descendant, desc_id))
      end)
      |> case do
        nil -> acc
        latest -> Map.put(acc, board_id, latest)
      end
    end)
  end

  @doc """
  Returns `%{board_id => [board_id | descendant_ids]}` for the given boards.

  Public because more than one caller needs the same rollup: the unread badge
  (`ReadTracking`) and `last_activity_by_board/1`, which must agree about what
  a board contains or the card contradicts itself.
  """
  def descendant_board_ids_map([]), do: %{}

  def descendant_board_ids_map(board_ids) do
    if board_cache_enabled?() do
      Map.new(board_ids, fn id -> {id, BoardCache.descendant_ids(id)} end)
    else
      result =
        Repo.query!(
          """
          WITH RECURSIVE tree AS (
            SELECT id, id AS root_id FROM boards WHERE id = ANY($1)
            UNION ALL
            SELECT b.id, t.root_id FROM boards b JOIN tree t ON b.parent_id = t.id
          )
          SELECT root_id, array_agg(id) FROM tree GROUP BY root_id
          """,
          [board_ids]
        )

      Map.new(result.rows, fn [root_id, ids] -> {root_id, ids} end)
    end
  end

  defp latest_datetime(a, nil), do: a
  defp latest_datetime(nil, b), do: b
  defp latest_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  @doc """
  Returns child boards of the given board, ordered by position.
  """
  def list_sub_boards(%Board{id: board_id}) do
    if board_cache_enabled?() do
      BoardCache.sub_boards(board_id)
    else
      from(b in Board, where: b.parent_id == ^board_id, order_by: b.position)
      |> Repo.all()
    end
  end

  @doc """
  Returns every board visible to the given user, flattened into hierarchy
  order: each board immediately followed by its descendants.

  `list_visible_top_boards/1` answers "what does the home page list"; this
  answers "which boards may this viewer name", which is what the board filter
  on `/search` needs. A sub-board is not reachable from the top-level list, and
  a reader who wants to search inside one should not have to find its parent
  first.

  Reads the board cache like its siblings, so rendering the filter costs no
  query. Boards hidden from the viewer are absent, so the control cannot
  become an existence signal for a private board's name.
  """
  def list_visible_boards(user) do
    level = if user, do: Setup.role_level(user.role.name), else: 0

    list_top_boards()
    |> Enum.flat_map(&flatten_board/1)
    |> Enum.filter(&(Setup.role_level(&1.min_role_to_view) <= level))
  end

  defp flatten_board(%Board{} = board) do
    [board | Enum.flat_map(list_sub_boards(board), &flatten_board/1)]
  end

  @doc """
  Returns child boards visible to the given user, ordered by position.
  """
  def list_visible_sub_boards(%Board{} = board, user) do
    level = if user, do: Setup.role_level(user.role.name), else: 0

    list_sub_boards(board)
    |> Enum.filter(&(Setup.role_level(&1.min_role_to_view) <= level))
  end

  @doc """
  Returns the ancestor chain for a board, from root to the board itself.

  Walks the `parent_id` chain upward (max 10 levels to prevent infinite loops).
  """
  def board_ancestors(%Board{} = board) do
    if board_cache_enabled?() do
      BoardCache.ancestors(board.id)
    else
      do_board_ancestors(board, [], 10)
    end
  end

  defp do_board_ancestors(%Board{parent_id: nil} = board, acc, _remaining) do
    [board | acc]
  end

  defp do_board_ancestors(_board, acc, 0), do: acc

  defp do_board_ancestors(%Board{parent_id: parent_id} = board, acc, remaining) do
    case Repo.get(Board, parent_id) do
      nil -> [board | acc]
      parent -> do_board_ancestors(parent, [board | acc], remaining - 1)
    end
  end

  @doc """
  Fetches a board by ID, returning `{:ok, board}` or `{:error, :not_found}`.
  """
  @spec get_board(term()) :: {:ok, %Board{}} | {:error, :not_found}
  def get_board(id) do
    if board_cache_enabled?() do
      BoardCache.get(id)
    else
      case Repo.get(Board, id) do
        nil -> {:error, :not_found}
        board -> {:ok, board}
      end
    end
  end

  @doc """
  Fetches a board by ID or raises `Ecto.NoResultsError`.
  """
  @spec get_board!(term()) :: %Board{}
  def get_board!(id) do
    if board_cache_enabled?() do
      case BoardCache.get(id) do
        {:ok, board} -> board
        {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Board
      end
    else
      Repo.get!(Board, id)
    end
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
  @spec create_board(map()) :: {:ok, %Board{}} | {:error, Ecto.Changeset.t()}
  def create_board(attrs) do
    result =
      %Board{}
      |> Board.changeset(attrs)
      |> Repo.insert()

    with {:ok, _} <- result, true <- board_cache_enabled?() do
      BoardCache.refresh()
    end

    result
  end

  @doc """
  Updates a board using `update_changeset` (slug excluded).

  A board is a `Group` actor, so a change to its name, description or avatar
  is a change remote followers should see. `Federation.update_actor/3` sends
  an `Update(Group)` when the rendered document differs and nothing when it
  does not — so editing a board's `min_role_to_post`, which no peer can see,
  costs no delivery. The activity commits with the change (ADR 0034); the
  cache refresh stays outside, because it must happen after the commit and
  has nothing to do with federation.
  """
  @spec update_board(%Board{}, map()) :: {:ok, %Board{}} | {:error, Ecto.Changeset.t()}
  def update_board(%Board{} = board, attrs) do
    result =
      Baudrate.Federation.update_actor(:board, board, fn ->
        board
        |> Board.update_changeset(attrs)
        |> Repo.update()
      end)

    with {:ok, _} <- result, true <- board_cache_enabled?() do
      BoardCache.refresh()
    end

    result
  end

  @doc """
  Deletes a board if it has no linked articles.

  Returns `{:error, :protected}` if the board is the SysOp board.
  Returns `{:error, :has_articles}` if the board has articles.
  """
  @spec delete_board(%Board{}) ::
          {:ok, %Board{}} | {:error, :protected | :has_articles | :has_children}
  def delete_board(%Board{slug: "sysop"}), do: {:error, :protected}

  def delete_board(%Board{} = board) do
    article_count =
      Repo.one(from(ba in BoardArticle, where: ba.board_id == ^board.id, select: count()))

    child_count =
      Repo.one(from(b in Board, where: b.parent_id == ^board.id, select: count()))

    cond do
      article_count > 0 ->
        {:error, :has_articles}

      child_count > 0 ->
        {:error, :has_children}

      true ->
        result =
          Repo.transaction(fn ->
            case Repo.delete(board) do
              {:ok, deleted_board} ->
                now = DateTime.utc_now() |> DateTime.truncate(:second)

                %ReservedHandle{}
                |> ReservedHandle.changeset(%{
                  handle: deleted_board.slug,
                  handle_type: "board",
                  reserved_at: now
                })
                |> Repo.insert!(on_conflict: :nothing)

                deleted_board

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)

        with {:ok, _} <- result, true <- board_cache_enabled?() do
          BoardCache.refresh()
        end

        result
    end
  end

  @doc """
  Toggles the `ap_enabled` flag on a board.

  When enabling federation, also ensures the board has an RSA keypair
  for HTTP Signature signing.
  """
  @spec toggle_board_federation(%Board{}) :: {:ok, %Board{}} | {:error, Ecto.Changeset.t()}
  def toggle_board_federation(%Board{} = board) do
    enabling = !board.ap_enabled

    result =
      if enabling do
        # Ensure keypair exists before enabling federation
        with {:ok, board} <- Baudrate.Federation.KeyStore.ensure_board_keypair(board) do
          board
          |> Ecto.Changeset.change(ap_enabled: true)
          |> Repo.update()
        end
      else
        board
        |> Ecto.Changeset.change(ap_enabled: false)
        |> Repo.update()
      end

    with {:ok, _} <- result, true <- board_cache_enabled?() do
      BoardCache.refresh()
    end

    result
  end

  @doc """
  Fetches a board by slug, or nil if not found.
  """
  @spec get_board_by_slug(String.t()) :: %Board{} | nil
  def get_board_by_slug(slug) do
    if board_cache_enabled?() do
      BoardCache.get_by_slug(slug)
    else
      Repo.get_by(Board, slug: slug)
    end
  end

  @doc """
  Fetches a board by slug or raises `Ecto.NoResultsError`.
  """
  @spec get_board_by_slug!(String.t()) :: %Board{}
  def get_board_by_slug!(slug) do
    if board_cache_enabled?() do
      case BoardCache.get_by_slug(slug) do
        nil -> raise Ecto.NoResultsError, queryable: Board
        board -> board
      end
    else
      Repo.get_by!(Board, slug: slug)
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
  IDs of the boards `user` may moderate: the boards they are a moderator of,
  and every board for staff (admins and global moderators moderate everywhere,
  like `Permissions.board_moderator?/2`). `[]` for anyone else, including
  guests.
  """
  @spec moderated_board_ids(map() | nil) :: [integer()]
  def moderated_board_ids(nil), do: []

  def moderated_board_ids(%{role: %{name: role_name}}) when role_name in ["admin", "moderator"],
    do: Repo.all(from(b in Board, select: b.id))

  def moderated_board_ids(%{id: user_id}) do
    Repo.all(from(bm in BoardModerator, where: bm.user_id == ^user_id, select: bm.board_id))
  end

  def moderated_board_ids(_user), do: []

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

      BoardCache.refresh()
      {:ok, board}
    end
  end

  defp board_cache_enabled? do
    Application.get_env(:baudrate, :settings_cache_enabled, true)
  end
end
