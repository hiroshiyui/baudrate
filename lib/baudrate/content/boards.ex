defmodule Baudrate.Content.Boards do
  @moduledoc """
  Board CRUD, board moderator management, and SysOp board seeding.

  Manages the board hierarchy, board cache integration, federation
  toggle, and board moderator assignments.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup

  alias Baudrate.Content.{
    Board,
    BoardArticle,
    BoardCache,
    BoardModerator
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
  """
  @spec update_board(%Board{}, map()) :: {:ok, %Board{}} | {:error, Ecto.Changeset.t()}
  def update_board(%Board{} = board, attrs) do
    result =
      board
      |> Board.update_changeset(attrs)
      |> Repo.update()

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
        result = Repo.delete(board)

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

      {:ok, board}
    end
  end

  defp board_cache_enabled? do
    Application.get_env(:baudrate, :settings_cache_enabled, true)
  end
end
