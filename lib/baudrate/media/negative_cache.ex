defmodule Baudrate.Media.NegativeCache do
  @moduledoc """
  Short-lived record of media URLs that failed to fetch.

  Without it, an image referenced from a popular page whose host is down would
  be re-fetched on every single view. With a one-hour TTL a dead host costs at
  most one outbound request per URL per hour.

  Backed by ETS with a periodic sweep, matching `Baudrate.Auth.WebAuthnChallenges`.
  """

  use GenServer

  @table __MODULE__
  @ttl_seconds 3600
  @sweep_interval :timer.minutes(10)

  # --- Client ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true when the URL failed recently enough to skip re-fetching."
  @spec failed?(String.t()) :: boolean()
  def failed?(url) when is_binary(url) do
    now = System.system_time(:second)

    case :ets.lookup(@table, url) do
      [{^url, expires_at}] when expires_at > now -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Records a failed fetch, suppressing retries for the TTL."
  @spec mark_failed(String.t()) :: :ok
  def mark_failed(url) when is_binary(url) do
    :ets.insert(@table, {url, System.system_time(:second) + @ttl_seconds})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    # Erlang atom `:"=<"` — Elixir's `:<=` is a different atom and silently
    # matches nothing.
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
