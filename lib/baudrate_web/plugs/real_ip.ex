defmodule BaudrateWeb.Plugs.RealIp do
  @moduledoc """
  Plug to extract the real client IP from a reverse proxy header.

  In production, `conn.remote_ip` is typically the reverse proxy's IP,
  making per-IP rate limiting ineffective (all requests share one bucket).
  This plug reads the original client IP from a configurable header
  (e.g., `x-forwarded-for`) and overwrites `conn.remote_ip`.

  ## Configuration

  Only activates when a header is configured (safe no-op by default):

      # config/prod.exs
      config :baudrate, BaudrateWeb.Plugs.RealIp, header: "x-forwarded-for"

  ## Security

  The operator **must** configure their reverse proxy to **set** (not append
  to) the configured header. If the proxy appends, an attacker can inject
  a spoofed IP by sending a crafted header value. This plug extracts the
  **leftmost** (first) IP, which is the client IP when the proxy sets the
  header.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case config_header() do
      nil -> conn
      header -> extract_ip(conn, header)
    end
  end

  defp config_header do
    Application.get_env(:baudrate, __MODULE__, [])
    |> Keyword.get(:header)
  end

  defp extract_ip(conn, header) do
    case get_req_header(conn, header) do
      [value | _] ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> parse_ip()
        |> case do
          {:ok, ip} -> %{conn | remote_ip: ip}
          :error -> conn
        end

      [] ->
        conn
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end
end
