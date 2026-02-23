defmodule BaudrateWeb.Plugs.RateLimit do
  @moduledoc """
  Plug for IP-based rate limiting using Hammer.

  ## Usage

      plug BaudrateWeb.Plugs.RateLimit, action: :login
      plug BaudrateWeb.Plugs.RateLimit, action: :totp
      plug BaudrateWeb.Plugs.RateLimit, action: :register

  ## Rate Limits

    * `:login` — 10 attempts per 5 minutes per IP
    * `:totp` — 15 attempts per 5 minutes per IP
    * `:register` — 5 attempts per hour per IP
    * `:activity_pub` — 120 requests per minute per IP
    * `:feeds` — 30 requests per minute per IP

  ## Bucket Naming

  Buckets are named `"action:ip"` (e.g., `"login:192.168.1.1"`), so each
  IP is rate-limited independently per action type.

  On rate limit errors (backend failure), the plug **fails open** to avoid
  blocking legitimate users due to infrastructure issues.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @limits %{
    login: {300_000, 10},
    totp: {300_000, 15},
    register: {3_600_000, 5},
    activity_pub: {60_000, 120},
    feeds: {60_000, 30}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    action = Keyword.fetch!(opts, :action)
    {scale_ms, limit} = Map.fetch!(@limits, action)
    ip = remote_ip(conn)
    bucket = "#{action}:#{ip}"

    case Hammer.check_rate(bucket, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=#{action} ip=#{ip}")

        if action == :activity_pub do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{error: "Too Many Requests"}))
          |> halt()
        else
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(429, "Too many requests. Please try again later.")
          |> halt()
        end

      {:error, reason} ->
        Logger.error("rate_limit.error: action=#{action} reason=#{inspect(reason)}")
        # Fail open to avoid blocking legitimate users on backend errors
        conn
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
