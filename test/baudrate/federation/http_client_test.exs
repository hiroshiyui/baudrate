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

      assert {:error, {:http_error, 404}} =
               HTTPClient.get("https://remote.example/users/missing")
    end

    test "returns http_error on 500" do
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500}} =
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

      assert {:error, {:http_error, 301}} =
               HTTPClient.get("https://remote.example/users/alice")
    end
  end

  describe "post/3" do
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

      assert {:error, {:http_error, 401}} =
               HTTPClient.post("https://remote.example/inbox", "{}")
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
      refute HTTPClient.private_ip?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      refute HTTPClient.private_ip?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})
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
  end
end
