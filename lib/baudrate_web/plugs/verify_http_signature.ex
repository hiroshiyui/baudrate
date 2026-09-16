defmodule BaudrateWeb.Plugs.VerifyHTTPSignature do
  @moduledoc """
  Verifies HTTP Signatures on incoming ActivityPub inbox requests.

  On success, assigns `:remote_actor` to the connection.
  On failure, halts with 401 and logs the rejection.

  A blocked domain is the exception: it is answered 202 and dropped, the same
  way `InboxHandler` drops a refused activity, so the sender does not retry
  forever. Verification cannot even complete for one, because resolving the
  actor behind the signature's `keyId` refuses to fetch from a blocked domain
  (ADR 0030) — which is also what keeps us from sending it a request and
  caching a `remote_actors` row for it.
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

      {:error, :domain_blocked} ->
        Logger.info("federation.inbox_domain_blocked: ip=#{client_ip(conn)}")

        conn
        |> send_resp(202, "")
        |> halt()

      {:error, reason} ->
        Logger.warning(
          "federation.signature_rejected: reason=#{inspect(reason)} ip=#{client_ip(conn)}"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Invalid signature"}))
        |> halt()
    end
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
