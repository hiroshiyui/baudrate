defmodule Baudrate.Federation.HTTPClientTest do
  use ExUnit.Case, async: true

  alias Baudrate.Federation.HTTPClient

  describe "validate_url/1" do
    # Note: validate_url does DNS resolution, so we can't test with fake domains.
    # We test the scheme/host validation and private_ip? separately.

    test "rejects HTTP URLs for non-localhost hosts" do
      assert {:error, :https_required} =
               HTTPClient.validate_url("http://remote.example/users/alice")
    end

    test "rejects URLs with no host" do
      assert {:error, _} = HTTPClient.validate_url("https:///path")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_url} = HTTPClient.validate_url(nil)
      assert {:error, :invalid_url} = HTTPClient.validate_url(123)
    end

    test "rejects URLs with empty host" do
      assert {:error, _} = HTTPClient.validate_url("https://")
    end

    test "rejects ftp scheme" do
      assert {:error, :https_required} = HTTPClient.validate_url("ftp://remote.example/file")
    end
  end

  describe "get/2" do
    test "returns body on 200" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"type":"Person"}))
      end)

      assert {:ok, %{status: 200, body: body}} =
               HTTPClient.get("https://remote.example/users/alice")

      assert body =~ "Person"
    end

    test "returns http_error on 404" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:error, {:http_error, 404, "Not Found"}} =
               HTTPClient.get("https://remote.example/users/missing")
    end

    test "returns http_error on 500" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               HTTPClient.get("https://remote.example/users/error")
    end

    test "rejects oversized response" do
      # Default max_payload_size from federation config; generate a body larger than 256KB
      big_body = String.duplicate("x", 256 * 1024 + 1)

      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, big_body)
      end)

      assert {:error, :response_too_large} =
               HTTPClient.get("https://remote.example/users/big")
    end

    test "halts a chunked body as soon as it exceeds the cap (never buffers it all)" do
      # 300 chunks of 1 KB = 300 KB > 256 KB cap. The collector must halt
      # mid-stream; a post-hoc byte_size check would have buffered it all.
      chunk = String.duplicate("y", 1024)

      Req.Test.stub(HTTPClient, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce_while(1..300, conn, fn _, conn ->
          case Plug.Conn.chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)
      end)

      assert {:error, :response_too_large} =
               HTTPClient.get("https://remote.example/users/chunked-big")
    end

    test "refuses a body whose declared content-length exceeds the cap" do
      Req.Test.stub(HTTPClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "999999999")
        |> Plug.Conn.send_resp(200, "tiny")
      end)

      assert {:error, :response_too_large} =
               HTTPClient.get("https://remote.example/users/lying-length")
    end

    test "honours a per-call :max_size on get_html/2" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("z", 2048))
      end)

      assert {:error, :response_too_large} =
               HTTPClient.get_html("https://remote.example/page", max_size: 1024)

      assert {:ok, %{body: body}} =
               HTTPClient.get_html("https://remote.example/page", max_size: 4096)

      assert byte_size(body) == 2048
    end
  end

  describe "get/2 redirects" do
    test "follows 301 redirect" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://remote.example/users/alice-moved")
          |> Plug.Conn.send_resp(301, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"type":"Person"}))
        end
      end)

      assert {:ok, %{status: 200, body: body}} =
               HTTPClient.get("https://remote.example/users/alice")

      assert body =~ "Person"
      assert Agent.get(agent, & &1) == 2
    end

    test "follows 302 redirect" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://remote.example/users/alice-found")
          |> Plug.Conn.send_resp(302, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"type":"Person"}))
        end
      end)

      assert {:ok, %{status: 200}} = HTTPClient.get("https://remote.example/users/alice")
    end

    test "follows 307 redirect" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://remote.example/users/alice-temp")
          |> Plug.Conn.send_resp(307, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"ok":true}))
        end
      end)

      assert {:ok, %{status: 200}} = HTTPClient.get("https://remote.example/users/alice")
    end

    test "follows 308 redirect" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://remote.example/users/alice-perm")
          |> Plug.Conn.send_resp(308, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"ok":true}))
        end
      end)

      assert {:ok, %{status: 200}} = HTTPClient.get("https://remote.example/users/alice")
    end

    test "returns error on too many redirects" do
      Req.Test.stub(HTTPClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://remote.example/loop")
        |> Plug.Conn.send_resp(301, "")
      end)

      assert {:error, :too_many_redirects} =
               HTTPClient.get("https://remote.example/loop")
    end

    test "returns http_error when Location header is missing on redirect" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 301, "")
      end)

      assert {:error, {:http_error, 301, ""}} =
               HTTPClient.get("https://remote.example/users/alice")
    end

    test "does not carry signature headers across a redirect" do
      # A signature is computed over one `(request-target)` and `host`, so it
      # is meaningless anywhere else — but the header list was forwarded
      # verbatim to every hop, handing a third party a valid site-key
      # signature and our `keyId` over a request they never received. A
      # redirect is the cheapest way for one server to collect our signed
      # credentials addressed to another.
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(HTTPClient, fn conn ->
        call = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        send(test_pid, {:hop, call, conn.req_headers})

        if call == 0 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/users/alice")
          |> Plug.Conn.send_resp(302, "")
        else
          Plug.Conn.send_resp(conn, 200, ~s({"type":"Person"}))
        end
      end)

      {_public, private} = Baudrate.Federation.KeyStore.generate_keypair()

      assert {:ok, %{status: 200}} =
               HTTPClient.signed_get(
                 "https://remote.example/users/alice",
                 private,
                 "https://local.example/ap/site#main-key",
                 headers: [{"digest", "SHA-256=deadbeef"}]
               )

      assert_received {:hop, 0, first_headers}
      assert List.keyfind(first_headers, "signature", 0), "the first hop is signed"
      assert List.keyfind(first_headers, "date", 0)
      assert List.keyfind(first_headers, "digest", 0)

      assert_received {:hop, 1, second_headers}
      names = Enum.map(second_headers, fn {name, _} -> String.downcase(name) end)

      refute "signature" in names, "the redirect target must not receive our signature"
      refute "digest" in names
      refute "date" in names

      # The request itself still happened, with the headers that are not
      # bound to the original request line.
      assert "accept" in names
      assert "user-agent" in names
    end
  end

  describe "post/3" do
    test "caps the response body like GET does" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("x", 256 * 1024 + 1))
      end)

      assert {:error, :response_too_large} =
               HTTPClient.post("https://remote.example/inbox", "{}")

      assert {:error, :response_too_large} =
               HTTPClient.post_raw("https://remote.example/push", "{}", [])
    end

    test "returns body on 202" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 202, "")
      end)

      assert {:ok, %{status: 202}} =
               HTTPClient.post("https://remote.example/inbox", "{}")
    end

    test "returns http_error on 401" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 401, "Unauthorized")
      end)

      assert {:error, {:http_error, 401, "Unauthorized"}} =
               HTTPClient.post("https://remote.example/inbox", "{}")
    end
  end

  describe "post_raw/3" do
    test "returns body on 201 with caller-supplied headers" do
      Req.Test.stub(HTTPClient, fn conn ->
        assert {"content-type", "application/octet-stream"} in conn.req_headers
        refute {"content-type", "application/activity+json"} in conn.req_headers
        Plug.Conn.send_resp(conn, 201, "Created")
      end)

      assert {:ok, %{status: 201, body: "Created"}} =
               HTTPClient.post_raw("https://remote.example/push", "payload", [
                 {"content-type", "application/octet-stream"}
               ])
    end

    test "returns http_error on 410" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, {:http_error, 410, "Gone"}} =
               HTTPClient.post_raw("https://remote.example/push", "payload")
    end
  end

  describe "private_ip?/1" do
    test "127.x.x.x is private" do
      assert HTTPClient.private_ip?({127, 0, 0, 1})
      assert HTTPClient.private_ip?({127, 255, 255, 255})
    end

    test "10.x.x.x is private" do
      assert HTTPClient.private_ip?({10, 0, 0, 1})
      assert HTTPClient.private_ip?({10, 255, 255, 255})
    end

    test "172.16-31.x.x is private" do
      assert HTTPClient.private_ip?({172, 16, 0, 1})
      assert HTTPClient.private_ip?({172, 31, 255, 255})
    end

    test "172.15.x.x and 172.32.x.x are not private" do
      refute HTTPClient.private_ip?({172, 15, 0, 1})
      refute HTTPClient.private_ip?({172, 32, 0, 1})
    end

    test "192.168.x.x is private" do
      assert HTTPClient.private_ip?({192, 168, 0, 1})
      assert HTTPClient.private_ip?({192, 168, 255, 255})
    end

    test "169.254.x.x (link-local) is private" do
      assert HTTPClient.private_ip?({169, 254, 0, 1})
      assert HTTPClient.private_ip?({169, 254, 255, 255})
    end

    test "0.x.x.x is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0})
      assert HTTPClient.private_ip?({0, 1, 2, 3})
    end

    test "IPv6 loopback ::1 is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 fc00::/7 (unique local) is private" do
      assert HTTPClient.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0xFDFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 fe80::/10 (link-local) is private" do
      assert HTTPClient.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 ff00::/8 (multicast) is private" do
      assert HTTPClient.private_ip?({0xFF00, 0, 0, 0, 0, 0, 0, 0})
      assert HTTPClient.private_ip?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0xFFFF, 0, 0, 0, 0, 0, 0, 0})
    end

    test "public IPv4 addresses return false" do
      refute HTTPClient.private_ip?({8, 8, 8, 8})
      refute HTTPClient.private_ip?({93, 184, 216, 34})
      refute HTTPClient.private_ip?({1, 1, 1, 1})
    end

    test "IPv6 unspecified address :: is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "public IPv6 addresses return false" do
      refute HTTPClient.private_ip?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})
      refute HTTPClient.private_ip?({0x2A00, 0x1450, 0, 0, 0, 0, 0, 1})
      # 2001::/32 is Teredo, but the rest of 2001::/16 is ordinary global unicast.
      refute HTTPClient.private_ip?({0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888})
    end

    test "IPv4-mapped IPv6 ::ffff:127.0.0.1 is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "IPv4-mapped IPv6 ::ffff:10.0.0.1 is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
    end

    test "IPv4-mapped IPv6 ::ffff:192.168.1.1 is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
    end

    test "IPv4-mapped IPv6 ::ffff:8.8.8.8 is public" do
      refute HTTPClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "NAT64 64:ff9b::127.0.0.1 is private" do
      assert HTTPClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
    end

    test "NAT64 64:ff9b::192.168.1.1 is private" do
      assert HTTPClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0xC0A8, 0x0101})
    end

    test "NAT64 64:ff9b::8.8.8.8 (public embedded IPv4) is public" do
      refute HTTPClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "IPv4-compatible IPv6 ::127.0.0.1 is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0, 0x7F00, 0x0001})
    end

    test "IPv4-compatible IPv6 ::169.254.0.1 (link-local) is private" do
      assert HTTPClient.private_ip?({0, 0, 0, 0, 0, 0, 0xA9FE, 0x0001})
    end

    test "6to4 2002::/16 re-checks the embedded IPv4" do
      # 2002:7f00:1:: is 127.0.0.1 behind a 6to4 relay — the same tunnelled
      # bypass as NAT64 and ::ffff:, one prefix further out.
      assert HTTPClient.private_ip?({0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0})
      assert HTTPClient.private_ip?({0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 0})
      assert HTTPClient.private_ip?({0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 0})
      # A 6to4 address wrapping a genuinely public IPv4 stays reachable.
      refute HTTPClient.private_ip?({0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 0})
    end

    test "Teredo 2001::/32 is refused outright" do
      # The embedded client IPv4 is the bitwise complement of the last group
      # pair rather than a plain copy, so the prefix is rejected wholesale.
      assert HTTPClient.private_ip?({0x2001, 0, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0x2001, 0, 0x4136, 0xE378, 0x8000, 0, 0, 0})
    end

    test "IPv6 documentation and discard prefixes are private" do
      assert HTTPClient.private_ip?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0x0100, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4 special-purpose ranges are private" do
      # RFC 6890 IETF protocol assignments, RFC 5737 TEST-NET-1/2/3,
      # RFC 2544 benchmarking. None is globally routable, and the benchmarking
      # range is routed to lab equipment on some networks.
      assert HTTPClient.private_ip?({192, 0, 0, 170})
      assert HTTPClient.private_ip?({192, 0, 2, 1})
      assert HTTPClient.private_ip?({198, 51, 100, 1})
      assert HTTPClient.private_ip?({203, 0, 113, 1})
      assert HTTPClient.private_ip?({198, 18, 0, 1})
      assert HTTPClient.private_ip?({198, 19, 255, 255})
    end

    test "NAT64 local-use prefix 64:ff9b:1::/48 is refused outright" do
      # RFC 8215. Unlike the well-known prefix, the embedded IPv4 sits at a
      # deployment-chosen offset, so there is nothing reliable to decode — and
      # an address in this range is by definition behind a local translator.
      assert HTTPClient.private_ip?({0x64, 0xFF9B, 1, 0, 0, 0, 0x0808, 0x0808})
      assert HTTPClient.private_ip?({0x64, 0xFF9B, 1, 0xFFFF, 0, 0, 0, 1})

      # Adjacent, outside the /48: 64:ff9b:2:: is not reserved for NAT64, and
      # 64:ff9b:: with a public embedded IPv4 stays reachable.
      refute HTTPClient.private_ip?({0x64, 0xFF9B, 2, 0, 0, 0, 0x0808, 0x0808})
      refute HTTPClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "IPv6 fec0::/10 (deprecated site-local) is private" do
      # Deprecated by RFC 3879 but still routed on some networks, so a host
      # resolving here is still reaching inside.
      assert HTTPClient.private_ip?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      assert HTTPClient.private_ip?({0xFEFF, 0, 0, 0, 0, 0, 0, 1})

      # Both neighbours of fec0::/10 were already denied (fe80::/10 below,
      # ff00::/8 above), so the check that it is still a range and not a
      # blanket `fe*` is the fe00::/9 gap between fc00::/7 and fe80::/10.
      refute HTTPClient.private_ip?({0xFE00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "192.88.99.0/24 (deprecated 6to4 relay anycast) is private" do
      # RFC 7526.
      assert HTTPClient.private_ip?({192, 88, 99, 1})
      assert HTTPClient.private_ip?({192, 88, 99, 255})

      refute HTTPClient.private_ip?({192, 88, 98, 1})
      refute HTTPClient.private_ip?({192, 88, 100, 1})
    end

    test "addresses adjacent to the new IPv4 ranges stay public" do
      refute HTTPClient.private_ip?({192, 0, 1, 1})
      refute HTTPClient.private_ip?({192, 0, 3, 1})
      refute HTTPClient.private_ip?({198, 17, 255, 255})
      refute HTTPClient.private_ip?({198, 20, 0, 1})
      refute HTTPClient.private_ip?({198, 51, 101, 1})
      refute HTTPClient.private_ip?({203, 0, 114, 1})
    end
  end
end
