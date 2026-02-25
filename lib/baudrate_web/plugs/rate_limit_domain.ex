defmodule BaudrateWeb.Plugs.RateLimitDomain do
  @moduledoc """
  Per-domain rate limiting for ActivityPub inbox endpoints.

  Runs after HTTP Signature verification. Extracts the domain from
  the verified remote actor and applies a rate limit bucket via
  `BaudrateWeb.RateLimiter` per domain (60 requests per minute).
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @scale_ms 60_000
  @limit 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:remote_actor] do
      %{domain: domain} ->
        bucket = "ap_domain:#{domain}"

        case BaudrateWeb.RateLimiter.check_rate(bucket, @scale_ms, @limit) do
          {:allow, _count} ->
            conn

          {:deny, _limit} ->
            Logger.warning("federation.domain_rate_limited: domain=#{domain}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(429, Jason.encode!(%{error: "Rate limited"}))
            |> halt()

          {:error, reason} ->
            Logger.error(
              "federation.rate_limit_error: domain=#{domain} reason=#{inspect(reason)}"
            )

            conn
        end

      _ ->
        # No remote actor assigned (shouldn't happen after VerifyHTTPSignature)
        conn
    end
  end
end
