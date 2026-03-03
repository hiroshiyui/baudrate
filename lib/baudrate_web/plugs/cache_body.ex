defmodule BaudrateWeb.Plugs.CacheBody do
  @moduledoc """
  Ensures the raw request body is available in `conn.assigns.raw_body` and
  enforces the federation payload size limit (256 KB by default).

  If `CacheBodyReader` already cached the body (via `Plug.Parsers`
  `body_reader` option), this plug just enforces the size limit.
  Otherwise, it reads and caches the body directly.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{raw_body: raw_body}} = conn, _opts) when is_binary(raw_body) do
    max_size =
      Application.get_env(:baudrate, Baudrate.Federation, [])
      |> Keyword.get(:max_payload_size, 262_144)

    if byte_size(raw_body) > max_size do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(413, Jason.encode!(%{error: "Payload too large"}))
      |> halt()
    else
      conn
    end
  end

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
