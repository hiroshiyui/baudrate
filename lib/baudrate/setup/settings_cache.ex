defmodule Baudrate.Setup.SettingsCache do
  @moduledoc """
  ETS-backed cache for site settings.

  Maintains individual `{key, value}` rows in a named ETS table, avoiding
  repeated DB queries on every `Setup.get_setting/1` call. Settings change
  rarely (admin action only), making them an ideal cache candidate.

  Follows the same pattern as `Baudrate.Federation.DomainBlockCache`:
  direct ETS reads (lock-free, no GenServer bottleneck) with
  GenServer-mediated writes. The DB read during `refresh/0` happens in
  the calling process for Ecto sandbox compatibility in tests.

  ## Cache update strategies

  - `put/2` — updates a single key in the cache. Used by `set_setting/2`
    to avoid replacing the entire cache (prevents race conditions in tests
    where concurrent sandbox transactions each see different DB state).
  - `refresh/0` — full reload from DB. Used at startup and after bulk
    operations like `complete_setup/2`.
  """

  use GenServer

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @table :settings_cache

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the value for the given setting key, or nil if not found.

  Reads directly from ETS (no GenServer call), so it's safe to call from
  any process at high frequency.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc """
  Updates a single key in the cache.

  Used by `Setup.set_setting/2` to keep the cache in sync without
  replacing the entire cache contents.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) when is_binary(key) and is_binary(value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc """
  Reloads all settings from the database into the ETS cache.

  The DB read happens in the calling process (important for Ecto sandbox
  in tests), then the result is written to ETS via a GenServer call.
  """
  @spec refresh() :: :ok
  def refresh do
    settings = read_all_from_db()
    GenServer.call(__MODULE__, {:update, settings})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    write_to_ets(read_all_from_db())
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(@table, {key, value})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, settings}, _from, state) do
    write_to_ets(settings)
    {:reply, :ok, state}
  end

  defp read_all_from_db do
    Repo.all(from s in Setting, select: {s.key, s.value})
  end

  defp write_to_ets(settings) do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, settings)
  end
end
