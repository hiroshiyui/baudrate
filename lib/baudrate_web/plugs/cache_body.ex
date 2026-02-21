defmodule BaudrateWeb.Plugs.CacheBody do
  @moduledoc """
  Reads and caches the raw request body in `conn.assigns.raw_body`.

  Needed because `Plug.Conn.read_body/2` can only be called once, but
  both JSON parsing and HTTP Signature digest verification need the raw body.

  Caps the body at 256 KB (configurable via federation config).
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    max_size =
      Application.get_env(:baudrate, Baudrate.Federation, [])
      |> Keyword.get(:max_payload_size, 262_144)

    case read_body(conn, length: max_size) do
      {:ok, body, conn} ->
        assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, Jason.encode!(%{error: "Payload too large"}))
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Bad request"}))
        |> halt()
    end
  end
end
