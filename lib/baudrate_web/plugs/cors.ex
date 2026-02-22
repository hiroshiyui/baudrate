defmodule BaudrateWeb.Plugs.CORS do
  @moduledoc """
  Plug that sets CORS headers on ActivityPub GET endpoints.

  All AP GET endpoints serve only public data, so `Access-Control-Allow-Origin`
  is set to `*`. OPTIONS preflight requests receive a 204 response with the
  appropriate allow headers.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "accept, content-type")
    |> handle_preflight()
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp handle_preflight(conn), do: conn
end
