defmodule Baudrate.Content.BoardCache do
  @moduledoc """
  ETS-backed cache for board lookups.

  Caches the entire boards table as pre-computed lookup structures,
  eliminating DB queries for board listing, slug lookups, sub-board
  queries, and ancestor chain walks. Boards are small in number
  (dozens to hundreds), mutated only by admins, and fetched on
  every page — an ideal cache candidate.

  Follows the same pattern as `Baudrate.Setup.SettingsCache`:
  direct ETS reads (lock-free, no GenServer bottleneck) with
  GenServer-mediated writes. The DB read during `refresh/0` happens
  in the calling process for Ecto sandbox compatibility in tests.

  ## ETS structure

  | Key | Value | Purpose |
  |-----|-------|---------|
  | `{:by_id, id}` | board struct | O(1) lookup by ID |
  | `{:by_slug, slug}` | board struct | O(1) lookup by slug |
  | `:top_boards` | sorted board list | Root boards (parent_id == nil) |
  | `{:sub_boards, parent_id}` | sorted board list | Children of a parent |
  | `{:ancestors, board_id}` | board list | Pre-computed ancestor chain (root → board) |

  ## Cache update

  Board mutations in `Content` (`create_board/1`, `update_board/2`,
  `delete_board/1`, `toggle_board_federation/1`) call `refresh/0`
  after successful DB operations.
  """

  use GenServer

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.Board

  @table :board_cache

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, board}` for the given ID, or `{:error, :not_found}`.

  Reads directly from ETS (no GenServer call).
  """
  @spec get(term()) :: {:ok, %Board{}} | {:error, :not_found}
  def get(id) do
    case :ets.lookup(@table, {:by_id, id}) do
      [{_, board}] -> {:ok, board}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the board with the given slug, or nil if not found.

  Reads directly from ETS (no GenServer call).
  """
  @spec get_by_slug(String.t()) :: %Board{} | nil
  def get_by_slug(slug) when is_binary(slug) do
    case :ets.lookup(@table, {:by_slug, slug}) do
      [{_, board}] -> board
      [] -> nil
    end
  end

  @doc """
  Returns root boards (parent_id == nil), sorted by position.

  Reads directly from ETS (no GenServer call).
  """
  @spec top_boards() :: [%Board{}]
  def top_boards do
    case :ets.lookup(@table, :top_boards) do
      [{:top_boards, boards}] -> boards
      [] -> []
    end
  end

  @doc """
  Returns children of the given parent board, sorted by position.

  Returns an empty list if the board has no children.
  Reads directly from ETS (no GenServer call).
  """
  @spec sub_boards(term()) :: [%Board{}]
  def sub_boards(parent_id) do
    case :ets.lookup(@table, {:sub_boards, parent_id}) do
      [{_, boards}] -> boards
      [] -> []
    end
  end

  @doc """
  Returns the ancestor chain for a board, from root to the board itself.

  Returns an empty list if the board is not found.
  Reads directly from ETS (no GenServer call).
  """
  @spec ancestors(term()) :: [%Board{}]
  def ancestors(board_id) do
    case :ets.lookup(@table, {:ancestors, board_id}) do
      [{_, chain}] -> chain
      [] -> []
    end
  end

  @doc """
  Reloads all boards from the database and rebuilds the ETS cache.

  The DB read happens in the calling process (important for Ecto sandbox
  in tests), then the result is written to ETS via a GenServer call.
  """
  @spec refresh() :: :ok
  def refresh do
    boards = read_all_from_db()
    entries = build_lookup_structures(boards)
    GenServer.call(__MODULE__, {:update, entries})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    boards = read_all_from_db()
    write_to_ets(build_lookup_structures(boards))
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:update, entries}, _from, state) do
    write_to_ets(entries)
    {:reply, :ok, state}
  end

  # --- Private ---

  defp read_all_from_db do
    Repo.all(from b in Board, order_by: [asc: b.position, asc: b.id])
  end

  @doc false
  def build_lookup_structures(boards) do
    by_id = Map.new(boards, &{&1.id, &1})

    by_id_entries = Enum.map(boards, &{{:by_id, &1.id}, &1})
    by_slug_entries = Enum.map(boards, &{{:by_slug, &1.slug}, &1})

    top_boards = Enum.filter(boards, &is_nil(&1.parent_id))

    sub_boards_map =
      boards
      |> Enum.filter(& &1.parent_id)
      |> Enum.group_by(& &1.parent_id)

    sub_boards_entries = Enum.map(sub_boards_map, fn {pid, children} -> {{:sub_boards, pid}, children} end)

    ancestors_entries =
      Enum.map(boards, fn board ->
        chain = build_ancestor_chain(board, by_id, [], 10)
        {{:ancestors, board.id}, chain}
      end)

    by_id_entries ++
      by_slug_entries ++
      sub_boards_entries ++
      ancestors_entries ++
      [{:top_boards, top_boards}]
  end

  defp build_ancestor_chain(%Board{parent_id: nil} = board, _by_id, acc, _remaining) do
    [board | acc]
  end

  defp build_ancestor_chain(_board, _by_id, acc, 0), do: acc

  defp build_ancestor_chain(%Board{parent_id: parent_id} = board, by_id, acc, remaining) do
    case Map.get(by_id, parent_id) do
      nil -> [board | acc]
      parent -> build_ancestor_chain(parent, by_id, [board | acc], remaining - 1)
    end
  end

  defp write_to_ets(entries) do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)
  end
end
