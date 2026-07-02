defmodule BaudrateWeb.RateLimiter.Hammer do
  @moduledoc """
  Rate limiter backend that delegates to the Hammer 7 store `BaudrateWeb.RateLimit`.

  `BaudrateWeb.RateLimit.hit/3` returns `{:allow, count}` or `{:deny, retry_after_ms}`,
  which already matches the `BaudrateWeb.RateLimiter` behaviour contract.
  """

  @behaviour BaudrateWeb.RateLimiter

  @impl true
  def check_rate(bucket, scale_ms, limit) do
    BaudrateWeb.RateLimit.hit(bucket, scale_ms, limit)
  end
end
