defmodule Baudrate.Auth.IpBanCache do
  @moduledoc """
  ETS-backed cache of the parsed IP bans, read on every registration and
  sign-in attempt.

  The shape `Baudrate.Federation.DomainBlockCache` established: one ETS entry
  holding the whole set, written through a GenServer and read from any
  process without a call. `Baudrate.Auth.IpBans` is the only writer and calls
  `refresh/0` after every change, so a ban takes effect immediately.

  **The cache holds every ban, expired ones included.** Whether a ban is in
  force is decided by `IpBans.banned?/1` against the clock at the moment of the
  check. A cache that dropped expired rows at refresh would keep enforcing a
  ban past its end until the next write happened to reload it — the
  missed-sweep failure ADR 0029 refuses for sanctions, arriving through a
  cache instead of a job.

  When `:settings_cache_enabled` is off (the test suite), every read goes to
  the caller's database sandbox, so concurrent tests cannot see each other's
  bans.
  """

  use GenServer

  alias Baudrate.Auth.IpBans

  @table :ip_ban_cache
  @key :ranges

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The parsed bans, active or not. Never raises; reads the database if ETS is empty."
  @spec active_ranges() :: [map()]
  def active_ranges do
    if cache_enabled?() do
      case :ets.whereis(@table) != :undefined and :ets.lookup(@table, @key) do
        [{@key, ranges}] -> ranges
        # Not loaded yet: decide from the database rather than fail open.
        _ -> IpBans.ranges_from_db()
      end
    else
      IpBans.ranges_from_db()
    end
  end

  @doc """
  Reloads the bans from the database.

  The read happens in the calling process (so the Ecto sandbox applies in
  tests), then the result is written to ETS through the GenServer.
  """
  def refresh do
    if cache_enabled?() do
      GenServer.call(__MODULE__, {:update, IpBans.ranges_from_db()})
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.insert(@table, {@key, IpBans.ranges_from_db()})
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:update, ranges}, _from, state) do
    :ets.insert(@table, {@key, ranges})
    {:reply, :ok, state}
  end

  defp cache_enabled? do
    Application.get_env(:baudrate, :settings_cache_enabled, true)
  end
end
