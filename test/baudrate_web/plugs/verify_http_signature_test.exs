defmodule BaudrateWeb.Plugs.VerifyHTTPSignatureTest do
  use Baudrate.DataCase

  import ExUnit.CaptureLog

  alias Baudrate.Federation.HTTPSignature
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Federation.RemoteActor
  alias BaudrateWeb.Plugs.VerifyHTTPSignature

  @inbox_path "/ap/inbox"
  @actor_ap_id "https://remote.example/users/alice"
  @key_id "#{@actor_ap_id}#main-key"

  setup do
    {public_pem, private_pem} = KeyStore.generate_keypair()

    actor =
      Repo.insert!(%RemoteActor{
        ap_id: @actor_ap_id,
        username: "alice",
        domain: "remote.example",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/alice/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{actor: actor, public_pem: public_pem, private_pem: private_pem}
  end

  defp build_inbox_conn(body \\ "", opts \\ []) do
    host = Keyword.get(opts, :host, "www.example.com")

    conn = Plug.Test.conn(:post, "https://#{host}#{@inbox_path}", body)

    # Plug.Test.conn sets conn.host but NOT the "host" req_header.
    # HTTP Signature verification reads host from req_headers, so inject it.
    %{conn | req_headers: [{"host", host} | conn.req_headers]}
    |> Plug.Conn.put_req_header("content-type", "application/activity+json")
    |> Map.put(:remote_ip, {198, 51, 100, 42})
  end

  defp call_plug(conn), do: VerifyHTTPSignature.call(conn, VerifyHTTPSignature.init([]))

  # --- Error paths ---

  describe "call/2 error paths" do
    test "returns 401 when no Signature header present" do
      conn = build_inbox_conn() |> call_plug()

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for malformed Signature header" do
      conn =
        build_inbox_conn()
        |> Plug.Conn.put_req_header("signature", "garbage-not-a-signature")
        |> call_plug()

      assert conn.halted
      assert conn.status == 401
    end

    test "response body is JSON with error message" do
      conn = build_inbox_conn() |> call_plug()

      assert %{"error" => "Invalid signature"} = Jason.decode!(conn.resp_body)
    end

    test "response content-type is application/json" do
      conn = build_inbox_conn() |> call_plug()

      [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "connection is halted on error" do
      conn = build_inbox_conn() |> call_plug()

      assert conn.halted
    end

    test "logs warning with client IP" do
      log =
        capture_log(fn ->
          build_inbox_conn() |> call_plug()
        end)

      assert log =~ "federation.signature_rejected"
      assert log =~ "198.51.100.42"
    end
  end

  # --- Success path ---

  describe "call/2 success path" do
    test "full crypto roundtrip: assigns remote_actor on valid signature", %{
      actor: actor,
      private_pem: private_pem
    } do
      body = Jason.encode!(%{"type" => "Create", "actor" => @actor_ap_id})
      host = "localhost"

      # Sign the request
      signed_headers =
        HTTPSignature.sign(:post, "https://#{host}#{@inbox_path}", body, private_pem, @key_id)

      # Build conn with signed headers and raw_body assign
      conn =
        build_inbox_conn(body, host: host)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("signature", signed_headers["signature"])
        |> Plug.Conn.put_req_header("date", signed_headers["date"])
        |> Plug.Conn.put_req_header("digest", signed_headers["digest"])
        |> call_plug()

      refute conn.halted
      assert conn.assigns.remote_actor.id == actor.id
      assert conn.assigns.remote_actor.ap_id == @actor_ap_id
    end

    test "does not halt connection on valid signature", %{private_pem: private_pem} do
      body = Jason.encode!(%{"type" => "Follow"})
      host = "localhost"

      signed_headers =
        HTTPSignature.sign(:post, "https://#{host}#{@inbox_path}", body, private_pem, @key_id)

      conn =
        build_inbox_conn(body, host: host)
        |> Plug.Conn.assign(:raw_body, body)
        |> Plug.Conn.put_req_header("signature", signed_headers["signature"])
        |> Plug.Conn.put_req_header("date", signed_headers["date"])
        |> Plug.Conn.put_req_header("digest", signed_headers["digest"])
        |> call_plug()

      refute conn.halted
    end
  end
end
