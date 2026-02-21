defmodule BaudrateWeb.Plugs.VerifyHTTPSignature do
  @moduledoc """
  Verifies HTTP Signatures on incoming ActivityPub inbox requests.

  On success, assigns `:remote_actor` to the connection.
  On failure, halts with 401 and logs the rejection.
  """

  import Plug.Conn
  require Logger

  alias Baudrate.Federation.HTTPSignature

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case HTTPSignature.verify(conn) do
      {:ok, remote_actor} ->
        assign(conn, :remote_actor, remote_actor)

      {:error, reason} ->
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        Logger.warning("federation.signature_rejected: reason=#{inspect(reason)} ip=#{ip}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Invalid signature"}))
        |> halt()
    end
  end
end
