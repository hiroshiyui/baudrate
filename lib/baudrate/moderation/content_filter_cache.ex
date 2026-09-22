defmodule Baudrate.Moderation.ContentFilterCache do
  @moduledoc """
  ETS-backed cache of the enabled content filters, compiled for matching and
  read on every post and every piece of inbound content (ADR 0065).

  The shape `Baudrate.Auth.IpBanCache` and `Baudrate.Federation.DomainBlockCache`
  established: one ETS entry holding the whole set, written through a
  GenServer and read from any process without a call.
  `Baudrate.Moderation.ContentFilters` is the only writer and calls
  `refresh/0` after every change, so a new filter applies to the next post.

  When `:settings_cache_enabled` is off (the test suite), every read goes to
  the caller's database sandbox, so concurrent tests cannot see each other's
  filters.
  """

  use GenServer

  alias Baudrate.Moderation.ContentFilters

  @table :content_filter_cache
  @key :filters

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The enabled filters, compiled. Never raises; reads the database if ETS is empty."
  @spec filters() :: [map()]
  def filters do
    if cache_enabled?() do
      case :ets.whereis(@table) != :undefined and :ets.lookup(@table, @key) do
        [{@key, filters}] -> filters
        # Not loaded yet: decide from the database rather than let a post
        # through unscreened.
        _ -> ContentFilters.compiled_from_db()
      end
    else
      ContentFilters.compiled_from_db()
    end
  end

  @doc """
  Reloads the filters from the database.

  The read happens in the calling process (so the Ecto sandbox applies in
  tests), then the result is written to ETS through the GenServer.
  """
  def refresh do
    if cache_enabled?() do
      GenServer.call(__MODULE__, {:update, ContentFilters.compiled_from_db()})
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.insert(@table, {@key, ContentFilters.compiled_from_db()})
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:update, filters}, _from, state) do
    :ets.insert(@table, {@key, filters})
    {:reply, :ok, state}
  end

  defp cache_enabled? do
    Application.get_env(:baudrate, :settings_cache_enabled, true)
  end
end
