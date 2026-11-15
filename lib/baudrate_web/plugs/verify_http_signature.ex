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
    if addressed_to_us?(conn) do
      verify(conn)
    else
      Logger.warning("federation.signature_rejected: reason=:wrong_host ip=#{client_ip(conn)}")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "Invalid signature"}))
      |> halt()
    end
  end

  # The signature covers the `host` header, but nothing compared it with
  # ours: a delivery another server legitimately received could be replayed
  # to our inbox, within the date window, by sending its original `Host`
  # (nginx forwards `$host` as given). The signed host must be this site's.
  defp addressed_to_us?(conn) do
    ours = BaudrateWeb.Endpoint.config(:url)[:host] |> to_string() |> String.downcase()

    case get_req_header(conn, "host") do
      [host] -> host |> strip_port() |> String.downcase() == ours
      _ -> false
    end
  end

  defp strip_port("[" <> _ = host), do: host |> String.split("]") |> hd() |> Kernel.<>("]")
  defp strip_port(host), do: host |> String.split(":") |> hd()

  defp verify(conn) do
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
