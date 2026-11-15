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

  alias Baudrate.Federation.{HTTPSignature, RemoteActors, Validator}
  alias Baudrate.Setup

  @exempt_prefixes ["/.well-known", "/nodeinfo"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if exempt?(conn.request_path) or not authorized_fetch_enabled?() do
      conn
    else
      with {:ok, remote_actor} <- HTTPSignature.verify_get(conn),
           :ok <- admit(remote_actor) do
        assign(conn, :remote_actor, remote_actor)
      else
        {:error, _reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "Signature required"}))
          |> halt()
      end
    end
  end

  # A valid signature from a blocked domain or a suspended actor is refused,
  # as the inbox refuses one (`InboxHandler.admit/2`). The resolver hands
  # back a cached actor without asking about blocks, so an instance blocked
  # after we had cached one of its actors kept signing GETs with that key and
  # was served every document — defeating the reason to turn this on. The
  # answer is the unsigned one: a blocked server learns nothing more.
  defp admit(remote_actor) do
    cond do
      Validator.domain_blocked?(remote_actor.domain) -> {:error, :blocked}
      RemoteActors.suspended?(remote_actor) -> {:error, :suspended}
      true -> :ok
    end
  end

  defp exempt?(path) do
    Enum.any?(@exempt_prefixes, &String.starts_with?(path, &1))
  end

  defp authorized_fetch_enabled? do
    Setup.get_setting("ap_authorized_fetch") == "true"
  end
end
