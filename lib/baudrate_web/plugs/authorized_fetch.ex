defmodule BaudrateWeb.Plugs.AuthorizedFetch do
  @moduledoc """
  Optional plug that requires HTTP Signatures on GET requests to AP endpoints.

  When the `ap_authorized_fetch` setting is `"true"`, unsigned GET requests
  receive a 401 Unauthorized response. Discovery endpoints (WebFinger,
  NodeInfo) are exempt per spec requirements.

  When disabled (default), this plug is a no-op.
  """

  @behaviour Plug

  import Plug.Conn

  alias Baudrate.Federation.HTTPSignature
  alias Baudrate.Setup

  @exempt_prefixes ["/.well-known", "/nodeinfo"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if exempt?(conn.request_path) or not authorized_fetch_enabled?() do
      conn
    else
      case HTTPSignature.verify_get(conn) do
        {:ok, remote_actor} ->
          assign(conn, :remote_actor, remote_actor)

        {:error, _reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "Signature required"}))
          |> halt()
      end
    end
  end

  defp exempt?(path) do
    Enum.any?(@exempt_prefixes, &String.starts_with?(path, &1))
  end

  defp authorized_fetch_enabled? do
    Setup.get_setting("ap_authorized_fetch") == "true"
  end
end
