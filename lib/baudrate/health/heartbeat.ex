defmodule Baudrate.Health.Heartbeat do
  @moduledoc """
  When each periodic worker last completed a run, for the detailed health view
  (`Baudrate.Health`).

  A worker calls `beat/1` after a run finishes. A worker that has stopped, or
  that crashes before finishing every time it is restarted, stops beating, and
  the health view reports it stale. Being alive is not enough: a process that
  is restarted every minute is alive most of the time.

  Times are monotonic milliseconds, so a change of the system clock never makes
  a worker look stale or fresh. They live in ETS (ADR 0033: one node), owned by
  this process, which starts before the workers.
  """

  use GenServer

  @table :baudrate_health_heartbeats

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records that `worker` just completed a run."
  @spec beat(atom()) :: :ok
  def beat(worker) when is_atom(worker) do
    :ets.insert(@table, {worker, System.monotonic_time(:millisecond)})
    :ok
  rescue
    # The table is gone only while this process restarts; a missed beat is
    # harmless.
    ArgumentError -> :ok
  end

  @doc "Monotonic milliseconds of `worker`'s last completed run, or `nil`."
  @spec last(atom()) :: integer() | nil
  def last(worker) when is_atom(worker) do
    case :ets.lookup(@table, worker) do
      [{^worker, at}] -> at
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Milliseconds since the node started, as recorded when this process started."
  @spec uptime_ms() :: non_neg_integer()
  def uptime_ms do
    case :ets.lookup(@table, :__started__) do
      [{:__started__, at}] -> System.monotonic_time(:millisecond) - at
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@table, {:__started__, System.monotonic_time(:millisecond)})
    {:ok, %{}}
  end
end
