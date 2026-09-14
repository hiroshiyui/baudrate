defmodule Baudrate.DataPortability.DownloadNonces do
  @moduledoc """
  Single-use nonces for data export download tokens (ADR 0023 §16).

  After step-up re-authentication, `DataExportLive` signs a short-lived
  `Phoenix.Token` carrying a random nonce, and records the nonce here. The
  download endpoint takes the nonce atomically (`:ets.take/2`), so a token
  works exactly once even inside its 60-second validity. A replayed token, for
  example one copied from browser devtools or a proxy log, fails.

  Entries expire after 90 seconds and are swept periodically. The store is
  per node. A token issued on one node and redeemed on another fails closed:
  the user re-authenticates and tries again.
  """

  use GenServer

  @table :data_export_download_nonces
  @ttl_seconds 90
  @sweep_interval_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Generates and stores a nonce bound to `user_id`. Returns the nonce."
  @spec issue(integer()) :: String.t()
  def issue(user_id) when is_integer(user_id) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ets.insert(@table, {nonce, user_id, System.system_time(:second) + @ttl_seconds})
    nonce
  end

  @doc """
  Consumes `nonce` for `user_id`. Returns `:ok` exactly once for a live nonce
  that belongs to the user, and `:error` otherwise.
  """
  @spec consume(term(), integer()) :: :ok | :error
  def consume(nonce, user_id) when is_binary(nonce) and is_integer(user_id) do
    case :ets.take(@table, nonce) do
      [{^nonce, ^user_id, expires_at}] ->
        if System.system_time(:second) <= expires_at, do: :ok, else: :error

      _ ->
        :error
    end
  end

  def consume(_nonce, _user_id), do: :error

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
