defmodule BaudrateWeb.Plugs.RealIpTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.RealIp

  defp conn_with_ip(ip_tuple) do
    %Plug.Conn{remote_ip: ip_tuple}
  end

  defp put_header(conn, key, value) do
    %{conn | req_headers: [{key, value} | conn.req_headers]}
  end

  describe "call/2 with no config" do
    test "passes through unchanged when no header configured" do
      # Default config: no header
      Application.delete_env(:baudrate, RealIp)

      conn = conn_with_ip({10, 0, 0, 1})
      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end
  end

  describe "call/2 with x-forwarded-for header" do
    setup do
      # These tests use a peer of 10.0.0.1, so the proxy has to be trusted
      # explicitly — the default allow-list is loopback only.
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["10.0.0.0/8"]
      )

      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "extracts first IP from x-forwarded-for" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "203.0.113.50, 70.41.3.18, 150.172.238.178")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 50}
    end

    test "handles single IP in header" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "203.0.113.50")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 50}
    end

    test "handles IPv6 address" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "2001:db8::1")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end

    test "ignores unparseable IP and keeps original" do
      conn =
        conn_with_ip({10, 0, 0, 1})
        |> put_header("x-forwarded-for", "not-an-ip")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end

    test "keeps original IP when header is absent" do
      conn = conn_with_ip({10, 0, 0, 1})
      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {10, 0, 0, 1}
    end
  end

  describe "trusted_proxies allow-list" do
    setup do
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "ignores header when peer is not in trusted_proxies" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["127.0.0.1"]
      )

      conn =
        conn_with_ip({203, 0, 113, 99})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 99}
    end

    test "honors header when peer matches an exact trusted_proxy entry" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["127.0.0.1", "::1"]
      )

      conn =
        conn_with_ip({127, 0, 0, 1})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {1, 2, 3, 4}
    end

    test "honors header when peer is inside a trusted CIDR" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["10.0.0.0/8"]
      )

      conn =
        conn_with_ip({10, 5, 6, 7})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {1, 2, 3, 4}
    end

    test "ignores header when peer is outside the trusted CIDR" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["10.0.0.0/8"]
      )

      conn =
        conn_with_ip({172, 16, 0, 1})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {172, 16, 0, 1}
    end
  end

  describe "extract_peer_ip/1 (shared LiveView helper)" do
    defp fake_socket(connect_info) do
      %Phoenix.LiveView.Socket{private: %{connect_info: connect_info}}
    end

    setup do
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "returns IP from x-forwarded-for when header is configured" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "203.0.113.50, 10.0.0.1"}],
          peer_data: %{address: {127, 0, 0, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "203.0.113.50"
    end

    test "returns single IP from x-forwarded-for" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "198.51.100.42"}],
          peer_data: %{address: {127, 0, 0, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "198.51.100.42"
    end

    test "falls back to peer_data when no header configured" do
      Application.delete_env(:baudrate, RealIp)

      socket =
        fake_socket(%{
          x_headers: [{"x-forwarded-for", "203.0.113.50"}],
          peer_data: %{address: {192, 168, 1, 1}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "192.168.1.1"
    end

    test "falls back to peer_data when header configured but absent in x_headers" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          x_headers: [],
          peer_data: %{address: {10, 0, 0, 5}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "10.0.0.5"
    end

    test "falls back to peer_data when x_headers is nil" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: {10, 0, 0, 5}}
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "10.0.0.5"
    end

    test "returns unknown when neither source is available" do
      Application.delete_env(:baudrate, RealIp)

      socket = fake_socket(%{})

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "unknown"
    end

    test "does not honor x-forwarded-for from an untrusted peer" do
      # The LiveView path must reach the same verdict as the plug path.
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: {203, 0, 113, 9}},
          x_headers: [{"x-forwarded-for", "1.2.3.4"}]
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "203.0.113.9"
    end
  end

  # Production binds the endpoint to the IPv6 any-address, so nginx on
  # 127.0.0.1 connects as ::ffff:127.0.0.1. Before unmapping, that never
  # matched "127.0.0.1": X-Forwarded-For was ignored and every visitor shared
  # the proxy's rate-limit bucket and logged IP.
  describe "IPv4-mapped IPv6 peers" do
    @mapped_loopback {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}

    setup do
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "unmap_ipv4/1 converts ::ffff:a.b.c.d and leaves everything else alone" do
      assert RealIp.unmap_ipv4(@mapped_loopback) == {127, 0, 0, 1}
      assert RealIp.unmap_ipv4({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}) == {203, 0, 113, 9}
      assert RealIp.unmap_ipv4({127, 0, 0, 1}) == {127, 0, 0, 1}
      assert RealIp.unmap_ipv4({0, 0, 0, 0, 0, 0, 0, 1}) == {0, 0, 0, 0, 0, 0, 0, 1}
      # NAT64 embeds an IPv4 address but is a different host: not unmapped.
      nat64 = {0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001}
      assert RealIp.unmap_ipv4(nat64) == nat64
      assert RealIp.unmap_ipv4(nil) == nil
    end

    test "a mapped loopback proxy is trusted by the default allow-list" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      assert RealIp.peer_trusted?(@mapped_loopback)
      assert RealIp.peer_trusted?("::ffff:127.0.0.1")

      conn =
        conn_with_ip(@mapped_loopback)
        |> put_header("x-forwarded-for", "198.51.100.23")

      assert RealIp.call(conn, RealIp.init([])).remote_ip == {198, 51, 100, 23}
    end

    test "a mapped untrusted peer cannot spoof its IP, and is stored unmapped" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")
      mapped_public = {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}

      refute RealIp.peer_trusted?(mapped_public)

      conn =
        conn_with_ip(mapped_public)
        |> put_header("x-forwarded-for", "1.2.3.4")

      assert RealIp.call(conn, RealIp.init([])).remote_ip == {203, 0, 113, 9}
    end

    test "NAT64 and 6to4 forms of a trusted IPv4 address are not trusted" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["127.0.0.1", "10.0.0.0/8"]
      )

      refute RealIp.peer_trusted?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
      refute RealIp.peer_trusted?({0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1})
    end

    test "trusted_proxies entries written in mapped form match unmapped peers" do
      Application.put_env(:baudrate, RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["::ffff:192.0.2.10", "::ffff:10.0.0.0/104"]
      )

      assert RealIp.peer_trusted?({192, 0, 2, 10})
      assert RealIp.peer_trusted?({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x020A})
      assert RealIp.peer_trusted?({10, 20, 30, 40})
      refute RealIp.peer_trusted?({11, 0, 0, 1})
    end

    test "a mapped client address in the header is stored unmapped" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      conn =
        conn_with_ip({127, 0, 0, 1})
        |> put_header("x-forwarded-for", "::ffff:198.51.100.23")

      assert RealIp.call(conn, RealIp.init([])).remote_ip == {198, 51, 100, 23}
    end

    test "the LiveView helper honors the header behind a mapped loopback proxy" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: @mapped_loopback},
          x_headers: [{"x-forwarded-for", "198.51.100.23"}]
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "198.51.100.23"
    end

    test "the LiveView helper reports an untrusted mapped peer unmapped" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}},
          x_headers: [{"x-forwarded-for", "1.2.3.4"}]
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "203.0.113.9"
    end

    test "the LiveView helper ignores an unparseable header value" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      socket =
        fake_socket(%{
          peer_data: %{address: {127, 0, 0, 1}},
          x_headers: [{"x-forwarded-for", "not-an-ip\nforged=log"}]
        })

      assert BaudrateWeb.Helpers.extract_peer_ip(socket) == "127.0.0.1"
    end
  end

  describe "fail-closed default" do
    setup do
      on_exit(fn -> Application.delete_env(:baudrate, RealIp) end)
    end

    test "an unconfigured allow-list does not trust an arbitrary peer" do
      # Regression test: this used to be a trust-everything branch, letting any
      # client spoof its IP and defeat every per-IP rate limit.
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      conn =
        conn_with_ip({203, 0, 113, 9})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {203, 0, 113, 9}
    end

    test "an unconfigured allow-list still honors a loopback peer" do
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for")

      conn =
        conn_with_ip({127, 0, 0, 1})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {1, 2, 3, 4}
    end

    test "an empty trusted_proxies list trusts nobody" do
      # `trusted_proxies: []` means what it says; it used to mean the opposite.
      Application.put_env(:baudrate, RealIp, header: "x-forwarded-for", trusted_proxies: [])

      conn =
        conn_with_ip({127, 0, 0, 1})
        |> put_header("x-forwarded-for", "1.2.3.4")

      result = RealIp.call(conn, RealIp.init([]))
      assert result.remote_ip == {127, 0, 0, 1}
    end

    test "peer_trusted?/1 defaults to loopback only" do
      Application.delete_env(:baudrate, RealIp)

      assert RealIp.peer_trusted?({127, 0, 0, 1})
      assert RealIp.peer_trusted?({0, 0, 0, 0, 0, 0, 0, 1})
      refute RealIp.peer_trusted?({10, 0, 0, 1})
      refute RealIp.peer_trusted?({203, 0, 113, 9})
    end
  end
end
