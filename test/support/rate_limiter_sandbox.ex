defmodule BaudrateWeb.RateLimiter.Sandbox do
  @moduledoc """
  ETS-backed test stub for `BaudrateWeb.RateLimiter`.

  Replaces Mox for rate limiter mocking. Lookup order mirrors Ecto.Sandbox:
  `self()` → `$callers` chain → `:global` key → default `{:allow, 1}`.

  This means LiveView processes spawned by tests automatically inherit the
  test process's stub without any global/private mode switching.

  ## Usage

      # In test_helper.exs:
      BaudrateWeb.RateLimiter.Sandbox.start()

      # In individual tests:
      Sandbox.set_response({:deny, 10})
      Sandbox.set_fun(fn _bucket, _scale, _limit -> {:allow, 1} end)

      # Global default (e.g. in ConnCase setup):
      Sandbox.set_global_response({:allow, 1})
      Sandbox.set_global_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)
  """

  @behaviour BaudrateWeb.RateLimiter
  @table __MODULE__

  @doc "Creates the ETS table. Idempotent — safe to call multiple times."
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Stores a fixed response tuple for the calling process."
  def set_response(response) do
    :ets.insert(@table, {self(), {:response, response}})
    :ok
  end

  @doc "Stores a fun/3 for the calling process."
  def set_fun(fun) when is_function(fun, 3) do
    :ets.insert(@table, {self(), {:fun, fun}})
    :ok
  end

  @doc "Stores a fixed response tuple under the `:global` key."
  def set_global_response(response) do
    :ets.insert(@table, {:global, {:response, response}})
    :ok
  end

  @doc "Stores a fun/3 under the `:global` key."
  def set_global_fun(fun) when is_function(fun, 3) do
    :ets.insert(@table, {:global, {:fun, fun}})
    :ok
  end

  @impl true
  def check_rate(bucket, scale_ms, limit) do
    case lookup(self()) do
      {:response, resp} -> resp
      {:fun, fun} -> fun.(bucket, scale_ms, limit)
      nil -> {:allow, 1}
    end
  end

  defp lookup(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, value}] -> value
      [] -> lookup_callers(Process.get(:"$callers", []))
    end
  end

  defp lookup_callers([]) do
    case :ets.lookup(@table, :global) do
      [{:global, value}] -> value
      [] -> nil
    end
  end

  defp lookup_callers([caller | rest]) do
    case :ets.lookup(@table, caller) do
      [{^caller, value}] -> value
      [] -> lookup_callers(rest)
    end
  end
end
