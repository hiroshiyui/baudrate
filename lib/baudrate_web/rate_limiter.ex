defmodule BaudrateWeb.RateLimiter do
  @moduledoc """
  Behaviour for rate limiting backends.

  Abstracts `check_rate/3` behind a behaviour so the implementation can be
  swapped in tests without touching Hammer's global ETS state.

  The concrete backend is read from application config:

      config :baudrate, :rate_limiter, BaudrateWeb.RateLimiter.Hammer

  Defaults to `BaudrateWeb.RateLimiter.Hammer` when not configured.
  """

  @type allow_result :: {:allow, non_neg_integer()}
  @type deny_result :: {:deny, non_neg_integer()}
  @type error_result :: {:error, term()}

  @callback check_rate(bucket :: String.t(), scale_ms :: pos_integer(), limit :: pos_integer()) ::
              allow_result() | deny_result() | error_result()

  @doc "Delegates to the configured rate limiter backend."
  @spec check_rate(String.t(), pos_integer(), pos_integer()) ::
          allow_result() | deny_result() | error_result()
  def check_rate(bucket, scale_ms, limit) do
    impl().check_rate(bucket, scale_ms, limit)
  end

  defp impl do
    Application.get_env(:baudrate, :rate_limiter, BaudrateWeb.RateLimiter.Hammer)
  end
end
