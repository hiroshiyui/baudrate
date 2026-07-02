defmodule BaudrateWeb.RateLimit do
  @moduledoc """
  Hammer 7 rate-limiting store, backed by ETS.

  Hammer 7 replaced the global `Hammer.check_rate/3` + `config :hammer, backend:`
  setup of v6 with a per-app module that `use`s Hammer and is started in the
  supervision tree. This module is that store; `BaudrateWeb.RateLimiter.Hammer`
  delegates to its `hit/3`.

  `hit(key, scale_ms, limit)` returns `{:allow, count}` or `{:deny, retry_after_ms}`.
  """
  use Hammer, backend: :ets

  @doc """
  Clears every rate-limit bucket from the ETS store.

  Test-support helper: Hammer 7 dropped v6's `Hammer.delete_buckets/1`, and the
  ETS table is named after this module, so tests reset state by emptying it.
  Safe to call before each test for isolation.
  """
  def reset_all do
    :ets.delete_all_objects(__MODULE__)
    :ok
  end
end
