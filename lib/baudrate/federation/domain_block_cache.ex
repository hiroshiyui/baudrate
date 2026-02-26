defmodule Baudrate.Federation.DomainBlockCache do
  @moduledoc """
  ETS-backed cache for federation domain blocking decisions.

  Maintains a single ETS entry with the current federation mode and the
  corresponding domain set (blocklist or allowlist), avoiding repeated
  DB queries on every incoming/outgoing activity.

  The cache is refreshed automatically when federation settings change
  (via `refresh/0` called from `Setup.save_settings/1`).
  """

  use GenServer

  @table :domain_block_cache
  @key :domain_config

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns true if the domain is blocked based on the cached federation mode.

  Reads directly from ETS (no GenServer call), so it's safe to call from
  any process at high frequency.
  """
  def domain_blocked?(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    case :ets.lookup(@table, @key) do
      [{@key, :allowlist, allowed}] ->
        allowed == MapSet.new() or not MapSet.member?(allowed, domain)

      [{@key, :blocklist, blocked}] ->
        MapSet.member?(blocked, domain)

      [] ->
        # Cache not yet loaded — fall back to not blocked
        false
    end
  end

  @doc """
  Reloads the domain block configuration from the database.

  The DB read happens in the calling process (important for Ecto sandbox
  in tests), then the result is written to ETS via a GenServer call.
  """
  def refresh do
    data = read_from_db()
    GenServer.call(__MODULE__, {:update, data})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    write_to_ets(read_from_db())
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:update, data}, _from, state) do
    write_to_ets(data)
    {:reply, :ok, state}
  end

  defp read_from_db do
    mode = Baudrate.Setup.get_setting("ap_federation_mode") || "blocklist"

    case mode do
      "allowlist" ->
        allowed = parse_domain_list(Baudrate.Setup.get_setting("ap_domain_allowlist") || "")
        {:allowlist, allowed}

      _ ->
        blocked = parse_domain_list(Baudrate.Setup.get_setting("ap_domain_blocklist") || "")
        {:blocklist, blocked}
    end
  end

  defp write_to_ets({mode, domain_set}) do
    :ets.insert(@table, {@key, mode, domain_set})
  end

  defp parse_domain_list(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end
end
