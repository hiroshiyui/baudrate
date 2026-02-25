defmodule BaudrateWeb.RateLimiter.Hammer do
  @moduledoc """
  Rate limiter backend that delegates to `Hammer.check_rate/3`.
  """

  @behaviour BaudrateWeb.RateLimiter

  @impl true
  def check_rate(bucket, scale_ms, limit) do
    Hammer.check_rate(bucket, scale_ms, limit)
  end
end
